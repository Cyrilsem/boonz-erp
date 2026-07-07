-- PRD-083 (Article 13): flag-gated RAISE-redirect deprecation of the Family-B orphan island.
-- DROP nothing (parked). KEEP approve_refill_plan/write_refill_plan/refill_plan_output.
-- Cody PASS (revisions applied: RLS on feature_flag; reconcile_intent_progress confirmed
-- no approve-path/Family-A/cron caller). Reversible: set engine_single_path <> 'deprecate'.
CREATE TABLE IF NOT EXISTS refill_qa.feature_flag (
  flag text PRIMARY KEY, value text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(), updated_by uuid);
ALTER TABLE refill_qa.feature_flag ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS qa_ff_read ON refill_qa.feature_flag;
CREATE POLICY qa_ff_read ON refill_qa.feature_flag FOR SELECT TO authenticated USING (true);
GRANT SELECT ON refill_qa.feature_flag TO authenticated, service_role;
INSERT INTO refill_qa.feature_flag(flag,value) VALUES ('engine_single_path','deprecate') ON CONFLICT (flag) DO NOTHING;
CREATE OR REPLACE FUNCTION refill_qa.flag(p_flag text) RETURNS text
LANGUAGE sql STABLE SET search_path TO 'refill_qa','public' AS $$
  SELECT value FROM refill_qa.feature_flag WHERE flag = p_flag; $$;
GRANT EXECUTE ON FUNCTION refill_qa.flag(text) TO authenticated, service_role;
DO $outer$
DECLARE rec record; v_def text; v_guard text;
BEGIN
  FOR rec IN SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('orchestrate_refill_plan','propose_add_plan','propose_swap_plan','engine_publish_to_refill_plan','reconcile_intent_progress')
  LOOP
    v_def := pg_get_functiondef(rec.oid);
    v_guard := format($g$  IF refill_qa.flag('engine_single_path') = 'deprecate' THEN RAISE EXCEPTION 'PRD-083: %s is a deprecated Family-B engine (Article 13). Use Family A: build_draft_for_confirmed pipeline (engine_add_pod/engine_swap_pod/engine_finalize_pod/pick_machines_for_refill).'; END IF;$g$, rec.proname);
    IF position(v_guard IN v_def) > 0 THEN CONTINUE; END IF;
    v_def := regexp_replace(v_def, E'(\\nBEGIN\\n)', E'\\1' || replace(v_guard,'\','\\') || E'\n', 1);
    EXECUTE v_def;
  END LOOP;
END $outer$;
