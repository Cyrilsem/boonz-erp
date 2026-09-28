-- Rollback capture for 20260925013000_loopv2_a3_g3_coverage_fix.sql
-- Prior live body of validate_refill_plan (G3 without the coverage NOT EXISTS clauses).

CREATE OR REPLACE FUNCTION public.validate_refill_plan(p_plan_date date, p_machines text[] DEFAULT NULL::text[], p_source text DEFAULT 'dispatch'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF p_source NOT IN ('dispatch','plan_output') THEN
    RAISE EXCEPTION 'validate_refill_plan: p_source must be ''dispatch'' or ''plan_output'' (got %)', p_source;
  END IF;

  WITH mach AS (
    SELECT DISTINCT rd.machine_id
      FROM public.refill_dispatching rd
      JOIN public.machines m ON m.machine_id = rd.machine_id
     WHERE p_source = 'dispatch'
       AND rd.dispatch_date = p_plan_date
       AND COALESCE(rd.cancelled,false)=false
       AND COALESCE(rd.skipped,false)=false
       AND COALESCE(rd.returned,false)=false
       AND (p_machines IS NULL OR m.official_name = ANY(p_machines))
    UNION
    SELECT DISTINCT rpo.machine_id
      FROM public.refill_plan_output rpo
      JOIN public.machines m ON m.machine_id = rpo.machine_id
     WHERE p_source = 'plan_output'
       AND rpo.plan_date = p_plan_date
       AND rpo.operator_status = 'pending'
       AND (p_machines IS NULL OR m.official_name = ANY(p_machines))
  ),
  weimi_now AS (
    SELECT mach.machine_id, wsn.shelf_code, wsn.pod_product_id AS weimi_pod_product_id
      FROM mach
      CROSS JOIN LATERAL public.weimi_shelf_now(mach.machine_id) wsn
  ),
  latest AS (
    SELECT s.machine_id, max(s.snapshot_date) d
      FROM public.weimi_aisle_snapshots s JOIN mach ON mach.machine_id = s.machine_id
     GROUP BY 1
  ),
  w AS (
    SELECT s.machine_id,
           upper(left(s.slot_code,1))||lpad(regexp_replace(s.slot_code,'^[A-Za-z]',''),2,'0') AS shelf_code,
           s.product_name AS pod, s.current_stock, s.max_stock
      FROM public.weimi_aisle_snapshots s
      JOIN latest l ON l.machine_id = s.machine_id AND l.d = s.snapshot_date
  ),
  lines AS (
    SELECT rd.machine_id, sc.shelf_code, rd.boonz_product_id, rd.pod_product_id, rd.action, rd.quantity, rd.source_origin
      FROM public.refill_dispatching rd
      JOIN mach ON mach.machine_id = rd.machine_id
      LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = rd.shelf_id
     WHERE p_source = 'dispatch'
       AND rd.dispatch_date = p_plan_date
       AND COALESCE(rd.cancelled,false)=false
       AND COALESCE(rd.skipped,false)=false
       AND COALESCE(rd.returned,false)=false
       AND COALESCE(rd.quantity,0) > 0
    UNION ALL
    SELECT rpo.machine_id, sc2.shelf_code, rpo.boonz_product_id, rpo.pod_product_id, rpo.action, rpo.quantity, rpo.source_origin
      FROM public.refill_plan_output rpo
      JOIN mach ON mach.machine_id = rpo.machine_id
      LEFT JOIN public.shelf_configurations sc2 ON sc2.shelf_id = rpo.shelf_id
     WHERE p_source = 'plan_output'
       AND rpo.plan_date = p_plan_date
       AND rpo.operator_status = 'pending'
       AND COALESCE(rpo.quantity,0) > 0
  ),
  lane AS (
    SELECT w.machine_id, w.shelf_code, w.pod, w.current_stock, w.max_stock,
           COALESCE(sum(l.quantity) FILTER (WHERE l.action IN ('Refill','Add New')),0) AS add_qty,
           COALESCE(sum(l.quantity) FILTER (WHERE l.action IN ('Remove','Machine To Warehouse')),0) AS out_qty,
           count(l.*) AS n_lines
      FROM w JOIN mach ON mach.machine_id = w.machine_id
      LEFT JOIN lines l ON l.machine_id = w.machine_id AND l.shelf_code = w.shelf_code
     GROUP BY 1,2,3,4,5
  ),
  avail AS (
    SELECT DISTINCT ON (l.boonz_product_id)
           l.boonz_product_id,
           (SELECT SUM(wi.warehouse_stock)
              FROM public.warehouse_inventory wi
             WHERE wi.boonz_product_id = l.boonz_product_id
               AND wi.warehouse_id = ANY(
                     CASE WHEN (SELECT pm.source_of_supply FROM public.product_mapping pm
                                 WHERE pm.boonz_product_id = l.boonz_product_id AND pm.status='Active'
                                   AND (pm.machine_id = l.machine_id OR pm.machine_id IS NULL)
                                 ORDER BY (pm.machine_id = l.machine_id) DESC NULLS LAST, pm.is_global_default DESC
                                 LIMIT 1) = 'venue_team'
                       THEN ARRAY['4fcfb52c-271f-4aa7-a373-3495e3271cd3'::uuid,'0aef9ccf-32ad-4545-8413-29bebd931d0b'::uuid]
                       ELSE ARRAY['4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid] END)
               AND COALESCE(wi.status,'Active') = 'Active'
               AND COALESCE(wi.quarantined,false) = false
               AND wi.warehouse_stock > 0
           ) AS stock
      FROM lines l
     WHERE l.action IN ('Refill','Add New')
     ORDER BY l.boonz_product_id, l.machine_id
  ),
  g AS (
    SELECT 'G3' AS code, 'blocking' AS severity, 'EMPTY lane with no line and no substitution rule' AS gate,
           m.official_name||' '||lane.shelf_code||' ('||lane.pod||')' AS detail
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.current_stock = 0 AND lane.n_lines = 0
    UNION ALL
    SELECT 'G5','blocking','product has no ACTIVE mapping on that machine or globally',
           m.official_name||' '||COALESCE(l.shelf_code,'?')||' '||bp.boonz_product_name
      FROM lines l JOIN public.machines m ON m.machine_id = l.machine_id
      LEFT JOIN public.boonz_products bp ON bp.product_id = l.boonz_product_id
     WHERE l.action IN ('Refill','Add New')
       AND NOT EXISTS (SELECT 1 FROM public.product_mapping pm
                        WHERE (pm.machine_id = l.machine_id OR pm.machine_id IS NULL)
                          AND pm.boonz_product_id = l.boonz_product_id
                          AND pm.status = 'Active')
    UNION ALL
    SELECT 'G7','blocking','Remove with no replacement on the same lane',
           m.official_name||' '||lane.shelf_code||' would go EMPTY'
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.out_qty > 0 AND lane.add_qty = 0
    UNION ALL
    SELECT 'G8','blocking','need exceeds free stock at the supplying warehouse (PRD-125 D3)',
           bp.boonz_product_name||': need '||x.need||', free '||x.free
      FROM (SELECT l.boonz_product_id, sum(l.quantity) AS need,
                   COALESCE(a.stock,0) AS free
              FROM lines l LEFT JOIN avail a ON a.boonz_product_id = l.boonz_product_id
             WHERE l.action IN ('Refill','Add New')
               AND COALESCE(l.source_origin,'warehouse') <> 'internal_transfer'
             GROUP BY 1, COALESCE(a.stock,0)) x
      JOIN public.boonz_products bp ON bp.product_id = x.boonz_product_id
     WHERE x.need > x.free
    UNION ALL
    SELECT 'G10','blocking','Refill/Add New lands on a lane WEIMI shows holding a different product, with no Remove for it',
           m.official_name||' '||l.shelf_code||': plan '||COALESCE(bp2.boonz_product_name,'?')||' vs WEIMI '||COALESCE(pp2.pod_product_name,'unmatched')
      FROM lines l
      JOIN public.machines m ON m.machine_id = l.machine_id
      JOIN weimi_now wn ON wn.machine_id = l.machine_id AND wn.shelf_code = l.shelf_code
      LEFT JOIN public.boonz_products bp2 ON bp2.product_id = l.boonz_product_id
      LEFT JOIN public.pod_products pp2 ON pp2.pod_product_id = wn.weimi_pod_product_id
     WHERE l.action IN ('Refill','Add New')
       AND wn.weimi_pod_product_id IS NOT NULL
       AND wn.weimi_pod_product_id IS DISTINCT FROM l.pod_product_id
       AND NOT EXISTS (
         SELECT 1 FROM lines l2
          WHERE l2.machine_id = l.machine_id AND l2.shelf_code = l.shelf_code
            AND l2.action IN ('Remove','Machine To Warehouse')
       )
  )
  SELECT jsonb_build_object(
    'plan_date', p_plan_date,
    'blocking', COALESCE(count(*) FILTER (WHERE severity='blocking'),0),
    'warnings', COALESCE(count(*) FILTER (WHERE severity='warning'),0),
    'violations', COALESCE(jsonb_agg(jsonb_build_object(
        'code',code,'severity',severity,'gate',gate,'detail',detail)
        ORDER BY severity, code), '[]'::jsonb)
  ) INTO v_out FROM g;

  RETURN v_out;
END;
$function$;
