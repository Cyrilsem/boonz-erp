# PRD-031 WS-3 — engine fill target: Hybrid cover-floor / capacity-ceiling (Dara design, for Cody)

**Date:** 2026-06-14 · **CS decision (2026-06-14):** Option B — "cover is the target, capacity caps." Slow-but-selling movers fill to cover, not full; capacity binds only for fast movers. Engine `engine_add_pod` v16 → v17.

## 0. Live reality (corrects the PRD premise)

PRD root-cause C said the engine sets qty from `velocity × days_cover`. **Live v16 does the opposite:** `need_raw = GREATEST(max_stock − current_stock, driver_req)` = fill-to-capacity (WH-capped). The velocity cover IS computed (`compute_refill_decision.velocity_target`) but the engine ignores it. The 278-vs-661 under-fill the PRD saw was the downstream stitch leak (WS-2, fixed), not the engine. So WS-3 is a real behavior change from "always fill to capacity" to "fill to cover, capacity caps."

`compute_refill_decision` already returns `velocity_target = v_velocity × p_days_cover × cover_mult` where `v_velocity = 0.6·v7 + 0.4·v30` and `cover_mult` is stance-aware (STAR 2.0, DOUBLE DOWN 1.5, KEEP/RAMPING/WATCH/WIND DOWN 1.0, ROTATE OUT/DEAD 0). That is exactly the cover units to top up. **Drift bug:** the engine calls `compute_refill_decision(..., 10)` hardcoded while its own `p_days_cover` defaults 14 — WS-3 aligns this so cover honors the engine's days_cover.

## 1. The change (engine_add_pod v17_cover_capped)

Cover is a top-up amount (units of demand over the cover window), capacity is the ceiling, driver requests are honored up to capacity, WH still caps last.

- `cover_units` (new): stance-aware cover top-up.
  `cover_units = CASE WHEN stance IN ('WIND DOWN','ROTATE OUT','DEAD') THEN 0 ELSE GREATEST(ROUND(velocity_target)::int, 1) END`.
  Wind-down/rotate/dead get 0 (matches `compute_refill_decision` capping their target at current — no refill). Every other live selling shelf gets at least 1 so it is never silently skipped to 0.
- `need_raw` (changed): `LEAST( GREATEST(cover_units, driver_req_qty), fill_to_cap )`.
  - Loacker (KEEP, v≈0.2, cover ≈ 0.2·14·1 = 2.8 → 3, gap 9) → **3** (cover binds, lean).
  - Sunbites (cover ≈ 4, gap 5) → **4**.
  - Coca-Cola (cover ≈ 30, gap 21) → **21** (capacity binds).
  - Driver requests 5 on Loacker → `LEAST(GREATEST(3,5),9)=5` (driver honored up to cap).
- `compute_refill_decision(c.machine_id, c.shelf_id, NULL, 10)` → `(..., p_days_cover)` (drift fix).
- `final_qty` unchanged: `LEAST(need_raw, GREATEST(wh_avail − prior_need, 0))` — WH allocation + shared-SKU `prior_need` pool intact (smaller `need_raw` means less WH contention, fewer false procurement gaps).
- `clamp_reason`: add `cover_capped` (cover_units < fill_to_cap → lean fill) vs keep `fill_to_cap` (cover ≥ gap → filled to capacity); `driver_request` when a driver request exceeded cover (≤ gap); existing `partial_wh_limited`/`blocked_no_wh`/`skipped_full`/`dead`/`drain` verbatim.
- `reasoning` jsonb gains `cover_units` + `velocity_target`; `engine_calibration` → `refillv2_v17_cover_capped`.
- Housekeeping for the version bump: the top `DELETE FROM pod_swaps ... tagged_by IN (...)` list gains `engine_add_pod_v17`; `dead_tags.tagged_by` and `driver_feedback.resolved_by_engine` → `engine_add_pod_v17`; `engine_version` → `v17_cover_capped`.

Not changed: `compute_refill_decision` (its `velocity_target` field is consumed as-is; the engine simply stops ignoring it). Its `refill_qty`/`target_units` carry an extra **visual floor** (`floor_pct × cap`, e.g. KEEP fills to 70% cap) which CS's "lean slow movers" decision explicitly rejects — so the engine consumes `velocity_target` (bare stance cover), NOT `refill_qty`. Documented in the registry so the two do not read as drift.

## 2. Article 16 (canonical "refill quantity decision")

The registered canonical object is `compute_refill_decision` + the engine emit. WS-3 keeps ONE definition: cover = `compute_refill_decision.velocity_target` (single source of the velocity cover), engine v17 applies the capacity ceiling + driver + WH. METRICS_REGISTRY row updated from "engine v16 fill-to-cap" to "engine v17 cover-capped (velocity_target ceiling capacity)". No inline re-derivation of velocity.

## 3. Battery (read-only; no live plan regenerated)

Primary is a read-only SELECT over real `slot_lifecycle` + `compute_refill_decision` for currently-picked machines (or a recent picked plan_date), per shelf computing `stance, velocity, velocity_target(14), fill_to_cap, v16_qty=fill_to_cap, v17_qty=LEAST(GREATEST(cover_units,driver),fill_to_cap)`:

- B-slow: a slow KEEP mover with gap > cover → v17 < v16 (lean), v17 = cover.
- B-fast: a fast mover with cover ≥ gap → v17 = v16 = fill_to_cap (capacity binds, unchanged).
- B-winddown: WIND DOWN/ROTATE OUT shelf → v17 = 0 (no refill).
- B-driver: a driver-requested shelf → driver qty honored up to cap.
- B-floor: a barely-selling KEEP shelf (cover rounds to 0) → v17 = 1 (floor), not skipped.
- Aggregate: total v17 units ≤ total v16 units; report the fleet-level reduction so CS sees the magnitude before live use.

Optionally a rolled-back `engine_add_pod(date,14)` on a real picked, non-dispatched date confirms the live function runs and emits cover-capped `pod_refills` (tx rolled back; no live plan altered).

## 4. Constitution

Class (b) writer DEFINER (`engine_add_pod`). Articles 1 (sole writer of `pod_refills`, unchanged), 4 (validates role + inputs, sets via_rpc — unchanged), 8 (audit trigger unchanged), 12 (forward-only CREATE OR REPLACE, no `_v2`), 16 (single canonical refill decision; registry updated). No protected-entity write surface changes; `warehouse_inventory.status` untouched (Article 6 N/A).
