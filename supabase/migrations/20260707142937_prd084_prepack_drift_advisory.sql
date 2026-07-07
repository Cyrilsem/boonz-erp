-- PRD-084 Phase 1 (advisory): read-only pre-pack drift checker + multi-SKU allowlist.
-- Non-protected, additive. NO plan/dispatch write. Phase 2 (block: include=false on
-- refill_dispatching) is protected and parked for Cody + advisory->block promotion.
CREATE TABLE IF NOT EXISTS refill_qa.multi_sku_shelf (
  machine_id uuid NOT NULL, shelf_id uuid NOT NULL, reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (machine_id, shelf_id));
ALTER TABLE refill_qa.multi_sku_shelf ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS qa_mss_read ON refill_qa.multi_sku_shelf;
CREATE POLICY qa_mss_read ON refill_qa.multi_sku_shelf FOR SELECT TO authenticated USING (true);
GRANT SELECT ON refill_qa.multi_sku_shelf TO authenticated, service_role;

CREATE OR REPLACE FUNCTION refill_qa.check_prepack_drift(p_plan_date date, p_machine_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SET search_path TO 'refill_qa','public','pg_temp' AS $$
  WITH lines AS (
    SELECT rd.dispatch_id, rd.machine_id, rd.shelf_id, rd.pod_product_id AS planned_pod, rd.action,
           sc.shelf_code, (LEFT(sc.shelf_code,1)||(SUBSTR(sc.shelf_code,2)::int)::text) AS slot_name
    FROM public.refill_dispatching rd
    JOIN public.shelf_configurations sc ON sc.shelf_id = rd.shelf_id AND sc.is_phantom = false
    WHERE rd.dispatch_date = p_plan_date AND rd.action IN ('Refill','Add New')
      AND COALESCE(rd.cancelled,false)=false AND COALESCE(rd.skipped,false)=false AND COALESCE(rd.is_m2m,false)=false
      AND (p_machine_ids IS NULL OR rd.machine_id = ANY(p_machine_ids))),
  resolved AS (
    SELECT l.*, (SELECT v.pod_product_id FROM public.v_live_shelf_stock v WHERE v.machine_id=l.machine_id AND v.slot_name=l.slot_name LIMIT 1) AS live_pod,
           EXISTS(SELECT 1 FROM refill_qa.multi_sku_shelf ms WHERE ms.machine_id=l.machine_id AND ms.shelf_id=l.shelf_id) AS allowlisted FROM lines l),
  classed AS (
    SELECT *, CASE WHEN action='Add New' THEN 'ok' WHEN allowlisted THEN 'allowed_multi_sku'
      WHEN live_pod IS NULL THEN 'weimi_unresolved' WHEN planned_pod = live_pod THEN 'ok' ELSE 'sku_mismatch' END AS class FROM resolved)
  SELECT jsonb_build_object('plan_date',p_plan_date,
    'totals', jsonb_build_object('ok',count(*) FILTER (WHERE class='ok'),'sku_mismatch',count(*) FILTER (WHERE class='sku_mismatch'),
      'weimi_unresolved',count(*) FILTER (WHERE class='weimi_unresolved'),'allowed_multi_sku',count(*) FILTER (WHERE class='allowed_multi_sku')),
    'mismatches', COALESCE((SELECT jsonb_agg(jsonb_build_object('machine_id',machine_id,'shelf_code',shelf_code,'planned_pod',planned_pod,'live_pod',live_pod)) FROM classed WHERE class='sku_mismatch'),'[]'::jsonb))
  FROM classed;
$$;
GRANT EXECUTE ON FUNCTION refill_qa.check_prepack_drift(date,uuid[]) TO authenticated, service_role;

INSERT INTO refill_qa.multi_sku_shelf(machine_id, shelf_id, reason)
SELECT sc.machine_id, sc.shelf_id, 'seed: known soft-drink/multi-SKU shelf (PRD-084)'
FROM shelf_configurations sc JOIN machines m ON m.machine_id=sc.machine_id
WHERE m.official_name LIKE 'AMZ-1029%' AND sc.shelf_code='A12' ON CONFLICT DO NOTHING;

COMMENT ON FUNCTION refill_qa.check_prepack_drift(date,uuid[]) IS
  'PRD-084 advisory: planned pod vs live WEIMI per dispatch line. Classes ok/sku_mismatch/weimi_unresolved/allowed_multi_sku. Read-only. Block tier parked (protected).';
