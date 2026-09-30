-- PRD-137 F11, drafted 2026-09-30 daytime, NOT YET APPLIED. Migration 1 of 3 (one per function,
-- per the spec): the shared G11 helper, and validate_refill_plan's new G11 gate row. Touches
-- dispatch/plan functions -- apply only inside the 22:00-06:00 Dubai window, then rename to match
-- whatever version apply_migration actually records (see last run's own note on why).
--
-- G11: for a Refill/Add New line, if product_mapping has Active rows with machine_id = the
-- line's machine for that pod_product, the line's boonz_product must be one of them. Override:
-- comment starts with "[sub]" AND every one of the mapped products has zero pickable stock at
-- WH_CENTRAL (v_wh_pickable, the canonical pickable-stock view). Shared helper so
-- write_refill_plan (write-time reject), validate_refill_plan (approve-time gate, used by
-- approve_refill_plan), and approve_refill_plan's own override-audit scan all use identical
-- logic -- no risk of the three drifting apart.
--
-- Rollback: supabase/rollback/20260930180324_prd137_f11a_g11_helper_and_validate_rollback.sql
CREATE OR REPLACE FUNCTION public.g11_check_machine_mapping(
  p_machine_id uuid, p_pod_product_id uuid, p_boonz_product_id uuid, p_comment text
) RETURNS TABLE(is_violation boolean, is_override boolean, mapped_ids uuid[])
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mapped_ids uuid[];
BEGIN
  SELECT array_agg(pm.boonz_product_id) INTO v_mapped_ids
  FROM public.product_mapping pm
  WHERE pm.machine_id = p_machine_id
    AND pm.pod_product_id = p_pod_product_id
    AND pm.status = 'Active';

  -- No machine-scoped mapping at all for this pod_product on this machine: nothing to enforce.
  IF v_mapped_ids IS NULL OR p_boonz_product_id = ANY(v_mapped_ids) THEN
    RETURN QUERY SELECT false, false, v_mapped_ids;
    RETURN;
  END IF;

  -- Override: comment starts with "[sub]" and none of the mapped products are pickable at
  -- WH_CENTRAL right now (v_wh_pickable already excludes quarantined/expired/zero-stock rows).
  IF COALESCE(p_comment, '') LIKE '[sub]%' AND NOT EXISTS (
    SELECT 1 FROM public.v_wh_pickable vwp
     WHERE vwp.boonz_product_id = ANY(v_mapped_ids)
       AND vwp.warehouse_id = '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid
  ) THEN
    RETURN QUERY SELECT false, true, v_mapped_ids;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, false, v_mapped_ids;
END;
$function$;

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
    SELECT rd.machine_id, sc.shelf_code, rd.boonz_product_id, rd.pod_product_id, rd.action, rd.quantity, rd.source_origin, rd.comment
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
    SELECT rpo.machine_id, sc2.shelf_code, rpo.boonz_product_id, rpo.pod_product_id, rpo.action, rpo.quantity, rpo.source_origin, rpo.comment
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
    -- Loop 2026-09-25 A3: G3 now excludes any lane already covered by an approved plan_output
    -- line or a live (non-cancelled/skipped/returned) dispatch line for this exact plan_date,
    -- regardless of p_source -- coverage that already exists is coverage, whether or not this
    -- particular validate_refill_plan call's own pending-batch scope happens to see it.
    SELECT 'G3' AS code, 'blocking' AS severity, 'EMPTY lane with no line and no substitution rule' AS gate,
           m.official_name||' '||lane.shelf_code||' ('||lane.pod||')' AS detail
      FROM lane JOIN public.machines m ON m.machine_id = lane.machine_id
     WHERE lane.current_stock = 0 AND lane.n_lines = 0
       AND NOT EXISTS (
         SELECT 1 FROM public.refill_plan_output rpo3
         JOIN public.shelf_configurations sc3 ON sc3.shelf_id = rpo3.shelf_id
          WHERE rpo3.machine_id = lane.machine_id
            AND sc3.shelf_code = lane.shelf_code
            AND rpo3.plan_date = p_plan_date
            AND rpo3.operator_status = 'approved'
            AND rpo3.action IN ('Refill','Add New')
            AND COALESCE(rpo3.quantity,0) > 0
       )
       AND NOT EXISTS (
         SELECT 1 FROM public.refill_dispatching rd3
         JOIN public.shelf_configurations sc4 ON sc4.shelf_id = rd3.shelf_id
          WHERE rd3.machine_id = lane.machine_id
            AND sc4.shelf_code = lane.shelf_code
            AND rd3.dispatch_date = p_plan_date
            AND COALESCE(rd3.cancelled,false)=false
            AND COALESCE(rd3.skipped,false)=false
            AND COALESCE(rd3.returned,false)=false
            AND rd3.action IN ('Refill','Add New')
            AND COALESCE(rd3.quantity,0) > 0
       )
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
       AND NOT (
         lane.current_stock > lane.out_qty
         AND EXISTS (
           SELECT 1 FROM public.v_expiry_pull_candidates vepc
           JOIN public.shelf_configurations sc5
             ON sc5.machine_id = lane.machine_id AND sc5.shelf_code = lane.shelf_code
            WHERE vepc.machine_id = lane.machine_id
              AND vepc.shelf_id = sc5.shelf_id
              AND vepc.is_pull_candidate IS DISTINCT FROM false
         )
       )
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
    UNION ALL
    -- PRD-137 F11: machine-scoped mapping gate. See g11_check_machine_mapping for the shared
    -- override logic ([sub] comment + zero WH_CENTRAL pickable stock on every mapped product).
    SELECT 'G11','blocking','G11 not in machine mapping',
           m.official_name||' '||COALESCE(l.shelf_code,'?')||' '||COALESCE(bp3.boonz_product_name,'?')
      FROM lines l
      JOIN public.machines m ON m.machine_id = l.machine_id
      LEFT JOIN public.boonz_products bp3 ON bp3.product_id = l.boonz_product_id
      CROSS JOIN LATERAL public.g11_check_machine_mapping(l.machine_id, l.pod_product_id, l.boonz_product_id, l.comment) gcm
     WHERE l.action IN ('Refill','Add New')
       AND gcm.is_violation
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
