# PRD-048 — ADD Brain: Service-Level Base-Stock Refill Sizing

Status: DRAFT (2026-06-22, authored from a live backtest on 5 machines)
Owner: CS · Builders: Dara (schema) → Cody (review) → Stax/assistant (impl)
Scope: **ENGINE ADD sizing only** (`compute_refill_decision` qty + `engine_add_pod` `covered`/`flagged` CTEs). Swap engine, picker, stitch, dispatch are OUT of scope and MUST NOT change behavior.

## 1. Problem

Today `engine_add_pod` sizes each refill as `add = velocity × 14d × band_fraction(1.0/0.6/0.3)`, capped at headroom, where `band_fraction` comes from ranking shelves _within a machine_ by `final_score` into terciles. Consequences (verified):

- Identical product at identical stock gets wildly different refills purely by velocity rank (HUAWEI Chocolate Bar 11/25 selling 3/wk → engine target **0**; NOOK same product 9/wk → fill to cap).
- Steady low-volume **local heroes** are starved (sit 40-60% full) → either stock out (fixed route) or force constant revisits (responsive picker).
- **No safety stock** anywhere; demand is ~Poisson so σ=√µ is large at low volume.
- The 14-day cover bakes in a revisit cadence instead of letting fill stretch the cadence.

Backtest (28d, Poisson demand from real 28d sales, common random numbers): under a responsive picker all policies hold ~99.8% service but trips fall 22→14 (-37%) moving from velocity-cover to base-stock; under a fixed weekly route base-stock holds 99.6% service vs 99.3% (existing) at HALF the lost units. The dead rule is fine; the failure is entirely on live sellers.

## 2. Objective

Replace velocity-cover×band sizing with a **service-level base-stock (order-up-to S) policy**: target a stock LEVEL that covers a configurable route interval `T` plus statistical safety stock, capped by capacity, shelf-life and warehouse-pickable stock. Keep the dead rule. Demote rank/score to allocation-order under scarcity only (never a qty cut).

## 3. Policy spec (per shelf, per plan)

```
inputs: v7, v30 (unit velocity windows), current_stock oh, max_stock cap,
        T_machine (route interval days), z_item (service z), shelf_life_days, wh_pickable
mu_day = 0.7*(v7/7) + 0.3*(v30/30)              # recency-weighted EWMA daily rate
sigma  = sqrt(mu_day)                            # Poisson approx; use empirical sd if available
if v7==0 AND v30==0:  add = 0                    # DEAD — unchanged, keep exactly
else:
  S        = mu_day*T_machine + z_item*sigma*sqrt(T_machine)   # base-stock order-up-to
  S        = min(S, mu_day*shelf_life_days*0.8)  # spoilage cap (perishables)
  is_seller = (mu_day*7) >= SELLER_WK_THRESHOLD  # default 1.5 units/wk
  floor    = ceil(MIN_FILL_PCT*cap) if is_seller else 0        # floor ONLY for sellers
  target   = min(cap, max(round(S), floor))
  add      = clamp(target - oh, 0, cap - oh)
  add      = min(add, wh_pickable)               # WH scarcity (engine already clamps)
```

Defaults (config, not hard-coded): `T_machine` per machine class (busy 10-14, standard 18-21, backup/low-traffic 28-45); `z_item` by margin tier (low 1.28≈90%, mid 1.65≈95%, high 2.05≈98%); `MIN_FILL_PCT=0.70`; `SELLER_WK_THRESHOLD=1.5`.

## 4. Edge cases (MUST handle — each needs a test)

1. **Floor-on-tail bug** (found in backtest): the MIN_FILL floor must NOT apply to near-dead items (e.g. Evian 0.2/wk, Loacker 0.5/wk) or it fills junk to 70%. Gate the floor on `is_seller` (mu\*7 ≥ threshold). Verified: ungated floor produced +47u of junk; gated → +19u of real sellers.
2. **New product / RAMPING** (v7=v30=0 but intentionally placed, not dead): do NOT treat as dead-zero. Use a prior: category/global mu, or a seed level = MIN_FILL_PCT\*cap for N days, flagged `cold_start`. Needs an explicit "is this new vs dead" signal (placement age or lifecycle stance RAMPING).
3. **Multi-shelf same product** (HUAWEI Healthy Cola A02+A03, NOOK Coca Cola Zero A01+A05): split demand across the shelves holding it; do not double-count mu.
4. **Censored demand**: recorded sales under-count true demand on stockout days. Inflate mu using a censoring correction (e.g. up-weight days that ended at 0) or use uncensored where the inventory log allows. At minimum document the bias.
5. **Perishable / short shelf-life**: spoilage cap `S ≤ mu*shelf_life*0.8` must dominate; a 3-week-shelf-life item on a 6-week target must clamp. Pull batch expiry (FEFO at WH pick) — coordinate with EXPIRY OPT.
6. **Overstock** `oh > cap` (snapshot artifacts, e.g. 23/20): add = 0, never negative.
7. **Zero WH pickable**: add clamps to 0 and emits a procurement alert (existing behavior — keep).
8. **Very high velocity**: S exceeds cap → fill to cap (already handled by min(cap,...)).
9. **Explicit operator overrides**: CS manual `edit_pod_refill_row` / swaps must survive; the brain sizes only engine-owned REFILL rows, never ADD_NEW/REMOVE swap rows or operator-edited rows (respect `edited_by`/source).
10. **Driver requested qty floor**: `add = max(add, driver_req_qty)` where present (keep current behavior).
11. **mu_day rounding to 0** for genuine slow sellers (1/month): base-stock gives ~1-2; do not force to floor; allow small adds.
12. **Capacity/planogram changes** mid-cycle: recompute against live `max_stock`; never assume stale cap.

## 5. Schema / inputs (Dara)

- `machines.trip_interval_days int` (nullable, default by a `machine_class` lookup). New column or a `machine_service_policy` table (machine_id, trip_interval_days, z_default).
- Item margin tier: reuse `v_product_landed_cost` + price → margin → z. Shelf-life/expiry: reuse `warehouse_inventory.expiration_date` (FEFO).
- A `refill_policy_params` singleton/table for global defaults (MIN_FILL_PCT, SELLER_WK_THRESHOLD, EWMA weights) so tuning needs no code change.

## 6. Implementation & gating (Cody is mandatory — canonical writer)

- New version `compute_refill_decision` (qty path) + `engine_add_pod` `covered`/`flagged` CTEs. Bump engine_version string (e.g. `v19_base_stock`).
- **Feature-flag `refill_sizing_mode` (`legacy` | `base_stock`), default `legacy`.** When `legacy`, output MUST be byte-identical to current (gate-clean test: md5 of pod_refill_plan for a fixed plan_date unchanged).
- No change to engine_swap_pod, picker, stitch, dispatch. swaps_enabled stays FALSE.
- Migrations applied **MCP-only**, NOT git-committed in this pass; NO prod enable.

## 7. Validation

- Port the backtest harness (Poisson MC, common random numbers, two regimes: responsive-picker trips, fixed-route service) into `boonz-erp/scripts` or a SQL/pytest harness. Metrics: service %, lost units, lost AED, trips, avg fill, avg on-hand.
- Acceptance: with flag `base_stock`, on the 5 pilot machines, trips ≤ legacy at equal-or-better service in responsive regime; lost units < legacy in fixed regime; no floor-on-tail (slow items < threshold get no floor); legacy flag gate-clean.

## 8. Rollout (later, CS-gated)

Ship flag OFF → backtest fleet-wide → enable `base_stock` per machine class behind the flag → pilot a tiered fixed route on the low-velocity class (see §9) → monitor trips & stockouts → fleet enable.

## 9. Open question answered: fixed weekly route?

Yes, for the low-traffic tier it cuts trips hard (responsive base-stock ≈14 trips/28d vs a fixed weekly route = 4), and the base-stock safety term is exactly what keeps service ~99.6% across the longer gap. But it must be a **per-machine-class cadence** (busy machines can't go weekly) and that cadence IS the brain's `T`. Sequence: ship the brain, then pilot fixed routes on the low-velocity class. Do not impose one global weekly route.

## 10. Non-goals

Swap/rotation logic, picker selection, pricing, planogram design, WH procurement sizing. ADD sizing only.
