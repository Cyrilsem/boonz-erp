-- PRD-085: finalize preserve-approved VERIFIED (no engine change). The live path
-- engine_finalize_pod(date) delegates to engine_finalize_pod(date,uuid[]) which calls
-- _assert_refill_plan_writable -> approved rows are preserved. Functional rollback test
-- PASS (approved row stays approved after finalize); 0 approved->draft resets in 30d.
-- This registers the durable read-only regression monitor.
CREATE OR REPLACE FUNCTION refill_qa.check_approved_preserved(p_plan_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SET search_path TO 'refill_qa','public','pg_temp' AS $$
  SELECT jsonb_build_object(
    'defect_rows', count(*), 'ok', count(*) = 0,
    'scope', COALESCE(p_plan_date::text,'all_dates'),
    'signature', 'approved_at IS NOT NULL AND status=draft (PRD-025 finalize-reset defect)')
  FROM public.pod_refill_plan
  WHERE status='draft' AND approved_at IS NOT NULL AND (p_plan_date IS NULL OR plan_date = p_plan_date);
$$;
GRANT EXECUTE ON FUNCTION refill_qa.check_approved_preserved(date) TO authenticated, service_role;
COMMENT ON FUNCTION refill_qa.check_approved_preserved(date) IS
  'PRD-085 regression monitor: 0 defect_rows = finalize preserves approved (PRD-025 fix holds). Read-only. Run per recent plan_date (all-dates includes pre-Refill-v2 residue).';
