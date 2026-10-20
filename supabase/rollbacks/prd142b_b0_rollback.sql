-- Rollback for prd142b_b0_engine_diff_runs (evidence table, nothing reads it).
DROP TABLE IF EXISTS public.strategy_engine_diff_runs;
