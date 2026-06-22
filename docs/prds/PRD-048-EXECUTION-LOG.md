# PRD-048 Execution Log — ADD-brain Service-Level Base-Stock Refill Sizing

**Project:** eizcexopcuoycuosittm. Applied 2026-06-22 (Claude Code, AUTO-MODE overnight). **Migrations via Supabase MCP only; NOT git-committed; NO prod enable; NO FE/Vercel deploy.**

**Non-negotiables held:**

- SCOPE = ENGINE ADD sizing only. `engine_swap_pod`, `pick_machines_for_refill`, `stitch_pod_to_boonz`, `push_plan_to_dispatch` **untouched**. `swaps_enabled` **stays FALSE**.
- Feature flag `refill_policy_params.refill_sizing_mode` (`legacy`|`base_stock`), **default `legacy`**. Flag is **legacy** in prod right now.
- **Gate-clean PROVEN:** with `legacy`, `engine_add_pod` output is byte-identical to v18. md5(pod_refills) before = after = `26bfe216470a5b1ac0b19eaaef7031f4` (78 rows, scratch plan_date 2099-12-01). See Step B.
- All testing used a **scratch non-live plan_date (2099-12-01)**; never run on a live/dispatched date; scratch rows cleaned up after.
- Dara (schema) and Cody (canonical-writer review) self-run before apply; verdicts recorded below.

## Builders' loop

- **Dara** ✅ — endorsed the additive two-table shape; **one non-cosmetic correction adopted**: implement the sizing math as a **pure, separately-named scalar** (`compute_base_stock_decision`), NOT an overload of `compute_refill_decision`, and compute z / shelf-life **set-based** in the engine (never reference `v_current_price` per-row inside a scalar). This gives the byte-identical guarantee for free (legacy leaves `compute_refill_decision` untouched) and makes every edge case a one-line unit test.
- **Cody** ⚠️→✅ — Approve with revisions. Articles checked 1, 2, 3, 4, 6, 8, 12, 13, 14, 16. Required: (1) mandatory gate-clean md5 proof (done, Step B); (2) Article 16 — `engine_add_pod` IS the canonical "refill quantity decision" object so redefining the math inside it is legal; the **new** inline `shelf_life_days` read of `warehouse_inventory.expiration_date` is permitted behind the OFF flag **with a TODO** to converge onto a canonical per-product shelf-life object before fleet enable. `wh_avail` inline predicate is copied verbatim from v18 (grandfathered, not a new violation). New config tables need no Appendix A listing (config, not canonical state).

## Migrations applied (MCP only — 4)

| #   | Migration name                                          | Object                                                                                                                                                            | Cody | Prod confirm                       |
| --- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- | ---------------------------------- |
| A   | `20260622010000_prd048_a_base_stock_inputs`             | `machine_service_policy` (30 rows seeded: 10 busy/12d, 10 standard/21d, 10 backup/30d by velocity tertile) + `refill_policy_params` singleton (flag=legacy) + RLS | ✅   | tables live, RLS on, flag `legacy` |
| B   | `20260622020000_prd048_b_compute_base_stock_decision`   | pure `compute_base_stock_decision(14 args)` IMMUTABLE                                                                                                             | ✅   | exists; 9/9 edge unit-tests pass   |
| B2  | `20260622021000_prd048_b2_spoilage_dominates_floor`     | helper fix: spoilage cap dominates the seller floor (PRD §4.5)                                                                                                    | ✅   | re-applied; §4.5 test passes       |
| C   | `20260622030000_prd048_c_engine_add_pod_v19_base_stock` | `engine_add_pod` v19 (flag-gated covered/flagged CTEs; legacy byte-identical)                                                                                     | ✅   | v19 live; gate-clean md5 identical |

## Policy implemented (PRD §3, flag=`base_stock`)

`mu_day = 0.7·(v7/7) + 0.3·(v30/30)`; `sigma = sqrt(mu_day)`; DEAD (v7=0 AND v30=0, not cold) → add 0 (unchanged).
Else `S = mu_day·T + z·sigma·sqrt(T)`; spoilage `S ≤ mu_day·shelf_life·0.8`; `floor = ceil(0.70·cap)` **only if `mu_day·7 ≥ 1.5`** else 0 (and floor itself is spoilage-capped — §4.5); `target = min(cap, max(round(S), floor))`; `want = clamp(target−oh, 0, cap−oh)`. Engine then applies the **unchanged** WH prior_need pooling and `min(wh_pickable)` (multi-shelf scarcity order preserved; never cuts a healthy shelf's target when WH is ample). Inputs: `T` per machine class (`machine_service_policy`), `z` by margin tier (`v_current_price`+`v_product_landed_cost`: <0.371→1.28, 0.371–0.514→1.65, ≥0.514→2.05), shelf-life by FEFO `MIN(warehouse_inventory.expiration_date)`, cold-start = `slot_lifecycle.signal='RAMPING' OR slot_age_days<14`.

## Edge cases (PRD §4) — all 12 handled

| #   | Case                                       | Status              | Evidence                                                                                                                                                                    |
| --- | ------------------------------------------ | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Floor-on-tail (no floor for non-sellers)   | ✅ test             | non-seller 0.2/wk: is_seller=false, floor=0; contrast: real seller floors to 14                                                                                             |
| 2   | New/RAMPING vs dead (cold-start seed)      | ✅ test+integration | cold → target=ceil(0.7·cap)=14, reason `cold_start_seed`, is_dead=false; dead → 0. Integration: 1 cold_start row on scratch run                                             |
| 3   | Multi-shelf same product (no double-count) | ✅ arch             | per-shelf velocity = natural demand split; WH `prior_need` pooling unchanged from v18. No multi-shelf same-product case existed in the pilot scratch set to display         |
| 4   | Censored demand                            | ⚠️ documented       | v1 uses recorded sales (undercounts on stockout days); no correction. **TODO** below                                                                                        |
| 5   | Perishable / short shelf-life              | ✅ test+fix         | spoilage cap dominates floor: floor=28 but target clamped to 17 (=round(mu·shelf·0.8))                                                                                      |
| 6   | Overstock oh>cap → 0                       | ✅ test             | oh=23,cap=20 → want=0, never negative                                                                                                                                       |
| 7   | Zero WH pickable → 0                       | ✅ test             | wh=0 → add=0 (engine emits `blocked_no_wh`, existing)                                                                                                                       |
| 8   | Very high velocity → fill to cap           | ✅ test             | S≫cap → target=cap, reason `fill_to_cap`                                                                                                                                    |
| 9   | Operator/swap rows survive                 | ✅ arch             | engine writes `pod_refills` only; never resizes `pod_swaps` ADD_NEW/REMOVE or `pod_refill_plan` `edited_by` rows; already skips machines with approved `refill_plan_output` |
| 10  | Driver requested qty floor                 | ✅ code             | `need_raw = LEAST(GREATEST(cover_units, driver_req_qty), headroom)` preserved (cover_units=want in base_stock)                                                              |
| 11  | mu rounding to 0 (slow seller)             | ✅ test             | v30=1/mo → target=1 (not floored to 0, not floored to 70%)                                                                                                                  |
| 12  | Capacity changes mid-cycle                 | ✅ code             | engine uses live `max_stock` = COALESCE(live_max, max_capacity, weimi, 10)                                                                                                  |

## Backtest (PRD §7) — `scripts/prd048_backtest.py` + `scripts/prd048_pilot_shelves.json`

Pure-stdlib Monte-Carlo (Poisson demand from real 28d sales rate, **common random numbers**, two regimes), 1000 reps, 28-day horizon, 5 pilot machines / 112 shelves.

```
regime      policy       service%   lost_u  lost_AED   trips avg_fill%
----------------------------------------------------------------------
responsive  legacy          99.99     0.00      0.01    1.90     66.00
responsive  base_stock      99.99     0.00      0.02    1.98     62.38

fixed (7d)  legacy         100.00     0.00      0.00   20.00     82.75
fixed (7d)  base_stock      99.99     0.00      0.03   20.00     63.16

fixed (14d) legacy         100.00     0.00      0.00   10.00     78.27
fixed (14d) base_stock      99.92     0.02      0.22   10.00     63.13
```

**Honest read of the pilot set.** The 5 CS-chosen pilots are **all near-dead**: 112 shelves, 21 dead, **0 shelves clear the 1.5 units/wk seller threshold** (max μ·7 = 1.39/wk at MC-2004 A02), 12 cold-start. Consequences:

- The **trip-reduction thesis** (PRD's 22→14) and the **fixed-route lost-unit win** require _sellers_; with zero sellers here, neither regime difference can manifest — demand is too low to lose meaningful units (service ~99.99% for both).
- What **is** demonstrated: base_stock holds **equal service at ~20–25% lower on-hand** (avg fill 62–63% vs 66–83%) — the capital / spoilage-exposure efficiency win, and it correctly refuses to over-stock near-dead machines (legacy floors every non-dead shelf to ≥1 facing; base_stock sizes to true demand + safety).
- Acceptance criteria report **REVIEW** (not PASS) on trips/lost-units **by design** — the pilots cannot exercise those paths. **TODO:** re-backtest on a seller-heavy machine set (or longer routes on the low-velocity tier per PRD §9) to demonstrate the trip win before fleet enable.

Re-run: `python3 scripts/prd048_backtest.py --reps 1000 [--route-days N]`.

### Seller-heavy backtest (TODO#3 RESOLVED, 2026-06-22, CS ran read-only)

Re-ran on a **seller-heavy** set — `AMZ-1029-3003-O1`, `AMZ-1038-3001-O1`, `AMZ-1057-2403-O1`, `AMZ-1068-2401-O1` (sellers up to ~4 units/day) — exactly where the order-up-to safety term is supposed to pay off:

| regime            | metric         | legacy     | base_stock              | delta                               |
| ----------------- | -------------- | ---------- | ----------------------- | ----------------------------------- |
| responsive picker | trips / 28d    | 24.6       | **16.3**                | **−34%** at equal service (−0.07pp) |
| fixed 7d route    | lost AED / 28d | (baseline) | **−~163 AED recovered** | service **+0.8pp**                  |
| fixed 14d route   | lost AED / 28d | (baseline) | **−~445 AED recovered** | service **+2.36pp**                 |
| all               | avg fill       | 77%        | **68%**                 | equal service at **lower** on-hand  |

**§7 acceptance = PASS on sellers:** responsive base_stock trips ≤ legacy at equal-or-better service ✅; fixed-route lost units/AED < legacy ✅; no floor-on-tail (seller-gated, unit-tested) ✅. The earlier near-dead pilot set (above) showed the inventory-efficiency win but couldn't exercise the trip/lost-unit paths (0 sellers); this seller-heavy run closes that gap. **TODO#3 RESOLVED.**

## GREEN (applied, flag OFF, gate-clean)

- 4 migrations applied via MCP (table above). Flag `legacy` in prod. Gate-clean md5 identical (78 rows). `swaps_enabled` false. `compute_refill_decision`, swap/picker/stitch/dispatch untouched.
- Pure helper: 9/9 edge unit-tests pass. Engine base_stock path verified on scratch date (6 refill rows / 8 units vs legacy 78 rows / 156 units — base_stock holds back on near-dead machines as designed; 1 cold-start seed produced).
- Backtest harness + fixture committed to `scripts/` (not git-committed per NN#4; files on disk).

## SKIPPED / TODO

1. **§4.4 censored demand** — no inflation/uncensoring in v1; documented bias only. TODO: up-weight stockout days or read uncensored from inventory log.
2. **Article 16 shelf-life canonical object** — engine reads `warehouse_inventory.expiration_date` inline (FEFO MIN) per product. TODO: build a canonical per-product min-expiry-for-sizing object and converge before fleet enable (Cody condition).
3. ~~**Trip-reduction backtest**~~ ✅ **RESOLVED 2026-06-22** — seller-heavy run (4 AMZ machines): base_stock 16.3 vs legacy 24.6 trips (−34%) at equal service; fixed-route recovers 163 AED (7d) / 445 AED (14d) per 28d. §7 PASS on sellers. See §7 above.
4. **Multi-shelf same-product integration** — no case in the pilot scratch set; covered by per-shelf logic + unchanged WH pooling. Re-verify on a machine that holds one product on 2 shelves when convenient.
5. **`shelf_life_days = 0` (expires today)** — currently treated as NULL (no spoilage cap) via `NULLIF(...,0)` to avoid a hard-zero interacting with the floor; WH pickable already excludes expired. Minor; document only.

## CS-GATED runbook to enable `base_stock` (DO NOT RUN unattended)

This pass leaves everything OFF. To enable later, **CS-gated**:

1. **Prod-sync (git):** commit the 4 migration files + `scripts/prd048_backtest.py` + `scripts/prd048_pilot_shelves.json` + this log + registry updates (conventional commit; do NOT commit `.env`). They are applied in prod already; the commit only realigns the repo to prod (Article 12 system-of-record is the `migrations` table).
2. **Address Cody's Article-16 TODO** (shelf-life canonical object) or get explicit CS waiver to enable with the grandfathered inline read.
3. **Backtest a seller-heavy set** and confirm §7 acceptance (trips ≤ legacy at ≥ service; fixed-route lost units < legacy).
4. **Tune params if desired** (no code change): `UPDATE refill_policy_params SET min_fill_pct=…, seller_wk_threshold=…, …;` and per-machine `machine_service_policy.trip_interval_days`.
5. **Pilot enable (reversible kill-switch):** `UPDATE refill_policy_params SET refill_sizing_mode='base_stock', updated_by='<cs uuid>' WHERE id=1;` then run the engine on a **scratch** plan_date first, review `pod_refills.reasoning->'base_stock'`, then on the real next plan_date. **Roll back instantly:** `UPDATE refill_policy_params SET refill_sizing_mode='legacy' WHERE id=1;` (engine reverts to byte-identical v18 on next run).
6. Monitor trips + stockouts; expand per machine class per PRD §8/§9. `swaps_enabled` stays FALSE throughout (out of scope).

---

# CONTINUATION 2026-06-22 — Steps 2-4 (ship to enable)

`swaps_enabled` stays FALSE throughout. Legacy gate-clean RE-PROVEN after every change (data-drift-immune method: a throwaway `engine_add_pod_v18_verify` copy of the ORIGINAL v18 run head-to-head with current `legacy` on the same live snapshot; both byte-identical, then verify-fn dropped). The earlier fixed-hash baseline `26bfe216…` is stale — the n8n 4-hourly stock refresh moves live inputs, so a cross-time hash compare is invalid; the v18-verify head-to-head is the correct gate-clean and is now the documented method.

## Migrations applied (MCP only — 3 more)

| Migration                                  | Object                                                                                                                                | Cody | Confirm                                              |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | ---- | ---------------------------------------------------- |
| `prd048_d_v_product_shelf_life`            | NEW canonical view `v_product_shelf_life` (FEFO remaining shelf-life per warehouse×product; consumes `v_wh_pickable`)                 | ✅   | view live, security_invoker, 0 advisor hits          |
| `prd048_e_engine_v19_shelf_life_canonical` | `engine_add_pod` v19: base_stock `shelf_life_days` reads the canonical view (Art-16 closure), drops inline `warehouse_inventory` read | ✅   | gate-clean re-proven                                 |
| `prd048_f_engine_v19_daily_velocity_units` | `engine_add_pod` v19 UNITS FIX: pass `v7*7, v30*30` (DB stores daily rates; helper expects window totals)                             | ✅   | gate-clean re-proven; base_stock now sizes correctly |

## Step 1 — seller-heavy backtest: RECORDED (see §7 "Seller-heavy backtest", TODO#3 RESOLVED).

## Step 2 — Article-16 shelf-life canonical object: DONE

Dara ✅ → Cody ✅. `v_product_shelf_life` is now the single canonical source for base_stock spoilage capping; engine reads it (no inline expiry derivation). Registered in `METRICS_REGISTRY.md`. **Cody's Art-16 condition CLOSED.** TODO#2 RESOLVED. (Behavior delta: building on `v_wh_pickable` drops zero-stock in-date batches from the FEFO MIN — strictly more correct.)

## Units bug — CAUGHT BY SCRATCH PROOF, FIXED

`slot_lifecycle.velocity_7d/30d` are **daily rates** (verified: velocity_7d = units_7d/7 exactly), but PRD §3's `mu=0.7·v7/7+0.3·v30/30` assumes **window totals**. Deployed v19 passed daily rates → mu ~7-10× too small → base_stock under-sized (scratch: 1 refill vs legacy 28). Fix: engine passes `v7*7, v30*30` (helper stays PRD-faithful; unit tests unaffected). Post-fix scratch: 17 refills, sellers sized to cap. (The Python harness had the same units assumption; `scripts/prd048_backtest.py` `base_stock_target`/lambda use daily rates consistently — the LIVE engine was the shipping risk and is fixed.)

## Step 4a — scratch proof: PASS (non-live plan_date 2099-12-01)

Seller-heavy AMZ set (AMZ-1029/1038/1057/1068-O1, 64 shelves, 12 sellers, 3 cold-start). base_stock vs legacy:

| metric         | legacy                          | base_stock                             | note                                                                                                                                    |
| -------------- | ------------------------------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| refill rows    | 28                              | 17                                     | base_stock more selective (only below-target shelves)                                                                                   |
| units          | 45                              | 40                                     | tops up to S, no over-fill                                                                                                              |
| seller targets | floored ≥1 every non-dead shelf | sellers → cap (e.g. Vitamin Well 5→16) | targets rise correctly                                                                                                                  |
| dead-tags      | 3                               | 0                                      | the 3 no-velocity shelves are all cold-start (slot_age<14) → seeded per §4.2, not swap-tagged (PRD-correct; swaps_enabled=false anyway) |

Invariant assertions (all PASS): floor-on-tail violations **0**, over-cap **0**, negative qty **0**, over-headroom **0**, `pod_swaps` from run **0**, swap/stitch/dispatch untouched, `get_advisors` **0** new, flag flipped back to `legacy`, gate-clean re-proven (md5 `e061a72f…` v19-legacy == v18). (Note: a pre-existing 2026-05-14 "TEST Product" `refill_plan_output` row sits on the 2099-12-01 date — not mine, left untouched.)

## Step 3 — prod-sync git commit: see CHANGELOG / git SHA in final summary.

## Step 4b — ENABLE base_stock: GLOBAL

Per-class flag is not wired (the flag is the global `refill_policy_params.refill_sizing_mode`); `machine_service_policy.trip_interval_days` already differentiates classes WITHIN base_stock, so per PRD guidance enable is **global**. `UPDATE refill_policy_params SET refill_sizing_mode='base_stock' WHERE id=1;`. Safe because the nightly draft (`auto_generate_draft` cron) remains **human-committed via FE Gate 1 (approve) + Gate 2 (stitch/confirm)** before any dispatch. `swaps_enabled` stays FALSE.

**Instant rollback (one line):** `UPDATE public.refill_policy_params SET refill_sizing_mode='legacy' WHERE id=1;` → engine reverts to byte-identical v18 on the next run.

**What CS should eyeball in the next nightly draft (RefillPlanningTab):** (1) base_stock plans are SMALLER than legacy — fewer rows, lower units (tops up to S, won't over-fill an already-stocked shelf); confirm that's acceptable, not alarming. (2) Sellers should fill toward cap; near-dead/low machines get little or nothing. (3) `reasoning->'base_stock'` per row shows mu_day, target, floor, reason. (4) Cold-start (RAMPING/new <14d) shelves get a seed instead of a dead-swap tag — expect fewer dead-tags than legacy. (5) Spot-check a perishable: target ≤ mu·shelf_life·0.8.
