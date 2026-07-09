-- PRD-077 refinement (2B): phantom_batch/oversubscribed_batch must evaluate only UNPACKED lines.
-- A packed line has legitimately consumed its batch; that batch reading 0-stock is correct, not a phantom.
CREATE OR REPLACE FUNCTION refill_qa.conservation_check(p_plan_date date, p_run_id uuid DEFAULT NULL::uuid, p_mode text DEFAULT 'absolute'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'refill_qa', 'public', 'pg_temp'
AS $function$
  WITH
  a AS (
    SELECT 'orphan_removal'::text AS violation_class,
           ('orphan:'||machine_id||':'||shelf_id||':'||COALESCE(pod_product_id::text,'-')||':'||action) AS signature,
           jsonb_build_object('machine_id',machine_id,'shelf_id',shelf_id,'pod_product_id',pod_product_id,
                              'action',action,'plan_qty',parent_pod_qty,'dispatched',children_sum,'delta',delta) AS detail
    FROM public.check_pod_conservation(p_plan_date)
  ),
  batch_need AS (
    SELECT rd.from_wh_inventory_id AS wh_inventory_id, SUM(rd.quantity)::numeric AS needed
    FROM public.refill_dispatching rd
    WHERE rd.dispatch_date = p_plan_date
      AND rd.from_wh_inventory_id IS NOT NULL
      AND rd.action IN ('Refill','Add New')
      AND COALESCE(rd.cancelled,false)=false AND COALESCE(rd.skipped,false)=false
      AND COALESCE(rd.is_m2m,false)=false
      AND COALESCE(rd.packed,false)=false   -- PRD-077 fix: packed lines already consumed their batch (not a phantom)
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
$function$;
