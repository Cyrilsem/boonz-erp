-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260714233505  name: fixA_picker_independent_sibling
CREATE OR REPLACE FUNCTION public.pick_machines_for_refill(p_plan_date date DEFAULT resolve_refill_plan_date(), p_max_total integer DEFAULT 8, p_max_siblings integer DEFAULT 2)
 RETURNS TABLE(out_machine_id uuid, out_official_name text, out_picked_reasons text[], out_priority_score numeric, out_route_cluster text, out_visit_order integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id        uuid;
  v_rows           integer;
  v_auto_closed    integer := 0;
  v_is_vox_day     boolean := false;
  v_vox_all_equip  boolean := false;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'pick_machines_for_refill', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'pick_machines_for_refill: caller % lacks role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;
  IF p_plan_date < CURRENT_DATE - 7 THEN
    RAISE EXCEPTION 'p_plan_date % too far in the past (>7d)', p_plan_date;
  END IF;
  IF p_max_total IS NULL OR p_max_total < 1 OR p_max_siblings IS NULL OR p_max_siblings < 0 THEN
    RAISE EXCEPTION 'invalid caps: p_max_total >= 1, p_max_siblings >= 0';
  END IF;

  -- PRD-035 WS-E: Saturday is a delivery day (off). Never pick a Saturday plan; defense-in-depth with
  -- the build_draft_for_confirmed guard so a manual pick on Saturday also yields no plan. Returns empty.
  IF EXTRACT(DOW FROM p_plan_date) = 6 THEN
    RAISE NOTICE 'pick_machines_for_refill: Saturday (%) is off (PRD-035 WS-E); no machines picked', p_plan_date;
    RETURN;
  END IF;

  v_is_vox_day := EXTRACT(DOW FROM p_plan_date) IN (3, 5);

  IF v_is_vox_day THEN
    SELECT bool_and(mp.fill_pct >= 70 AND COALESCE(mp.runway_days,0) >= 5 AND COALESCE(mp.empty_shelves_count,0) = 0)
      INTO v_vox_all_equip
      FROM public.v_machine_priority mp
     WHERE mp.venue_group = 'VOX'
       AND mp.include_in_refill = true
       AND mp.machine_status NOT IN ('Warehouse','Inactive');
    v_vox_all_equip := COALESCE(v_vox_all_equip, true);
  END IF;

  WITH pending AS (
    SELECT ps.swap_id, ps.machine_id, ps.shelf_code, ps.notes,
           add_pp.pod_product_id    AS add_pod_id,
           remove_pp.pod_product_id AS remove_pod_id
    FROM public.planned_swaps ps
    LEFT JOIN public.pod_products add_pp    ON add_pp.pod_product_name    = ps.add_pod_product_name
    LEFT JOIN public.pod_products remove_pp ON remove_pp.pod_product_name = ps.remove_pod_product_name
    WHERE ps.status = 'pending'
      AND add_pp.pod_product_id IS NOT NULL
      AND remove_pp.pod_product_id IS NOT NULL
  ),
  add_present AS (
    SELECT p.swap_id FROM pending p
    WHERE EXISTS (
      SELECT 1 FROM public.v_live_shelf_stock vls
      WHERE vls.machine_id = p.machine_id AND vls.pod_product_id = p.add_pod_id
    )
  ),
  remove_absent AS (
    SELECT p.swap_id FROM pending p
    WHERE NOT EXISTS (
      SELECT 1 FROM public.v_live_shelf_stock vls
      JOIN public.shelf_configurations sc
        ON sc.machine_id = vls.machine_id
       AND sc.shelf_code = p.shelf_code
       AND sc.is_phantom = false
       AND vls.slot_name = LEFT(sc.shelf_code, 1) || (SUBSTR(sc.shelf_code, 2)::int)::text
      WHERE vls.machine_id = p.machine_id AND vls.pod_product_id = p.remove_pod_id
    )
  ),
  to_close AS (
    SELECT a.swap_id FROM add_present a JOIN remove_absent r USING (swap_id)
  ),
  closed AS (
    UPDATE public.planned_swaps ps
       SET status               = 'applied',
           applied_at           = now(),
           applied_to_plan_date = p_plan_date,
           notes                = COALESCE(ps.notes || ' ', '')
                                 || '[auto_detect_via_picker_' || p_plan_date::text || ']'
     WHERE swap_id IN (SELECT swap_id FROM to_close)
     RETURNING 1
  )
  SELECT COUNT(*) INTO v_auto_closed FROM closed;

  UPDATE public.machines_to_visit
     SET status = 'superseded', updated_at = now()
   WHERE plan_date = p_plan_date AND status = 'picked';

  IF v_is_vox_day AND NOT v_vox_all_equip THEN
    WITH scored AS (
      SELECT mp.*
      FROM public.v_machine_priority mp
      WHERE mp.include_in_refill = true
        AND mp.machine_status NOT IN ('Warehouse', 'Inactive')
    ),
    vox_centroid AS (
      SELECT AVG(m.latitude) AS lat0, AVG(m.longitude) AS long0
      FROM scored sc
      JOIN public.machines m ON m.machine_id = sc.machine_id
      WHERE sc.venue_group = 'VOX'
    ),
    vox_sel AS (
      SELECT sc.*,
             CASE WHEN sc.p_tier = 'P1_RESTOCK' THEN 'P1_RESTOCK' ELSE 'P2_MAINTAIN' END AS final_tier,
             sc.p_score AS final_score,
             false      AS sibling,
             'vox'::text AS route_kind,
             0::bigint   AS near_rn
      FROM scored sc
      WHERE sc.venue_group = 'VOX'
    ),
    nonvox_sel AS (
      SELECT sc.*,
             sc.p_tier  AS final_tier,
             sc.p_score AS final_score,
             false      AS sibling,
             'main'::text AS route_kind,
             ROW_NUMBER() OVER (
               ORDER BY (CASE WHEN m.latitude IS NULL OR vc.lat0 IS NULL THEN 1 ELSE 0 END),
                        ( (m.latitude - vc.lat0)^2
                          + ((m.longitude - vc.long0) * COS(RADIANS(COALESCE(vc.lat0,0))))^2 ) ASC NULLS LAST,
                        sc.p_score DESC, sc.units_last_7d DESC, sc.official_name
             ) AS near_rn
      FROM scored sc
      JOIN public.machines m ON m.machine_id = sc.machine_id
      CROSS JOIN vox_centroid vc
      WHERE sc.venue_group IS DISTINCT FROM 'VOX'
        AND sc.p_tier = 'P1_RESTOCK'
    ),
    nonvox_pick AS (
      SELECT * FROM nonvox_sel WHERE near_rn <= 3
    ),
    final_picks AS (
      SELECT * FROM vox_sel
      UNION ALL
      SELECT * FROM nonvox_pick
    ),
    ordered AS (
      SELECT fp.*,
        CASE WHEN fp.route_kind = 'vox'
             THEN ARRAY_APPEND(fp.reasons_arr, 'vox_calendar_day')
             ELSE ARRAY_APPEND(fp.reasons_arr, 'vox_day_nonvox_nearest') END AS final_reasons,
        ROW_NUMBER() OVER (
          ORDER BY (fp.route_kind = 'vox') DESC,
                   CASE WHEN fp.final_tier = 'P1_RESTOCK' THEN 0 ELSE 1 END,
                   fp.final_score DESC, fp.units_last_7d DESC, fp.official_name
        )::integer AS v_order
      FROM final_picks fp
    )
    INSERT INTO public.machines_to_visit (
      plan_date, machine_id, official_name, location_type, venue_group, building_id,
      dead_slot_pct, days_since_visit, empty_shelf_pct,
      active_intent_count, is_ramping, units_last_7d,
      expired_skus_now, expired_skus_3d, expired_skus_7d, expired_skus_30d,
      fill_pct, hero_slot_count, health_tier,
      empty_shelves_count, runway_days, severity,
      picked_reasons, priority_score, route_cluster, visit_order,
      service_track, priority_tier,
      picked_at, picked_by, status
    )
    SELECT p_plan_date, o.machine_id, o.official_name, o.location_type, o.venue_group, o.building_id,
      o.dead_slot_pct, o.days_since_visit, o.empty_shelf_pct,
      o.active_intent_count, o.is_ramping, o.units_last_7d,
      o.expired_skus_now, o.expired_skus_3d, o.expired_skus_7d, o.expired_skus_30d,
      o.fill_pct, o.hero_slot_count, o.tier,
      o.empty_shelves_count, o.runway_days,
      CASE WHEN o.final_tier = 'P1_RESTOCK' AND o.final_score >= 60 THEN 'critical'
           WHEN o.final_tier = 'P1_RESTOCK' THEN 'urgent'
           WHEN o.final_tier = 'P2_MAINTAIN' AND o.final_score >= 18 THEN 'high'
           ELSE 'medium' END,
      o.final_reasons, o.final_score, o.r_cluster, o.v_order,
      o.svc_track, o.final_tier,
      now(), v_user_id, 'picked'
    FROM ordered o
    ON CONFLICT (plan_date, machine_id) DO UPDATE
       SET official_name=EXCLUDED.official_name, location_type=EXCLUDED.location_type,
           venue_group=EXCLUDED.venue_group, building_id=EXCLUDED.building_id,
           dead_slot_pct=EXCLUDED.dead_slot_pct, days_since_visit=EXCLUDED.days_since_visit,
           empty_shelf_pct=EXCLUDED.empty_shelf_pct, active_intent_count=EXCLUDED.active_intent_count,
           is_ramping=EXCLUDED.is_ramping, units_last_7d=EXCLUDED.units_last_7d,
           expired_skus_now=EXCLUDED.expired_skus_now, expired_skus_3d=EXCLUDED.expired_skus_3d,
           expired_skus_7d=EXCLUDED.expired_skus_7d, expired_skus_30d=EXCLUDED.expired_skus_30d,
           fill_pct=EXCLUDED.fill_pct, hero_slot_count=EXCLUDED.hero_slot_count,
           health_tier=EXCLUDED.health_tier,
           empty_shelves_count=EXCLUDED.empty_shelves_count, runway_days=EXCLUDED.runway_days,
           severity=EXCLUDED.severity,
           picked_reasons=EXCLUDED.picked_reasons, priority_score=EXCLUDED.priority_score,
           route_cluster=EXCLUDED.route_cluster, visit_order=EXCLUDED.visit_order,
           service_track=EXCLUDED.service_track, priority_tier=EXCLUDED.priority_tier,
           picked_at=EXCLUDED.picked_at, picked_by=EXCLUDED.picked_by, status='picked',
           confirmed_at=NULL, confirmed_by=NULL, updated_at=now();

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'pick_machines_for_refill v11 (VOX-day; all_equip=%) % -> % rows', v_vox_all_equip, p_plan_date, v_rows;

  ELSE
    WITH scored AS (
      SELECT mp.*
      FROM public.v_machine_priority mp
      WHERE mp.include_in_refill = true
        AND mp.machine_status NOT IN ('Warehouse', 'Inactive')
    ),
    ranked_primary AS (
      SELECT sc.*, ROW_NUMBER() OVER (
        ORDER BY sc.p_score DESC, sc.units_last_7d DESC, sc.official_name
      ) AS pick_rn
      FROM scored sc WHERE sc.p_tier = 'P1_RESTOCK'
        AND ( v_is_vox_day
              OR sc.venue_group IS DISTINCT FROM 'VOX'
              OR ( sc.venue_group = 'VOX' AND COALESCE(sc.runway_days, 999) < public.days_until_next_vox_day(p_plan_date) ) )
    ),
    primary_picks AS (
      SELECT rp.*, rp.p_tier AS final_tier, rp.p_score AS final_score, false AS sibling
      FROM ranked_primary rp WHERE rp.pick_rn <= p_max_total
    ),
    sibling_ranked AS (
      SELECT sc.*, ROW_NUMBER() OVER (
        ORDER BY sc.p_score DESC, sc.units_last_7d DESC, sc.official_name
      ) AS pick_rn
      FROM scored sc
      WHERE sc.venue_group IS DISTINCT FROM 'VOX'
        AND sc.r_cluster <> 'INDEPENDENT'          -- FIX A: catch-all bucket is not a route cluster; do not treat group-less machines as siblings
        AND sc.r_cluster IN (SELECT r_cluster FROM primary_picks WHERE svc_track = 'main')
        AND sc.machine_id NOT IN (SELECT machine_id FROM primary_picks)
        AND (sc.empty_shelves_count > 0 OR sc.fill_pct < 70 OR sc.days_since_visit >= 7
          OR sc.expired_skus_7d > 0 OR sc.active_intent_count > 0)
    ),
    sibling_picks AS (
      SELECT sr.*, 'P2_MAINTAIN'::text AS final_tier, sr.p_score AS final_score, true AS sibling
      FROM sibling_ranked sr
      WHERE sr.pick_rn <= GREATEST(
        LEAST(p_max_siblings, p_max_total - (SELECT COUNT(*) FROM primary_picks)), 0)
    ),
    final_picks AS (
      SELECT * FROM primary_picks
      UNION ALL
      SELECT * FROM sibling_picks
    ),
    ordered AS (
      SELECT fp.*,
        CASE WHEN fp.sibling THEN ARRAY_APPEND(fp.reasons_arr, 'sibling') WHEN fp.venue_group = 'VOX' THEN ARRAY_APPEND(fp.reasons_arr, 'vox_emergency_offday') ELSE fp.reasons_arr END AS final_reasons,
        ROW_NUMBER() OVER (
          ORDER BY (fp.svc_track = 'vox'),
                   CASE WHEN fp.final_tier = 'P1_RESTOCK' THEN 0 ELSE 1 END,
                   fp.final_score DESC, fp.units_last_7d DESC, fp.official_name
        )::integer AS v_order
      FROM final_picks fp
    )
    INSERT INTO public.machines_to_visit (
      plan_date, machine_id, official_name, location_type, venue_group, building_id,
      dead_slot_pct, days_since_visit, empty_shelf_pct,
      active_intent_count, is_ramping, units_last_7d,
      expired_skus_now, expired_skus_3d, expired_skus_7d, expired_skus_30d,
      fill_pct, hero_slot_count, health_tier,
      empty_shelves_count, runway_days, severity,
      picked_reasons, priority_score, route_cluster, visit_order,
      service_track, priority_tier,
      picked_at, picked_by, status
    )
    SELECT p_plan_date, o.machine_id, o.official_name, o.location_type, o.venue_group, o.building_id,
      o.dead_slot_pct, o.days_since_visit, o.empty_shelf_pct,
      o.active_intent_count, o.is_ramping, o.units_last_7d,
      o.expired_skus_now, o.expired_skus_3d, o.expired_skus_7d, o.expired_skus_30d,
      o.fill_pct, o.hero_slot_count, o.tier,
      o.empty_shelves_count, o.runway_days,
      CASE WHEN o.final_tier = 'P1_RESTOCK' AND o.final_score >= 60 THEN 'critical'
           WHEN o.final_tier = 'P1_RESTOCK' THEN 'urgent'
           WHEN o.final_tier = 'P2_MAINTAIN' AND o.final_score >= 18 THEN 'high'
           ELSE 'medium' END,
      o.final_reasons, o.final_score, o.r_cluster, o.v_order,
      o.svc_track, o.final_tier,
      now(), v_user_id, 'picked'
    FROM ordered o
    ON CONFLICT (plan_date, machine_id) DO UPDATE
       SET official_name=EXCLUDED.official_name, location_type=EXCLUDED.location_type,
           venue_group=EXCLUDED.venue_group, building_id=EXCLUDED.building_id,
           dead_slot_pct=EXCLUDED.dead_slot_pct, days_since_visit=EXCLUDED.days_since_visit,
           empty_shelf_pct=EXCLUDED.empty_shelf_pct, active_intent_count=EXCLUDED.active_intent_count,
           is_ramping=EXCLUDED.is_ramping, units_last_7d=EXCLUDED.units_last_7d,
           expired_skus_now=EXCLUDED.expired_skus_now, expired_skus_3d=EXCLUDED.expired_skus_3d,
           expired_skus_7d=EXCLUDED.expired_skus_7d, expired_skus_30d=EXCLUDED.expired_skus_30d,
           fill_pct=EXCLUDED.fill_pct, hero_slot_count=EXCLUDED.hero_slot_count,
           health_tier=EXCLUDED.health_tier,
           empty_shelves_count=EXCLUDED.empty_shelves_count, runway_days=EXCLUDED.runway_days,
           severity=EXCLUDED.severity,
           picked_reasons=EXCLUDED.picked_reasons, priority_score=EXCLUDED.priority_score,
           route_cluster=EXCLUDED.route_cluster, visit_order=EXCLUDED.visit_order,
           service_track=EXCLUDED.service_track, priority_tier=EXCLUDED.priority_tier,
           picked_at=EXCLUDED.picked_at, picked_by=EXCLUDED.picked_by, status='picked',
           confirmed_at=NULL, confirmed_by=NULL, updated_at=now();

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'pick_machines_for_refill v11 (normal-day) % -> % rows (cap %, siblings %)',
      p_plan_date, v_rows, p_max_total, p_max_siblings;
  END IF;

  RETURN QUERY
  SELECT mv.machine_id, mv.official_name, mv.picked_reasons,
         mv.priority_score, mv.route_cluster, mv.visit_order
    FROM public.machines_to_visit mv
   WHERE mv.plan_date = p_plan_date AND mv.status = 'picked'
   ORDER BY mv.visit_order;
END;
$function$;
