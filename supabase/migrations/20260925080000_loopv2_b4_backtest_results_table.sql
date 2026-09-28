-- Loop 2026-09-25 B4 (PRD-133): picker_backtest_results table structure.
--
-- The 24-day replay itself (backtest_priority(p_from, p_to)) is deliberately NOT built in this
-- migration. pick_machines_v12 and pick_machines_for_refill both read v_machine_priority and
-- v_lane_grain, which reflect only the latest WEIMI snapshot, not a chosen point in time. A real
-- 24-day backtest needs a parallel "as-of-date" version of those inputs (or of the pickers
-- themselves) to replay each day using that day's own snapshot; that is a substantial, separate
-- build, not a thin wrapper around the existing engines. Building it within this loop's remaining
-- surgical scope would mean shipping it without the same verification discipline used everywhere
-- else in this loop (confirm root cause / behaviour against live data before writing), so it is
-- left for a follow-up rather than rushed or faked. See STATE.md, "Scope decision on B4-B6".
--
-- This table is the structure PRD-133 asks backtest_priority to write into, created now so that
-- work is not blocked on this piece when the replay capability lands. It starts empty.

CREATE TABLE public.picker_backtest_results (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  picker_version              text NOT NULL CHECK (picker_version IN ('v11','v12')),
  plan_date                   date NOT NULL,
  critical_lane_days_unserved integer,
  low_need_visits             integer,
  expired_units_left_over_1d  integer,
  slow_machines_10d_plus      integer,
  vox_false_p1_count          integer,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (picker_version, plan_date)
);

ALTER TABLE public.picker_backtest_results ENABLE ROW LEVEL SECURITY;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.picker_backtest_results FROM authenticated;
REVOKE ALL ON public.picker_backtest_results FROM anon, PUBLIC;

CREATE POLICY picker_backtest_results_authenticated_select ON public.picker_backtest_results
  FOR SELECT TO authenticated
  USING (true);
