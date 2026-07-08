# PRD-090: Merchandising-fill floor for scarce/niche SKUs

Status: SHIPPED DARK 2026-07-08 (add_niche_fill_v1=off; flag-OFF diff_vs_golden IDENTICAL; footprint via slot_lifecycle; Cody PASS). NOT enabled. See EXECUTION-LOG.
Owner: CS. Mode: AUTO with hard gates. Dara designs, Cody reviews, Stax wires.

## Why

The engine sizes to days-of-cover, never to merchandising fill. A SKU that sells in only 1–2 places (e.g. SF Pancake on HUAWEI) gets a sparse facing that looks empty, suppresses impulse sales, drops velocity, and eventually gets rotated out — a doom loop. Give narrow-footprint SKUs a visible-facing floor at their proven location when pickable WH stock exists.

## Design (Dara designs, Cody reviews, Stax wires)

1. `refill_policy_params`: `niche_footprint_max` (machines, e.g. 2), `niche_facing_target` (units or % of cap, e.g. 0.8×cap).
2. In `engine_add_pod`: compute per-`pod_product` footprint = COUNT(DISTINCT active machines carrying it). If `footprint <= niche_footprint_max` AND this shelf is the product's best location (highest v30), set `need_raw := GREATEST(cover_units, niche_facing_target)` — clamped to shelf cap and **PRD-079 pickable** `wh_avail` (so quarantined/held stock does NOT get promised). Behind `add_niche_fill_v1`.
3. When flag off, identical to today.

## Gates

- Flag OFF ⇒ `diff_vs_golden` IDENTICAL. Flag ON ⇒ capture delta; niche SKUs with pickable WH get filled to facing floor; those with only held/quarantined WH surface as procurement/held (NOT a false promise). Conservation green; no oversubscription. Cody signs.

## T-tests

- T1 flag off ⇒ golden identical.
- T2 flag on ⇒ a footprint≤max SKU at its best location with pickable WH gets a fill-to-facing row.
- T3 flag on ⇒ SF Pancake (all WH quarantined) yields a held/procurement flag, not a phantom fill.
- T4 conservation green; T5 no shelf > pickable `wh_avail`.

## CLOSE

CHANGELOG + registry; PRD-090 SHIPPED DARK + EXECUTION-LOG (on-delta for CS); commit+push. Pairs with the `dispatch_return_unverified` quarantine-drain data task (unlocks real niche stock). Rollback = flag off.
