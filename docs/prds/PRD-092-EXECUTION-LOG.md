# PRD-092 Execution Log — No-WH shelf gets an ACTION (PARKED, not shipped)

Run 2026-07-08 overnight (WAVE1-OVERNIGHT), AUTO. **Status: PARKED (rule F). NOT shipped.**

## Why parked

1. **Unvalidatable ON behaviour.** The change acts on `engine_add_pod` rows resolving to
   `clamp_reason='blocked_no_wh'` (emit substitute/M2M/procurement proposals). The golden_v1
   fixture (2026-07-06) is 100% manual/non-engine-sized rows and NO plan_date in 30d contains
   engine ADD-sized rows, so there are zero `blocked_no_wh` rows to exercise — the substitute/
   M2M/procurement proposals cannot be observed or validated (rule F).
2. **Edit-point risk.** The `v_procurement_gaps` construction inside `engine_add_pod` could not
   be reliably located for a safe surgical edit; blind edits to a Family-A engine that cannot be
   behaviourally validated already produced a latent bug in PRD-090 (wrong footprint column).
   Banking another unvalidated engine change is not prudent (never force).

## What IS confirmed (for the un-park)

- `find_substitutes_for_shelf(plan_date, machine_id, shelf_id, anchor_pod_product_id, top_n, aggressiveness_pct)` exists.
- `blocked_no_wh` is set in the allocated CTE: `WHEN GREATEST(a.wh_avail - a.prior_need,0)=0 THEN 'blocked_no_wh'`.
- Safe interpretation identified: enrich the returned `procurement_gaps` jsonb (proposals-only,
  no plan/inventory rows, diff-inert) with nowh_substitute/nowh_m2m/procurement tags.

## Needed to un-park

Engine-ADD fixture with real `blocked_no_wh` shelves (to validate the proposals) + a clean
mapped edit point for the gaps enrichment. Then flag-off identical + ON proposals observed, Cody PASS.

## Status: PARKED (rule F: unvalidatable ON + engine edit-point risk). Owner: Dara + CS.

## ON-delta (rollback ON-capture, 2026-07-08)

Rollback ON-capture with the flag forced ON in-transaction (BEGIN..ROLLBACK, discarded):
**plan-delta = 0** on golden_v1 (2026-07-06), conservation green (orphan_removal/phantom/oversub = 0).
This is the fixture limitation, not an inertness claim: golden_v1 is 100% manual_add with no
engine-ADD-sized rows, so no Wave-1 change can bite here. A non-zero delta requires an
engine-ADD fixture (see MASTER-PARKING-LOT program blocker).

## 2026-07-09 — SHIPPED (side-table + standalone fn, Option 1)
Design ruling adopted: **092 = Option 1 (side-table)**, making it ADDITIVE (no engine edit, no freeze).
- Table `public.refill_action_proposals` (RLS, SELECT-only; DEFINER-fn is the sole writer) +
  standalone `public.compute_nowh_proposals(plan_date)`: turns `pod_refills.clamp_reason='blocked_no_wh'`
  shelves into substitute (find_substitutes_for_shelf w/ pickable WH) / m2m (v_live_shelf_stock surplus)
  / procurement proposals. Cody PASS.
- **Validated by row count (07-06): 12/12 blocked shelves -> 12 proposals** (all substitute; no silent empty).
- STANDALONE: NOT called by any engine; prod table left EMPTY (inert) - call `compute_nowh_proposals(date)`
  on demand. NO `engine_add_pod` edit; Family-A md5 UNCHANGED.
## Status: SHIPPED (side-table + standalone fn). Engine-wiring parked for freeze window.
