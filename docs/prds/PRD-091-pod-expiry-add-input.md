# PRD-091: On-machine expiry as an ADD/rotation input

Status: PARKED 2026-07-08 (rule F: expiry_pull representation is an unmade Dara/CS decision + pull/refill conservation not validatable on the manual-add fixture). NOT shipped. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why

Step 2 never reads **on-machine (pod_inventory) expiry**. A performing shelf holding soon-to-expire stock keeps getting refilled while the old units spoil — the engine only reacts to zero velocity, never to spoilage risk. Feed on-shelf expiry so a performing shelf with stock expiring < N days produces a pull-old + refill-fresh remediation, and hands an `expiry_risk` signal to SWAP (Wave 2 consumes it).

## Design (Dara designs, Cody reviews)

1. `refill_policy_params`: `expiry_risk_days` (e.g. 7).
2. In `engine_add_pod`: read `v_pod_inventory_latest` min expiration per shelf → `days_to_expiry_min`. If `days_to_expiry_min < expiry_risk_days` AND velocity>0, emit an `expiry_pull` remediation (REMOVE expiring qty into `pod_swaps`/`pod_refills` reasoning tag `expiry_risk` + a fresh REFILL sized normally). Behind `expiry_input_v1`.
3. Do NOT auto-swap here (that's Wave 2/PRD-088-swap); this PRD only surfaces the pull + fresh refill and tags the signal.
4. Flag off ⇒ identical.

## Gates

- Flag OFF ⇒ `diff_vs_golden` IDENTICAL. Flag ON ⇒ capture delta; a performing shelf with stock expiring < N days emits a remediation row; conservation green (pull + fresh reconcile); no oversubscription. Cody signs.

## T-tests

- T1 flag off ⇒ golden identical.
- T2 flag on ⇒ velocity>0 shelf with `days_to_expiry_min < expiry_risk_days` produces an `expiry_risk`-tagged remediation.
- T3 a fresh shelf (no near-expiry) is untouched.
- T4 conservation green; T5 no shelf > `wh_avail`.

## CLOSE

CHANGELOG + registry; PRD-091 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Rollback = flag off.
