---
id: PRD-018-refill-pipeline
program: PROGRAM-2026-06-01
title: Amendable committed plans — a granular, gated, non-destructive post-commit edit layer
status: Proposed
severity: P1
reported: 2026-06-01
source: 2026-06-01 live conductor session (6-machine route: GRIT Plaay launch + VOXMM VOX-source tagging). Failed FE Commit left the plan half-written and every correction path was blocked or destructive.
routing:
  [
    Dara (schema: status machine, RELOCATE action, unique constraints, in-stock variant view),
    Cody (constitution: new canonical writers on pod_refill_plan + refill_dispatching, Articles 4/6/9/12/14),
    Stax (FE Commit transactionality + truthful banner, packing pre-pickup edit UI),
  ]
---

## TL;DR

The refill pipeline is built for one clean pass: cron drafts the plan, CS reviews, CS clicks Commit once, drivers pick it up. That happy path works. The moment anything deviates (a Commit that fails halfway, a manual shelf edit, a launch placement, a wrong variant, a same-day correction), the system has no safe, granular way to amend a plan that has already been stitched. Every correction route is either destructive (full reset that wipes hand-made rows) or hard-blocked (status gate, pickup gate, or auth gate). This PRD specifies the amendment layer that makes a committed plan editable without a full rebuild.

The one-line root cause: **`pod_refill_plan` has a one-directional status machine (draft to approved to stitched) with no sanctioned reverse, and `inject_swap` is the only pre-pickup amend tool, but it bypasses the gates and is buggy.** Everything else in this PRD follows from that.

---

## The session that exposed this (2026-06-01)

CS scoped a 6-machine route (GRIT, HUAWEI, USH, VML-1003, VML-1004, VOXMM-1013), built the engine draft in chat, and added a GRIT Plaay launch (remove Vitamin Well from A05/A08, relocate it onto the other VW shelves, add Plaay Truffles and Plaay Tablets). Then this happened:

1. The FE **Commit chain failed silently**. `pod_refill_plan` showed 4 rows flipped to `stitched` while `refill_plan_output` and `refill_dispatching` had **zero** rows for the date. The FE banner read "Plan committed for 2026-06-02. Drivers will see it" with `?` counts. Nothing was live. Drivers would have seen nothing.

2. The same partial run **reverted two manual edits** (the A05/A09 Vitamin Well stops went from qty 0 back to 1 and 3), because `engine_finalize_pod` rebuilds `pod_refill_plan` from the intermediate `pod_refills` table and the hand-made stops live only in `pod_refill_plan`.

3. The 4 phantom-`stitched` rows **could not be reopened**. `restore_pod_refill_row` only handles `superseded` to `draft`. `reset_and_restitch` re-runs finalize from `pod_refills`, which would have wiped the Plaay placement entirely. There is no `stitched` to `draft/approved` path that preserves hand-made rows.

4. Re-applying the GRIT swap had to go through `inject_swap`, which writes straight to `refill_plan_output` and `refill_dispatching` as `approved`, **bypassing Gate 1 and Gate 2**.

5. `inject_swap`'s REMOVE quantity was **wrong**: it reads `current_stock` for the product with `LIMIT 1` and no shelf scoping, so for a product on multiple shelves (Vitamin Well sits on 5 GRIT shelves) it grabbed an arbitrary shelf's stock (9) instead of the actual A05 (3) and A08 (4).

6. `inject_swap` **cannot split a multi-variant Mix** (Plaay Truffles maps to 3 boonz SKUs, Tablets to 2). It takes one boonz product per shelf. Its REMOVE row also writes `boonz_product_id = NULL`, so the packing FE renders the product as a dash.

7. There is **no intra-pod RELOCATE action**. Moving Vitamin Well from A05/A08 onto A09/A10/A11 within the same machine could only be expressed as a REMOVE plus a free-text comment, and REMOVE semantically means return-to-warehouse.

8. Correcting the dead-stock **Barebells variants** (the stitch even-split landed 2 of 5 units on Cookies & Cream and White Almond Chocolate, both 0 in active WH) was **blocked**: `edit_dispatch_product` refuses any product change until the line is picked up ("driver edits blocked").

9. **VOX-source tagging** the four VOXMM lines was **blocked**: `mark_dispatch_vox_sourced` hard-requires `auth.uid()` and throws on a service or automated context, unlike the newer `edit_dispatch_*` RPCs that take `p_edit_role` as a parameter.

Net: the route shipped, but four legitimate corrections had to be punted to the FE, and the only reason the plan recovered at all was a long manual workaround. None of this was the operator doing something exotic. It was a launch placement and a few same-day edits.

---

## Root cause analysis

The defects cluster into four families. Each gets an ID used in Acceptance Criteria.

### Family A: one-directional status machine (the keystone)

- **R-A1.** `pod_refill_plan.status` flows `draft to approved to stitched` with no sanctioned reverse for `stitched`. `restore_pod_refill_row` only covers `superseded to draft`. So a stitched row, or a phantom-stitched row with no output, is a dead end.
- **R-A2.** The only way to recycle a stitched plan is `reset_and_restitch`, which **re-derives from `pod_refills`** and therefore destroys any row that was added or edited directly in `pod_refill_plan` (manual ADD_NEW, REMOVE, stop). Manual work and engine output cannot coexist through a reset.
- **R-A3.** `engine_finalize_pod` reverts manual edits for the same reason (it rebuilds from `pod_refills`). A manual stop or qty change can be silently undone by any later finalize, including the one inside the FE Commit chain.

### Family B: the Commit chain is not transactional

- **R-B1.** The FE Commit chain (`approve_pod_refill_plan` to `engine_finalize_pod` to `stitch_pod_to_boonz(false)` to `approve_refill_plan`) has **no rollback**. A failure mid-chain leaves pod rows flipped to `stitched` with no `refill_plan_output` behind them. (Known Stax note: "no rollback on commit chain failure." This is the incident that note predicted.)
- **R-B2.** The banner reports success optimistically. It printed "Plan committed. Drivers will see it" with `?` counts while the output and dispatch tables were empty. The banner must reflect verified row counts, not intent.

### Family C: `inject_swap` is the wrong shape for amendment

- **R-C1.** It bypasses Gate 1 and Gate 2 (writes `refill_plan_output` and `refill_dispatching` directly as `approved`).
- **R-C2.** REMOVE quantity is read with `LIMIT 1` and no shelf scoping, so it is wrong for any product present on more than one shelf.
- **R-C3.** It takes a single boonz product and cannot even-split a multi-variant Mix.
- **R-C4.** Its REMOVE row sets `boonz_product_id = NULL` (renders as a dash) and is semantically return-to-warehouse, with no relocate option.

### Family D: pre-pickup edits and auth are inconsistent

- **R-D1.** Product and variant changes on a committed line are **post-pickup only** (`edit_dispatch_product` blocks "not picked up"). There is no pre-pickup product/variant correction for a stitched plan short of a full reset.
- **R-D2.** The stitch even-split picks variants from `product_mapping` **without an in-stock filter**, so it routes units to variants with 0 active warehouse stock (Barebells incident repeats from PRD-002 / the Barebells variant incident).
- **R-D3.** Auth is inconsistent. Newer `edit_dispatch_*` RPCs accept `p_edit_role` and work headless; `mark_dispatch_vox_sourced` hard-requires `auth.uid()` and cannot run from automation, cron, or the conductor.
- **R-D4.** No unique constraint on `refill_plan_output` or `refill_dispatching` (plan_date, machine, shelf, product, action), so amendment paths risk silent duplicates and deletes are scoped by hand.

---

## Goals

1. A committed plan can be amended at the shelf or line level without a full rebuild and without destroying hand-made rows.
2. Every amendment is gated and audited the same way the first commit is. No tool bypasses the gates.
3. A failed Commit never leaves the plan half-written. State is all-or-nothing, and the UI tells the truth about what shipped.
4. Multi-variant and in-stock correctness is enforced by the engine, not patched by hand at packing time.
5. Auth is uniform: every writer the conductor or cron must call accepts an explicit role parameter.

## Non-goals

- Rewriting the engine's sizing logic (that is PRD-010/PRD-015 territory).
- Changing the two-gate model. This PRD makes amendment respect the gates, it does not remove them.
- Building a general planogram editor. Intra-pod RELOCATE here is a refill-time action, not a permanent planogram change.

---

## Proposed solution

### 1. Keystone: `reopen_pod_refill_rows` (Family A)

A new canonical writer that moves specific `pod_refill_plan` rows from `stitched` (or `approved`) back to `draft`, **without** re-deriving from `pod_refills`, and **without** touching any `refill_plan_output` row that is past `pending`.

```
reopen_pod_refill_rows(
  p_plan_date date,
  p_machine_ids uuid[],          -- scope
  p_shelf_ids uuid[] DEFAULT NULL,-- optional finer scope
  p_edit_role text,              -- explicit role, no auth.uid dependency
  p_reason text                  -- >= 10 chars, audited
) RETURNS jsonb
```

Behavior: flip matched rows to `draft`, stamp `reasoning.reopened_at` + reason, write to `pod_refill_plan_audit`. Refuse if any linked `refill_plan_output` row for the same shelf is past `pending` (those are physical commitments and stay locked). This is the missing inverse edge in the status machine. With it, the 2026-06-01 recovery would have been: reopen the 4 GRIT rows, re-apply the stops, re-approve, re-stitch once. No `inject_swap`, no destructive reset.

### 2. Make re-stitch additive and idempotent (Family A + D4)

- **R-D4 fix:** add a partial unique index on `refill_plan_output` and `refill_dispatching` over (plan_date, machine, shelf_code, boonz_product, action) where `operator_status = 'pending'`. This lets the writer upsert instead of delete-then-insert, and kills the duplicate-row class.
- Change `write_refill_plan` to upsert pending rows on that key rather than the current delete-pending-then-insert. Confirm it never deletes or rewrites a row past `pending` (the lock check already exists, this hardens it).

### 3. Commit chain becomes one transaction with a truthful result (Family B)

- **R-B1 fix:** wrap `approve_pod_refill_plan to engine_finalize_pod to stitch_pod_to_boonz(false) to approve_refill_plan` in a single server-side RPC, `commit_refill_plan(p_plan_date, p_machine_names[], p_edit_role, p_reason)`, that either completes fully or rolls back. The FE Commit button calls this one RPC. No partial state is possible.
- **R-B2 fix:** the RPC returns verified counts (`boonz_rows_written`, `dispatch_rows_created`, `machines_covered`). The FE banner renders those numbers. If any count is zero where it should not be, the banner shows an error, not a success.
- **R-A3 fix:** `engine_finalize_pod` must preserve rows whose `reasoning` carries a `manual_add` or `manual_edit` marker (do not overwrite their qty from `pod_refills`). Manual intent survives a finalize.

### 4. Fix or retire `inject_swap` (Family C)

Two options, Cody to choose:

- **Option A (preferred): retire `inject_swap` for the amend use case.** Replace it with the gated path: `reopen_pod_refill_rows` plus `add_pod_refill_row` (already exists, writes draft, stitch handles multi-variant split correctly) plus the normal approve/stitch. The GRIT swap done this way would have produced correct REMOVE quantities, a correct 3-way Truffle split and 2-way Tablet split, and a named REMOVE product, all through the gates.
- **Option B (if `inject_swap` must stay):** scope its REMOVE qty read to the actual shelf (R-C2), make it fan out a Mix across active variants (R-C3), set the REMOVE `boonz_product_id` to the resolved variant rather than NULL (R-C4), and route it through the draft layer so it is gated (R-C1).

### 5. New intra-pod RELOCATE action (Family C4)

Add a `RELOCATE` action to the action enum, expressed as a `(from_shelf, to_shelf)` move within one machine, with no warehouse debit or credit. The engine and stitch treat it as a physical move instruction for the driver. This is what "pull Vitamin Well off A05/A08 and put it on the other VW shelves" actually is. Today it is forced into REMOVE plus a comment, which means return-to-warehouse semantics and no destination.

### 6. Pre-pickup product/variant correction (Family D1 + D2)

- **R-D1 fix:** a pre-pickup product/variant edit that operates through the draft layer (reopen plus edit plus re-stitch) so a wrong variant can be corrected before pickup, not only by the driver after pickup. `edit_dispatch_product` stays as the post-pickup driver tool.
- **R-D2 fix:** the stitch even-split must only distribute across variants with active warehouse stock (`warehouse_stock > 0 AND status = 'Active' AND quarantined = false`). Expose a `v_in_stock_variants` view and have the split read from it. This closes the Barebells repeat for good.

### 7. Uniform headless auth (Family D3)

- **R-D3 fix:** give `mark_dispatch_vox_sourced` a `p_edit_role text` parameter and the same `auth.uid() IS NOT NULL AND role NOT IN (...)` guard pattern the `edit_dispatch_*` family uses, so cron, automation, and the conductor can call it. Audit the rest of the canonical writers for the same hard-`auth.uid()` pattern and normalize.

---

## Acceptance criteria

1. **AC-1 (reopen):** Given a `stitched` `pod_refill_plan` row with no past-`pending` output, `reopen_pod_refill_rows` returns it to `draft`, audited, and a subsequent approve plus stitch includes it. Given a row whose output is past `pending`, the call refuses with a clear message.
2. **AC-2 (no destructive reset needed):** the 2026-06-01 GRIT scenario can be fully recovered using only reopen plus existing edit RPCs plus one approve plus one stitch, with the Plaay placement and VW relocation intact and no `inject_swap`.
3. **AC-3 (transactional commit):** injecting a forced failure in any step of `commit_refill_plan` leaves `pod_refill_plan`, `refill_plan_output`, and `refill_dispatching` exactly as they were before the call. No phantom `stitched` rows.
4. **AC-4 (truthful banner):** the FE banner shows the verified `boonz_rows_written` and `dispatch_rows_created`. A zero-output commit renders as an error.
5. **AC-5 (finalize preserves manual):** a manual stop or add survives a subsequent `engine_finalize_pod` for that machine.
6. **AC-6 (no dup rows):** the partial unique index is live; a double-stitch of the same machine produces no duplicate `refill_plan_output` or `refill_dispatching` rows.
7. **AC-7 (RELOCATE):** a RELOCATE row renders on the driver app as a move from shelf X to shelf Y with no WH debit, and reconciliation does not credit or debit warehouse stock for it.
8. **AC-8 (in-stock split):** the stitch never routes a unit to a variant with 0 active WH stock. The Barebells case splits only across Caramel Cashew / Hazelnut Naugat / Salty Peanut when those are the in-stock set.
9. **AC-9 (headless vox tag):** `mark_dispatch_vox_sourced` runs from the conductor with `p_edit_role`, no `auth.uid()` required, audited.
10. **AC-10 (pre-pickup variant fix):** a wrong variant on a committed-but-not-picked line can be corrected through the gated draft path without waiting for the driver.

---

## Phasing

- **Phase 1 (unblocks the conductor immediately): R-A1 reopen, R-D3 headless vox tag, R-B2 truthful banner.** Small, high leverage. Reopen alone removes the worst rigidity.
- **Phase 2 (correctness): R-B1 transactional commit, R-A3 finalize-preserves-manual, R-D2 in-stock split, R-D4 unique index + upsert.**
- **Phase 3 (ergonomics): RELOCATE action, inject_swap retire/fix, R-D1 pre-pickup variant edit.**

---

## Cody pre-read (constitution surface)

- New canonical writers on protected entities: `reopen_pod_refill_rows` and `commit_refill_plan` write `pod_refill_plan`; the auth normalization touches `refill_dispatching`. Article 4 (RPC tagging), Article 6 (status transitions), Article 9 (no raw writes), Article 12 (generated columns / index changes), Article 14 (no parallel tables). All in scope for Cody review before any `CREATE OR REPLACE`.
- The unique index is a schema change: Dara designs, Cody reviews, with a dedup pass on existing rows first.
- RELOCATE is an enum addition: Dara confirms the action enum and the stitch / dispatch / reconcile handling; Cody confirms it does not open a warehouse-accounting hole.

## Open questions

1. Reopen scope default: should reopen ever be allowed to touch a row whose output is past `pending`, with a louder confirmation, or is the lock absolute? (Recommend absolute.)
2. Should `commit_refill_plan` be machine-scoped by default so a subset commit is first-class, fixing the subset-commit finalize gotcha noted in memory?
3. RELOCATE: do we also want a permanent planogram-change variant (slot product change) as a follow-on, or keep RELOCATE strictly per-refill?
4. inject_swap: retire (Option A) or harden (Option B)? Recommend retire once reopen ships, since reopen plus `add_pod_refill_row` covers the use case through the gates.

---

## Appendix: what shipped manually on 2026-06-01 (so it is not lost)

The 6-machine plan for 2026-06-02 is live: 52 boonz lines plus the GRIT Plaay swap. GRIT A05 = Plaay Truffles (6) with VW REMOVE (3, relocate to A09/A10/A11), A08 = Plaay Tablets (6) with VW REMOVE (4, relocate). Extra Gum raised to 6 at HUAWEI B07 and VML-1004 A01. Still owed in the FE (the exact items this PRD removes the need to hand-fix next time): VOX-source tag the 4 VOXMM lines (Ice Tea, Aquafina x2, Maltesers), substitute the 2 dead-stock Barebells variants to active stock, relabel the VW REMOVE rows if they render as a dash.
