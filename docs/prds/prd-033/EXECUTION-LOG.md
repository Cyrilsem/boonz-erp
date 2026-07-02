# PRD-033 Execution Log

Branch: `feat/prd-033-operator-flexibility`.

## APPLIED TO PROD 2026-06-17 (CS go). Order A -> C -> D -> B -> E.

CS decisions: Phase A scope = `status IN ('draft','approved')` + cap at current_stock;
Phase D = BLOCK (no auto-hold). All five objects applied via apply_migration straight
from the migration file bodies (live == file by construction); each functionally
verified (read-only or rolled-back). No live-vs-file divergence on any object.

### Post-apply acceptance checks (against prod)

| Check                                                             | Verdict | Evidence (live)                                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A** `planned_removed <= current_stock` every shelf              | ✅ PASS | live `v_shelf_capacity`: 2615 shelves, 0 violations; shelves-with-removes 93 -> 68 (stitched-only removes dropped out). Flagged shelves' inflation gone: A04 117->capped 15 (headroom 14), A06 144->8 (6), A11 192->26 (25); cap_ok + headroom_consistent true. |
| **B** reopen + re-stitch idempotent, no dup on dispatched shelves | ✅ PASS | live `reopen_stitched_rows` + `stitch(date,false)`, rolled back: control machines `refill_plan_output` 76->76, `refill_dispatching` 108->108, duplicate groups = 0.                                                                                             |
| **C** release no-op on non-quarantined row                        | ✅ PASS | live no-op = `noop` (no change); rolled-back positive release: quarantined t->f, provenance->manual_adjust, `released`.                                                                                                                                         |
| **D** Phase D returns `flagged[]` on block                        | ✅ PASS | live `check_remove_without_replace`, rolled-back synthetic: `status=block`, `flagged_count=1` (AMZ-1029/A14, pickable 0).                                                                                                                                       |
| **E** convert_shelf frees capacity (R1+R6)                        | ✅ PASS | live `convert_shelf`, rolled back: full shelf (pre-headroom 10) -> M2W removed 14 -> ADD_NEW 15 honored (clamp_reason null, post_removal_headroom 21), 2 rows written.                                                                                          |

---

(Authoring record below; files now applied.)

Migration files; each phase stopped for CS sign-off before apply.
Branch: `feat/prd-033-operator-flexibility`.

## Acceptance checks (PRD "Acceptance checks") - all demonstrated in rolled-back tx, nothing persisted

| Check                                                                                                                      | Verdict | Evidence (2026-06-17)                                                                                                                                                                                                                                                                                                               |
| -------------------------------------------------------------------------------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A** after apply, `planned_removed <= current_stock` on every shelf                                                       | ✅ PASS | New view logic run inline over all 2615 shelves: 0 violations. 93 shelves carry planned removes; 91 now have `headroom > 0` (vs 0 before). Guaranteed by capping `planned_removed = LEAST(raw, current_stock)` (headroom math unchanged).                                                                                           |
| **B** reopen + re-stitch IDEMPOTENT; no duplicate `refill_plan_output`/`refill_dispatching` for already-dispatched shelves | ✅ PASS | Rolled-back battery on 2026-06-17: one machine's output synthetically set pending, `reopen_stitched_rows` (ok, 13 rows) + `stitch_pod_to_boonz(date,false)`. CONTROL (other, already-dispatched machines): `refill_plan_output` 76->76, `refill_dispatching` 108->108; duplicate (plan_date,machine,shelf,boonz,action) groups = 0. |
| **C** `release_wh_quarantine` NO-OP + explicit report on a non-quarantined row                                             | ✅ PASS | Rolled-back: called on a `quarantined=false` row -> `status='noop'`; provenance/stock/status before==after (dispatch_return / 0 / Inactive, unchanged).                                                                                                                                                                             |
| **D** Phase D returns `flagged[]` on block                                                                                 | ✅ PASS | Rolled-back: synthetic REMOVE + ADD_NEW (pod with 0 pickable WH) -> `check_remove_without_replace` returned `status='block'`, `flagged_count=1` (AMZ-1029/A14, Lays Chips, pickable_units=0).                                                                                                                                       |

Note: each demonstration created the new object transiently (EXECUTE inside a DO block) and/or
inserted synthetic rows, then RAISEd to roll the whole transaction back. Prod is unchanged;
the RPCs/view exist only in the migration files. Phase A file updated to cap `planned_removed`
at `current_stock` so the AC-A invariant holds by construction.

## Phase A (R1) - v_shelf_capacity nets planned removals

**Status:** SQL written, awaiting CS sign-off. Not applied.
**Migration:** `supabase/migrations/20260617090000_prd033_a_shelf_capacity_nets_removals.sql`

- **A1 (view redefine):** DONE in file. `headroom = max_stock - GREATEST(current_stock - planned_removed, 0)`; new `planned_removed` column appended (preserves existing column order for CREATE OR REPLACE VIEW). `planned_removed` = SUM(qty) of REMOVE/M2W rows on the shelf with `status NOT IN ('superseded','voided')`, scoped to the shelf's latest active plan_date to keep one row per shelf (no fan-out).
- **A2 (clamp pickup):** CONFIRMED, no RPC change needed. `add_pod_refill_row` and `edit_pod_refill_row` both read `v_shelf_capacity` live by `shelf_id` (`SELECT max_stock, current_stock, headroom INTO ... WHERE shelf_id = p_shelf_id`) and clamp REFILL/ADD_NEW to `headroom`. They do not snapshot capacity, so the new post-removal headroom flows through automatically. (Cosmetic: their `capacity_clamp` JSON still echoes the live `current_stock`; not changed in Phase A to avoid touching the clamp writers.)
- **A3 (verify):** PASS (read-only SELECT, nothing applied). Shelves at/over max with a paired REMOVE move from `old_headroom = 0` to `new_headroom = max_stock` (full remove) or a proportional value (partial remove). e.g. `f1a528fb/A04` 12/12 remove 12 -> 0 to 12; `69195812/A16` 23 of max 20 remove 4 -> 0 to 1.

**OPEN DECISION for CS (raised by A3 data):** the spec's `status NOT IN ('superseded','voided')` also nets _stitched/dispatched_ removes whose stock WEIMI has already dropped (seen as planned_removed 192/144/117 >> max on some shelves), which double-counts and over-inflates headroom. Recommend tightening to un-executed removes only - `status IN ('draft','approved')` (and/or `plan_date >= CURRENT_DATE`). Held for sign-off before applying.

## Phase B (R2) - reopen_stitched_rows

**Status:** SQL written, awaiting CS sign-off. Not applied.
**Migration:** `supabase/migrations/20260617091000_prd033_b_reopen_stitched_rows.sql`

- **B1:** new DEFINER `reopen_stitched_rows(p_plan_date, p_machine_ids[], p_shelf_ids[] DEFAULT NULL, p_reason)`. Flips selected `pod_refill_plan` rows `stitched -> approved` in place (no re-derive, no supersede). Role-gated operator_admin/superadmin; reason >= 10 chars. Sets `app.via_rpc`+`app.rpc_name` (generic `audit_log_write` trigger) and writes `pod_refill_plan_audit` (edit_type='reopen'). Refuses the whole call if any selected stitched row's linked `refill_plan_output` is past `pending` (same lock predicate as add/edit). Bumps `edited_at` so `restitch_after_edits` (approved AND edited_at>last_stitch) also accepts them (B3).
- **B2 (idempotency):** no writer change needed. `stitch_pod_to_boonz` gates on `status='approved'`; `write_refill_plan` DELETEs only `operator_status='pending'` output rows for the affected machines then re-inserts. Dispatched/reviewed lines are non-pending and untouched; B1 refuses to reopen rows whose output is past pending, so re-stitch cannot duplicate a dispatched line.

## Phase C (R3) - release_wh_quarantine

**Status:** SQL written, awaiting CS sign-off. Not applied.
**Migration:** `supabase/migrations/20260617092000_prd033_c_release_wh_quarantine.sql`

- **C1:** new DEFINER `release_wh_quarantine(p_wh_inventory_id, p_reason, p_verified_by DEFAULT NULL)`. Sets `provenance_reason='manual_adjust'` (already in both provenance CHECKs; NOT in the `quarantined` generation set) so the GENERATED `quarantined` flips to false and the row enters `v_wh_pickable`. No new enum value, no CHECK change. Role-gated warehouse/operator_admin; reason >= 10 chars; `app.via_rpc`+`app.rpc_name` set (trusted by `detect_silent_warehouse_inventory_write`; recorded by generic audit). Does NOT set `app.provenance_reason` GUC, so `set_warehouse_inventory_provenance` leaves the explicit value. Stock/status unchanged (never trips the silent-reactivation pattern). No-op + report if the row is not quarantined.
- **C2 (FE):** RPC shipped; one-click "verify and release" surfacing is a Stax follow-up (out of scope here).

## Phase D (R4) - check_remove_without_replace

**Status:** SQL written, awaiting CS sign-off. Not applied.
**Migration:** `supabase/migrations/20260617093000_prd033_d_check_remove_without_replace.sql`

- **D1:** new READ-ONLY DEFINER `check_remove_without_replace(p_plan_date)` returns `{status: ok|block, flagged_count, flagged[]}`. Flags any shelf with an active REMOVE/M2W AND a paired active ADD_NEW whose pod resolves to 0 pickable WH units (SUM over Active mapped boonz in `v_wh_pickable`, reserved-to-this-machine-or-unreserved; mirrors stitch's wh_avail). Pure removals (no paired ADD_NEW) are intentional and NOT flagged. **DEFAULT = block** (conductor/FE blocks the commit on status='block'); writes nothing, so no protected-write gate. CS may instead choose auto-hold-the-REMOVE - that is a writer edit and is deliberately NOT built here pending the choice.

## Phase E (R6) - convert_shelf

**Status:** SQL written, awaiting CS sign-off. Not applied.
**Migration:** `supabase/migrations/20260617094000_prd033_e_convert_shelf.sql`

- **E1:** new DEFINER `convert_shelf(plan_date, machine_id, shelf_id, old_pod, new_pod, new_qty, return_mode DEFAULT 'wh', reason)`. Atomically writes REMOVE/M2W(old, tracked physical qty) + ADD_NEW(new, new_qty), upserting each 5-tuple (insert or qty-update; no delete). REMOVE qty = SUM Active `v_pod_inventory_latest` current_stock over old pod's mapped boonz. After the REMOVE row is written, re-reads `v_shelf_capacity.headroom` (Phase A nets it) and clamps the ADD_NEW to post-removal headroom. `return_mode='wh' -> M2W` else `REMOVE`; source_origin='warehouse'. Role-gated operator_admin/superadmin/warehouse; same past-pending lock as add/edit; `app.via_rpc`+`app.rpc_name`; `pod_refill_plan_audit` edit_type='convert' per row. **Depends on Phase A** for the headroom to be non-zero on a full shelf.
- **Dependency note:** convert_shelf's post-removal clamp only works once Phase A is applied; the Phase A plan_date-scoping decision (latest-active-plan) means convert_shelf is correct when `p_plan_date` is the shelf's latest active plan (the normal case).

## Sequencing for apply (after sign-off)

A (view) first - B/E depend on the post-removal headroom. C and D are independent. Apply order: A, then C, D, then B, then E. Each still needs its own apply + verification once CS signs off.
