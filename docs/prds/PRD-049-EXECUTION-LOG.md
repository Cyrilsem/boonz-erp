# PRD-049 Execution Log — Packing + Returns FE stabilization

Date: 2026-06-22. FE-only (+ one backend RPC for Phase C). Existing RPCs, no new `.from()` writes (S1). Per-phase gate: diff + phone QA, then CS promotes. Phone QA + promotion are CS steps (performed on the Vercel previews); the assistant did not run phone QA. CS working-tree drift preserved throughout (isolated git worktrees + byte-preserving save/restore for build checks).

## Status by phase — ALL SHIPPED to main 2026-06-22 (CS-authorized promote)

| Phase | Issue(s) | Status                                                                         | Branch / artifact                                                   |
| ----- | -------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------- |
| A     | 1,2,3    | SHIPPED to main (grafted onto current origin/main; Vercel prod)                | merged via `prd-049-ship`                                           |
| B     | 4        | SHIPPED to main (contains A)                                                   | merged via `prd-049-ship`                                           |
| C     | 5        | APPLIED to prod (`edit_transfer_qty`, Cody ✅) + FE wired (DispatchEditDialog) | `supabase/migrations/20260622070000_prd049_c_edit_transfer_qty.sql` |
| D     | 6        | SHIPPED to main (Vercel prod)                                                  | merged via `prd-049-ship`                                           |

Note: A/B were re-grafted onto current origin/main (their original `feat/*` branches were based on the older `2111dda` and would have reverted 43 files of newer main work; origin/main's packing page was byte-identical to that base, so the graft was conflict-free). Phase C FE wiring (`editTransferQty` action + `DispatchEditDialog` qty-tab routing for `sourceKind='m2m'`) shipped in the same commit. CS working-tree drift never committed.

## Phase A — packing qty persist + skip + Finish gate (issues 1,2,3)

Root cause (1 bug behind 1 & 3): `submitSkip` and `handleMarkNotFilled` called `fetchData()` after their RPC, rebuilding `lines` + `batchPickQtys` from the DB and wiping locally-staged pack actions + edited pick quantities on OTHER lines (packing is staged locally, committed at Finish). Fix: drop those refetches (skip moves the line into the Skipped panel surgically; not_filled relies on local action + the already-persisted `pack_outcome`). Issue 2: skip reason auto-pads to >=10 chars instead of blocking a category-only skip; RPC errors surfaced. Diff +38/-2. tsc + build clean. `scripts/prd049_phaseA_logic_check.mjs` 16/16 (incl. 2 that reproduce the old refetch-clobber).

## Phase B — swap per-variant qty/skip (issue 4)

Per-variant editing already existed (per-batch inputs); `qty<=0` already excluded zeroed flavors from `pack_dispatch_line` picks. Added: (1) a per-variant **"Set 0"** button (zeros a flavor -> excluded from picks -> never moves to pod inventory); (2) preserve pending mix-variant edits across the **"Save & come back"** refetch (snapshot `batchPickQtys`, re-apply over the fresh FIFO init; committed lines have disabled inputs so the overlay is inert). PRD-047 one-tap swap confirmed already live on prod (`c7ac999`, promoted `58a72e8`). Diff +48/-2. tsc + build clean.

## Phase C — M2M transfer-with-edit (issue 5) — backend RPC, migration FILE only

Trace: the edit-qty -> pick-destination -> apply flow is in `DispatchEditDialog` -> `dispatch-edits` actions -> RPCs; the FE wiring is correct. Root cause is backend: `edit_dispatch_qty` edits a SINGLE `refill_dispatching` row, but an M2M transfer is a pair (Remove@source + Add New@dest) sharing `m2m_transfer_id` carrying the same quantity. Editing one leg desyncs the pair ("both legs correct" fails). Per the FE-only rule, this is not an FE hack (sequential FE calls cannot keep the pair atomic).

Solution (Dara design ✅, Cody ✅ — Articles 1,4,8,12,14): new DEFINER `edit_transfer_qty(p_dispatch_id, p_new_qty, p_edit_role, p_reason)` that locks the whole pair (ORDER BY dispatch*id FOR UPDATE), refuses if either leg is packed/picked_up/item_added, updates BOTH legs' quantity (+ original_quantity/edit_count/last_edited*\*) in one transaction, and audits each leg (`refill_dispatching_edit_log` edit_kind 'qty' + transfer context in jsonb; generic `write_audit_log` via `app.via_rpc`). Preserves `m2m_transfer_id`/`is_m2m`/`source_origin` so `block_orphan_internal_transfer` stays quiet; `conserve_split` skips is_m2m; `flag_remove` needs is_m2m=false. Does NOT make `edit_dispatch_qty` m2m-aware (CS decision).

**Migration FILE only — NOT applied.** Pending CS apply via MCP, then Stax wires the transfer-edit dialog to call `edit_transfer_qty` for M2M lines (FE, existing RPC, no `.from()` writes), preview, phone QA (edit a transfer qty + destination + apply -> completes, both legs correct, no guard error).

## Phase D — returns expiry-split (issue 6)

`PendingRemoveApprovalsPanel` already sent `p_batch_breakdown` to `wh_approve_remove_receipt` but only ever as a single-element array. Added a **"Split by expiry"** mode (parallel to Split by variant, mutually exclusive): the operator enters one `{qty, expiry}` row per physical batch; the panel validates the rows total the verified qty, builds a MULTI-element `p_batch_breakdown`, and calls the SAME existing `wh_approve_remove_receipt` (each `{expiry, qty}` credited to its own `warehouse_inventory` batch row). FE-only, no backend change. Diff +229/-6. tsc + build clean.

## CS gates remaining

1. **Apply Phase C:** `apply_migration 20260622070000_prd049_c_edit_transfer_qty`; verify `pg_proc` + smoke a scratch transfer; update `RPC_REGISTRY.md` + `CHANGELOG.md`. Then Stax FE wiring + preview + phone QA.
2. **Phone QA A/B/D** on their previews:
   - A: edited qty persists; short skip processes; last-line not_filled keeps Finish enabled.
   - B: per-flavor edit survives Save & come back; Set-0 flavor excluded from pod inventory.
   - D: a multi-expiry return credits each expiry to its own `warehouse_inventory` batch.
3. **Promote** (only after QA passes): merge `feat/prd-049-phase-b` (contains A) and `feat/prd-049-phase-d` -> main; Vercel builds prod. Commit only PRD-049 files; do not touch CS drift. (`prd-049-phase-a-packing` is superseded by `feat/prd-049-phase-a`.)

## Validation performed by the assistant (not a substitute for phone QA)

tsc clean + production build clean for A, B, D, and the Phase C file (compiled against the main checkout, CS drift restored byte-identical). Phase A logic test 16/16. Phase C RPC: Dara design + Cody constitutional ✅ (not applied).
