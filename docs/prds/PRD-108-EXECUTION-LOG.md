# PRD-108 — Execution Log (Volume-Driven Size-Up)

**Codename:** volume-sizeup · **Started:** 2026-07-29 · **Project:** eizcexopcuoycuosittm (PostgreSQL 17.6)
**Status:** PHASE 1 COMPLETE — awaiting CS threshold sign-off. **No writes made. Phase 2 not started.**

---

## Phase 1 — Calibration (READ-ONLY, trailing 90d, fleet-wide)

Target gate, `rank_slot_suitability` → `flagged` CTE:

```sql
( e.is_present
  AND (GREATEST(COALESCE(NULLIF(cap_typical,0),8), onmach_cap) / GREATEST(machine_vel,0.1)) < v_trip
  AND e.proven_machine_pctile >= 0.80     -- ← replaced by T1 AND T2 AND T3
  AND NOT e.is_blended
  AND e.is_dd )                            AS is_size_up
```

### 1.0 Unit verification (prerequisite — the whole calibration depends on it)

`slot_lifecycle.velocity_30d` is **units per DAY**, not units per 30 days. Verified against actual
30d sales: ratio 0.989, corr 1.000 over 377 matched (machine, pod) pairs. T1 = 1.0/day ≈ 7/wk is
therefore correctly scaled as written.

### 1.1 🚨 BLOCKER FOUND — `machine_vel` cannot be used for T1 as-is

`machine_vel` in the live function is `COALESCE(omv.vel, pv.ppad, 0)`, where the fallback `ppad` is
`SUM(qty) / COUNT(DISTINCT selling_date)` — units per **selling** day, not per **calendar** day.

| Measure                                                                 | Value                                 |
| ----------------------------------------------------------------------- | ------------------------------------- |
| (machine, pod) pairs with 90d sales                                     | 701                                   |
| Pairs with no current `slot_lifecycle` row → fall back to `ppad`        | 297                                   |
| Of those, would pass T1 at 1.0/day                                      | **297 (all)**                         |
| Of those, **false positives** (true calendar velocity < 1.0/day)        | **286**                               |
| Mean `ppad` overstatement                                               | **23.6×**                             |
| Max `ppad` overstatement                                                | **90×** (product sold on 1 day in 90) |
| Fallback pairs that are also `is_present` (can actually reach the gate) | 86                                    |
| **Live false positives reaching the size-up gate**                      | **83**                                |

A zombie's hero that sold 3 units on a single day scores `ppad = 3.0` and sails through a 1.0/day
floor. **T1 must be defined on a calendar-day velocity**, e.g.
`COALESCE(slot_lifecycle.velocity_30d, sales_90d/90.0, 0)`. All calibration below uses that corrected
definition.

### 1.2 🚨 The T3 newcomer benchmark decides everything

T3 compares against "exp_vel of the rank-1 NON-present candidate". Two readings give opposite answers:

| Benchmark for OMDCW-1021                                         | Value/day | T3 bar (×1.3) | Star case (incr 1.648/day) |
| ---------------------------------------------------------------- | --------- | ------------- | -------------------------- |
| `MAX(exp_vel)` across all candidates                             | 1.721     | 2.238         | ❌ **FAILS**               |
| Engine's true **rank-1 by suitability** (`Nutella Biscuits T12`) | **0.258** | **0.335**     | ✅ **PASSES**              |

`exp_vel = GREATEST(proven, lookalike, global)` is a max of three optimistic estimators; taking a
further MAX across candidates compounds it. On OMDCW the MAX proxy claims a newcomer would deliver
1.721/day at a machine selling 7.2/day across **all** products — 24% of the machine's entire volume
from one new SKU. That product's best _proven_ velocity on OMDCW is 0.278/day, and it is not even in
the top 8 by suitability.

**The PRD's wording is correct and must be implemented literally**: rank-1 **by suitability**, not by
velocity. Measured rank-1 benchmarks (via live `rank_slot_suitability` calls):

| Machine      | rank-1 newcomer                      | exp_vel     | T3 bar      |
| ------------ | ------------------------------------ | ----------- | ----------- |
| OMDCW-1021   | Nutella Biscuits T12 / Dubai Popcorn | 0.251–0.258 | 0.326–0.335 |
| ADDMIND-1007 | Hunter                               | 0.366       | 0.476       |
| AMZ-1038     | Hunter                               | 0.444       | 0.578       |
| AMZ-1029     | Barebells                            | 0.320       | 0.416       |
| MC-2004      | Red Bull / G&H Popped Chips          | 0.233–0.443 | 0.302–0.576 |

### 1.3 Acceptance replays at the proposed thresholds (T1 1.0, T2 1.25, T3 1.3)

| Acceptance criterion                      | Result                                                                                         |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Star: capacity-constrained shelf passes   | ✅ **OMDCW-1021 Al Ain Zero passes** (18.2/wk, 20 units, trip 21, incr 1.648/day vs bar 0.335) |
| Zombie: machine ≤30 u/wk → zero proposals | ❌ **FAILS — one leak: ADDMIND-1007 (28.0 u/wk), Pepsi Black**                                 |

`ADDMIND-1007 / Pepsi Black`: vel 1.20/day (8.4/wk), shelf 14 units, trip **30 days**.
T1 1.20 ≥ 1.00 ✅ · T2 36.0 > 17.5 ✅ · T3 incr 0.733 ≥ 0.476 ✅ → **passes all three**.

This contradicts the PRD's stated assumption that _"volume can only exist where traffic exists, so no
explicit machine-tier gate is needed"_. A 30-day trip on a 14-unit shelf creates genuine overflow even
on a low-traffic machine. Note the size-up is arguably **correct on the merits** — the shelf really
does run dry — but it violates CS's explicit rule that ≤30 u/wk machines get exploration, never
concentration.

### 1.4 Full zombie exposure across the ±25% band (every machine ≤30 u/wk)

| Machine          | u/wk     | Product         | vel/day  | units | trip | T2  | T1@0.75  | T1@1.00  | T1@1.25   |
| ---------------- | -------- | --------------- | -------- | ----- | ---- | --- | -------- | -------- | --------- |
| IFLYMCC-1024     | 23.2     | Aquafina        | 2.07     | 112   | 12   | ❌  | safe     | safe     | safe      |
| **ADDMIND-1007** | **28.0** | **Pepsi Black** | **1.20** | 14    | 30   | ✅  | **LEAK** | **LEAK** | ✅ closed |
| VML-1004         | 23.3     | Soft Drinks Mix | 0.93     | 14    | 30   | ✅  | leak¹    | safe     | safe      |
| LVLUP-1018       | 10.6     | Arwa Water      | 0.80     | 30    | 21   | ❌  | safe     | safe     | safe      |

¹ also `is_blended`, so excluded by the retained `NOT is_blended` regardless.

**T1 = 1.25/day (8.75/wk) is the only change needed to close the leak, and it sits inside the +25%
sensitivity band already proposed.** The star case keeps 2× headroom (2.60 vs 1.25).

### 1.5 Sensitivity (27 combinations, ±25% on each threshold)

Run with the conservative `MAX(exp_vel)` benchmark, so treat the absolute counts as a lower bound on
T3 pass rate; the T1/T2 columns are exact.

| Threshold | Range tested           | Passers (T1 alone) | Passers (T2 alone) |
| --------- | ---------------------- | ------------------ | ------------------ |
| T1        | 0.75 / 1.00 / 1.25     | 74 / 52 / 39       | —                  |
| T2        | 0.9375 / 1.25 / 1.5625 | —                  | 76 / 52 / 33       |
| T3        | 0.975 / 1.30 / 1.625   | —                  | —                  |

Combined `all_three` stayed in a tight **9–14** band across all 27 points: the design is not
threshold-fragile. T1∧T2 (exact, corrected velocity) = **31** (machine, pod) pairs, of which **11** are
`is_blended` and therefore already excluded by the retained bar.

### 1.6 ⚠️ Operational consequence — the change ships INERT

**Zero** of the T1–T3 passers currently carries a `DOUBLE DOWN` flag. `is_dd` is retained (PRD-106b),
so on the day this ships it produces **zero size-up proposals fleet-wide**. There are 14 DD facings on
11 (machine, pod) pairs today, and none of them passes T1–T3:

| DD facing                     | u/wk  | vel/wk | T1  | T2  | T3                     |
| ----------------------------- | ----- | ------ | --- | --- | ---------------------- |
| VOXMCC-1005 Chocolate Bar     | 244.4 | 18.9   | ✅  | ✅  | ❌ (also `is_blended`) |
| AMZ-1068 Hunter               | 68.4  | 5.6    | ❌  | ✅  | ❌                     |
| NOOK-1019 Vitamin Well        | 30.6  | 4.9    | ❌  | ✅  | ❌                     |
| ACTIVATEMCC-1037 Vitamin Well | 46.7  | 6.8    | ❌  | ❌  | ❌                     |
| ACTIVATE-2005 Gatorade        | 201.4 | 5.8    | ❌  | ❌  | ❌                     |
| (6 others)                    | —     | ≤5.6   | ❌  | ❌  | ❌                     |

This is safe (fails closed) but means the value only lands once DD flags move onto the volume
passers — which is exactly what Phase 2b's weekly DD proposal loop is for. Worth deciding whether 2b
becomes mandatory rather than optional.

### 1.7 Method notes and limitations

- Grain: (machine, pod), trailing 90d, `v_sales_history_resolved` `delivery_status='Successful'`.
- `full_shelf_units` = `SUM(GREATEST(max_stock,0))` over `v_live_shelf_stock` per (machine, pod) —
  matches the live `onmach_cap`.
- `trip` = `machine_service_policy.trip_interval_days` (values 12/21/30 across 30 machines), default 21.
- `incremental_per_day` defined as `GREATEST(0, vel_day − full_shelf_units/trip)` — the unmet demand
  rate, i.e. literal lost-sales-per-day. This is T2's overflow expressed as a rate, which keeps T2 and
  T3 dimensionally consistent.
- Shelf sizes for a present pod taken from `product_size_fit`, **not** by joining
  `v_live_shelf_stock.slot_name` to `shelf_configurations.shelf_code` — that view has no `shelf_id`
  and the A01↔A1 normalisation is a known join landmine.
- **Sell-out-day telemetry (T2's upgrade form) was NOT derivable.** `v_live_shelf_stock` is a current
  snapshot with no retained history at shelf grain, so "shelf at 0 before refill" cannot be counted
  over 30–60d. T2 must ship in its velocity × trip vs capacity fallback form. Flagged for CS.
- Fleet-wide rank-1 benchmarking via `rank_slot_suitability` timed out (per-shelf plpgsql, ~600 calls);
  benchmarks were computed for the decisive machines only. Sufficient for the threshold decision, not
  a fleet-complete T3 census.

---

## Phase 1 GATE — CS threshold sign-off (2026-07-29)

Presented in full (blocker 1.1, benchmark 1.2, star pass, zombie leak, inert-ship warning). CS decided:

| Decision                                        | Value                       | Rationale given                                                                                                                                         |
| ----------------------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **T1 `sizeup_min_vel_per_day`**                 | **1.25 /day** (8.75/wk)     | Closes the sole zombie leak (ADDMIND-1007 at 1.20/day); inside the +25% band; star keeps 2× headroom                                                    |
| **Machine floor `sizeup_min_machine_units_wk`** | **> 30 u/wk**               | Structural guarantee. T1 is a per-product test and cannot enforce a machine-level rule; a future fast product on a low-traffic machine would leak again |
| **T2 `sizeup_overflow_factor`**                 | **1.25**                    | Unchanged. Ships in velocity × trip vs capacity form — sell-out telemetry not derivable (§1.7)                                                          |
| **T3 `sizeup_vs_alternative_factor`**           | **1.3**                     | Unchanged                                                                                                                                               |
| **T3 benchmark**                                | **rank-1 BY SUITABILITY**   | The PRD's literal wording. `MAX(exp_vel)` compares against a product the engine would never pick and fails the star case                                |
| **Phase 2b DD proposal loop**                   | **MANDATORY, this session** | Without it PRD-108 delivers zero behaviour change (§1.6)                                                                                                |

**Gate cleared. Phase 2 authorised.**

---

## Phase 2 — Implementation

### 2.0 Call-site audit (before any signature change)

`rank_slot_suitability` has exactly **one** caller in the database — `engine_swap_pod` — and **zero**
callers in the FE or edge functions. `engine_swap_pod` consumes it by **named column only**:

```sql
SELECT rss.pod_product_id, rss.wh_pickable, rss.min_refill_qty, rss.is_size_up, rss.suitability
  FROM public.rank_slot_suitability(...) rss
 ...
 ORDER BY rss.rank
```

No `SELECT *`, no positional dependency. **Appending columns to `RETURNS TABLE` is therefore safe.**
Changing the return type requires `DROP` + `CREATE` (not `CREATE OR REPLACE`), which is acceptable
here: one caller, named-column access, and PostgreSQL resolves function calls at runtime so no
dependency is broken. **No overload will be created** (42725 trap, `RPC_REGISTRY.md:372`).

`rank_slot_suitability` is **not** in the frozen Family-A set
(`engine_add_pod` / `engine_swap_pod` / `engine_finalize_pod` / `pick_machines_for_refill`), so the
PRD-094/095 engine freeze is not touched. `engine_swap_pod` itself is not edited.

### 2.1 Cody constitutional review (2026-07-29, BEFORE any apply)

**Verdict:** ⚠️ Approve with revisions — 1 blocking, fixed before apply.
**Articles checked:** 1, 2, 4, 12, 13, 14, 15, 16

| Finding                                                                                                                                                                                                                                                                                                                                     | Article | State                   |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ----------------------- |
| Design computed velocity inline. `METRICS_REGISTRY.md:33` registers _Machine velocity_ → `v_machine_velocity`, and `:44` registers per-(machine,product) velocity → `v_shelf_sales_identity.dvel`. Inline re-derivation of a registered metric. Required: T1 reads `v_shelf_sales_identity.dvel`, machine floor reads `v_machine_velocity`. | 16      | ❌ blocking → **fixed** |
| `DROP` + `CREATE` permitted only because `RETURNS TABLE` must gain a column; one caller, named-column access, new column appended last, both statements in one migration.                                                                                                                                                                   | 12      | ⚠️ cleared              |
| Same name, same argument list → no overload, no deprecation window needed. Verified `pg_proc` = 1 row after apply.                                                                                                                                                                                                                          | 13      | ✅                      |
| `rank_slot_suitability` stays `STABLE` + `SECURITY INVOKER`; no write statements.                                                                                                                                                                                                                                                           | 4       | ✅                      |
| `refill_policy_params` RLS already enabled (2 policies); additive columns change no policy surface.                                                                                                                                                                                                                                         | 2       | ✅                      |
| No `_v2` object; canonical function evolves in place. No protected entity written; `slot_lifecycle.signal` read-only; PRD-106b `is_dd` requirement untouched.                                                                                                                                                                               | 1, 14   | ✅                      |
| Thresholds param-driven, not hardcoded.                                                                                                                                                                                                                                                                                                     | 15      | ✅                      |

### 2.2 🚨 Second ppad blocker, caught BEFORE apply

The Phase 1 blocker (§1.1) also poisons **T3's benchmark**. Under the function's own
`exp_vel = GREATEST(proven_raw, lookalike, global)` with `proven_raw = ppad`, OMDCW's rank-1 newcomer
scores **1.462** instead of **0.258** — a 5.7× inflation that fails the star case:

| proven term | lookalike | global | exp_vel | T3 bar | star (incr 1.648) |
| ----------- | --------- | ------ | ------- | ------ | ----------------- |
| ppad 1.462  | 0.068     | 0.258  | 1.462   | 1.900  | ❌ fails          |
| calendar    | 0.068     | 0.258  | 0.258   | 0.335  | ✅ passes         |

Fixed by introducing a parallel `proven_cal` (90d calendar rate) used **only** by the size-up path.
`proven_raw` is deliberately **left untouched** for suitability ranking — changing it would move every
candidate's rank fleet-wide, far beyond this PRD's scope.

### 2.3 Applied (prod eizcexopcuoycuosittm)

| #   | Migration                                            | Result                                                                                         |
| --- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| 1   | `prd108_sizeup_params`                               | ✅ 4 params on `refill_policy_params`                                                          |
| 2   | `prd108_rank_slot_suitability_volume_tests`          | ✅ DROP+CREATE; T1∧T2∧T3∧floor; `sizeup_rationale jsonb` appended; 1 overload, STABLE, INVOKER |
| 3   | `prd108_v_sizeup_candidates` + `..._rank1_benchmark` | ✅ Phase 2b proposal surface                                                                   |
| 4   | `prd108_recommend_swaps_dd_parity`                   | ✅ DD branch volume-gated; 1 overload; smoke run returns 3 rows                                |

### 2.4 Phase 2b — `v_sizeup_candidates` (the DD proposal loop's data surface)

Built because `rank_slot_suitability` filters present products out of `gated` unless `is_size_up` is
already true, and `is_size_up` requires `is_dd`. A product passing T1–T3 **without** a DD flag is
therefore invisible in the function's output — exactly the set the weekly loop must surface.

`earns_double_down` = floor ∧ T1 ∧ T2 ∧ T3 ∧ ¬blended. `dd_proposal` = earns it but has no DD flag yet
→ the CS batch-approval worklist. It **proposes only**; `rank_slot_suitability` remains the sole gate
and still requires `is_dd` (PRD-106b intact).

**First-cut bug, caught and fixed:** the view initially used `MAX(exp_vel)` and reproduced the exact
defect Phase 1 identified (OMDCW 1.7214 vs 0.2579 → star failed). Root cause understood and recorded:
**`global_vel` does not appear in the suitability score at all** — that score is
`0.28·pctile(proven) + 0.20·pctile(lookalike) + margin/basket/avail/freshness`; `global_vel` only
enters `exp_vel`. That is precisely why the engine's rank-1 is never the fleet-global outlier and why
`MAX(exp_vel)` is the wrong benchmark. The view now ranks newcomers on the two velocity percentile
terms that dominate suitability.

### 2.5 Acceptance

| Criterion                                                                 | Result                                                                                                                                                                        |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Zombie replay: machine ≤30 u/wk → zero size-up proposals across the band  | ✅ **0 leaks** (`earns_double_down ∧ machine_units_wk ≤ 30` = 0)                                                                                                              |
| Star replay: capacity-constrained shelf passes and outranks best newcomer | ✅ **OMDCW-1021 Al Ain Zero**: floor ✅ T1 ✅ T2 ✅ T3 ✅ (incr 1.648 vs bar 0.897), `earns_double_down`                                                                      |
| Rationale exposes T1/T2/T3 inputs + thresholds                            | ✅ `sizeup_rationale` jsonb: vel_day, full_shelf_units, demand_over_trip, incremental_per_day, newcomer name+exp_vel, machine_units_wk, all 4 thresholds, all 4 test booleans |
| Thresholds tunable without migration                                      | ✅ `refill_policy_params`; view and gate read the same row                                                                                                                    |
| DD still required (PRD-106b invariant)                                    | ✅ `is_dd` retained in `is_size_up`; 0 of 11 existing DD facings qualify, so nothing auto-enables                                                                             |
| `engine_swap_pod` untouched / freeze intact                               | ✅ not edited; `rank_slot_suitability` is not Family-A                                                                                                                        |
| No overload created                                                       | ✅ `pg_proc` = 1 row for both functions                                                                                                                                       |
| Blended still excluded                                                    | ✅ 0 blended in `earns_double_down`                                                                                                                                           |
| **pgTAP suite**                                                           | ❌ **NOT WRITTEN** — verification was live SQL replays, not pgTAP. Carry-forward                                                                                              |

**Live worklist:** 17 `dd_proposal` rows for CS batch approval. Zero take effect until CS sets the flags.

### 2.6 Carry-forward

1. **pgTAP suite** — T1/T2/T3 boundaries, missing-lookalike fallback in T3, DD-still-required invariant,
   params-driven thresholds. Not written; the acceptance criterion is unmet.
2. **Article 16 gap** — no canonical object covers "calendar velocity of a product NOT currently on the
   machine". `v_shelf_sales_identity` covers on-machine slots only, so newcomer `proven_cal` falls back
   to an inline 90d rate. Consider registering that, or widening `v_shelf_sales_identity`.
3. **View vs gate T3 divergence** — the view omits the shelf-specific out-price similarity term, so its
   `newcomer_exp_vel` differs from the gate's (OMDCW: 0.690 view vs 0.258 gate). The view is
   conservative here; both pass the star. Reconcile if the worklist looks off.
4. **T2 upgrade** — measured sell-out days remain unavailable; revisit if shelf-grain history is retained.
5. **Registries** — `MIGRATIONS_REGISTRY.md`, `CHANGELOG.md`, `METRICS_REGISTRY.md` (register
   `v_sizeup_candidates`), `RPC_REGISTRY.md` (`rank_slot_suitability` new return column).
