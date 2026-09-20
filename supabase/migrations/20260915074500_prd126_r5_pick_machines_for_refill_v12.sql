-- ONE-LOOP-3 Job 2 / PRD-126 R5: pick_machines_for_refill v12.
--
-- Replaces p_max_total/p_max_siblings with p_cars/p_per_car (defaults 2, 8).
-- Ranking basis switches from the old points-based p_tier/p_score to the new
-- AED-denominated p_tier_aed/p_score_aed (PRD-126 R1-R4, already live on
-- v_machine_priority as of a prior turn -- this migration only changes the
-- PICKER, not the score/tier formula itself).
--
-- Algorithm (R5): rank all P1/P2-eligible machines by p_score_aed. For each
-- car in turn: seed with the highest-scoring unpicked P1 whose cluster
-- (r_cluster: venue_group, then building_id) has not already been claimed as
-- another car's seed cluster this run (this is what makes distinct cars land
-- on distinct clusters "without being told" -- A5); fill the rest of that
-- car's capacity from the SAME cluster (P1s before P2s, then by score) before
-- any car crosses to another cluster. Only once every car has had a chance to
-- claim its own cluster does a final cross-cluster pass top up any car still
-- short of p_per_car. This ordering is why the algorithm runs in three
-- explicit passes over a temp table rather than one declarative query: "seed
-- every car first" is what stops car 1 hoovering up car 2's cluster while
-- car 2 sits unseeded.
--
-- Only 3 real callers exist (checked via pg_get_functiondef scan of every
-- function mentioning this name): auto_generate_draft, build_draft_for_confirmed,
-- _build_draft_core_v3. All three call it as pick_machines_for_refill(p_plan_date)
-- with defaults for everything else, so this signature change is source-compatible
-- with every live caller.
--
-- car_no here is a PROPOSAL stamped at pick time, so the "picked" list already
-- shows sensible car groupings before CS reviews it (A5 is checkable straight
-- off machines_to_visit). confirm_and_build's own car_no round-robin (built in
-- an earlier turn, prd12x j1 item 1) re-stamps car_no when CS confirms the
-- final machine list -- that is the authoritative assignment for dispatch,
-- since it runs after CS's edits are locked in. Two writers on the same
-- column at two different pipeline stages is intentional here, not a race:
-- pick proposes, confirm_and_build finalizes, and nothing reads car_no for a
-- dispatch action in between.

DROP FUNCTION IF EXISTS public.pick_machines_for_refill(date, integer, integer);

CREATE FUNCTION public.pick_machines_for_refill(
  p_plan_date date DEFAULT resolve_refill_plan_date(),
  p_cars integer DEFAULT 2,
  p_per_car integer DEFAULT 8
)
RETURNS TABLE(out_machine_id uuid, out_official_name text, out_picked_reasons text[], out_priority_score numeric, out_route_cluster text, out_visit_order integer, out_car_no integer)
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
  v_car            int;
  v_used_clusters  text[] := ARRAY[]::text[];
  v_seed_id        uuid;
  v_seed_cluster   text;
  v_next_id        uuid;
  v_filled         int;
  v_order          int := 0;
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
  IF p_plan_date > CURRENT_DATE + 30 THEN
    RAISE EXCEPTION 'pick_machines_for_refill: p_plan_date % is more than 30 days ahead -- refusing (exploratory/test calls must not write real picked rows this far out)', p_plan_date;
  END IF;
  IF p_cars IS NULL OR p_cars < 1 OR p_per_car IS NULL OR p_per_car < 1 THEN
    RAISE EXCEPTION 'invalid caps: p_cars >= 1, p_per_car >= 1';
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
     WHERE mp.svc_track = 'vox'
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

  -- PRD-122 (D-011, ONE-LOOP-2 Block A0): this VOX-day branch is DEAD CODE.
  -- The 3 partner_filled machines have zero rows in v_machine_priority, so
  -- svc_track='vox' matches nothing, bool_and() over the empty set is NULL,
  -- COALESCE(...,true) makes v_vox_all_equip true, and this IF never fires.
  -- MCC clustering still works via the normal-day branch's own cluster fill
  -- on r_cluster='VOX'. Carried forward verbatim per D-011: documented, not
  -- removed (that's a separate, later PRD) -- and since v12's CREATE is
  -- written fresh anyway, this is now an inline comment instead of the
  -- COMMENT ON FUNCTION metadata D-011 used on v11.
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
      WHERE sc.svc_track = 'vox'
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
      WHERE sc.svc_track IS DISTINCT FROM 'vox'
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
      picked_reasons, priority_score, route_cluster, visit_order, car_no,
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
      o.final_reasons, o.final_score, o.r_cluster, o.v_order, NULL::integer,
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
           car_no=EXCLUDED.car_no,
           service_track=EXCLUDED.service_track, priority_tier=EXCLUDED.priority_tier,
           picked_at=EXCLUDED.picked_at, picked_by=EXCLUDED.picked_by, status='picked',
           confirmed_at=NULL, confirmed_by=NULL, updated_at=now();

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'pick_machines_for_refill v12 (VOX-day; all_equip=%) % -> % rows', v_vox_all_equip, p_plan_date, v_rows;

  ELSE
    DROP TABLE IF EXISTS pg_temp._pmfr_candidates;
    CREATE TEMP TABLE _pmfr_candidates AS
    SELECT mp.machine_id, mp.official_name, mp.location_type, mp.venue_group, mp.building_id,
           mp.dead_slot_pct, mp.days_since_visit, mp.empty_shelf_pct,
           mp.active_intent_count, mp.is_ramping, mp.units_last_7d,
           mp.expired_skus_now, mp.expired_skus_3d, mp.expired_skus_7d, mp.expired_skus_30d,
           mp.fill_pct, mp.hero_slot_count, mp.tier,
           mp.empty_shelves_count, mp.runway_days,
           mp.reasons_arr, mp.p_score_aed, mp.p_tier_aed,
           COALESCE(mp.venue_group, mp.building_id, mp.official_name) AS r_cluster,
           mp.svc_track,
           false AS picked, NULL::int AS assigned_car, NULL::int AS out_order, NULL::text AS fill_reason
      FROM public.v_machine_priority mp
     WHERE mp.include_in_refill = true
       AND mp.machine_status NOT IN ('Warehouse', 'Inactive')
       AND mp.p_tier_aed IN ('P1','P2')
       AND ( v_is_vox_day
             OR mp.svc_track IS DISTINCT FROM 'vox'
             OR ( mp.svc_track = 'vox' AND COALESCE(mp.hero_runway_days, 999) < public.days_until_next_vox_day(p_plan_date) ) );

    -- Phase 1: seed each car with the highest-scoring unpicked P1 whose
    -- cluster has not already been claimed by an earlier car this run. This
    -- is what stops two P1s in the same cluster (e.g. two AMAZON machines)
    -- from becoming two different cars' seeds -- see the migration header.
    FOR v_car IN 1..p_cars LOOP
      SELECT machine_id, r_cluster INTO v_seed_id, v_seed_cluster
        FROM _pmfr_candidates
       WHERE NOT picked AND p_tier_aed = 'P1' AND NOT (r_cluster = ANY(v_used_clusters))
       ORDER BY p_score_aed DESC, units_last_7d DESC, official_name
       LIMIT 1;
      IF v_seed_id IS NULL THEN
        -- No fresh-cluster P1 left; fall back to the highest-scoring unpicked
        -- machine of any tier whose cluster is still fresh, then finally to
        -- the highest-scoring unpicked machine at all (fewer clusters than cars).
        SELECT machine_id, r_cluster INTO v_seed_id, v_seed_cluster
          FROM _pmfr_candidates
         WHERE NOT picked AND NOT (r_cluster = ANY(v_used_clusters))
         ORDER BY (p_tier_aed <> 'P1'), p_score_aed DESC, units_last_7d DESC, official_name
         LIMIT 1;
      END IF;
      IF v_seed_id IS NULL THEN
        SELECT machine_id, r_cluster INTO v_seed_id, v_seed_cluster
          FROM _pmfr_candidates
         WHERE NOT picked
         ORDER BY (p_tier_aed <> 'P1'), p_score_aed DESC, units_last_7d DESC, official_name
         LIMIT 1;
      END IF;
      EXIT WHEN v_seed_id IS NULL;
      v_order := v_order + 1;
      UPDATE _pmfr_candidates
         SET picked = true, assigned_car = v_car, out_order = v_order, fill_reason = 'car_seed'
       WHERE machine_id = v_seed_id;
      v_used_clusters := v_used_clusters || v_seed_cluster;
    END LOOP;

    -- Phase 2: fill each car from its own seed's cluster (P1s before P2s,
    -- then by score) up to p_per_car, before any car is allowed to cross.
    FOR v_car IN 1..p_cars LOOP
      SELECT r_cluster INTO v_seed_cluster
        FROM _pmfr_candidates WHERE assigned_car = v_car AND fill_reason = 'car_seed';
      CONTINUE WHEN v_seed_cluster IS NULL;
      SELECT COUNT(*) INTO v_filled FROM _pmfr_candidates WHERE assigned_car = v_car;
      WHILE v_filled < p_per_car LOOP
        SELECT machine_id INTO v_next_id
          FROM _pmfr_candidates
         WHERE NOT picked AND r_cluster = v_seed_cluster
         ORDER BY (p_tier_aed <> 'P1'), p_score_aed DESC, units_last_7d DESC, official_name
         LIMIT 1;
        EXIT WHEN v_next_id IS NULL;
        v_order := v_order + 1;
        UPDATE _pmfr_candidates
           SET picked = true, assigned_car = v_car, out_order = v_order, fill_reason = 'cluster_fill'
         WHERE machine_id = v_next_id;
        v_filled := v_filled + 1;
      END LOOP;
    END LOOP;

    -- Phase 3: only now, top up any car still short of p_per_car from
    -- whatever is left fleet-wide, highest score first, in car order.
    FOR v_car IN 1..p_cars LOOP
      SELECT COUNT(*) INTO v_filled FROM _pmfr_candidates WHERE assigned_car = v_car;
      WHILE v_filled < p_per_car LOOP
        SELECT machine_id INTO v_next_id
          FROM _pmfr_candidates
         WHERE NOT picked
         ORDER BY (p_tier_aed <> 'P1'), p_score_aed DESC, units_last_7d DESC, official_name
         LIMIT 1;
        EXIT WHEN v_next_id IS NULL;
        v_order := v_order + 1;
        UPDATE _pmfr_candidates
           SET picked = true, assigned_car = v_car, out_order = v_order, fill_reason = 'cross_cluster_fill'
         WHERE machine_id = v_next_id;
        v_filled := v_filled + 1;
      END LOOP;
    END LOOP;

    INSERT INTO public.machines_to_visit (
      plan_date, machine_id, official_name, location_type, venue_group, building_id,
      dead_slot_pct, days_since_visit, empty_shelf_pct,
      active_intent_count, is_ramping, units_last_7d,
      expired_skus_now, expired_skus_3d, expired_skus_7d, expired_skus_30d,
      fill_pct, hero_slot_count, health_tier,
      empty_shelves_count, runway_days, severity,
      picked_reasons, priority_score, route_cluster, visit_order, car_no,
      service_track, priority_tier,
      picked_at, picked_by, status
    )
    SELECT p_plan_date, c.machine_id, c.official_name, c.location_type, c.venue_group, c.building_id,
      c.dead_slot_pct, c.days_since_visit, c.empty_shelf_pct,
      c.active_intent_count, c.is_ramping, c.units_last_7d,
      c.expired_skus_now, c.expired_skus_3d, c.expired_skus_7d, c.expired_skus_30d,
      c.fill_pct, c.hero_slot_count, c.tier,
      c.empty_shelves_count, c.runway_days,
      CASE WHEN c.p_tier_aed = 'P1' AND c.expired_skus_now > 0 THEN 'critical'
           WHEN c.p_tier_aed = 'P1' THEN 'urgent'
           WHEN c.p_tier_aed = 'P2' AND c.p_score_aed >= 100 THEN 'high'
           ELSE 'medium' END,
      CASE WHEN c.fill_reason = 'car_seed' THEN c.reasons_arr
           ELSE ARRAY_APPEND(c.reasons_arr, c.fill_reason) END,
      c.p_score_aed, c.r_cluster, c.out_order, c.assigned_car,
      c.svc_track,
      -- machines_to_visit_priority_tier_check only allows the legacy
      -- P1_RESTOCK/P2_MAINTAIN strings; p_tier_aed's own P1/P2 values map
      -- onto them 1:1, so translate rather than loosen the constraint.
      CASE WHEN c.p_tier_aed = 'P1' THEN 'P1_RESTOCK' ELSE 'P2_MAINTAIN' END,
      now(), v_user_id, 'picked'
    FROM _pmfr_candidates c
    WHERE c.picked
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
           car_no=EXCLUDED.car_no,
           service_track=EXCLUDED.service_track, priority_tier=EXCLUDED.priority_tier,
           picked_at=EXCLUDED.picked_at, picked_by=EXCLUDED.picked_by, status='picked',
           confirmed_at=NULL, confirmed_by=NULL, updated_at=now();

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RAISE NOTICE 'pick_machines_for_refill v12 (normal-day) % -> % rows (cars %, per_car %)',
      p_plan_date, v_rows, p_cars, p_per_car;

    DROP TABLE IF EXISTS pg_temp._pmfr_candidates;
  END IF;

  RETURN QUERY
  SELECT mv.machine_id, mv.official_name, mv.picked_reasons,
         mv.priority_score, mv.route_cluster, mv.visit_order, mv.car_no
    FROM public.machines_to_visit mv
   WHERE mv.plan_date = p_plan_date AND mv.status = 'picked'
   ORDER BY mv.visit_order;
END;
$function$;
