-- PRD-CLEAN-09: engine-side binding-drift fix.
-- 1) Pre-run assertion in BOTH engines: COUNT(*) FROM v_slot_binding_drift must be 0
--    or the plan halts (RAISE aborts the whole engine transaction).
-- 2) Defense-in-depth hard-skip: engine_add_pod emits qty-0 rows with
--    clamp_reason='binding_drift' for drifted shelves (never dead-tags them);
--    engine_swap_pod excludes drifted shelves from all 4 swap passes.
-- 3) Nightly check 05:30 Dubai (01:30 UTC): cron_slot_binding_drift_alert ->
--    monitoring_alerts (severity critical) when v_slot_binding_drift is non-empty.
-- v_slot_binding_drift already existed (slot_lifecycle vs v_live_shelf_stock via
-- regexp_replace(slot_name,'^([A-Z])(\d)$','\10\2') = shelf_code - never aisle_code).
-- Rollbacks: docs/prds/rollback/engine_add_pod_2026-07-12.sql +
--            docs/prds/rollback/engine_swap_pod_2026-07-12.sql
-- Cron rollback: SELECT cron.unschedule('slot_binding_drift_nightly');
--                DROP FUNCTION public.cron_slot_binding_drift_alert();

CREATE OR REPLACE FUNCTION public.cron_slot_binding_drift_alert()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_n    integer;
  v_rows jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'cron_slot_binding_drift_alert', true);

  SELECT COUNT(*),
         COALESCE(jsonb_agg(jsonb_build_object(
           'machine_id', machine_id, 'shelf_code', shelf_code,
           'lifecycle_product', lifecycle_product, 'weimi_product', weimi_product,
           'goods_name_raw', goods_name_raw, 'snapshot_at', snapshot_at)), '[]'::jsonb)
    INTO v_n, v_rows
  FROM public.v_slot_binding_drift;

  IF v_n > 0 THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('slot_binding_drift', 'critical', jsonb_build_object(
      'title', format('%s slot binding drift row(s): slot_lifecycle vs Weimi - nightly plan will HALT (PRD-CLEAN-09)', v_n),
      'rows', v_rows,
      'detected_by', 'cron_slot_binding_drift_alert',
      'detected_at', now()));
  END IF;

  RETURN jsonb_build_object('status', 'ok', 'drift_rows', v_n);
END;
$function$;

SELECT cron.schedule(
  'slot_binding_drift_nightly',
  '30 1 * * *',
  $$SELECT public.cron_slot_binding_drift_alert();$$
);

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

  -- PRD-CLEAN-09: pre-run assertion - any slot_lifecycle vs Weimi binding drift halts the plan
  SELECT COUNT(*) INTO v_binding_drift FROM public.v_slot_binding_drift;
  IF v_binding_drift > 0 THEN
    RAISE EXCEPTION 'engine_add_pod: % slot binding drift row(s) in v_slot_binding_drift - plan halted (PRD-CLEAN-09). Reconcile slot_lifecycle vs Weimi before building.', v_binding_drift;
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
$function$;

CREATE OR REPLACE FUNCTION public.engine_swap_pod(p_plan_date date DEFAULT (CURRENT_DATE + 1), p_max_swaps_per_machine integer DEFAULT 2, p_min_pearson numeric DEFAULT 0.30, p_days_cover integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id            uuid;
  v_t0                 timestamptz := clock_timestamp();
  v_tag_swaps          integer := 0;
  v_tag_m2w            integer := 0;
  v_dead_resolved      integer := 0;
  v_dead_m2w           integer := 0;
  v_driver_rec_swaps   integer := 0;
  v_dead_deferred      integer := 0;
  v_dead_fallback      integer := 0;
  v_machine_swap_n     integer := 0;
  v_shelf_cap          integer;
  r                    record;
  v_sub                record;
  v_score_swaps        integer := 0;
  v_incumbent_boonz    uuid;
  v_cand_boonz         uuid;
  v_fleet_cap          integer := 10;
  v_fleet_swaps        integer := 0;
  v_theta              numeric := 0.15;
  v_w_sister           numeric := 0.5;
  v_w_global           numeric := 0.3;
  v_w_pearson          numeric := 0.2;
  v_cap                integer;
  v_inc_vel            numeric;
  v_inc_margin         numeric;
  v_v_keep             numeric;
  v_sister_vel         numeric;
  v_global_vel         numeric;
  v_proj_vel           numeric;
  v_cand_margin        numeric;
  v_v_cand             numeric;
  v_best_v             numeric;
  v_best_pod           uuid;
  v_best_src           text;
  v_best_pearson       numeric;
  v_best_wh            numeric;
  v_loc_type           text;
  v_K                  integer := 3;
  v_top_n              integer := 10;
  v_cand_min_stock     numeric := 3;
  v_binding_drift      integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','engine_swap_pod',true);
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up WHERE up.id=v_user_id AND up.role='operator_admin'
  ) THEN RAISE EXCEPTION 'engine_swap_pod: caller % lacks operator_admin role', v_user_id; END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'engine_swap_pod: p_plan_date required'; END IF;
  IF p_days_cover IS NULL OR p_days_cover <= 0 THEN
    RAISE EXCEPTION 'engine_swap_pod: p_days_cover must be > 0';
  END IF;

  -- PRD-CLEAN-09: pre-run assertion - any slot_lifecycle vs Weimi binding drift halts the plan
  SELECT COUNT(*) INTO v_binding_drift FROM public.v_slot_binding_drift;
  IF v_binding_drift > 0 THEN
    RAISE EXCEPTION 'engine_swap_pod: % slot binding drift row(s) in v_slot_binding_drift - plan halted (PRD-CLEAN-09). Reconcile slot_lifecycle vs Weimi before building.', v_binding_drift;
  END IF;

  PERFORM public._assert_refill_plan_writable(p_plan_date);

  DELETE FROM public.pod_swaps
   WHERE plan_date = p_plan_date
     AND NOT (pod_product_id_in IS NULL AND reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16'));
  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date=p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_swap_pod: no picked/cs_added machines for %', p_plan_date;
  END IF;
  PERFORM public._assert_gate_zero(p_plan_date);
  CREATE TEMP TABLE _r5_removal_cooldown ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id, pp.pod_product_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
    JOIN public.pod_products pp ON pp.pod_product_name = rpo.pod_product_name
   WHERE rpo.action ILIKE 'Remove%' AND rpo.plan_date >= p_plan_date - interval '14 days';
  CREATE TEMP TABLE _r5_introduction_cooldown ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id, pp.pod_product_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
    JOIN public.pod_products pp ON pp.pod_product_name = rpo.pod_product_name
   WHERE rpo.action ILIKE 'Remove%' AND rpo.plan_date >= p_plan_date - interval '30 days';
  CREATE TEMP TABLE _fleet_velocity ON COMMIT DROP AS
  SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric(8,3) AS avg_v30
    FROM public.slot_lifecycle sl
   WHERE sl.archived=false AND sl.is_current=true GROUP BY sl.pod_product_id;
  CREATE TEMP TABLE _shelf_live_stock ON COMMIT DROP AS
  SELECT vls.machine_id, sc.shelf_id, MAX(vls.current_stock)::int AS current_stock
  FROM public.v_live_shelf_stock vls
  JOIN public.shelf_configurations sc
    ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
   AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
  GROUP BY vls.machine_id, sc.shelf_id;
  CREATE TEMP TABLE _planned_swap_shelves ON COMMIT DROP AS
  SELECT DISTINCT sl.machine_id, sl.shelf_id
    FROM public.planned_swaps ps
    JOIN public.pod_products pp ON pp.pod_product_name = ps.remove_pod_product_name
    JOIN public.slot_lifecycle sl
      ON sl.machine_id = ps.machine_id AND sl.pod_product_id = pp.pod_product_id
     AND sl.archived = false AND sl.is_current = true
   WHERE ps.status = 'pending';
  CREATE TEMP TABLE _machine_present_pods ON COMMIT DROP AS
  SELECT DISTINCT machine_id, pod_product_id FROM (
    SELECT sl.machine_id, sl.pod_product_id
      FROM public.slot_lifecycle sl
     WHERE sl.archived = false AND sl.is_current = true
    UNION
    SELECT vls.machine_id, vls.pod_product_id
      FROM public.v_live_shelf_stock vls
     WHERE vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
  ) present;
  CREATE TEMP TABLE _swaps_disabled_machines ON COMMIT DROP AS
  SELECT m.machine_id
    FROM public.machines m
   WHERE COALESCE(
           (SELECT rs.setting_value FROM public.refill_settings rs
             WHERE rs.setting_key = 'swaps_enabled:' || m.machine_id::text),
           (SELECT rs.setting_value FROM public.refill_settings rs
             WHERE rs.setting_key = 'swaps_enabled'),
           'true'::jsonb
         ) = 'false'::jsonb;
  CREATE TEMP TABLE _committed_machines ON COMMIT DROP AS
  SELECT DISTINCT m.machine_id
    FROM public.refill_plan_output rpo
    JOIN public.machines m ON m.official_name = rpo.machine_name
   WHERE rpo.plan_date = p_plan_date AND rpo.operator_status = 'approved';
  CREATE TEMP TABLE _binding_drift ON COMMIT DROP AS
  SELECT machine_id, shelf_id FROM public.v_slot_binding_drift;
  CREATE TEMP TABLE _suppressed_swap_subs ON COMMIT DROP AS
  SELECT machine_id, pod_product_id AS pod_in
    FROM public.refill_edit_signals
   WHERE signal_type = 'swap_rejected'
     AND pod_product_id IS NOT NULL
     AND created_at >= now() - interval '30 days'
   GROUP BY machine_id, pod_product_id
  HAVING COUNT(*) >= 3;
  WITH picked AS (SELECT mtv.machine_id FROM public.machines_to_visit mtv
    WHERE mtv.plan_date=p_plan_date AND mtv.status IN ('picked','cs_added')
      AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = mtv.machine_id)
      AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = mtv.machine_id)),
  tag_targets AS (
    SELECT smt.tag_id, smt.strategic_intent_id AS intent_id, smt.machine_id, smt.pod_product_id AS pod_out,
           smt.action_directive, smt.substitute_pod_product_id AS pod_in, smt.priority,
           sl.shelf_id AS sl_shelf,
           ROW_NUMBER() OVER (PARTITION BY smt.machine_id
             ORDER BY smt.priority ASC, smt.proposed_at ASC, smt.tag_id) AS rnk
    FROM public.strategic_machine_tags smt
    JOIN picked p ON p.machine_id = smt.machine_id
    JOIN public.strategic_intents si ON si.intent_id = smt.strategic_intent_id
                                     AND si.status IN ('queued','in_progress')
    LEFT JOIN public.slot_lifecycle sl ON sl.machine_id = smt.machine_id
     AND sl.pod_product_id = smt.pod_product_id AND sl.archived = false AND sl.is_current = true
    WHERE smt.status = 'approved' AND smt.action_directive IN ('swap_out_with_substitute','swap_out_m2w')
  ),
  tag_capped AS (SELECT * FROM tag_targets WHERE rnk <= p_max_swaps_per_machine),
  tag_resolved AS (
    SELECT tc.*,
           COALESCE(tc.sl_shelf,
             (SELECT ssi.shelf_id FROM public.v_shelf_slot_identity ssi
               WHERE ssi.machine_id = tc.machine_id AND ssi.pod_product_id = tc.pod_out
                 AND ssi.match_method <> 'unmatched'
               ORDER BY ssi.current_stock DESC NULLS LAST LIMIT 1)
           ) AS shelf_id_final
    FROM tag_capped tc
  )
  INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
    qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
  SELECT p_plan_date, tr.machine_id, tr.shelf_id_final, tr.pod_out,
    CASE WHEN tr.action_directive='swap_out_with_substitute' THEN tr.pod_in ELSE NULL END,
    COALESCE((SELECT GREATEST(SUM(vls.current_stock),1)::int FROM public.v_live_shelf_stock vls JOIN public.shelf_configurations sc ON sc.machine_id = vls.machine_id AND sc.is_phantom = false AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text WHERE vls.machine_id = tr.machine_id AND sc.shelf_id = tr.shelf_id_final AND vls.pod_product_id = tr.pod_out),1)::int,
    CASE WHEN tr.action_directive='swap_out_m2w' THEN NULL
         ELSE GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                                  WHERE sms.shelf_id = tr.shelf_id_final),8)/2,4)::int END,
    CASE WHEN tr.action_directive='swap_out_m2w' THEN 'm2w' ELSE 'intent_driven' END,
    'strategic_tag', NULL::numeric, tr.intent_id,
    jsonb_build_object('pass','1','source','strategic_machine_tag','tag_id', tr.tag_id,
                       'tag_directive', tr.action_directive, 'tag_priority', tr.priority,
                       'engine_version','v15_slot_profile')
  FROM tag_resolved tr WHERE tr.shelf_id_final IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM _binding_drift bd
                     WHERE bd.machine_id = tr.machine_id AND bd.shelf_id = tr.shelf_id_final)
  ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;
  UPDATE public.strategic_machine_tags smt
     SET status = 'consumed', consumed_at = now(), consumed_at_plan_date = p_plan_date,
         consumed_via_swap_id = ps.swap_id
    FROM public.pod_swaps ps
   WHERE ps.plan_date = p_plan_date AND (ps.reasoning->>'source') = 'strategic_machine_tag'
     AND (ps.reasoning->>'tag_id')::uuid = smt.tag_id AND smt.status = 'approved';
  SELECT COUNT(*) FILTER (WHERE ps.reason='intent_driven'),
         COUNT(*) FILTER (WHERE ps.reason='m2w')
  INTO v_tag_swaps, v_tag_m2w
  FROM public.pod_swaps ps
  WHERE ps.plan_date = p_plan_date AND (ps.reasoning->>'source')='strategic_machine_tag';

  FOR r IN
    SELECT ps.swap_id, ps.machine_id, ps.shelf_id, ps.pod_product_id_out, ps.reason, ps.reasoning
      FROM public.pod_swaps ps
      JOIN public.machines_to_visit mtv
        ON mtv.machine_id = ps.machine_id AND mtv.plan_date = ps.plan_date
       AND mtv.status IN ('picked','cs_added')
      LEFT JOIN _shelf_live_stock sls
        ON sls.machine_id = ps.machine_id AND sls.shelf_id = ps.shelf_id
     WHERE ps.plan_date = p_plan_date
       AND ps.pod_product_id_in IS NULL
       AND ps.reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16')
       AND ps.reason IN ('dead','rotate_out')
       AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = ps.machine_id)
       AND NOT EXISTS (SELECT 1 FROM _binding_drift bd
                        WHERE bd.machine_id = ps.machine_id AND bd.shelf_id = ps.shelf_id)
     ORDER BY ps.machine_id, COALESCE(sls.current_stock, 0) ASC, ps.swap_id
  LOOP
    SELECT COUNT(*) INTO v_machine_swap_n
      FROM public.pod_swaps psx
     WHERE psx.plan_date = p_plan_date
       AND psx.machine_id = r.machine_id
       AND ((psx.reasoning->>'source') = 'strategic_machine_tag'
            OR (psx.pod_product_id_in IS NOT NULL AND psx.reasoning ? 'resolved_by'));
    IF v_machine_swap_n >= p_max_swaps_per_machine THEN
      UPDATE public.pod_swaps
         SET reasoning = reasoning || jsonb_build_object(
               'resolved_by','engine_swap_pod_v13',
               'deferred_by_cap', true,
               'cap', p_max_swaps_per_machine)
       WHERE swap_id = r.swap_id;
      v_dead_deferred := v_dead_deferred + 1;
      CONTINUE;
    END IF;

    SELECT fs.pod_product_id, fs.pearson_score, fs.source, fs.wh_stock_units
      INTO v_sub
      FROM public.find_substitutes_for_shelf(
             p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id_out, 5, 50
           ) fs
      LEFT JOIN _machine_present_pods mpp
        ON mpp.machine_id = r.machine_id AND mpp.pod_product_id = fs.pod_product_id
      LEFT JOIN _suppressed_swap_subs sss
        ON sss.machine_id = r.machine_id AND sss.pod_in = fs.pod_product_id
      LEFT JOIN _r5_introduction_cooldown rc
        ON rc.machine_id = r.machine_id AND rc.pod_product_id = fs.pod_product_id
     WHERE mpp.pod_product_id IS NULL
       AND sss.pod_in IS NULL
       AND rc.pod_product_id IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM public.pod_swaps ps2
          WHERE ps2.plan_date = p_plan_date AND ps2.machine_id = r.machine_id
            AND ps2.pod_product_id_in = fs.pod_product_id)
     ORDER BY (COALESCE(fs.pearson_score, -1) >= p_min_pearson) DESC, fs.rank
     LIMIT 1;

    IF v_sub.pod_product_id IS NOT NULL THEN
      SELECT MAX(sms.max_stock_weimi)::int INTO v_shelf_cap
        FROM public.v_shelf_max_stock sms
       WHERE sms.shelf_id = r.shelf_id;
      UPDATE public.pod_swaps
         SET pod_product_id_in = v_sub.pod_product_id,
             qty_in            = LEAST(
                                   GREATEST(COALESCE(v_shelf_cap, 8), 1),
                                   COALESCE(v_sub.wh_stock_units,0)::int),
             substitute_source = CASE WHEN COALESCE(v_sub.pearson_score, -1) >= p_min_pearson
                                      THEN v_sub.source
                                      ELSE 'global_performer_fallback' END,
             substitute_score  = v_sub.pearson_score,
             reasoning         = reasoning || jsonb_build_object(
                                   'resolved_by','engine_swap_pod_v13',
                                   'swap_in_source', v_sub.source,
                                   'min_pearson', p_min_pearson,
                                   'below_pearson_threshold',
                                     (COALESCE(v_sub.pearson_score, -1) < p_min_pearson),
                                   'return_to_warehouse', true)
                                 || CASE WHEN v_shelf_cap IS NULL
                                        THEN jsonb_build_object('clamp_reason','default_capacity_8')
                                        ELSE '{}'::jsonb END
       WHERE swap_id = r.swap_id;
      IF COALESCE(v_sub.pearson_score, -1) < p_min_pearson THEN
        v_dead_fallback := v_dead_fallback + 1;
      END IF;
      v_dead_resolved := v_dead_resolved + 1;
    ELSE
      UPDATE public.pod_swaps
         SET reasoning = reasoning || jsonb_build_object(
                           'resolved_by','engine_swap_pod_v13',
                           'resolved_as','m2w',
                           'return_to_warehouse', true)
       WHERE swap_id = r.swap_id;
      v_dead_m2w := v_dead_m2w + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT dr.rec_id, dr.machine_id, dr.shelf_id, dr.boonz_product_id,
           COALESCE(
             (SELECT pm.pod_product_id FROM public.product_mapping pm
               WHERE pm.boonz_product_id = dr.boonz_product_id
                 AND pm.machine_id = dr.machine_id AND pm.status = 'Active'
               ORDER BY pm.updated_at DESC LIMIT 1),
             (SELECT pm.pod_product_id FROM public.product_mapping pm
               WHERE pm.boonz_product_id = dr.boonz_product_id
                 AND pm.is_global_default = true AND pm.status = 'Active'
               ORDER BY pm.updated_at DESC LIMIT 1)
           ) AS pod_in,
           (SELECT sl.pod_product_id FROM public.slot_lifecycle sl
             WHERE sl.machine_id = dr.machine_id AND sl.shelf_id = dr.shelf_id
               AND sl.archived = false AND sl.is_current = true
             ORDER BY sl.pod_product_id LIMIT 1) AS pod_out
      FROM public.driver_recommendations dr
      JOIN public.machines_to_visit mtv
        ON mtv.machine_id = dr.machine_id AND mtv.plan_date = p_plan_date
       AND mtv.status IN ('picked','cs_added')
     WHERE dr.kind = 'wrong_product'
       AND dr.status = 'open'
       AND dr.shelf_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = dr.machine_id)
       AND NOT EXISTS (SELECT 1 FROM _binding_drift bd
                        WHERE bd.machine_id = dr.machine_id AND bd.shelf_id = dr.shelf_id)
       AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = dr.machine_id)
  LOOP
    CONTINUE WHEN r.pod_in IS NULL OR r.pod_out IS NULL OR r.pod_in = r.pod_out;

    INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
      qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
    VALUES (
      p_plan_date, r.machine_id, r.shelf_id, r.pod_out, r.pod_in,
      GREATEST(COALESCE((SELECT MAX(vls.current_stock)::int FROM public.v_live_shelf_stock vls
                          JOIN public.shelf_configurations sc
                            ON sc.machine_id = vls.machine_id AND sc.is_phantom = false
                           AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
                         WHERE vls.machine_id = r.machine_id AND sc.shelf_id = r.shelf_id
                           AND vls.pod_product_id = r.pod_out), 1), 1)::int,
      GREATEST(COALESCE((SELECT MAX(sms.max_stock_weimi)::int FROM public.v_shelf_max_stock sms
                          WHERE sms.shelf_id = r.shelf_id),8),1)::int,
      'rotate_out', 'driver_recommendation', NULL::numeric, NULL::uuid,
      jsonb_build_object('pass','2b','source','driver_recommendation',
                         'rec_id', r.rec_id, 'resolved_by','engine_swap_pod_v13',
                         'return_to_warehouse', true, 'engine_version','v15_slot_profile')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO UPDATE
      SET pod_product_id_in = EXCLUDED.pod_product_id_in,
          qty_in            = EXCLUDED.qty_in,
          reason            = 'rotate_out',
          substitute_source = 'driver_recommendation',
          reasoning         = public.pod_swaps.reasoning || EXCLUDED.reasoning;
    v_driver_rec_swaps := v_driver_rec_swaps + 1;
  END LOOP;

  SELECT COUNT(*) INTO v_fleet_swaps FROM public.pod_swaps
   WHERE plan_date = p_plan_date AND reasoning->>'source' = 'value_model_swap_broad' AND pod_product_id_in IS NOT NULL;

  CREATE TEMP TABLE _p3_intro ON COMMIT DROP AS
  SELECT pm.boonz_product_id AS boonz, COUNT(DISTINCT ps.machine_id)::int AS n
    FROM public.pod_swaps ps
    JOIN public.product_mapping pm ON pm.pod_product_id = ps.pod_product_id_in AND pm.status='Active'
   WHERE ps.plan_date = p_plan_date AND ps.reasoning->>'source' = 'value_model_swap_broad' AND ps.pod_product_id_in IS NOT NULL
   GROUP BY pm.boonz_product_id;
  CREATE UNIQUE INDEX ON _p3_intro (boonz);

  CREATE TEMP TABLE _p3_slots ON COMMIT DROP AS
  WITH picked AS (
    SELECT mtv.machine_id FROM public.machines_to_visit mtv
     WHERE mtv.plan_date = p_plan_date AND mtv.status IN ('picked','cs_added')
       AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = mtv.machine_id)
       AND NOT EXISTS (SELECT 1 FROM _committed_machines cm WHERE cm.machine_id = mtv.machine_id)
  ),
  incum AS (
    SELECT sl.machine_id, sl.shelf_id, sl.pod_product_id, pp.pod_product_name,
           (public.compute_refill_decision(sl.machine_id, sl.shelf_id, NULL::uuid, p_days_cover)->>'final_score')::numeric AS incumbent_final_score
      FROM public.slot_lifecycle sl
      JOIN picked p ON p.machine_id = sl.machine_id
      JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id
     WHERE sl.archived = false AND sl.is_current = true
  ),
  ranked AS (
    SELECT i.*,
           ntile(3) OVER (PARTITION BY i.machine_id ORDER BY i.incumbent_final_score DESC NULLS LAST) AS band,
           COUNT(*) OVER (PARTITION BY i.machine_id) AS shelf_n
      FROM incum i
  )
  SELECT machine_id, shelf_id, pod_product_id, pod_product_name, incumbent_final_score
    FROM ranked
   WHERE band = 3 AND shelf_n >= 3
     AND NOT EXISTS (SELECT 1 FROM _r5_removal_cooldown rc
                      WHERE rc.machine_id = ranked.machine_id AND rc.pod_product_id = ranked.pod_product_id)
     AND NOT EXISTS (SELECT 1 FROM _binding_drift bd
                      WHERE bd.machine_id = ranked.machine_id AND bd.shelf_id = ranked.shelf_id);

  CREATE TEMP TABLE _p3_slot_keep ON COMMIT DROP AS
  SELECT s.machine_id, s.shelf_id, s.pod_product_id, s.pod_product_name, s.incumbent_final_score,
         m.location_type AS loc_type,
         (SELECT pg.shelf_size FROM public.planogram pg
           WHERE pg.shelf_id = s.shelf_id AND pg.is_active = true
           ORDER BY pg.effective_from DESC NULLS LAST LIMIT 1) AS shelf_size,
         (SELECT sc.shelf_code FROM public.shelf_configurations sc WHERE sc.shelf_id = s.shelf_id LIMIT 1) AS shelf_code,
         (SELECT pm.boonz_product_id FROM public.product_mapping pm
           WHERE pm.pod_product_id = s.pod_product_id AND pm.status='Active' AND (pm.machine_id = s.machine_id OR pm.machine_id IS NULL)
           ORDER BY (pm.machine_id = s.machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1) AS inc_boonz,
         COALESCE((SELECT sl.velocity_30d FROM public.slot_lifecycle sl
                    WHERE sl.machine_id=s.machine_id AND sl.shelf_id=s.shelf_id AND sl.pod_product_id=s.pod_product_id
                      AND sl.archived=false AND sl.is_current=true LIMIT 1),0) AS inc_vel
    FROM _p3_slots s
    JOIN public.machines m ON m.machine_id = s.machine_id;
  ALTER TABLE _p3_slot_keep ADD COLUMN inc_phys text;
  UPDATE _p3_slot_keep k SET inc_phys = bp.physical_type
    FROM public.boonz_products bp WHERE bp.product_id = k.inc_boonz;
  ALTER TABLE _p3_slot_keep ADD COLUMN inc_cap int;
  UPDATE _p3_slot_keep k SET inc_cap = GREATEST(COALESCE(
      (SELECT scm.override_max_stock FROM public.slot_capacity_max scm
        WHERE scm.machine_id = k.machine_id AND scm.aisle_code = k.shelf_code LIMIT 1),
      FLOOR(public.product_slot_capacity_units(k.inc_phys, k.shelf_size) * 0.85)::int,
      (SELECT sc.max_capacity FROM public.shelf_configurations sc WHERE sc.shelf_id = k.shelf_id LIMIT 1),
      8), 1);
  ALTER TABLE _p3_slot_keep ADD COLUMN keep_v numeric;
  UPDATE _p3_slot_keep k SET keep_v = GREATEST(COALESCE(
      (SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.machine_id=k.machine_id AND pg.pod_product_id=k.pod_product_id AND pg.is_active=true),
      (SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.pod_product_id=k.pod_product_id AND pg.is_active=true), 0)
    - COALESCE((SELECT lc.landed_cost::numeric FROM public.v_product_landed_cost lc WHERE lc.boonz_product_id = k.inc_boonz),0), 0)
    * LEAST(GREATEST(k.inc_vel,0) * p_days_cover, k.inc_cap);

  CREATE TEMP TABLE _p3_sister ON COMMIT DROP AS
  SELECT m2.location_type AS loc_type, sh.pod_product_id AS pod, SUM(sh.qty)/30.0 AS vel
    FROM public.v_sales_history_resolved sh
    JOIN public.machines m2 ON m2.machine_id = sh.machine_id
   WHERE m2.location_type IN (SELECT DISTINCT loc_type FROM _p3_slot_keep)
     AND sh.transaction_date >= p_plan_date - 30
   GROUP BY 1,2;

  CREATE TEMP TABLE _p3_basket ON COMMIT DROP AS
  SELECT DISTINCT k.machine_id, sl.pod_product_id
    FROM (SELECT DISTINCT machine_id FROM _p3_slot_keep) k
    JOIN public.slot_lifecycle sl ON sl.machine_id = k.machine_id AND sl.archived=false AND sl.is_current=true
     AND (COALESCE(sl.velocity_7d,0)>0 OR COALESCE(sl.velocity_30d,0)>0);

  CREATE TEMP TABLE _p3_affinity ON COMMIT DROP AS
  WITH am AS (
    SELECT b.machine_id, cm.pod_product_b AS cand_pod, AVG(cm.pearson) AS score
      FROM _p3_basket b
      JOIN public.correlation_pod_per_machine cm ON cm.machine_id=b.machine_id AND cm.pod_product_a=b.pod_product_id
     GROUP BY 1,2),
  al AS (
    SELECT mk.machine_id, cl.pod_product_b AS cand_pod, AVG(cl.pearson) AS score
      FROM (SELECT DISTINCT machine_id, loc_type FROM _p3_slot_keep) mk
      JOIN _p3_basket b ON b.machine_id=mk.machine_id
      JOIN public.correlation_pod_per_loc_type cl ON cl.location_type=mk.loc_type AND cl.pod_product_a=b.pod_product_id
     GROUP BY 1,2)
  SELECT COALESCE(am.machine_id, al.machine_id) AS machine_id,
         COALESCE(am.cand_pod, al.cand_pod)     AS cand_pod,
         COALESCE(am.score, al.score, 0)        AS score
    FROM am FULL JOIN al ON al.machine_id=am.machine_id AND al.cand_pod=am.cand_pod;

  CREATE TEMP TABLE _p3_cand ON COMMIT DROP AS
  WITH wh AS (
    SELECT vp.boonz_product_id AS boonz, SUM(vp.warehouse_stock) AS wh_stock
      FROM public.v_wh_pickable vp GROUP BY 1 HAVING SUM(vp.warehouse_stock) > v_cand_min_stock
  ),
  base AS (
    SELECT w.boonz, w.wh_stock, pm.pod_product_id AS cand_pod, bp.physical_type AS cand_phys,
           GREATEST(COALESCE((SELECT AVG(pg.price_aed) FROM public.planogram pg WHERE pg.pod_product_id=pm.pod_product_id AND pg.is_active=true),0)
                    - COALESCE((SELECT lc.landed_cost::numeric FROM public.v_product_landed_cost lc WHERE lc.boonz_product_id=w.boonz),0), 0) AS cand_margin,
           COALESCE(fv.avg_v30,0) AS global_vel
      FROM wh w
      JOIN public.boonz_products bp ON bp.product_id = w.boonz
      JOIN LATERAL (SELECT pm.pod_product_id FROM public.product_mapping pm
                     WHERE pm.boonz_product_id = w.boonz AND pm.status='Active'
                     ORDER BY pm.is_global_default DESC, pm.updated_at DESC LIMIT 1) pm ON true
      JOIN public.pod_products pp ON pp.pod_product_id=pm.pod_product_id AND COALESCE(pp.is_catchall,false)=false
      LEFT JOIN _fleet_velocity fv ON fv.pod_product_id = pm.pod_product_id
  )
  SELECT mk.machine_id, mk.loc_type, b.boonz AS cand_boonz, b.cand_pod, b.cand_phys, b.wh_stock,
         b.cand_margin, b.global_vel,
         COALESCE(si.vel,0) AS sister_vel,
         GREATEST(COALESCE(af.score,0),0) AS affinity
    FROM (SELECT DISTINCT machine_id, loc_type FROM _p3_slot_keep) mk
    JOIN base b ON true
    LEFT JOIN _p3_sister si ON si.loc_type = mk.loc_type AND si.pod = b.cand_pod
    LEFT JOIN _p3_affinity af ON af.machine_id = mk.machine_id AND af.cand_pod = b.cand_pod
   WHERE NOT EXISTS (SELECT 1 FROM _machine_present_pods mpp WHERE mpp.machine_id=mk.machine_id AND mpp.pod_product_id=b.cand_pod)
     AND NOT EXISTS (SELECT 1 FROM _suppressed_swap_subs sss WHERE sss.machine_id=mk.machine_id AND sss.pod_in=b.cand_pod)
     AND NOT EXISTS (SELECT 1 FROM _r5_introduction_cooldown ic WHERE ic.machine_id=mk.machine_id AND ic.pod_product_id=b.cand_pod)
     AND EXISTS (SELECT 1 FROM public.v_wh_pickable vp2 WHERE vp2.boonz_product_id=b.boonz
                  AND (vp2.reserved_for_machine_id IS NULL OR vp2.reserved_for_machine_id=mk.machine_id))
     AND NOT public._coexistence_blocks(mk.machine_id, b.boonz)
     AND NOT public._travel_scope_blocks(mk.machine_id, b.boonz);

  CREATE TEMP TABLE _p3_pairs ON COMMIT DROP AS
  WITH capd AS (
    SELECT k.machine_id, k.shelf_id, k.pod_product_id AS inc_pod, k.shelf_size, k.keep_v,
           cc.cand_boonz, cc.cand_pod, cc.cand_phys, cc.wh_stock, cc.cand_margin, cc.global_vel, cc.sister_vel, cc.affinity,
           spp.fill_qty AS cand_cap
      FROM _p3_slot_keep k
      JOIN _p3_cand cc ON cc.machine_id = k.machine_id
      JOIN public.slot_profile_pool spp
        ON spp.boonz_product_id = cc.cand_boonz
       AND spp.shelf_size = k.shelf_size
       AND spp.lane_family = (SELECT lf.lane_family FROM public.physical_type_lane_family lf WHERE lf.physical_type = k.inc_phys)
  ),
  valued AS (
    SELECT c.*,
           c.cand_margin * LEAST(GREATEST(v_w_sister*c.sister_vel + v_w_global*c.global_vel + v_w_pearson*c.affinity*c.global_vel,0)*p_days_cover, c.cand_cap) AS v_cand
      FROM capd c
  ),
  topn AS (
    SELECT v.*, ROW_NUMBER() OVER (PARTITION BY v.machine_id, v.shelf_id ORDER BY v.v_cand DESC) AS rn
      FROM valued v
     WHERE v.v_cand > 0 AND v.v_cand >= v.keep_v * (1 + v_theta)
  )
  SELECT machine_id, shelf_id, inc_pod, cand_boonz, cand_pod, cand_cap, wh_stock, v_cand, keep_v, shelf_size
    FROM topn WHERE rn <= v_top_n;

  FOR r IN
    SELECT * FROM _p3_pairs ORDER BY machine_id, v_cand DESC, shelf_id
  LOOP
    CONTINUE WHEN v_fleet_swaps >= v_fleet_cap;
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.pod_swaps ps2
      WHERE ps2.plan_date=p_plan_date AND ps2.machine_id=r.machine_id AND ps2.shelf_id=r.shelf_id);
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.pod_swaps ps2
      WHERE ps2.plan_date=p_plan_date AND ps2.machine_id=r.machine_id AND ps2.pod_product_id_in=r.cand_pod);
    SELECT COUNT(*) INTO v_machine_swap_n FROM public.pod_swaps psx
     WHERE psx.plan_date=p_plan_date AND psx.machine_id=r.machine_id AND psx.pod_product_id_in IS NOT NULL;
    CONTINUE WHEN v_machine_swap_n >= p_max_swaps_per_machine;
    CONTINUE WHEN COALESCE((SELECT n FROM _p3_intro WHERE boonz = r.cand_boonz),0) >= v_K;

    INSERT INTO public.pod_swaps(plan_date, machine_id, shelf_id, pod_product_id_out, pod_product_id_in,
      qty_out, qty_in, reason, substitute_source, substitute_score, linked_intent_id, reasoning)
    VALUES (
      p_plan_date, r.machine_id, r.shelf_id, r.inc_pod, r.cand_pod,
      GREATEST(COALESCE((SELECT MAX(sls.current_stock) FROM _shelf_live_stock sls
                          WHERE sls.machine_id=r.machine_id AND sls.shelf_id=r.shelf_id),1),1)::int,
      LEAST(GREATEST(r.cand_cap,1), COALESCE(r.wh_stock,0)::int),
      'rotate_out', 'value_model_broad', NULL::numeric, NULL::uuid,
      jsonb_build_object(
        'pass','3','source','value_model_swap_broad','resolved_by','engine_swap_pod_v13',
        'v_keep', round(r.keep_v,2), 'v_candidate', round(r.v_cand,2),
        'theta', v_theta, 'days_cover', p_days_cover, 'cap', r.cand_cap,
        'shelf_size', r.shelf_size,
        'projection_basis','w_sister0.5_global0.3_pearson0.2',
        'universe','v_wh_pickable_broad', 'homogenisation_k', v_K,
        'displaced_pod_product_id', r.inc_pod, 'return_to_warehouse', true,
        'engine_version','v15_slot_profile')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO NOTHING;

    INSERT INTO _p3_intro(boonz, n) VALUES (r.cand_boonz, 1)
      ON CONFLICT (boonz) DO UPDATE SET n = _p3_intro.n + 1;
    v_score_swaps := v_score_swaps + 1;
    v_fleet_swaps := v_fleet_swaps + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'plan_date',p_plan_date, 'max_swaps_per_machine',p_max_swaps_per_machine,
    'min_pearson',p_min_pearson, 'days_cover',p_days_cover,
    'tag_swaps', v_tag_swaps, 'tag_m2w', v_tag_m2w,
    'dead_tags_resolved', v_dead_resolved, 'dead_tags_m2w', v_dead_m2w,
    'dead_tags_deferred_by_cap', v_dead_deferred,
    'dead_tags_below_pearson_fallback', v_dead_fallback,
    'driver_rec_swaps', v_driver_rec_swaps,
    'score_driven_swaps', v_score_swaps,
    'theta', v_theta, 'fleet_cap', v_fleet_cap, 'homogenisation_k', v_K,
    'total_swaps', v_tag_swaps + v_dead_resolved + v_driver_rec_swaps + v_score_swaps,
    'total_m2w', v_tag_m2w + v_dead_m2w,
    'engine_version','v15_slot_profile',
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int);
END;
$function$;