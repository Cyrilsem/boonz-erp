-- PRD-010 AC#5: pick_machines_for_refill v6
-- Auto-close planned_swaps that have already been physically executed at the
-- machine. Runs at the top of pick_machines_for_refill (before the supersede
-- UPDATE) so subsequent engine stages do not re-propose the same swap.
--
-- A pending planned_swap is auto-closed when BOTH:
--   (a) The add_pod_product is currently present somewhere on the target
--       machine (matched by pod_product_id via v_live_shelf_stock).
--   (b) The remove_pod_product is NOT currently on the shelf the swap was
--       originally planned for (matched by shelf_code -> shelf_id via
--       shelf_configurations, then checked against v_live_shelf_stock).
--
-- Schema adaptation note: PRD AC#5 spec'd status='completed' with
-- completed_at/completed_by columns, but planned_swaps.status CHECK only
-- allows ('pending','applied','cancelled') and has no completed_* columns.
-- Per the goal's no-schema-change constraint, this migration uses the closest
-- existing semantic: status='applied' with applied_at=now(),
-- applied_to_plan_date=p_plan_date, and an '[auto_detect_via_picker_<date>]'
-- tag appended to notes for forensic visibility. If CS wants the literal
-- 'completed' state, a follow-up migration widens the CHECK constraint and
-- adds the columns.

CREATE OR REPLACE FUNCTION public.pick_machines_for_refill(
  p_plan_date date DEFAULT (CURRENT_DATE + 1)
) RETURNS TABLE(
  out_machine_id      uuid,
  out_official_name   text,
  out_picked_reasons  text[],
  out_priority_score  numeric,
  out_route_cluster   text,
  out_visit_order     integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id          uuid;
  v_rows             integer;
  v_auto_closed      integer := 0;
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

  -- v6 AC#5: auto-close planned_swaps that WEIMI already shows as executed.
  WITH pending AS (
    SELECT
      ps.swap_id,
      ps.machine_id,
      ps.shelf_code,
      ps.notes,
      add_pp.pod_product_id    AS add_pod_id,
      remove_pp.pod_product_id AS remove_pod_id
    FROM public.planned_swaps ps
    LEFT JOIN public.pod_products add_pp
      ON add_pp.pod_product_name = ps.add_pod_product_name
    LEFT JOIN public.pod_products remove_pp
      ON remove_pp.pod_product_name = ps.remove_pod_product_name
    WHERE ps.status = 'pending'
      AND add_pp.pod_product_id IS NOT NULL
      AND remove_pp.pod_product_id IS NOT NULL
  ),
  add_present AS (
    SELECT p.swap_id
    FROM pending p
    WHERE EXISTS (
      SELECT 1 FROM public.v_live_shelf_stock vls
      WHERE vls.machine_id = p.machine_id
        AND vls.pod_product_id = p.add_pod_id
    )
  ),
  remove_absent AS (
    SELECT p.swap_id
    FROM pending p
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_live_shelf_stock vls
      JOIN public.shelf_configurations sc
        ON sc.machine_id = vls.machine_id
       AND sc.shelf_code = p.shelf_code
       AND sc.is_phantom = false
       AND vls.slot_name = LEFT(sc.shelf_code, 1) || (SUBSTR(sc.shelf_code, 2)::int)::text
      WHERE vls.machine_id = p.machine_id
        AND vls.pod_product_id = p.remove_pod_id
    )
  ),
  to_close AS (
    SELECT a.swap_id
    FROM add_present a
    JOIN remove_absent r USING (swap_id)
  ),
  closed AS (
    UPDATE public.planned_swaps ps
       SET status               = 'applied',
           applied_at           = now(),
           applied_to_plan_date = p_plan_date,
           notes                = COALESCE(ps.notes || ' ', '')
                                 || '[auto_detect_via_picker_'
                                 || p_plan_date::text || ']'
     WHERE swap_id IN (SELECT swap_id FROM to_close)
     RETURNING 1
  )
  SELECT COUNT(*) INTO v_auto_closed FROM closed;

  RAISE NOTICE 'pick_machines_for_refill v6: auto-closed % planned_swaps for plan_date %',
    v_auto_closed, p_plan_date;

  UPDATE public.machines_to_visit
     SET status = 'superseded', updated_at = now()
   WHERE plan_date = p_plan_date AND status = 'picked';

  WITH scored AS (
    SELECT
      s.*,
      CASE
        WHEN s.empty_shelves_count > 1
          OR s.expired_skus_now >= 1
          OR s.fill_pct < 50
          OR (s.runway_days IS NOT NULL AND s.runway_days < 2)
        THEN 'critical'
        WHEN s.empty_shelves_count = 1
          OR s.expired_skus_3d >= 1
          OR (s.runway_days IS NOT NULL AND s.runway_days < 4)
        THEN 'urgent'
        WHEN s.expired_skus_7d >= 1
          OR (s.fill_pct >= 50 AND s.fill_pct < 70)
        THEN 'high'
        WHEN s.days_since_visit >= 15
          OR s.active_intent_count > 0
        THEN 'medium'
        ELSE 'skip'
      END AS severity,
      ARRAY_REMOVE(ARRAY[
        CASE WHEN s.empty_shelves_count >  1 THEN 'empty_multi'    END,
        CASE WHEN s.empty_shelves_count =  1 THEN 'empty_one'      END,
        CASE WHEN s.expired_skus_now   >= 1  THEN 'expired_now'    END,
        CASE WHEN s.expired_skus_3d    >= 1  THEN 'expiring_3d'    END,
        CASE WHEN s.expired_skus_7d    >= 1  THEN 'expiring_7d'    END,
        CASE WHEN s.fill_pct           <  50 THEN 'fill_critical'  END,
        CASE WHEN s.fill_pct >= 50 AND s.fill_pct < 70 THEN 'fill_high' END,
        CASE WHEN s.runway_days IS NOT NULL AND s.runway_days < 2 THEN 'runway_critical' END,
        CASE WHEN s.runway_days IS NOT NULL AND s.runway_days >= 2 AND s.runway_days < 4 THEN 'runway_urgent' END,
        CASE WHEN s.days_since_visit   >= 15 THEN 'stale'          END,
        CASE WHEN s.active_intent_count > 0  THEN 'intent'         END
      ], NULL) AS reasons_arr
    FROM public.v_machine_health_signals s
  ),
  with_score AS (
    SELECT sc.*,
      CASE sc.severity
        WHEN 'critical' THEN 100
        WHEN 'urgent'   THEN  75
        WHEN 'high'     THEN  50
        WHEN 'medium'   THEN  25
        ELSE 0
      END::numeric(5,2) AS pri_score,
      COALESCE(sc.venue_group, sc.building_id, sc.official_name) AS r_cluster
    FROM scored sc
  ),
  primary_picks AS (
    SELECT * FROM with_score WHERE severity <> 'skip'
  ),
  sibling_picks AS (
    SELECT ws.* FROM with_score ws
     WHERE ws.r_cluster IN (SELECT r_cluster FROM primary_picks)
       AND ws.machine_id NOT IN (SELECT machine_id FROM primary_picks)
       AND (
         ws.empty_shelves_count > 0
         OR ws.fill_pct < 70
         OR ws.days_since_visit >= 7
         OR ws.expired_skus_7d > 0
         OR ws.active_intent_count > 0
       )
  ),
  final_picks AS (
    SELECT pp.*, false AS sibling, pp.pri_score AS final_score FROM primary_picks pp
    UNION ALL
    SELECT sp.*, true AS sibling,
           (
             (CASE WHEN sp.empty_shelves_count > 0 THEN 8 ELSE 0 END) +
             (CASE WHEN sp.fill_pct IS NOT NULL AND sp.fill_pct < 70 THEN 6 ELSE 0 END) +
             (CASE WHEN sp.days_since_visit >= 7 THEN 5 ELSE 0 END) +
             (CASE WHEN sp.expired_skus_7d > 0 THEN 6 ELSE 0 END) +
             (CASE WHEN sp.active_intent_count > 0 THEN 5 ELSE 0 END)
           )::numeric(5,2) AS final_score
    FROM sibling_picks sp
  ),
  ordered AS (
    SELECT fp.*,
      CASE WHEN fp.sibling THEN ARRAY_APPEND(fp.reasons_arr, 'sibling') ELSE fp.reasons_arr END AS final_reasons,
      ROW_NUMBER() OVER (
        ORDER BY fp.r_cluster NULLS LAST,
                 fp.final_score DESC,
                 fp.expired_skus_now DESC,
                 fp.units_last_7d DESC,
                 fp.official_name
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
    picked_at, picked_by, status
  )
  SELECT
    p_plan_date, o.machine_id, o.official_name, o.location_type, o.venue_group, o.building_id,
    o.dead_slot_pct, o.days_since_visit, o.empty_shelf_pct,
    o.active_intent_count, o.is_ramping, o.units_last_7d,
    o.expired_skus_now, o.expired_skus_3d, o.expired_skus_7d, o.expired_skus_30d,
    o.fill_pct, o.hero_slot_count, o.tier,
    o.empty_shelves_count, o.runway_days, o.severity,
    o.final_reasons, o.final_score, o.r_cluster, o.v_order,
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
         picked_at=EXCLUDED.picked_at, picked_by=EXCLUDED.picked_by, status='picked',
         confirmed_at=NULL, confirmed_by=NULL, updated_at=now();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RAISE NOTICE 'pick_machines_for_refill v6 % -> % rows picked', p_plan_date, v_rows;

  RETURN QUERY
  SELECT mv.machine_id, mv.official_name, mv.picked_reasons,
         mv.priority_score, mv.route_cluster, mv.visit_order
    FROM public.machines_to_visit mv
   WHERE mv.plan_date = p_plan_date AND mv.status = 'picked'
   ORDER BY mv.visit_order;
END;
$function$;
