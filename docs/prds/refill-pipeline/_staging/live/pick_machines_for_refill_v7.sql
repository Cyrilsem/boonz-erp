CREATE OR REPLACE FUNCTION public.pick_machines_for_refill(p_plan_date date DEFAULT (CURRENT_DATE + 1))
 RETURNS TABLE(out_machine_id uuid, out_official_name text, out_picked_reasons text[], out_priority_score numeric, out_route_cluster text, out_visit_order integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id     uuid;
  v_rows        integer;
  v_auto_closed integer := 0;
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

  RAISE NOTICE 'pick_machines_for_refill v7: auto-closed % planned_swaps for plan_date %',
    v_auto_closed, p_plan_date;

  UPDATE public.machines_to_visit
     SET status = 'superseded', updated_at = now()
   WHERE plan_date = p_plan_date AND status = 'picked';

  WITH shelf_u25 AS (
    SELECT vls.machine_id,
           COUNT(*) FILTER (WHERE vls.is_enabled AND vls.current_stock > 0 AND vls.fill_pct < 25) AS under25
    FROM public.v_live_shelf_stock vls
    GROUP BY vls.machine_id
  ),
  scored AS (
    SELECT s.*,
      COALESCE(u.under25, 0) AS under25,
      CASE WHEN s.venue_group = 'VOX' THEN 'vox' ELSE 'main' END AS svc_track,
      CASE
        WHEN s.empty_shelves_count >= 1
          OR (s.runway_days IS NOT NULL AND s.runway_days < 7)
          OR (s.runway_days IS NOT NULL AND s.runway_days < 14 AND s.units_last_7d >= 20)
          OR (COALESCE(u.under25,0) >= 1 AND s.units_last_7d >= 20)
          THEN 'P1_RESTOCK'
        WHEN s.dead_slot_pct >= 15 OR s.days_since_visit >= 14
          OR s.expired_skus_now >= 1 OR s.active_intent_count > 0
          THEN 'P2_MAINTAIN'
        ELSE 'skip'
      END AS p_tier,
      (  (CASE WHEN s.empty_shelves_count >= 1 THEN 50 + LEAST((s.empty_shelves_count-1)*12, 36) ELSE 0 END)
       + (CASE WHEN s.units_last_7d >= 50 AND s.runway_days < 14 THEN 35
               WHEN s.units_last_7d >= 20 AND s.runway_days < 10 THEN 28
               WHEN s.runway_days < 7 THEN 25
               WHEN s.runway_days < 14 THEN 12 ELSE 0 END)
       + (CASE WHEN s.units_last_7d >= 15 THEN LEAST(COALESCE(u.under25,0)*8, 24) ELSE 0 END)
       + (CASE WHEN s.units_last_7d >= 50 THEN 10 ELSE 0 END)
       + (CASE WHEN s.dead_slot_pct >= 30 THEN 15 WHEN s.dead_slot_pct >= 15 THEN 8 ELSE 0 END)
       + (CASE WHEN s.days_since_visit >= 21 THEN 10 WHEN s.days_since_visit >= 14 THEN 6 WHEN s.days_since_visit >= 10 THEN 3 ELSE 0 END)
       + (CASE WHEN s.expired_skus_now >= 1 THEN 8 ELSE 0 END)
       + (CASE WHEN s.active_intent_count > 0 THEN 5 ELSE 0 END)
      )::numeric(6,2) AS p_score,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN s.empty_shelves_count > 1 THEN 'empty_multi' END,
        CASE WHEN s.empty_shelves_count = 1 THEN 'empty_one'  END,
        CASE WHEN s.runway_days IS NOT NULL AND s.runway_days < 7 THEN 'runway_critical' END,
        CASE WHEN s.runway_days IS NOT NULL AND s.runway_days >= 7 AND s.runway_days < 14 AND s.units_last_7d >= 20 THEN 'selling_low_runway' END,
        CASE WHEN s.units_last_7d >= 15 AND COALESCE(u.under25,0) >= 1 THEN 'shelf_under25' END,
        CASE WHEN s.units_last_7d >= 50 THEN 'high_velocity' END,
        CASE WHEN s.dead_slot_pct >= 15 THEN 'dead_slots' END,
        CASE WHEN s.days_since_visit >= 14 THEN 'stale' END,
        CASE WHEN s.expired_skus_now >= 1 THEN 'expired_now' END,
        CASE WHEN s.active_intent_count > 0 THEN 'intent' END
      ], NULL) AS reasons_arr,
      COALESCE(s.venue_group, s.building_id, s.official_name) AS r_cluster
    FROM public.v_machine_health_signals s
    LEFT JOIN shelf_u25 u ON u.machine_id = s.machine_id
  ),
  primary_picks AS (
    SELECT *, p_tier AS final_tier, p_score AS final_score, false AS sibling
    FROM scored WHERE p_tier <> 'skip'
  ),
  sibling_picks AS (
    SELECT sc.*, 'P2_MAINTAIN' AS final_tier, sc.p_score AS final_score, true AS sibling
    FROM scored sc
    WHERE sc.venue_group IS DISTINCT FROM 'VOX'
      AND sc.r_cluster IN (SELECT r_cluster FROM primary_picks WHERE svc_track = 'main')
      AND sc.machine_id NOT IN (SELECT machine_id FROM primary_picks)
      AND (sc.empty_shelves_count > 0 OR sc.fill_pct < 70 OR sc.days_since_visit >= 7
        OR sc.expired_skus_7d > 0 OR sc.active_intent_count > 0)
  ),
  final_picks AS (
    SELECT * FROM primary_picks
    UNION ALL
    SELECT * FROM sibling_picks
  ),
  ordered AS (
    SELECT fp.*,
      CASE WHEN fp.sibling THEN ARRAY_APPEND(fp.reasons_arr, 'sibling') ELSE fp.reasons_arr END AS final_reasons,
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
  RAISE NOTICE 'pick_machines_for_refill v7 % -> % rows picked', p_plan_date, v_rows;

  RETURN QUERY
  SELECT mv.machine_id, mv.official_name, mv.picked_reasons,
         mv.priority_score, mv.route_cluster, mv.visit_order
    FROM public.machines_to_visit mv
   WHERE mv.plan_date = p_plan_date AND mv.status = 'picked'
   ORDER BY mv.visit_order;
END;
$function$
