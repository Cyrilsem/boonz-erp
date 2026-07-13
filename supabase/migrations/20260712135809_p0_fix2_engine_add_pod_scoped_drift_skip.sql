CREATE OR REPLACE FUNCTION public.engine_add_pod(p_plan_date date DEFAULT (CURRENT_DATE + 1), p_days_cover integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_add_abs_floor boolean := (refill_qa.flag('add_abs_floor_v1')='on');
  v_abs_velocity_floor numeric := COALESCE((SELECT abs_velocity_floor FROM public.refill_policy_params LIMIT 1),0.5);
  v_min_facing_floor integer := COALESCE((SELECT min_facing_floor FROM public.refill_policy_params LIMIT 1),2);
  v_add_niche_fill boolean := (refill_qa.flag('add_niche_fill_v1')='on');
  v_niche_footprint_max integer := COALESCE((SELECT niche_footprint_max FROM public.refill_policy_params LIMIT 1),2);
  v_niche_facing_target numeric := COALESCE((SELECT niche_facing_target FROM public.refill_policy_params LIMIT 1),0.8);
  v_user_id          uuid;
  v_refills          integer := 0;
  v_dead_tags        integer := 0;
  v_skipped_intent   integer := 0;
  v_procurement_gaps jsonb   := '[]'::jsonb;
  v_t0               timestamptz := clock_timestamp();
  v_default_max      integer := 10;
  v_qty0_rows        integer := 0;
  v_binding_drift    integer := 0;
  v_binding_skipped  integer := 0;
  v_mode             text;
  v_minfill          numeric;
  v_sellwk           numeric;
  v_w7               numeric;
  v_w30              numeric;
  v_spf              numeric;
  v_zlo              numeric;
  v_zmid             numeric;
  v_zhi              numeric;
  v_mlo              numeric;
  v_mhi              numeric;
  v_cold_days        integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'engine_add_pod', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'engine_add_pod: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL OR p_days_cover IS NULL OR p_days_cover <= 0 THEN
    RAISE EXCEPTION 'engine_add_pod: p_plan_date required, p_days_cover > 0';
  END IF;

  -- PRD-CLEAN-09v2 (migration p0_fix2, 2026-07-12): drift no longer halts the plan.
  -- Drifted shelves are hard-skipped per-row via the existing binding_drift path
  -- (final_qty=0, clamp_reason='binding_drift') and alerted, scoped to tonight's machines.
  SELECT COUNT(*) INTO v_binding_drift
    FROM public.v_slot_binding_drift bd
    JOIN public.machines_to_visit mtv
      ON mtv.machine_id = bd.machine_id
     AND mtv.plan_date  = p_plan_date
     AND mtv.status IN ('picked','cs_added')
  ;
  IF v_binding_drift > 0 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('engine_add_pod_binding_drift','critical', jsonb_build_object(
      'title', format('engine_add_pod %s: %s drifted shelf(s) hard-skipped (clamp_reason=binding_drift)', p_plan_date, v_binding_drift),
      'plan_date', p_plan_date,
      'rows', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                 'machine_id', bd.machine_id, 'shelf_code', bd.shelf_code,
                 'lifecycle_product', bd.lifecycle_product,
                 'weimi_product', bd.weimi_product)), '[]'::jsonb)
               FROM public.v_slot_binding_drift bd
               JOIN public.machines_to_visit mtv2
                 ON mtv2.machine_id = bd.machine_id
                AND mtv2.plan_date  = p_plan_date
                AND mtv2.status IN ('picked','cs_added')),
      'detected_at', now()));
  END IF;

  SELECT rpp.refill_sizing_mode, rpp.min_fill_pct, rpp.seller_wk_threshold, rpp.ewma_w7, rpp.ewma_w30,
         rpp.spoilage_factor, rpp.z_low, rpp.z_mid, rpp.z_high, rpp.margin_low_cut, rpp.margin_high_cut,
         rpp.cold_start_days
    INTO v_mode, v_minfill, v_sellwk, v_w7, v_w30, v_spf, v_zlo, v_zmid, v_zhi, v_mlo, v_mhi, v_cold_days
  FROM public.refill_policy_params rpp WHERE rpp.id = 1;
  v_mode := COALESCE(v_mode, 'legacy');

  PERFORM public._assert_refill_plan_writable(p_plan_date);

  DELETE FROM public.pod_refills WHERE plan_date = p_plan_date;
  DELETE FROM public.pod_swaps
   WHERE plan_date = p_plan_date
     AND reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16','engine_add_pod_v17','engine_add_pod_v18','engine_add_pod_v19_base_stock');

  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_add_pod: no picked/cs_added machines for %; run Stage 1 first', p_plan_date;
  END IF;

  PERFORM public._assert_gate_zero(p_plan_date);

  WITH shelf_state AS (
    SELECT vls.machine_id, sc.shelf_id,
      MAX(vls.current_stock)::int AS current_stock,
      MAX(vls.max_stock)::int     AS live_max_stock
    FROM public.v_live_shelf_stock vls
    JOIN public.shelf_configurations sc
      ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
     AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    GROUP BY vls.machine_id, sc.shelf_id
  ),
  picked AS (
    SELECT mtv.machine_id, mtv.official_name FROM public.machines_to_visit mtv
     WHERE mtv.plan_date = p_plan_date AND mtv.status IN ('picked','cs_added')
       AND NOT EXISTS (
         SELECT 1 FROM public.refill_plan_output rpo
          WHERE rpo.plan_date = p_plan_date
            AND rpo.machine_name = mtv.official_name
            AND rpo.operator_status = 'approved')
  ),
  blocked_intents AS (
    SELECT DISTINCT si.scope_pod_product_id AS pod_product_id, si.intent_id, si.intent_type, si.scope_machine_ids
      FROM public.strategic_intents si
     WHERE si.intent_type IN ('decommission','rebalance')
       AND si.status IN ('queued','in_progress') AND si.scope_pod_product_id IS NOT NULL
  ),
  candidates AS (
    SELECT
      p.machine_id, p.official_name, sl.shelf_id, sc.shelf_code,
      COALESCE(NULLIF(ss.live_max_stock, 0), NULLIF(sc.max_capacity, 0),
               sms.max_stock_weimi, v_default_max)::int AS max_stock,
      sl.pod_product_id, pp.pod_product_name, sl.signal,
      COALESCE(sl.velocity_7d, 0)::numeric                    AS v7,
      COALESCE(sl.velocity_30d, 0)::numeric                   AS v30,
      COALESCE(ss.current_stock, 0)::integer                  AS current_stock,
      COALESCE((
        SELECT SUM(wi.warehouse_stock)
        FROM public.product_mapping pm
        JOIN public.warehouse_inventory wi
          ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active' AND wi.quarantined = false
         AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
         AND wi.warehouse_id = ANY (ARRAY[mwh.primary_warehouse_id, mwh.secondary_warehouse_id])
         AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = sl.machine_id)
        WHERE pm.pod_product_id = sl.pod_product_id AND pm.status = 'Active'
          AND (pm.machine_id IS NULL OR pm.machine_id = sl.machine_id)
      ), 0)::integer                                          AS wh_avail,
      COALESCE(dfd.requested_qty, 0)::int                     AS driver_req_qty,
      bi.intent_id   AS blocking_intent_id,
      bi.intent_type AS blocking_intent_type,
      (bd.shelf_id IS NOT NULL)                               AS binding_drift,
      CASE WHEN v_mode = 'base_stock'
           THEN COALESCE((SELECT msp.trip_interval_days FROM public.machine_service_policy msp
                          WHERE msp.machine_id = sl.machine_id), 21)
           ELSE NULL END                                      AS trip_days,
      CASE WHEN v_mode = 'base_stock' THEN COALESCE((
             SELECT CASE WHEN q.margin IS NULL THEN COALESCE((SELECT msp.z_default FROM public.machine_service_policy msp WHERE msp.machine_id = sl.machine_id), v_zmid)
                         WHEN q.margin <  v_mlo THEN v_zlo
                         WHEN q.margin >= v_mhi THEN v_zhi
                         ELSE v_zmid END
             FROM (
               SELECT (cp.effective_price_aed - lc.landed_cost)/NULLIF(cp.effective_price_aed,0) AS margin
               FROM public.product_mapping pm
               JOIN public.v_current_price cp
                 ON cp.boonz_product_id = pm.boonz_product_id AND cp.machine_id = sl.machine_id
               JOIN public.v_product_landed_cost lc ON lc.boonz_product_id = pm.boonz_product_id
               WHERE pm.pod_product_id = sl.pod_product_id AND pm.status = 'Active'
               LIMIT 1
             ) q
           ), v_zmid)
           ELSE NULL END                                      AS z_item,
      CASE WHEN v_mode = 'base_stock' THEN (
             SELECT NULLIF(MIN(psl.remaining_shelf_life_days), 0)::numeric
             FROM public.product_mapping pm
             JOIN public.v_product_shelf_life psl
               ON psl.boonz_product_id = pm.boonz_product_id
              AND psl.warehouse_id = ANY (ARRAY[mwh.primary_warehouse_id, mwh.secondary_warehouse_id])
             WHERE pm.pod_product_id = sl.pod_product_id AND pm.status = 'Active'
           )
           ELSE NULL END                                      AS shelf_life_days,
      CASE WHEN v_mode = 'base_stock'
           THEN (sl.signal = 'RAMPING' OR COALESCE(sl.slot_age_days, 9999) < v_cold_days)
           ELSE false END                                     AS is_cold_start
    FROM picked p
    JOIN public.machines mwh ON mwh.machine_id = p.machine_id
    JOIN public.slot_lifecycle sl ON sl.machine_id = p.machine_id AND sl.archived = false AND sl.is_current = true
    JOIN public.shelf_configurations sc ON sc.shelf_id = sl.shelf_id AND sc.is_phantom = false
    JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id
    LEFT JOIN public.v_shelf_max_stock sms ON sms.shelf_id = sl.shelf_id
    LEFT JOIN shelf_state ss ON ss.machine_id = sl.machine_id AND ss.shelf_id = sl.shelf_id
    LEFT JOIN public.v_driver_feedback_demand dfd ON dfd.machine_id = sl.machine_id AND dfd.pod_product_id = sl.pod_product_id
    LEFT JOIN blocked_intents bi ON bi.pod_product_id = sl.pod_product_id
     AND (bi.scope_machine_ids IS NULL OR sl.machine_id = ANY(bi.scope_machine_ids))
    LEFT JOIN public.v_slot_binding_drift bd
      ON bd.machine_id = sl.machine_id AND bd.shelf_id = sl.shelf_id
  ),
  candidates_with_machine_velocity AS (
    SELECT c.*, ROUND(SUM(c.v30) OVER (PARTITION BY c.machine_id) / 30.0, 2) AS machine_daily_velocity
    FROM candidates c
  ),
  decided AS (
    SELECT c.*,
      d.decision,
      (d.decision->>'stance')                                 AS u_stance,
      (d.decision->>'cover_mult')::numeric                    AS u_cover_mult,
      (d.decision->>'floor_pct')::numeric                     AS u_floor_pct,
      (d.decision->>'velocity')::numeric                      AS u_velocity,
      (d.decision->>'target_units')::int                      AS u_target_units,
      (d.decision->>'velocity_target')::numeric               AS u_velocity_target,
      (d.decision->>'refill_qty')::int                        AS u_refill_qty,
      (d.decision->>'runway_days')::numeric                   AS u_runway_days,
      (d.decision->>'final_score')::numeric                   AS u_final_score
    FROM candidates_with_machine_velocity c
    CROSS JOIN LATERAL (
      SELECT public.compute_refill_decision(c.machine_id, c.shelf_id, NULL::uuid, p_days_cover) AS decision
    ) d
  ),
  ranked AS (
    SELECT dc.*,
      ntile(3) OVER (PARTITION BY dc.machine_id
                     ORDER BY dc.u_final_score DESC NULLS LAST, dc.v30 DESC, dc.shelf_id) AS machine_band,
      ROUND(percent_rank() OVER (PARTITION BY dc.machine_id
                     ORDER BY dc.u_final_score ASC NULLS FIRST)::numeric, 3)              AS machine_rank_pct
    FROM decided dc
  ),
  bs AS (
    SELECT r.*,
      CASE WHEN v_mode = 'base_stock' THEN
        public.compute_base_stock_decision(
          r.v7 * 7.0, r.v30 * 30.0, r.current_stock, r.max_stock,
          r.trip_days, r.z_item, r.shelf_life_days, r.wh_avail,
          v_minfill, v_sellwk, v_w7, v_w30, v_spf, r.is_cold_start)
      ELSE NULL END AS bs_decision
    FROM ranked r
  ),
  covered AS (
    SELECT b.*,
      (CASE b.machine_band WHEN 1 THEN 1.00 WHEN 2 THEN 0.60 ELSE 0.30 END)::numeric AS band_fraction,
      CASE WHEN v_mode = 'base_stock' THEN
        GREATEST((b.bs_decision->>'want')::int, 0)
      ELSE
        CASE
          WHEN (b.v7 = 0 AND b.v30 = 0) THEN 0
          WHEN b.machine_band = 3 AND b.current_stock = 0 THEN 1
          ELSE GREATEST(ROUND(COALESCE(b.u_velocity,0) * p_days_cover
                 * (CASE WHEN v_add_abs_floor AND (b.v30/30.0 >= v_abs_velocity_floor OR b.v7 >= v_abs_velocity_floor) THEN 1.00 ELSE (CASE b.machine_band WHEN 1 THEN 1.00 WHEN 2 THEN 0.60 ELSE 0.30 END) END))::int, 1)
        END
      END AS cover_units
    FROM bs b
  ),
  flagged AS (
    SELECT cv.*,
      (CASE WHEN v_mode = 'base_stock' THEN (cv.bs_decision->>'is_dead')::boolean
            ELSE (cv.v7 = 0 AND cv.v30 = 0) END) AS is_dead,
      false                      AS is_drain,
      GREATEST(cv.max_stock - cv.current_stock, 0)                           AS fill_to_cap,
      LEAST(GREATEST(cv.cover_units, COALESCE(cv.driver_req_qty,0), CASE WHEN v_add_abs_floor AND NOT(cv.v7=0 AND cv.v30=0) THEN v_min_facing_floor ELSE 0 END, CASE WHEN v_add_niche_fill AND (SELECT count(DISTINCT sl.machine_id) FROM slot_lifecycle sl JOIN machines mm ON mm.machine_id=sl.machine_id AND mm.status='Active' WHERE sl.pod_product_id = cv.pod_product_id AND sl.is_current AND NOT sl.archived) <= v_niche_footprint_max AND cv.v30 >= (SELECT MAX(cv2.v30) FROM covered cv2 WHERE cv2.pod_product_id = cv.pod_product_id) THEN (CASE WHEN v_niche_facing_target <= 1 THEN CEIL(v_niche_facing_target * cv.max_stock)::int ELSE v_niche_facing_target::int END) ELSE 0 END),
            GREATEST(cv.max_stock - cv.current_stock, 0))                    AS need_raw
    FROM covered cv
  ),
  allocated AS (
    SELECT f.*,
      COALESCE(SUM(CASE WHEN f.is_dead OR f.is_drain OR f.blocking_intent_id IS NOT NULL OR f.binding_drift
                        THEN 0 ELSE f.need_raw END)
        OVER (PARTITION BY f.pod_product_id
              ORDER BY f.v30 DESC, f.u_final_score DESC NULLS LAST, f.shelf_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)          AS prior_need
    FROM flagged f
  ),
  final AS (
    SELECT a.*,
      CASE
        WHEN a.binding_drift                  THEN 0
        WHEN a.blocking_intent_id IS NOT NULL THEN 0
        WHEN a.is_dead                        THEN 0
        WHEN a.is_drain                       THEN 0
        ELSE LEAST(a.need_raw, GREATEST(a.wh_avail - a.prior_need, 0))
      END::int AS final_qty,
      CASE
        WHEN a.binding_drift                                               THEN 'binding_drift'
        WHEN a.blocking_intent_id IS NOT NULL                              THEN 'skipped_strategic_intent'
        WHEN a.is_dead                                                     THEN 'dead_tagged_for_swap'
        WHEN a.is_drain                                                    THEN 'drain_no_refill'
        WHEN a.need_raw = 0                                                THEN 'skipped_full'
        WHEN GREATEST(a.wh_avail - a.prior_need, 0) = 0                    THEN 'blocked_no_wh'
        WHEN LEAST(a.need_raw, GREATEST(a.wh_avail - a.prior_need,0)) < a.need_raw THEN 'partial_wh_limited'
        WHEN COALESCE(a.driver_req_qty,0) > a.cover_units
             AND COALESCE(a.driver_req_qty,0) <= a.fill_to_cap            THEN 'driver_request'
        WHEN a.cover_units < a.fill_to_cap                                THEN 'cover_capped'
        ELSE 'fill_to_cap'
      END AS clamp_reason
    FROM allocated a
  ),
  inserted AS (
    INSERT INTO public.pod_refills(
      plan_date, machine_id, shelf_id, pod_product_id,
      qty, current_stock, max_stock, velocity_30d, days_cover, signal,
      wh_available_pod, clamp_reason, reasoning)
    SELECT p_plan_date, f.machine_id, f.shelf_id, f.pod_product_id,
      f.final_qty, f.current_stock, f.max_stock, f.v30, p_days_cover, f.signal,
      f.wh_avail, f.clamp_reason,
      jsonb_build_object(
        'shelf_code',       f.shelf_code,
        'official_name',    f.official_name,
        'need_raw',         f.need_raw,
        'fill_to_cap',      f.fill_to_cap,
        'cover_units',      f.cover_units,
        'velocity_target',  f.u_velocity_target,
        'driver_req_qty',   f.driver_req_qty,
        'prior_need_pool',  f.prior_need,
        'target_stock',     f.max_stock,
        'velocity_target_units', f.u_target_units,
        'runway_days',      f.u_runway_days,
        'stance',           f.u_stance,
        'velocity_blend',   f.u_velocity,
        'final_score',      f.u_final_score,
        'machine_band',     f.machine_band,
        'band_fraction',    f.band_fraction,
        'machine_rank_pct', f.machine_rank_pct,
        'machine_daily_velocity', f.machine_daily_velocity,
        'wh_avail',         f.wh_avail,
        'wh_warning',       CASE WHEN f.wh_avail < f.need_raw THEN true ELSE false END,
        'max_stock_source', 'weimi_live_v5',
        'engine_calibration', CASE WHEN v_mode='base_stock' THEN 'v19_base_stock' ELSE 'refillv2_v18_relative_score_band' END,
        'decision',         f.decision
      ) || (CASE WHEN v_mode='base_stock'
                 THEN jsonb_build_object('base_stock', f.bs_decision, 'sizing_mode', 'base_stock')
                 ELSE '{}'::jsonb END)
    FROM final f
    WHERE (NOT f.is_dead AND f.need_raw > 0) OR f.binding_drift
    RETURNING qty, clamp_reason
  ),
  dead_tags AS (
    INSERT INTO public.pod_swaps(
      plan_date, machine_id, shelf_id, pod_product_id_out, qty_out, reason, reasoning)
    SELECT p_plan_date, f.machine_id, f.shelf_id, f.pod_product_id,
      GREATEST(f.current_stock, 1),
      CASE WHEN f.u_stance = 'ROTATE OUT' THEN 'rotate_out' ELSE 'dead' END,
      jsonb_build_object(
        'shelf_code',    f.shelf_code,
        'official_name', f.official_name,
        'stance',        f.u_stance,
        'velocity_30d',  f.v30,
        'current_stock', f.current_stock,
        'reason_detail', 'no_sales_7d_30d',
        'tagged_by',     CASE WHEN v_mode='base_stock' THEN 'engine_add_pod_v19_base_stock' ELSE 'engine_add_pod_v18' END
      )
    FROM final f
    WHERE f.is_dead AND NOT f.binding_drift
    RETURNING 1
  ),
  gap_rows AS (
    SELECT f.official_name, f.shelf_code, f.pod_product_name, f.signal,
      f.v30::numeric(6,2) AS v30, f.current_stock, f.max_stock,
      f.max_stock AS target_stock, (f.need_raw - f.final_qty) AS gap_units,
      f.u_runway_days AS runway_days
    FROM final f
    WHERE NOT f.is_dead AND NOT f.is_drain AND f.blocking_intent_id IS NULL
      AND NOT f.binding_drift
      AND f.need_raw > f.final_qty
  )
  SELECT (SELECT COUNT(*) FROM inserted),
         (SELECT COUNT(*) FROM inserted WHERE qty = 0),
         (SELECT COUNT(*) FROM dead_tags),
         (SELECT COUNT(*) FROM inserted WHERE clamp_reason = 'binding_drift'),
    COALESCE(jsonb_agg(jsonb_build_object(
      'machine', gap_rows.official_name, 'shelf', gap_rows.shelf_code,
      'product', gap_rows.pod_product_name, 'signal', gap_rows.signal,
      'velocity_30d', gap_rows.v30, 'current_stock', gap_rows.current_stock,
      'max_stock', gap_rows.max_stock, 'target_signal', gap_rows.target_stock,
      'gap_units', gap_rows.gap_units, 'runway_days', gap_rows.runway_days
    ) ORDER BY gap_rows.gap_units DESC) FILTER (WHERE gap_rows.gap_units > 0), '[]'::jsonb)
  INTO v_refills, v_qty0_rows, v_dead_tags, v_binding_skipped, v_procurement_gaps FROM gap_rows;

  UPDATE public.driver_feedback df
     SET resolved = true, resolved_at = now(),
         resolved_by_engine = CASE WHEN v_mode='base_stock' THEN 'engine_add_pod_v19_base_stock' ELSE 'engine_add_pod_v18' END
   WHERE df.resolved = false
     AND df.feedback_id IN (
       SELECT unnest(dfd.feedback_ids)
       FROM public.v_driver_feedback_demand dfd
       JOIN public.pod_refills pr
         ON pr.machine_id = dfd.machine_id AND pr.pod_product_id = dfd.pod_product_id
        AND pr.plan_date = p_plan_date AND pr.qty > 0
     );

  SELECT COUNT(*) INTO v_skipped_intent
  FROM public.slot_lifecycle sl
  JOIN public.machines_to_visit mtv
    ON mtv.machine_id = sl.machine_id AND mtv.plan_date = p_plan_date AND mtv.status IN ('picked','cs_added')
  JOIN public.strategic_intents si
    ON si.scope_pod_product_id = sl.pod_product_id AND si.intent_type IN ('decommission','rebalance')
   AND si.status IN ('queued','in_progress')
   AND (si.scope_machine_ids IS NULL OR sl.machine_id = ANY(si.scope_machine_ids))
  WHERE sl.archived=false AND sl.is_current=true;

  RETURN jsonb_build_object(
    'plan_date', p_plan_date, 'days_cover', p_days_cover, 'refills_inserted', v_refills,
    'qty0_rows_written', v_qty0_rows,
    'dead_tags_written', v_dead_tags,
    'binding_drift_skipped', v_binding_skipped,
    'skipped_strategic_intent', v_skipped_intent,
    'procurement_gaps_count', jsonb_array_length(v_procurement_gaps),
    'procurement_gaps', v_procurement_gaps,
    'engine_version', CASE WHEN v_mode='base_stock' THEN 'v19_base_stock' ELSE 'v18_relative_score_band_f1_per_machine' END,
    'sizing_mode', v_mode,
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$
