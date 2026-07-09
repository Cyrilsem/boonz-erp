# PRD-092: No-warehouse shelf gets an ACTION, not a silent empty

Status: SHIPPED 2026-07-09 (side-table + standalone fn, Option 1: refill_action_proposals + compute_nowh_proposals; additive; 12/12 validated; no engine edit). See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews.

## Why

When `wh_avail = 0` for a needed shelf, `engine_add_pod` only sets `clamp_reason='blocked_no_wh'` and drops it into `procurement_gaps` — the shelf just stays empty and loses sales. Instead, a blocked shelf should get an ACTION: a substitute (if a good one has WH), or an M2M-source proposal (pull from a surplus machine), else a real procurement alert.

## Design (Dara designs, Cody reviews)

1. In `engine_add_pod`, for rows resolving to `clamp_reason='blocked_no_wh'` (behind `add_nowh_action_v1`):
   a. Call `find_substitutes_for_shelf` — if a substitute with pickable WH ≥ min exists, emit an `ADD_NEW`/swap proposal (hand to SWAP, tagged `nowh_substitute`).
   b. Else look for a **surplus** machine holding the same pod_product above its own need → emit an M2M-source proposal (`swap_between_machines` shape, tagged `nowh_m2m`).
   c. Else keep the `procurement_gaps` alert (unchanged).
2. Proposals only — no execution; SWAP/M2M paths (Wave 2/3) or the operator act on them.
3. Flag off ⇒ identical.

## Gates

- Flag OFF ⇒ `diff_vs_golden` IDENTICAL. Flag ON ⇒ capture delta; **no `blocked_no_wh` shelf is left with neither a substitute nor an M2M nor a procurement alert**; conservation green; no oversubscription (substitute/M2M respect pickable WH / source surplus). Cody signs.

## T-tests

- T1 flag off ⇒ golden identical.
- T2 flag on ⇒ a `blocked_no_wh` shelf with a viable substitute emits a `nowh_substitute` proposal.
- T3 flag on ⇒ a `blocked_no_wh` shelf with a surplus-machine source emits a `nowh_m2m` proposal.
- T4 flag on ⇒ a truly-out SKU still yields a procurement alert (no silent empty).
- T5 conservation green; no oversubscription.

## CLOSE

CHANGELOG + registry; PRD-092 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Rollback = flag off.
