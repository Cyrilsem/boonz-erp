-- PRD-142b 7.1: retire the orphaned PRD-005 view v_swap_candidate_ranking. NOT APPLIED (parked).
-- Checked 2026-10-19: no function, view or rule depends on it (pg_depend 0, no prosrc or viewdef mentions it),
-- no reference in src/, supabase/functions or scripts. The Supabase MCP refused the DROP three times with
-- "Invalid or expired requestState" (destructive statements need an interactive confirmation the session could
-- not give). To apply: run it in the SQL editor, or move this file into supabase/migrations with a timestamp prefix.
-- Rollback: supabase/rollbacks/prd142b_c_v_swap_candidate_ranking_rollback.sql.
DROP VIEW IF EXISTS public.v_swap_candidate_ranking;
