-- PRD-077: conservation merge gate (reusable pre-merge pass/fail referee). Read-only.
-- Wraps the SHIPPED canonical logic (does NOT fork): assertion (a) plan-balance reuses
-- public.check_pod_conservation; (b)/(c) batch availability use the canonical v_wh_pickable
-- predicate (shared with PRD-079), evaluated at the DISPATCH layer because the PLAN carries
-- no batch reference (pod_refill_plan.preferred_wh_inventory_id = 0/678 populated 2026-07-07;
-- binding happens at dispatch via from_wh_inventory_id — PRD-036/072). Engines untouched.

CREATE TABLE IF NOT EXISTS refill_qa.conservation_baseline (
  signature       text PRIMARY KEY,
  captured_for    date NOT NULL,
  violation_class text NOT NULL,
  detail          jsonb NOT NULL DEFAULT '{}'::jsonb,
  status          text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed','agreed')),
  agreed_by       uuid,
  agreed_at       timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE refill_qa.conservation_baseline ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS qa_cb_read ON refill_qa.conservation_baseline;
CREATE POLICY qa_cb_read ON refill_qa.conservation_baseline FOR SELECT TO authenticated USING (true);
GRANT SELECT ON refill_qa.conservation_baseline TO authenticated, service_role;

-- conservation_check(plan_date, run_id?, mode) -> {status, violations[], totals}
-- mode 'absolute' = all violations; 'delta' = only those NOT in the agreed known-debt baseline.
CREATE OR REPLACE FUNCTION refill_qa.conservation_check(
  p_plan_date date, p_run_id uuid DEFAULT NULL, p_mode text DEFAULT 'absolute')
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path TO 'refill_qa','public','pg_temp'
AS $$
  WITH
  -- (a) plan balance: reuse shipped canonical. Each returned row = REMOVE/M2W plan qty
  -- not matched by dispatch children => orphan_removal; non-integer residual => rounding_leak.
  a AS (
    SELECT 'orphan_removal'::text AS violation_class,
           ('orphan:'||machine_id||':'||shelf_id||':'||COALESCE(pod_product_id::text,'-')||':'||action) AS signature,
           jsonb_build_object('machine_id',machine_id,'shelf_id',shelf_id,'pod_product_id',pod_product_id,
                              'action',action,'plan_qty',parent_pod_qty,'dispatched',children_sum,'delta',delta) AS detail
    FROM public.check_pod_conservation(p_plan_date)
  ),
  -- (b)/(c) batch availability at the dispatch layer (plan carries no batch ref).
  batch_need AS (
    SELECT rd.from_wh_inventory_id AS wh_inventory_id, SUM(rd.quantity)::numeric AS needed
    FROM public.refill_dispatching rd
    WHERE rd.dispatch_date = p_plan_date
      AND rd.from_wh_inventory_id IS NOT NULL
      AND rd.action IN ('Refill','Add New')
      AND COALESCE(rd.cancelled,false)=false AND COALESCE(rd.skipped,false)=false
      AND COALESCE(rd.is_m2m,false)=false
    GROUP BY rd.from_wh_inventory_id
  ),
  bc AS (
    SELECT CASE WHEN wp.wh_inventory_id IS NULL THEN 'phantom_batch'
                WHEN bn.needed > COALESCE(wp.warehouse_stock,0) THEN 'oversubscribed_batch'
                WHEN (bn.needed <> round(bn.needed)) THEN 'rounding_leak' END AS violation_class,
           ('batch:'||bn.wh_inventory_id) AS signature,
           jsonb_build_object('wh_inventory_id',bn.wh_inventory_id,'needed',bn.needed,
                              'pickable',COALESCE(wp.warehouse_stock,0)) AS detail
    FROM batch_need bn
    LEFT JOIN public.v_wh_pickable wp ON wp.wh_inventory_id = bn.wh_inventory_id
    WHERE wp.wh_inventory_id IS NULL OR bn.needed > COALESCE(wp.warehouse_stock,0) OR bn.needed <> round(bn.needed)
  ),
  all_v AS (SELECT violation_class, signature, detail FROM a
            UNION ALL SELECT violation_class, signature, detail FROM bc),
  filtered AS (
    SELECT * FROM all_v v
    WHERE p_mode <> 'delta'
       OR NOT EXISTS (SELECT 1 FROM refill_qa.conservation_baseline b
                      WHERE b.signature = v.signature AND b.status='agreed')
  )
  SELECT jsonb_build_object(
    'status', CASE WHEN EXISTS (SELECT 1 FROM filtered) THEN 'fail' ELSE 'pass' END,
    'mode', p_mode, 'plan_date', p_plan_date,
    'batch_eval', (SELECT count(*) FROM batch_need) > 0,
    'violations', COALESCE((SELECT jsonb_agg(jsonb_build_object('class',violation_class,'signature',signature,'detail',detail)) FROM filtered), '[]'::jsonb),
    'totals', jsonb_build_object(
      'orphan_removal',     (SELECT count(*) FROM filtered WHERE violation_class='orphan_removal'),
      'phantom_batch',      (SELECT count(*) FROM filtered WHERE violation_class='phantom_batch'),
      'oversubscribed_batch',(SELECT count(*) FROM filtered WHERE violation_class='oversubscribed_batch'),
      'rounding_leak',      (SELECT count(*) FROM filtered WHERE violation_class='rounding_leak'),
      'total',              (SELECT count(*) FROM filtered))
  );
$$;
GRANT EXECUTE ON FUNCTION refill_qa.conservation_check(date,uuid,text) TO authenticated, service_role;

COMMENT ON FUNCTION refill_qa.conservation_check(date,uuid,text) IS
  'PRD-077 conservation merge gate. Wraps check_pod_conservation (a) + v_wh_pickable batch checks (b/c, dispatch layer). Modes absolute/delta vs refill_qa.conservation_baseline. Read-only.';
