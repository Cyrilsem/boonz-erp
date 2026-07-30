# PRD-106 — Machine-Level Swap Recommendation (replace per-shelf substitute picker)

**Status:** DRAFT — needs Dara (design) + Cody (constitutional review)
**Author:** CS via assistant session, 2026-07-28 evening
**Trigger incident:** MC-2004-0100-O1, plan 2026-07-29. `find_substitutes_for_shelf` returned the IDENTICAL ranked list for all 3 dead shelves (A11 Loacker, B02 Tamreem, B03 Ice Tea), with rank 1 = Coca Cola Mix — a product already live on the machine (A2, A4). Row-by-row assessment produces duplicate recommendations and in-machine collisions.

## Problem

The current substitute engine evaluates each shelf independently:

1. Same candidate universe returned per shelf → if N shelves need swaps, the engine recommends the same top product N times.
2. No in-machine exclusion → recommends products already on other shelves of the same machine (also tracked as bug_swap_brain_within_machine_duplicate, Hunter A04 vs A10, 07-21).
3. No warehouse-availability weighting → candidates ranked purely on correlation; WH stock checked only later at stitch, producing blocked_no_wh surprises.
4. Correlation scores are machine-level basket fit, so per-shelf calls add no shelf-specific signal — the per-shelf framing is noise.

## CS Requirement (dictated 2026-07-28)

- Build ONE machine-level swap recommendation: the universe of optimal swap-ins for the machine, ranked.
- Given K shelves to swap, ASSIGN the top-K DISTINCT products from that universe — one per shelf, no repeats within the machine.
- Ranking = probability of match (basket correlation / velocity evidence) × warehouse availability (real pickable units, dedup by batch — NOT the product_mapping fan-out join).
- Hard exclusion: any pod_product already live on ANY shelf of the machine.
- Exception: a product already on the machine MAY be recommended for a second facing ONLY if it is top-performing AND carries an explicit DOUBLE DOWN flag (stance from engine_add_pod decision).
- Form-factor / slot-profile compatibility still applies (PRD-042 slot profile pools).

## Proposed shape (for Dara)

New RPC `recommend_swaps_for_machine(p_plan_date, p_machine_id, p_k int)` returning K (shelf_id, out_pod, in_pod, qty_suggested, rank_score, wh_available, rationale) rows:

1. Candidate universe = active pod_products with Active mapping, minus in-machine products (unless DOUBLE DOWN), minus decommission-intent products, filtered to slot-profile-compatible.
2. Score = f(basket_corr, fleet_velocity_30d, wh_pickable_units, expiry_pressure boost for near-FEFO stock).
3. Assignment = greedy top-K distinct, highest-value shelf gets highest-ranked candidate (or Hungarian if shelf-profile constraints bind).
4. WH availability from `v_wh_pickable` aggregated by boonz_product, summed per pod_product via mapping WITHOUT row multiplication.

## Known bugs this supersedes / touches

- bug_swap_brain_within_machine_duplicate (OPEN) — fixed by hard exclusion.
- RC-06 engine_swap_pod hardcoded DEAD tag versions v15/v16 vs add v18/v19 — fix alongside (LIKE 'engine_add_pod%').
- Candidate stock queries must dedup: product_mapping join inflates stock ~10x (observed again 2026-07-28: Red Bull 1599 vs real 39).

## Interim workaround (until built)

Manual conductor flow used 2026-07-28: pull machine WEIMI inventory + dead rows, run find_substitutes once, exclude in-machine products by hand, verify WH stock with dedup query, assign distinct products manually, write via stop_pod_refill_row + add_pod_refill_row (REMOVE + ADD_NEW pairs).

## Acceptance

- For a machine with K dead shelves: K distinct swap-ins, none already on machine (unless DOUBLE DOWN flagged), all with wh_available >= qty_suggested, zero blocked_no_wh at stitch for swap rows.
- Re-run engine_swap_pod on MC-2004 scenario reproduces the manual outcome class (no Coca Cola Mix recommendation).
