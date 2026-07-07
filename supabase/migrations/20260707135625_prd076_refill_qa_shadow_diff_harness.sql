-- PRD-076: refill shadow-diff harness (the referee). NET-NEW, additive QA infra.
-- Non-protected: lives in its own refill_qa schema, outside all planning/inventory tables.
-- Engines untouched (read-only fingerprints). capture_run is branch-guarded (refuses on prod).
-- Cody: additive schema in an isolated namespace; no RLS change on public business tables;
-- diff_runs/diff_run_rows are pure SELECT; capture_run SECURITY DEFINER but self-guards.

CREATE SCHEMA IF NOT EXISTS refill_qa;

CREATE TABLE IF NOT EXISTS refill_qa.plan_run (
  run_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date         date NOT NULL,
  label             text NOT NULL,
  engine_fingerprint text,
  input_fingerprint  text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  meta              jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS refill_qa.plan_run_row (
  run_id          uuid NOT NULL REFERENCES refill_qa.plan_run(run_id) ON DELETE CASCADE,
  machine_id      uuid,
  shelf_id        uuid,
  pod_product_id  uuid,
  action          text,
  qty             numeric,
  status          text,
  source          text,
  linked_intent_id uuid,
  reasoning       jsonb
);
CREATE INDEX IF NOT EXISTS idx_plan_run_row_key
  ON refill_qa.plan_run_row (run_id, machine_id, shelf_id, pod_product_id, action);

-- QA store: authenticated may READ; writes only via the SECURITY DEFINER capture fn.
ALTER TABLE refill_qa.plan_run     ENABLE ROW LEVEL SECURITY;
ALTER TABLE refill_qa.plan_run_row ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS qa_pr_read  ON refill_qa.plan_run;
DROP POLICY IF EXISTS qa_prr_read ON refill_qa.plan_run_row;
CREATE POLICY qa_pr_read  ON refill_qa.plan_run     FOR SELECT TO authenticated USING (true);
CREATE POLICY qa_prr_read ON refill_qa.plan_run_row FOR SELECT TO authenticated USING (true);
GRANT USAGE ON SCHEMA refill_qa TO authenticated, service_role;
GRANT SELECT ON refill_qa.plan_run, refill_qa.plan_run_row TO authenticated, service_role;

-- ── capture_run: branch-only. Refuses unless the session opts in via a GUC that the
-- runbook sets ONLY on a preview branch. On prod the GUC is unset -> refuse, so the
-- engine (which writes pod_refill_plan) can never be invoked against prod by this fn.
CREATE OR REPLACE FUNCTION refill_qa.capture_run(p_plan_date date, p_label text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'refill_qa','public','pg_temp'
AS $$
DECLARE
  v_run_id uuid;
  v_engine_fp text;
  v_input_fp text;
BEGIN
  IF COALESCE(current_setting('refill_qa.on_branch', true), 'false') <> 'true' THEN
    RAISE EXCEPTION 'refill_qa.capture_run: refused - not on a preview branch (set refill_qa.on_branch=true only on a branch). This fn writes pod_refill_plan via the engine and must never run on prod.';
  END IF;

  v_engine_fp := md5(string_agg(md5(pg_get_functiondef(p.oid)), ',' ORDER BY p.proname))
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN
      ('build_draft_for_confirmed','engine_add_pod','engine_swap_pod','engine_finalize_pod','compute_refill_decision','pick_machines_for_refill');

  v_input_fp := md5(concat_ws('|',
    (SELECT md5(COALESCE(string_agg(sl.slot_id::text, ',' ORDER BY sl.slot_id), '')) FROM slot_lifecycle sl WHERE sl.is_current AND NOT sl.archived),
    (SELECT md5(COALESCE(string_agg(v.machine_id::text||v.slot_name||v.current_stock::text, ',' ORDER BY v.machine_id, v.slot_name), '')) FROM v_live_shelf_stock v),
    (SELECT md5(COALESCE(string_agg(w.wh_inventory_id::text||w.warehouse_stock::text, ',' ORDER BY w.wh_inventory_id), '')) FROM warehouse_inventory w),
    (SELECT md5(COALESCE(string_agg(mtv.machine_id::text||mtv.status, ',' ORDER BY mtv.machine_id), '')) FROM machines_to_visit mtv WHERE mtv.plan_date = p_plan_date)
  ));

  -- run the engine in isolation on THIS (branch) database
  PERFORM public.build_draft_for_confirmed(p_plan_date, true);

  INSERT INTO refill_qa.plan_run (plan_date, label, engine_fingerprint, input_fingerprint, meta)
  VALUES (p_plan_date, p_label, v_engine_fp, v_input_fp,
          jsonb_build_object('captured_by','capture_run','db',current_database()))
  RETURNING run_id INTO v_run_id;

  INSERT INTO refill_qa.plan_run_row (run_id, machine_id, shelf_id, pod_product_id, action, qty, status, source, linked_intent_id, reasoning)
  SELECT v_run_id, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action, prp.qty, prp.status,
         prp.source_origin::text, prp.linked_intent_id, prp.reasoning
  FROM public.pod_refill_plan prp
  WHERE prp.plan_date = p_plan_date;

  RETURN v_run_id;
END;
$$;
REVOKE ALL ON FUNCTION refill_qa.capture_run(date, text) FROM public;
GRANT EXECUTE ON FUNCTION refill_qa.capture_run(date, text) TO service_role;

-- ── diff_run_rows: per-row classification. Grain = (machine_id, shelf_id, pod_product_id):
-- one action per plan slot, so this grain makes action_changed detectable (a join key that
-- included action would make action_changed unreachable - it would show as removed+added).
-- Change priority when several attrs differ: action > qty > status > reason.
CREATE OR REPLACE FUNCTION refill_qa.diff_run_rows(p_baseline uuid, p_candidate uuid, p_scope uuid[] DEFAULT NULL)
RETURNS TABLE(machine_id uuid, shelf_id uuid, pod_product_id uuid, class text,
              base_action text, cand_action text, base_qty numeric, cand_qty numeric,
              base_status text, cand_status text)
LANGUAGE sql STABLE
AS $$
  WITH b AS (SELECT * FROM refill_qa.plan_run_row WHERE run_id = p_baseline
             AND (p_scope IS NULL OR machine_id = ANY(p_scope))),
       c AS (SELECT * FROM refill_qa.plan_run_row WHERE run_id = p_candidate
             AND (p_scope IS NULL OR machine_id = ANY(p_scope)))
  SELECT COALESCE(b.machine_id, c.machine_id),
         COALESCE(b.shelf_id, c.shelf_id),
         COALESCE(b.pod_product_id, c.pod_product_id),
         CASE
           WHEN b.machine_id IS NULL THEN 'added'
           WHEN c.machine_id IS NULL THEN 'removed'
           WHEN b.action IS DISTINCT FROM c.action THEN 'action_changed'
           WHEN b.qty    IS DISTINCT FROM c.qty    THEN 'qty_changed'
           WHEN b.status IS DISTINCT FROM c.status THEN 'status_changed'
           WHEN b.reasoning IS DISTINCT FROM c.reasoning THEN 'reason_changed'
           ELSE 'unchanged'
         END,
         b.action, c.action, b.qty, c.qty, b.status, c.status
  FROM b FULL OUTER JOIN c
    ON b.machine_id = c.machine_id AND b.shelf_id = c.shelf_id
   AND b.pod_product_id IS NOT DISTINCT FROM c.pod_product_id;
$$;

-- ── diff_runs: fleet + per-machine aggregate summary. Pure SELECT.
CREATE OR REPLACE FUNCTION refill_qa.diff_runs(p_baseline uuid, p_candidate uuid, p_scope uuid[] DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  WITH d AS (SELECT * FROM refill_qa.diff_run_rows(p_baseline, p_candidate, p_scope)),
       agg AS (
         SELECT count(*) FILTER (WHERE class='unchanged')      AS unchanged,
                count(*) FILTER (WHERE class='added')          AS added,
                count(*) FILTER (WHERE class='removed')        AS removed,
                count(*) FILTER (WHERE class='qty_changed')    AS qty_changed,
                count(*) FILTER (WHERE class='action_changed') AS action_changed,
                count(*) FILTER (WHERE class='status_changed') AS status_changed,
                count(*) FILTER (WHERE class='reason_changed') AS reason_changed,
                COALESCE(sum(cand_qty),0) - COALESCE(sum(base_qty),0) AS net_units
         FROM d
       ),
       per_machine AS (
         SELECT machine_id,
                count(*) FILTER (WHERE class <> 'unchanged') AS changed_rows
         FROM d GROUP BY machine_id HAVING count(*) FILTER (WHERE class <> 'unchanged') > 0
       ),
       fps AS (
         SELECT (SELECT input_fingerprint FROM refill_qa.plan_run WHERE run_id=p_baseline) AS b_fp,
                (SELECT input_fingerprint FROM refill_qa.plan_run WHERE run_id=p_candidate) AS c_fp
       )
  SELECT jsonb_build_object(
    'identical', (agg.added=0 AND agg.removed=0 AND agg.qty_changed=0 AND agg.action_changed=0 AND agg.status_changed=0 AND agg.reason_changed=0),
    'inputs_differ', (SELECT b_fp IS DISTINCT FROM c_fp FROM fps),
    'fleet', to_jsonb(agg),
    'per_machine', COALESCE((SELECT jsonb_agg(jsonb_build_object('machine_id',machine_id,'changed_rows',changed_rows) ORDER BY changed_rows DESC) FROM per_machine), '[]'::jsonb)
  )
  FROM agg;
$$;
GRANT EXECUTE ON FUNCTION refill_qa.diff_run_rows(uuid,uuid,uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION refill_qa.diff_runs(uuid,uuid,uuid[]) TO authenticated, service_role;

COMMENT ON SCHEMA refill_qa IS 'PRD-076 referee: shadow-diff harness. capture_run (branch-only) + diff_runs/diff_run_rows (pure SELECT). Precondition for PRD-079..085 output-level validation.';
