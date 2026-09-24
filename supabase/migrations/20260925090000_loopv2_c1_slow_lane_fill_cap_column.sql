-- Loop 2026-09-25 C1 (PRD-133-135 safety flag): refill_policy_params.slow_lane_fill_cap_pct.
--
-- Default NULL (off). When set, the intent is for engine_add_pod to cap the target fill for any
-- lane whose velocity is below hero_velocity_floor/3 (hero_velocity_floor already exists in this
-- table, default 3) at that percentage of max_stock, instead of filling toward the machine's
-- normal target.
--
-- The wiring into engine_add_pod itself is deliberately NOT done in this migration.
-- engine_add_pod's live body is roughly 25KB of already-battle-tested refill sizing logic; adding
-- a new capping branch to it safely requires reading and understanding that whole function first,
-- which this loop's remaining time did not allow to do with the same verification discipline used
-- everywhere else in this loop (confirm behaviour against live data, rolled-back smoke test, no
-- guessing). Since the flag must default OFF and the task explicitly says "do NOT enable" this
-- loop, adding the column now with zero behavioural effect, and deferring the engine wiring as an
-- honestly-documented open item, is safer than rushing a change into a large, live sizing engine
-- under time pressure for a feature that must not be live anyway. See STATE.md and the loop
-- report for the backtest evidence (computed by direct read-only analysis against
-- 2026-09-25's real data, not by running the not-yet-built capped code path).

ALTER TABLE public.refill_policy_params
  ADD COLUMN slow_lane_fill_cap_pct numeric;

COMMENT ON COLUMN public.refill_policy_params.slow_lane_fill_cap_pct IS
  'Loop 2026-09-25 C1 (PRD-133-135): when set, caps the refill target for lanes with velocity '
  'below hero_velocity_floor/3 at this percent of max_stock. NULL (default) = off. Engine wiring '
  'into engine_add_pod not yet built; this column currently has no effect. See STATE.md.';
