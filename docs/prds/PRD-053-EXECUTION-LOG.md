# PRD-053 EXECUTION LOG

## Phase A - stitch conservation (2026-06-23) — FILE authored + verified read-only; STOPPED for CS

**Migration FILE (not applied):** `supabase/migrations/20260624000000_prd053_a_stitch_conservation.sql`

### Live bodies fetched (pg_get_functiondef, never guessed)
- `stitch_pod_to_boonz(date,boolean)` — engine v26_multivariant_spread. Leak located in the `remove_lines` CTE: `... ELSE LEAST((FLOOR(pod_qty/variant_count)+remainder)::int, current_stock)::int END AS variant_final`. Exactly **1** `ELSE LEAST(` in the body (confirmed read-only), so the surgical replace is unambiguous; the DO-block RAISEs if the target is not found or the cap survives.
- `write_refill_plan(date,jsonb)` — writes `refill_plan_output` from the stitch lines (carries `quantity`, no expiry). So the leak (6) propagates stitch → refill_plan_output → refill_dispatching; `expiry_date` is assigned downstream in push.
- `push_plan_to_dispatch(date,text)` (v5) — reads `refill_plan_output`, writes one `refill_dispatching` row per line; REMOVE got `expiry_date=NULL` (pin is Refill/Add-only).

### Diff (what changed)
- **stitch_pod_to_boonz:** REMOVE child `... ELSE LEAST((dist)::int, current_stock)::int END` → `(dist)::int` (both internal_transfer and warehouse branches now size from the pod plan total; **no pod_inventory cap**). engine_version → `v27_remove_conservation`.
- **push_plan_to_dispatch:** new REMOVE/M2W branch — split `line.quantity` across the shelf's Active `v_pod_inventory_latest` batches FEFO (`take = LEAST(stock, remaining)`, `expiry_date = batch.expiration_date`), then one NULL-expiry "EXPIRY-TO-CONFIRM" line for the remainder; CONTINUE (skip the single-row insert). New end-of-function assert loops `check_pod_conservation(plan_date)` for this machine → on any row: INSERT `stitch_leakage` + RAISE (stop-ship). `rpc_version` → `v6_prd053_conservation`.
- **NEW:** `stitch_leakage` table; `check_pod_conservation(date)` read-only fn.

### AC verification (read-only against live data; NOTHING applied to prod)
- **AC-A1 — conservation parent = pod plan, not pod_inventory.** ✅ Replicated the new (uncapped) REMOVE distribution on VML-1004 A03 Ice Tea: OLD `LEAST(13,6)` = **6** (the leak); NEW = **13** = `parent_pod_qty`.
- **AC-A2 — REMOVE sized from plan, FEFO across known batches + NULL remainder.** ✅ Push split conserves to 13: with the Active 6-unit batch → 6 @ 2027-04-15 + 7 @ NULL; when that batch is Inactive (live data shifted mid-verify) → 13 @ NULL. Either way SUM(children) = 13. The "known batch" line only materialises when pod_inventory is Active at push time; conservation holds regardless.
- **AC-A3 — publish-time assert + telemetry + stop-ship.** ✅ `check_pod_conservation` run read-only against the current live state returns the leaking instruction: `parent_pod_qty=13, children_sum=6, delta=7`. The push assert RAISEs on this (full rollback = stop-ship) and logs the delta to `stitch_leakage`. After the uncap fix children_sum=13 → delta=0 → checker empty → assert passes.

### Cody verdict (per writer)
- `stitch_pod_to_boonz` (writer, modified): ✅ **Approve.** Art 1 (still builds lines for the canonical write_refill_plan; no new write path), Art 4 (app.via_rpc/rpc_name + operator_admin gate unchanged), Art 12 (forward-only CREATE OR REPLACE via DO-block on the live body, no _v2, guarded), Art 16 (removes a pod_inventory cap; introduces no inline metric re-derivation).
- `push_plan_to_dispatch` (writer, modified): ⚠️ **Approve with note.** Art 1/3 (the canonical plan→dispatch writer; extends its own INSERT, no foreign direct write), Art 4 (gates unchanged), Art 8 (split INSERTs ride the generic write_audit_log trigger via app.via_rpc), Art 12 (forward-only). **Note:** on a stop-ship RAISE the `stitch_leakage` INSERT rolls back with the abort (single-tx), so the persisted telemetry row is best-effort; the delta is durable in the RAISE message + Postgres log, and `check_pod_conservation` lets a monitor/cron persist a row non-blockingly. CS to decide whether to layer a durable autonomous-tx telemetry write.
- `check_pod_conservation` (read-only helper): ✅ **Approve.** SECURITY INVOKER, no writes.
- `stitch_leakage` (new table): ✅ **Approve.** Art 2 (RLS on), Art 7 (append-only — no UPDATE/DELETE policy; DEFINER-only writes). Not a protected entity.

**STOP — awaiting CS review before apply.** Nothing applied to prod; migration is a FILE only.

## Phase B - field per-expiry split, TOTAL LOCKED (2026-06-23) — FILE authored + verified read-only

**Migration FILE (not applied):** `supabase/migrations/20260624000100_prd053_b_set_dispatch_breakdown.sql`

- **Live body fetched:** `receive_dispatch_line(p_dispatch_id uuid, p_filled_quantity numeric, p_received_by uuid, p_batch_breakdown jsonb)`. Its `p_batch_breakdown` shape = a jsonb array `[{ "qty": <number>, "expiry": "<date>"|null, "wh_inventory_id": <uuid>|null }, ...]` validated as `SUM(qty) = filled_quantity`. `refill_dispatching.driver_confirmed_breakdown` (jsonb) is the store.
- **SQL / diff:** NEW `set_dispatch_line_breakdown(p_dispatch_id, p_batch_breakdown, p_edit_role, p_reason)` — DEFINER, app.via_rpc/rpc_name, role gate. Validates each entry (qty>=0; expiry optional = to-confirm) and enforces `SUM(qty) = refill_dispatching.quantity` (the total is immutable). On pass: `UPDATE refill_dispatching SET driver_confirmed_breakdown = p_batch_breakdown, expiry_date = earliest, edit_count+1`. Never changes quantity/action/status. Locked once item_added/dispatched.
- **AC-B verification (read-only):** the example split `[{qty:6,expiry:2027-04-15},{qty:7,expiry:2027-08-01}]` sums to **13** = the line total (saved); a mismatch (e.g. 11) RAISEs. All written columns exist with correct types (`driver_confirmed_breakdown` jsonb, `last_edited_*`, `edit_count` int) → applies cleanly. A full driver→split→save round-trip is a rolled-back test once applied.
- **Cody:** ✅ **Approve.** Art 1 (an edit writer on refill_dispatching, peer of skip_dispatch_line / edit_transfer_qty — no foreign write), Art 4 (gates + SUM==total validation), Art 5 (no status/action/qty flip — only the expiry distribution), Art 8 (generic write_audit_log trigger + edit_count), Art 12 (forward-only).
- **FE (Stax) follow-up (specified):** add a per-expiry breakdown editor on the driver dispatching/packing line that calls `set_dispatch_line_breakdown` (distinct from the WH returns-approval panel). The total field is read-only (locked); only the per-expiry rows are editable; client also asserts SUM == total before submit.

## Phase C - flagged driver additions to Head Office (2026-06-23) — FILE authored + verified read-only

**Migration FILE (not applied):** `supabase/migrations/20260624000200_prd053_c_flagged_driver_additions.sql`

- **Dara — column/flag design (additive, forward-only) on refill_dispatching:** `needs_review bool default false`, `review_reason text`, `review_status text default 'none'` (none|pending|accepted|rejected), `reviewed_by uuid`, `reviewed_at timestamptz`, + partial index `WHERE needs_review AND review_status='pending'`. RLS already enabled on refill_dispatching (confirmed) → new columns covered, no RLS change.
- **SQL / diff:** (1) `driver_add_flagged_row(...)` — wrapper that COMPOSES the canonical `add_dispatch_row` (12-arg signature confirmed to match) then stamps `needs_review=true / review_reason='driver_addition' / review_status='pending'`; never blocks. A defaulted-param overload of add_dispatch_row was rejected (overload foot-gun, CLAUDE.md), hence a wrapper. (2) `review_driver_addition(dispatch_id, decision, reason)` — operator_admin/superadmin/manager records accepted|rejected (reviewed_by/at); does NOT delete or cut qty (rejection is actioned via the existing skip/cancel writer). (3) `v_driver_addition_review_queue` — the Head Office queue (pending flagged adds).
- **AC-C verification (read-only):** `add_dispatch_row` 12-arg signature matches the wrapper call exactly; `needs_review` absent → clean ALTER; refill_dispatching RLS enabled. By construction: a driver addition is INSERTED by add_dispatch_row (recorded) then flagged (needs_review=true) and appears in `v_driver_addition_review_queue`; nothing blocked. Full "add 2 extra → 15 total → 2 flagged" round-trip is a rolled-back test once applied.
- **Cody:** ✅ **Approve.** Additive columns under existing RLS (Art 2/12); `driver_add_flagged_row` composes the canonical writer (Art 1) + an audited flag stamp (Art 4/8), never blocks; `review_driver_addition` is role-gated (Art 4), records the decision only — no delete, no qty cut.
- **FE (Stax) follow-up (specified):** route the packing-page "Add product" beyond-plan path through `driver_add_flagged_row`; add a Head Office review screen reading `v_driver_addition_review_queue` with Accept/Reject calling `review_driver_addition`.

**STOP — all three phases delivered as FILES (nothing applied to prod). Awaiting CS to apply (per phase) + the Stax FE wiring for B/C.**
