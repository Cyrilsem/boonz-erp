# Unpriced lanes, 2026-09-15

`v_current_price_filled` (migration `20260915002900_prd12x_pb_v_current_price_filled.sql`)
closed most of the price gap that blocked PRD-126 A3/A5/A6/A7: 2,033 merchandised
(machine, pod product) lanes now resolve a price, 1,810 from `effective_price_aed` directly,
144 from this machine's own 30-day realised sales, 65 and 9 from fleet medians. Only 5 lanes
(0.25%) remain genuinely `unpriced`.

**None of the 5 have velocity at or above 1/day** (all are at 0.00 over both the 7-day and
30-day windows), so the list ONE-LOOP-2 asked for -- "every lane still at unpriced with
velocity at or above 1, sorted by velocity, for CS to fix in WEIMI" -- is empty. Listed below
anyway for completeness, since they are the full remaining gap:

| Machine             | Product             | Velocity 30d | Velocity 7d |
| ------------------- | ------------------- | ------------ | ----------- |
| USH-1008-0000-W1    | Hunter Canister 40G | 0.00         | 0.00        |
| VML-1004-0500-O1    | Hunter Canister 40G | 0.00         | 0.00        |
| NOOK-1019-0200-B1   | Eviron Health Drink | 0.00         | 0.00        |
| HUAWEI-2003-0000-B1 | Eviron Health Drink | 0.00         | 0.00        |
| VML-1003-0400-O1    | Hunter Canister 40G | 0.00         | 0.00        |

All 5 are dead or near-dead lanes on this data (zero sales in the last 30 days on that
machine, and no price found anywhere in the fleet for that pod product either -- no machine
has ever recorded an `effective_price_aed` or a realised sale for Hunter Canister 40G or
Eviron Health Drink in the last 30 days). Since nothing in this list has meaningful velocity,
there is no urgency for CS to set a WEIMI price today; this is here so the gap is visible if
either product's velocity picks up later. Re-run this query
(`select ... from v_current_price_filled where price_source='unpriced'`) periodically to
re-check.
