-- PRD-035 Phase D (WS-E) - Step-0 picker: VOX calendar + Saturday-off.
--
-- CS decisions (2026-06-18):
--   E1 cluster key      = venue_group  (already the picker's sibling-cluster basis; r_cluster is venue-derived).
--   E2 VOX well-equipped = every VOX machine fill_pct >= 70 AND runway_days >= 5 AND empty_shelves_count = 0
--                          (machine-grain proxy for "every VOX shelf >= 70% fill AND runway >= 5d").
--   E3 non-VOX on VOX days = top P1 need, the 2-3 NEAREST the VOX centroid (lat/long).
--   E4 sister def        = same as E1 (venue_group); unchanged from the existing sibling logic.
--
-- TWO surgical changes, both forward-only CREATE OR REPLACE:
--
-- 1. build_draft_for_confirmed (the Friday-8pm cron entry): refuse to build a SATURDAY plan. Saturday is a
--    delivery day; the cron must not emit a Saturday plan. Early return BEFORE any pick/confirm/engine write.
--
-- 2. pick_machines_for_refill: branch on the plan_date day-of-week.
--      - VOX days (Wed=3, Fri=5): select ALL VOX venue machines (UNLESS every VOX machine is well-equipped,
--        in which case skip VOX and focus non-VOX) + the 2-3 nearest P1 non-VOX machines to the VOX centroid.
--      - All other days: the EXISTING v9.2 P1-first + venue-cluster + non-VOX sibling logic, reproduced verbatim.
--    Both branches write the same machines_to_visit columns. Non-VOX-day path is byte-identical to v9.2.
--
-- Both are SECURITY DEFINER; app.via_rpc / app.rpc_name / operator_admin guards preserved. Targets are the
-- non-protected staging table machines_to_visit (pick) and downstream engine RPCs (cron). No change to any
-- protected-entity write path.

-- ============================================================================
-- 1) build_draft_for_confirmed - Saturday-off guard
-- ============================================================================
CREATE OR REPLACE FUNCTION public.build_draft_for_confirmed(p_plan_date date DEFAULT resolve_refill_plan_date(), p_repick boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '1200000'
AS $function$
DECLARE
  v_user_id   uuid;
  v_picked    int;
  v_confirmed int;
  v_included  int;
  v_repicked  boolean := false;
  v_auto_conf jsonb;
  v_add       jsonb;
  v_swap      jsonb;
  v_final     jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'build_draft_for_confirmed', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role IN ('operator_admin', 'superadmin')
  ) THEN
    RETURN jsonb_build_object('status', 'error',
      'message', 'unauthorized: requires operator_admin or superadmin');
  END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;

  -- PRD-035 WS-E: Saturday is a delivery day (no refill plan). The Friday-8pm cron resolves tomorrow =
  -- Saturday and must NOT build a plan. Early return before any pick/confirm/engine write.
  IF EXTRACT(DOW FROM p_plan_date) = 6 THEN
    RETURN jsonb_build_object('status', 'skipped_saturday', 'plan_date', p_plan_date,
      'message', 'Saturday is a delivery day; no refill plan is generated (PRD-035 WS-E calendar)');
  END IF;

  -- Never touch a live plan
  IF EXISTS (SELECT 1 FROM public.pod_refill_plan
              WHERE plan_date = p_plan_date AND status IN ('approved','stitched'))
     OR EXISTS (SELECT 1 FROM public.refill_dispatching WHERE dispatch_date = p_plan_date) THEN
    RETURN jsonb_build_object('status', 'refused_live_plan', 'plan_date', p_plan_date,
      'message', 'plan already approved/stitched/dispatched; use edit RPCs');
  END IF;

  -- Fresh pick at build time (supersedes the morning preview pick)
  IF p_repick THEN
    PERFORM public.pick_machines_for_refill(p_plan_date);
    v_repicked := true;
  END IF;

  v_auto_conf := public.confirm_machines_to_visit(p_plan_date);

  SELECT
    COUNT(*) FILTER (WHERE status = 'picked'),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL AND COALESCE(is_included, true) = true)
  INTO v_picked, v_confirmed, v_included
  FROM public.machines_to_visit
  WHERE plan_date = p_plan_date;

  BEGIN
    PERFORM public._assert_gate_zero(p_plan_date);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('status', 'awaiting_confirmation',
      'plan_date', p_plan_date, 'confirmed', v_confirmed, 'picked', v_picked);
  END;

  IF v_included = 0 THEN
    RETURN jsonb_build_object('status', 'no_included_machines',
      'plan_date', p_plan_date, 'confirmed', v_confirmed);
  END IF;

  v_add   := engine_add_pod(p_plan_date, 14);
  v_swap  := engine_swap_pod(p_plan_date, 2, 0.30, 14);
  v_final := engine_finalize_pod(p_plan_date);

  RETURN jsonb_build_object(
    'status', 'draft_ready',
    'plan_date', p_plan_date,
    'repicked', v_repicked,
    'machines_picked', v_picked,
    'machines_confirmed', v_confirmed,
    'machines_included', v_included,
    'auto_confirmed', v_auto_conf,
    'stage_2a', v_add,
    'stage_2b', v_swap,
    'stage_2c', v_final,
    'coverage', public.check_refill_coverage(p_plan_date)
  );
END;
$function$;

-- ============================================================================
-- 2) pick_machines_for_refill - VOX calendar branch (Wed/Fri) + verbatim normal path
-- ============================================================================
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

  -- PRD-035 WS-E VOX calendar: Wed (DOW 3) and Fri (DOW 5) are VOX days.
  v_is_vox_day := EXTRACT(DOW FROM p_plan_date) IN (3, 5);

  -- E2: every in-scope VOX machine well-equipped (fill >=70, runway >=5d, no empty shelf) -> skip VOX.
  IF v_is_vox_day THEN
    SELECT bool_and(mp.fill_pct >= 70 AND COALESCE(mp.runway_days,0) >= 5 AND COALESCE(mp.empty_shelves_count,0) = 0)
      INTO v_vox_all_equip
      FROM public.v_machine_priority mp
     WHERE mp.venue_group = 'VOX'
       AND mp.include_in_refill = true
       AND mp.machine_status NOT IN ('Warehouse','Inactive');
    v_vox_all_equip := COALESCE(v_vox_all_equip, true);  -- no VOX machines -> nothing to serve
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
    -- ===================== VOX-DAY SELECTION (PRD-035 WS-E) =====================
    -- VOX day with at least one needy VOX machine: serve ALL VOX + 2-3 nearest P1 non-VOX.
    -- (If every VOX machine is well-equipped, we fall through to the normal branch = focus non-VOX.)
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
      -- all VOX venue machines (this branch only runs when >=1 VOX machine is needy).
      -- machines_to_visit.priority_tier CHECK allows only P1_RESTOCK / P2_MAINTAIN; VOX machines can be
      -- P3_OK, so force-included VOX picks map to P2_MAINTAIN (served on the route) unless already P1.
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
      -- E3: P1 non-VOX, ordered NEAREST the VOX centroid (planar lat/long approx), score as tiebreak
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
      SELECT * FROM nonvox_sel WHERE near_rn <= 3   -- 2-3 nearest P1 non-VOX
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
    RAISE NOTICE 'pick_machines_for_refill v10 (VOX-day; all_equip=%) % -> % rows', v_vox_all_equip, p_plan_date, v_rows;

  ELSE
    -- ===================== NORMAL-DAY SELECTION (v9.2, verbatim) =====================
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
    RAISE NOTICE 'pick_machines_for_refill v10 (normal-day) % -> % rows (cap %, siblings %)',
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
