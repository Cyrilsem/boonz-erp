# Refill Engine Bible v6 — the one doctrine (as live in prod)

**Status: CANONICAL as of 2026-07-11 (PRD-CLEAN-04).**
**Supersedes:** BOONZ_REFILL_BRAIN_v3.md lineage, refill_engine_bible_v5_7.html,
v5_8.html, v5_9.html, v5_10.html. Those documents describe engines that no longer run.

This document describes the doctrine as **implemented** by the live engine
(`engine_add_pod`, engine_version `v19_base_stock`, `refill_sizing_mode='base_stock'`
in `refill_policy_params` since 2026-06-22). It is a description of running code,
not an aspiration. If this doc and `pg_get_functiondef(engine_add_pod)` disagree,
the code wins and this doc is stale.

## 1. The v5-era contradiction, and how v6 resolves it

- v3/v5.x doctrine: velocity-based days-of-cover, "never blindly refill to max_stock".
- Refill v2 (June 2026, "v15"): fill-to-capacity on every selling shelf, warehouse
  scarcity as the only throttle.

Doctrine v6 is the hybrid: **a demand-based base-stock target with a seller floor and
a perishability cap**. Fast shelves still fill toward capacity (the floor), slow
shelves get a statistical days-of-cover target, and perishables are capped by what can
sell within their remaining shelf life. Ranking/score stays ranking-only for warehouse
scarcity ordering — it never caps a fill.

## 2. The formula (compute_base_stock_decision, per shelf)

Inputs: 7d/30d sales, current stock (oh), slot capacity (cap), machine trip interval
(machine_service_policy.trip_interval_days, default 21), service level z by product
margin, remaining shelf life of pickable WH stock (v_product_shelf_life), WH pickable
units, and the tuner row `refill_policy_params` (single row, id=1).

```
mu_day       = w7 * (sales_7d / 7) + w30 * (sales_30d / 30)        -- EWMA blend (0.7 / 0.3)
sigma        = sqrt(mu_day)                                        -- Poisson approximation
s_raw        = mu_day * trip_days + z * sigma * sqrt(trip_days)    -- base-stock level
spoilage_cap = mu_day * shelf_life_days * spoilage_factor          -- perishable cap (0.8)
s_capped     = LEAST(s_raw, spoilage_cap)                          -- cap binds ALL grades
floor        = is_seller ? CEIL(min_fill_pct * cap) : 0            -- seller floor (70%)
target       = LEAST(cap, GREATEST(round(s_capped),
                    is_seller ? LEAST(floor, round(spoilage_cap)) : 0))
want         = GREATEST(LEAST(target, cap) - oh, 0)                -- never below current stock
add          = LEAST(want, wh_pickable)                            -- WH scarcity clamp
```

- `is_seller`: mu_day * 7 >= seller_wk_threshold (1.5/week).
- `z` by margin: < 37.1% margin → 1.28; >= 51.4% → 2.05; else 1.65
  (z_low / z_mid / z_high; per-machine z_default can override when margin unknown).
- Dead shelf (no 7d AND no 30d sales, not cold-start): qty 0 + dead tag in `pod_swaps`
  (reason 'dead' or 'rotate_out' by stance) — the swap engine handles replacement.
- Cold start (RAMPING signal or slot age < cold_start_days=14): seeded to
  min_fill_pct * cap instead of being marked dead.

### Reason codes (bs_decision.reason)

`dead_zero`, `cold_start_seed`, `at_or_above_target`, `wh_limited`, `fill_to_cap`,
`seller_floor`, `base_stock_target`. Row-level `clamp_reason` on `pod_refills`:
`skipped_strategic_intent`, `dead_tagged_for_swap`, `drain_no_refill`, `skipped_full`,
`blocked_no_wh`, `partial_wh_limited`, `driver_request`, `cover_capped`, `fill_to_cap`.

## 3. How the v6 hybrid maps to the old A/B/C/D grading

The engine no longer grades A/B/C/D directly; the base-stock math produces the same
qualitative behaviour continuously:

- Old "A/B fill to capacity" → seller floor (70% of cap) + s_raw that exceeds cap for
  fast movers → `fill_to_cap` / `seller_floor`.
- Old "C: velocity * cover_days with floor" → `base_stock_target` (s_raw with safety
  stock; z replaces the arbitrary floor).
- Old "perishable half-life cap" → `spoilage_cap` using REAL remaining shelf life of
  the warehouse batches that would be picked (not a category-level assumption).
- Old "D: qty 0 + swap tag" → `dead_zero` + pod_swaps tag (unchanged).

## 4. Warehouse scarcity allocation

Shelves compete for WH stock per pod product, ordered by v30 DESC then final_score
(ranking-only). Each shelf gets `LEAST(need, remaining_pool)`; shortfalls surface as
`procurement_gaps` in the engine output and as procurement alerts at stitch time.
WH availability = serving warehouses only, status='Active', quarantined=false,
in-date, not reserved for another machine (see DARA warehouse-availability canonical).

## 5. Other live inputs the target respects

- Driver feedback demand (v_driver_feedback_demand) can raise qty up to headroom
  (`driver_request`); resolved feedback is stamped by the engine.
- Strategic intents (decommission/rebalance, queued/in_progress) zero the shelf
  (`skipped_strategic_intent`).
- Optional flags (refill_qa.flag): `add_abs_floor_v1` (min facing floor for shelves
  with velocity >= abs_velocity_floor), `add_niche_fill_v1` (niche products with
  footprint <= 2 machines). Both dark unless flipped.
- Approved machines are never rebuilt (`v14_preserve_approved` finalize; picked
  machines with an approved refill_plan_output row are excluded).

## 6. Pipeline context (unchanged by v6)

pick_machines_for_refill (06:00 Dubai cron) → build_draft_for_confirmed (20:00 Dubai
cron) → engine_add_pod → engine_swap_pod → engine_finalize_pod → approve_pod_refill_plan
→ stitch_pod_to_boonz (v29, WEIMI slot-identity guard) → write_refill_plan →
push_plan_to_dispatch → refill_dispatching (driver PWA). Gate model: `_assert_gate_zero`
before the engine writes; `_assert_refill_plan_writable` protects stitched/dispatched
dates; stitch refuses without approved rows.

## 7. Tuner surface (where CS turns knobs)

- `refill_policy_params` (id=1): refill_sizing_mode, min_fill_pct, seller_wk_threshold,
  ewma_w7/w30, z_low/mid/high, margin cuts, spoilage_factor, cold_start_days,
  abs_velocity_floor, min_facing_floor, niche_*, expiry_risk_days, weimi_slot_guard.
- `machine_service_policy`: per-machine trip_interval_days, z_default.
- `pick_urgency_params`: picker urgency weights (visit selection, not sizing).
- `refill_settings`: swaps_enabled (still false as of 2026-07-11).

## 8. Verified invariants (2026-07-11, PRD-CLEAN-04 battery)

On live engine output: 0 rows qty < 0; 0 rows with qty > 0 while current >= target;
0 rows over headroom; spoilage_cap present on 42/43 rows of the sample plan and
binding on real dates (e.g. Activia Mix & Go s_raw 20.2 → cap 4.9 at ADDMIND-1007;
Chocolate Bar s_raw 60.3 → cap 32.5 at AMZ-1038). Finalize R7 (60% machine cap)
reported 0 overruled refills on the same cycle.

## 9. Capacity model (documented per PRD-CLEAN-07; no physical change)

Two live tables answer "how many units fit in a slot":

- `capacity_standard` (~110 rows) — per product-TYPE default capacity by slot format.
  The fallback when no product-specific override exists.
- `product_slot_capacity` (~33 rows) — per-PRODUCT override; wins over the standard
  when present (engine_swap_pod capacity matrix, PRD-039).

`slot_capacity_max` was the third, dead variant (0 rows) — graveyarded would have been
PRD-CLEAN-03's call, but it is KEPT in public because live `engine_swap_pod` still
references it (see DECISIONS.md PRD-CLEAN-03).

## 10. Config single pane

`SELECT * FROM v_refill_config ORDER BY source_table, param;` — long-format
(source_table, param, value) union over pick_urgency_params (36 params),
refill_policy_params (21), refill_settings (2 flags). Dead config tables
refill_priority_params and service_priority_params moved to graveyard 2026-07-11.
Deferred debt: folding refill_policy_params / refill_settings into one table would
require patching engine_add_pod / engine_swap_pod / assert_weimi_slot_match — parked
deliberately (live-engine criticality).
