-- PRD-142b Block B evidence: each full-fleet before/after draft-plan diff runs inside a plpgsql sub-block that is
-- rolled back (engine writes, machines_to_visit rows and patched function bodies all undone); only the captured
-- rows are kept here so the diff can be read after a run longer than the SQL client timeout. No engine reads it.
CREATE TABLE IF NOT EXISTS public.strategy_engine_diff_runs (
  run_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  label       text NOT NULL,
  plan_date   date NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  duration_ms integer,
  error       text,
  flags       jsonb,
  add_old     jsonb, swap_old jsonb, refills_old jsonb, swaps_old jsonb,
  add_new     jsonb, swap_new jsonb, refills_new jsonb, swaps_new jsonb
);
ALTER TABLE public.strategy_engine_diff_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY strategy_engine_diff_runs_admin_select ON public.strategy_engine_diff_runs
  FOR SELECT TO authenticated USING (is_admin((SELECT auth.uid())));
REVOKE ALL ON public.strategy_engine_diff_runs FROM anon;
