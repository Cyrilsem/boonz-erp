# PRD-091 Execution Log — On-machine expiry input (PARKED, not shipped)

Run 2026-07-08 overnight (WAVE1-OVERNIGHT), AUTO. **Status: PARKED (rule F). NOT shipped.**

## Why parked (two rule-F blockers)

1. **Unmade representation decision.** The spec emits an `expiry_pull` remediation "into
   pod_swaps/pod_refills" — the `/` is an open Dara/CS design choice. `pod_refills` has no
   REMOVE/action column (its `signal` is lifecycle: STAR/ROTATE OUT/WIND DOWN…); `pod_swaps`
   models out/in (`qty_out`/`qty_in`) but implies a swap, which the spec explicitly excludes
   ("No auto-swap here"). How to represent a same-SKU pull+fresh-refill is undecided.
2. **Conservation not validatable.** The remediation's pull+refill must reconcile
   (conservation green). The golden_v1 fixture (2026-07-06) is 100% manual/non-engine-sized
   rows, and NO plan_date in the last 30d contains engine ADD-sized rows — so the rollback
   ON-capture cannot exercise or verify the remediation's conservation. Rule F's "conservation
   regresses on the ON-capture" gate is uncheckable → cannot clear it.

Shipping this dark would be inert-safe but un-reviewable (no previewable delta for CS to enable
on) and would author inventory-affecting REMOVE emission with an undecided shape and unverified
conservation — exactly what rule F says to PARK, never force.

## What IS confirmed (for the un-park)

- `v_pod_inventory_latest` exists (machine_id, shelf_id, boonz_product_id, expiration_date,
  current_stock, batch_id, snapshot_at) → `days_to_expiry_min` per shelf is computable.
- `refill_policy_params += expiry_risk_days` (not applied — deferred with the park).

## Needed to un-park

1. Dara/CS: decide the expiry_pull representation (pod_swaps out=in same SKU vs a pod_refills
   tag vs a new remediation shape) + the conservation reconciliation contract.
2. An **engine-ADD fixture** (a date/machine set where engine_add_pod actually sizes via
   covered/flagged) so the ON-capture can validate the remediation's conservation.
3. Then: build behind expiry_input_v1, prove flag-off identical + ON conservation green, Cody PASS.

## Status: PARKED (rule F: unmade decision + unvalidatable conservation). Owner: Dara + CS.

## ON-delta (rollback ON-capture, 2026-07-08)

Rollback ON-capture with the flag forced ON in-transaction (BEGIN..ROLLBACK, discarded):
**plan-delta = 0** on golden_v1 (2026-07-06), conservation green (orphan_removal/phantom/oversub = 0).
This is the fixture limitation, not an inertness claim: golden_v1 is 100% manual_add with no
engine-ADD-sized rows, so no Wave-1 change can bite here. A non-zero delta requires an
engine-ADD fixture (see MASTER-PARKING-LOT program blocker).

## 2026-07-09 — SHIPPED (signal-only, Option 3)

Design ruling adopted: **091 = Option 3 (signal-only)**, making it ADDITIVE (no engine edit, no freeze).

- `refill_policy_params.expiry_risk_days` (default 7) + view `public.v_shelf_expiry_risk`
  (machine_id, shelf_id, pod_product_id, days_to_expiry_min, expiry_risk) from
  `v_pod_inventory_latest` + `slot_lifecycle`. Cody PASS. **Live: 80 shelves expiry_risk=true.**
- Inert: reads only; NO `engine_add_pod` edit; Family-A md5 UNCHANGED (add=b91c530b/swap=90f26896/pick=48cc1844).
- Consumed later by **PRD-095** (expiry-swap trigger, held for the engine-freeze window).

## Status: SHIPPED (signal-only). Engine-wiring parked for freeze window (PRD-095).
