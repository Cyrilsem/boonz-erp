# /goal — PRD-031 WS-3: engine fill target = capacity (CS decision 2026-06-14)

Paste into Claude Code in the `boonz-erp` repo. Read `docs/architecture/01_constitution.html`, `RPC_REGISTRY.md`, `MIGRATIONS_REGISTRY.md` first. Dara designs, Cody reviews every SECURITY DEFINER fn + DDL, Stax for any FE/skill copy. No raw writes; forward-only migration, no \_v2; apply to prod only on CS sign-off; no em dashes.

---

/goal Implement PRD-031 WS-3 per docs/prds/PRD-031-refill-execution-accuracy.md and the 2026-06-14 effectiveness assessment. Objective: change engine_add_pod fill target from velocity x days_cover to FILL-TO-CAPACITY for selling shelves, with a slow-mover expiry guard. Warehouse availability is the only hard throttle.

CS DECISION (do not re-litigate): visits run every ~4-5 days (median 4, p90 ~10.6); drivers already hand-fill to capacity; high-velocity shelves are being double-shelved. So:

- Selling shelf (velocity_7d > 0 OR velocity_30d > 0): target_qty = max_stock - current_stock (full capacity gap).
- Hard throttle: cap target by wh_available_pod (the existing WH-availability calc). Never dispatch more than WH can cover; surface the shortfall as a procurement gap, do not silently drop (this is also PRD-031 WS-2 conservation).
- Slow-mover expiry guard: let cover30 = ceil( (velocity_30d / 30.0) \* 30 ) = ceil(velocity_30d). If cover30 < capacity_gap, cap target at cover30. So a shelf that sells 3/month tops at ~3 even if it holds 12; a shelf that sells a full shelf within 30 days fills to capacity. Guard only ever lowers, never raises.
- Dead shelf (velocity_7d = 0 AND velocity_30d = 0): unchanged - qty 0 + dead tag to the swap engine.
- Driver-feedback floor (v_driver_feedback_demand) still applies as a lower bound (do not let the target fall below a driver-requested qty).

STATE (verified live 2026-06-14, do not re-diagnose): deployed engine_add_pod computes u_target_units from velocity and p_days_cover=10 (candidates CTE reads slot_lifecycle velocity_7d/30d as v7/v30; final_qty derives from the cover target, capped by gap and wh_avail). This caps selling shelves below capacity (AMZ-1029 Loacker pod 3 of 12, Sunbites 5 of 10). slot_lifecycle velocity is fresh; the cover target, not velocity, is the limiter for slow movers. Memory note: v15/v16 were specified as fill-to-capacity; the live function drifted to cover-based - this restores the spec.

BUILD ORDER:

1. Dara: rewrite the target expression in engine_add_pod (the final_qty / u_target_units calc) to capacity-with-expiry-guard above. Keep the WH cap, the dead-tag path, the driver floor, the R7 60% shelf cap, and the procurement_gaps emission. Only the target formula changes. Show the before/after CTE diff.
2. Cody: review the engine_add_pod CREATE OR REPLACE (Articles 1,4,8,12,14; this is a protected canonical writer). Capture rollback functiondef. Forward migration phaseF_engine_add_pod_fill_to_capacity.
3. Replay before apply: on a non-live date, run the new vs old target for the 5 machines from 06-14 and show per-shelf old_qty vs new_qty vs gap vs wh_avail. Confirm selling shelves now hit capacity (WH permitting) and slow movers cap at ~30-day demand. No live/dispatched plan regenerated.
4. Align docs: update boonz-master-3 + refill-brain skill docs and the conductor notes so "fill target = capacity, WH-throttled, 30-day slow-mover guard" is the single stated behavior (kills the drift between docs and function). Update RPC_REGISTRY, MIGRATIONS_REGISTRY, CHANGELOG, METRICS_REGISTRY.
5. Battery: (a) a fast shelf (empty, strong velocity, WH stocked) fills to capacity; (b) a slow shelf (sells 3/mo, holds 12) caps at ~3; (c) a dead shelf stays qty 0 + tagged; (d) a WH-short shelf caps at wh_avail and emits a procurement gap; (e) a driver-requested qty is honored as a floor.

DONE WHEN: battery green, Cody sign-off recorded, registries + docs updated, migration applied on CS go, committed. SEQUENCING NOTE: the headline fill number only fully recovers once PRD-024 (split normalization) and PRD-031 WS-1/WS-2/WS-2b (mapping dedup + off-shelf redistribution) also land - this WS-3 raises pod intent to capacity; those stop the downstream leak. Land WS-3 alongside or after them. Start with step 1 and show me the target-expression diff before applying.
