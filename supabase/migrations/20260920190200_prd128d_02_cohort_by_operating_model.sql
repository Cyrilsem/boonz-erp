-- PRD-128d step 02: machine_cohort() tested service_model = 'partner_filled' before
-- operating_model = 'co_managed', so a co_managed machine that a partner venue fills
-- (VOXMCC-1012-0100-V0, VOXMCC-1017-0200-V0, VOXMM-1001-0100-V0) misfiled as 'partner' when
-- it is a VOX-owned location. Confirmed live before this fix:
-- machine_cohort('co_managed', 'partner_filled') = 'partner'.
--
-- Cohort is now decided by operating_model alone: partner_managed -> partner, co_managed ->
-- vox, fully_managed -> boonz, NULL -> unclassified. service_model no longer participates in
-- the cohort decision at all -- it now sets is_boonz_serviced only (see get_machine_health()
-- below), independent of which cohort a machine displays under. p_service_model stays in the
-- signature (unused) so every existing call site (get_machine_health, get_pod_refill_draft,
-- and check_machine_health_integrity, which calls both) keeps working unchanged -- no
-- overload, no signature break, per the function-naming-gotcha rule in CLAUDE.md.
--
-- Verified live before writing this migration: Active machines split
-- co_managed(11: 8 boonz_filled + 3 partner_filled) / fully_managed(24, all boonz_filled) /
-- partner_managed(3, all boonz_filled) / null(0) -- exactly boonz 24, vox 11, partner 3,
-- unclassified 0 under the new rule.

CREATE OR REPLACE FUNCTION public.machine_cohort(p_operating_model text, p_service_model text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_operating_model = 'partner_managed' THEN 'partner'
    WHEN p_operating_model = 'co_managed' THEN 'vox'
    WHEN p_operating_model = 'fully_managed' THEN 'boonz'
    ELSE 'unclassified'
  END;
$function$;

REVOKE ALL ON FUNCTION public.machine_cohort(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.machine_cohort(text, text) TO authenticated;

-- get_machine_health(): two changes on top of the cohort fix above.
-- (a) is_boonz_serviced now reads service_model directly (true only when 'boonz_filled'),
--     not machine_cohort(...) IN ('boonz','vox') -- the two questions are independent: cohort
--     answers "who owns this location," is_boonz_serviced answers "does Boonz staff need to
--     visit and refill it," and a partner_managed-but-boonz_filled machine can be true on the
--     second while displaying under 'partner' for the first.
-- (b) new p_include_inactive boolean DEFAULT false, filtering the row set to status='Active'
--     at source unless true. Every existing zero-arg call site (the frontend RPC,
--     check_machine_health_integrity()) keeps working unchanged via the default. Before this,
--     every unclassified machine had a NULL operating_model and every one of them was
--     Inactive -- filtering to Active at the DEFAULT makes the unclassified group disappear
--     without needing any separate unclassified-specific logic.

DROP FUNCTION public.get_machine_health();

CREATE FUNCTION public.get_machine_health(p_include_inactive boolean DEFAULT false)
 RETURNS TABLE(
   machine_name text, machine_id uuid, is_online boolean, total_stock integer, max_capacity integer,
   fill_pct numeric, total_slots integer, slots_at_zero integer, slots_below_25pct integer,
   daily_velocity numeric, days_until_empty numeric, has_sensor_errors boolean, machine_status text,
   include_in_refill boolean, recently_offline boolean, expired_units integer, expiring_7d_units integer,
   expiring_30d_units integer, days_to_earliest_expiry integer, machine_health_label text,
   machine_strategy text, machine_days_active integer, dead_stock_count integer, local_hero_count integer,
   health_tier text, health_sort integer, days_since_visit integer, pending_swap_count integer,
   is_picked_tomorrow boolean, picker_reasons text[], service_track text,
   priority_tier text, priority_score numeric,
   last_plan_date date, last_plan_days integer, urgency_breakdown jsonb, reasons_arr text[],
   pct_empty_lanes numeric, pct_quasi_lanes numeric, pct_ab_empty_or_quasi numeric, hero_runway_days numeric,
   s_gap numeric, p_score_aed numeric, car_no integer, top_contributors_aed jsonb,
   priority_tier_structural text, priority_score_structural numeric,
   unresolved_lane_count integer, machine_cohort text, cohort_sort integer,
   operating_model text, service_model text, is_boonz_serviced boolean, last_seen_at timestamptz,
   last_delivery_verdict text, lanes_not_landed integer
 )
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH mp_data AS MATERIALIZED (
    SELECT * FROM public.v_machine_priority
  ),
  hs_data AS MATERIALIZED (
    SELECT * FROM public.v_machine_health_signals
  ),
  dv_data AS MATERIALIZED (
    SELECT * FROM public.v_delivery_verification
  ),
  latest_device AS (
    SELECT DISTINCT ON (w.machine_id)
      w.machine_id, w.device_name, w.door_statuses, w.total_curr_stock, w.snapshot_at
    FROM weimi_device_status w
    WHERE w.machine_id IS NOT NULL
    ORDER BY w.machine_id, w.snapshot_at DESC
  ),
  device_metrics AS (
    SELECT
      m.machine_id,
      COALESCE(ld.device_name, m.official_name) as device_name,
      m.status as machine_status,
      m.venue_group as venue_grp,
      COALESCE(m.include_in_refill, true) as include_in_refill,
      m.operating_model,
      m.service_model,
      ld.snapshot_at,
      GREATEST(COALESCE(ld.total_curr_stock, 0), 0) as total_stock,
      (SELECT COALESCE(SUM(GREATEST((a->>'maxStock')::int,0)),0) FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a) as max_capacity,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a) as total_slots,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int <= 0) as slots_at_zero,
      (SELECT COUNT(*)::int FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int > 0 AND (a->>'currStock')::numeric / NULLIF((a->>'maxStock')::numeric,0) <= 0.25) as slots_below_25pct,
      (SELECT COUNT(*)::int > 0 FROM jsonb_array_elements(COALESCE(ld.door_statuses,'[]'::jsonb)) cab, jsonb_array_elements(cab->'layers') lyr, jsonb_array_elements(lyr->'aisles') a WHERE (a->>'currStock')::int < 0) as has_sensor_errors
    FROM machines m
    LEFT JOIN latest_device ld ON ld.machine_id = m.machine_id
    WHERE m.status = 'Active' OR p_include_inactive
  ),
  current_pod_ids AS (
    SELECT vls.machine_id,
      array_agg(DISTINCT vls.pod_product_id) FILTER (WHERE vls.pod_product_id IS NOT NULL) as ids
    FROM v_live_shelf_stock vls
    GROUP BY vls.machine_id
  ),
  unresolved_lanes AS (
    SELECT vls.machine_id, count(*)::int as unresolved_lane_count
    FROM v_live_shelf_stock vls
    WHERE vls.pod_product_id IS NULL
    GROUP BY vls.machine_id
  ),
  with_velocity AS (
    SELECT dm.*,
      COALESCE((SELECT vv.daily_velocity_7d FROM public.v_machine_velocity vv WHERE vv.machine_id = dm.machine_id), 0) as daily_velocity,
      COALESCE((SELECT SUM(sh.paid_amount) / NULLIF(GREATEST(EXTRACT(EPOCH FROM (NOW() - MIN(sh.transaction_date))) / 86400, 1), 0)
        FROM sales_history sh WHERE sh.machine_id = dm.machine_id AND sh.delivery_status IN ('Success','Successful') AND sh.transaction_date >= NOW() - interval '60 days'), 0) as daily_revenue,
      (SELECT EXTRACT(DAY FROM NOW() - vfs.first_sale_at)::int
       FROM v_machine_first_sale vfs
       WHERE vfs.machine_id = dm.machine_id) as days_active,
      (SELECT COUNT(*)::int FROM (
        SELECT sh_ds.pod_product_id as norm_product,
          COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM public.v_sales_history_resolved sh_ds
        WHERE sh_ds.machine_id = dm.machine_id
          AND sh_ds.delivery_status IN ('Success','Successful')
          AND sh_ds.pod_product_id = ANY (COALESCE((SELECT cpi.ids FROM current_pod_ids cpi WHERE cpi.machine_id = dm.machine_id), ARRAY[]::uuid[]))
        GROUP BY sh_ds.pod_product_id
        HAVING COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(sh_ds.qty) FILTER (WHERE sh_ds.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 = 0
      ) x) as dead_stock_count,
      (SELECT COUNT(*)::int FROM (
        SELECT sh_lh.pod_product_id as norm_product,
          COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '7 days'), 0) * 4
          + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 as bs
        FROM public.v_sales_history_resolved sh_lh
        WHERE sh_lh.machine_id = dm.machine_id
          AND sh_lh.delivery_status IN ('Success','Successful')
          AND sh_lh.pod_product_id = ANY (COALESCE((SELECT cpi.ids FROM current_pod_ids cpi WHERE cpi.machine_id = dm.machine_id), ARRAY[]::uuid[]))
        GROUP BY sh_lh.pod_product_id
        HAVING COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '7 days'), 0) * 4
             + COALESCE(SUM(sh_lh.qty) FILTER (WHERE sh_lh.transaction_date >= NOW() - interval '15 days'), 0) * 0.5 > 5
      ) x) as local_hero_count
    FROM device_metrics dm
  ),
  with_expiry AS (
    SELECT wv.*,
      COALESCE(ex.expired_units, 0) as expired_units,
      COALESCE(ex.expiring_7d_units, 0) as expiring_7d_units,
      COALESCE(ex.expiring_30d_units, 0) as expiring_30d_units,
      ex.days_to_earliest as days_to_earliest_expiry
    FROM with_velocity wv
    LEFT JOIN v_machine_expiry_summary ex ON ex.machine_id = wv.machine_id
  ),
  swap_data AS (
    SELECT ps.machine_name, COUNT(*)::int as swap_count
    FROM planned_swaps ps
    WHERE ps.status = 'pending'
    GROUP BY ps.machine_name
  ),
  picker_data AS (
    SELECT mtv.machine_id, mtv.picked_reasons, mtv.car_no
    FROM machines_to_visit mtv
    WHERE mtv.plan_date = public.resolve_refill_plan_date()
      AND mtv.status IN ('picked','cs_added')
  ),
  last_plan AS (
    SELECT rpo.machine_id, max(rpo.plan_date) as last_plan_date
    FROM refill_plan_output rpo
    WHERE rpo.operator_status = 'approved'
    GROUP BY rpo.machine_id
  ),
  last_delivery AS (
    SELECT dv.machine_id, max(dv.dispatch_date) as last_dispatch_date
    FROM dv_data dv
    GROUP BY dv.machine_id
  ),
  last_delivery_detail AS (
    SELECT ld2.machine_id,
      count(*) FILTER (WHERE dv.verdict = 'not_landed')::int as lanes_not_landed,
      (array_agg(dv.verdict ORDER BY
        CASE dv.verdict WHEN 'not_landed' THEN 0 WHEN 'partial' THEN 1 WHEN 'landed' THEN 2 ELSE 3 END
      ))[1] as last_delivery_verdict
    FROM last_delivery ld2
    JOIN dv_data dv ON dv.machine_id = ld2.machine_id AND dv.dispatch_date = ld2.last_dispatch_date
    GROUP BY ld2.machine_id
  )
  SELECT
    we.device_name, we.machine_id,
    (we.snapshot_at IS NOT NULL AND we.snapshot_at >= now() - interval '24 hours') as is_online,
    we.total_stock, we.max_capacity,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END,
    we.total_slots, we.slots_at_zero, we.slots_below_25pct,
    ROUND(we.daily_velocity, 1),
    CASE WHEN we.daily_velocity > 0 THEN ROUND(GREATEST(we.total_stock,0)::numeric / we.daily_velocity, 1) ELSE 999 END,
    we.has_sensor_errors,
    COALESCE(we.machine_status, 'Active'),
    we.include_in_refill,
    (we.snapshot_at IS NOT NULL AND we.snapshot_at < now() - interval '24 hours' AND we.snapshot_at >= now() - interval '7 days') as recently_offline,
    we.expired_units, we.expiring_7d_units, we.expiring_30d_units, we.days_to_earliest_expiry,
    CASE WHEN we.days_active IS NOT NULL AND we.days_active < 30 THEN '🟦 Ramp-Up Performer'
      ELSE compute_machine_health_label(ROUND(we.daily_revenue::numeric, 1)) END,
    CASE WHEN we.days_active IS NOT NULL AND we.days_active < 30 THEN 'Maintain Visual Standards'
      ELSE compute_machine_strategy(ROUND(we.daily_revenue::numeric, 1)) END,
    we.days_active,
    COALESCE(we.dead_stock_count, 0),
    COALESCE(we.local_hero_count, 0),
    CASE
      WHEN NOT we.include_in_refill THEN 'excluded'
      WHEN COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive') THEN 'excluded'
      WHEN we.expired_units > 0 THEN 'critical'
      WHEN we.slots_at_zero > 0 THEN 'critical'
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.30 THEN 'critical'
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 2 THEN 'critical'
      WHEN we.expiring_7d_units > 0 THEN 'warning'
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.60 THEN 'warning'
      WHEN we.slots_below_25pct >= 2 THEN 'warning'
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 5 THEN 'warning'
      ELSE 'healthy'
    END,
    CASE
      WHEN NOT we.include_in_refill THEN 5
      WHEN COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive') THEN 5
      WHEN we.expired_units > 0 THEN 1
      WHEN we.slots_at_zero > 0 THEN 1
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.30 THEN 1
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 2 THEN 1
      WHEN we.expiring_7d_units > 0 THEN 2
      WHEN we.max_capacity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.max_capacity) < 0.60 THEN 2
      WHEN we.slots_below_25pct >= 2 THEN 2
      WHEN we.daily_velocity > 0 AND (GREATEST(we.total_stock,0)::numeric / we.daily_velocity) < 5 THEN 2
      ELSE 3
    END,
    COALESCE(hs.days_since_visit, -1)::int,
    COALESCE(sd.swap_count, 0),
    pd.machine_id IS NOT NULL,
    pd.picked_reasons,
    COALESCE(mp.svc_track, 'main'),
    CASE
      WHEN NOT we.include_in_refill OR COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive')
        THEN 'excluded'
      WHEN mp.p_tier_aed = 'P1' THEN 'P1_RESTOCK'
      WHEN mp.p_tier_aed = 'P2' THEN 'P2_MAINTAIN'
      ELSE 'skip'
    END,
    COALESCE(mp.p_score_aed, 0),
    lpn.last_plan_date,
    COALESCE(hs.days_since_visit, -1)::int,
    CASE WHEN mp.machine_id IS NULL THEN '[]'::jsonb ELSE
      (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', t.l, 'aed', t.aed) ORDER BY t.aed DESC), '[]'::jsonb)
       FROM (VALUES
         ('runout', round(COALESCE(mp.s_runout_aed,0), 2)),
         ('gap',    round(0.5 * COALESCE(mp.s_gap_aed,0), 2)),
         ('expiry', round(COALESCE(mp.expiry_penalty_aed,0), 2)),
         ('stale',  round(COALESCE(mp.stale_penalty_aed,0), 2))
       ) t(l, aed)
       WHERE t.aed <> 0)
    END,
    mp.reasons_arr,
    mp.pct_empty_lanes,
    mp.pct_quasi_lanes,
    mp.pct_ab_empty_or_quasi,
    mp.hero_runway_days,
    mp.s_gap,
    COALESCE(mp.p_score_aed, 0),
    pd.car_no,
    CASE WHEN mp.machine_id IS NULL THEN '[]'::jsonb ELSE
      (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', t.l, 'aed', t.aed) ORDER BY t.aed DESC), '[]'::jsonb)
       FROM (
         SELECT * FROM (VALUES
           ('runout', round(COALESCE(mp.s_runout_aed,0), 2)),
           ('gap',    round(0.5 * COALESCE(mp.s_gap_aed,0), 2)),
           ('expiry', round(COALESCE(mp.expiry_penalty_aed,0), 2)),
           ('stale',  round(COALESCE(mp.stale_penalty_aed,0), 2))
         ) v(l, aed)
         WHERE v.aed <> 0
         ORDER BY v.aed DESC
         LIMIT 3
       ) t)
    END,
    CASE
      WHEN NOT we.include_in_refill OR COALESCE(we.machine_status,'Active') IN ('Warehouse','Inactive')
        THEN 'excluded'
      WHEN mp.p_tier = 'P3_OK' OR mp.p_tier IS NULL THEN 'skip'
      ELSE mp.p_tier
    END,
    COALESCE(mp.p_score, 0),
    COALESCE(unl.unresolved_lane_count, 0),
    machine_cohort(we.operating_model, we.service_model),
    CASE machine_cohort(we.operating_model, we.service_model)
      WHEN 'boonz' THEN 1 WHEN 'vox' THEN 2 WHEN 'partner' THEN 3 ELSE 4 END,
    we.operating_model, we.service_model,
    COALESCE(we.service_model = 'boonz_filled', false),
    we.snapshot_at,
    ldd.last_delivery_verdict,
    COALESCE(ldd.lanes_not_landed, 0)
  FROM with_expiry we
  LEFT JOIN swap_data sd ON sd.machine_name = we.device_name
  LEFT JOIN picker_data pd ON pd.machine_id = we.machine_id
  LEFT JOIN mp_data mp ON mp.machine_id = we.machine_id
  LEFT JOIN hs_data hs ON hs.machine_id = we.machine_id
  LEFT JOIN unresolved_lanes unl ON unl.machine_id = we.machine_id
  LEFT JOIN last_plan lpn ON lpn.machine_id = we.machine_id
  LEFT JOIN last_delivery_detail ldd ON ldd.machine_id = we.machine_id
  ORDER BY 26,
    CASE WHEN we.max_capacity > 0 THEN ROUND((GREATEST(we.total_stock,0)::numeric / we.max_capacity)*100, 1) ELSE 0 END ASC;
$function$;

REVOKE ALL ON FUNCTION public.get_machine_health(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_machine_health(boolean) TO authenticated;
