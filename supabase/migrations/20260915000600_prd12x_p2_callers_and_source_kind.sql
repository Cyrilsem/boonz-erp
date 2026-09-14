-- PRD-125 D3 / ONE-LOOP Phase 2 -- remaining callers + source_kind mapping.
--
-- 1) engine_add_pod: its wh_avail computation used to sum warehouse_inventory
--    across ONLY the machine's own primary_warehouse_id/secondary_warehouse_id
--    columns. Verified live this misses real stock: ACTIVATE-2005's
--    secondary_warehouse_id is WH_CENTRAL, not WH_MM, so a venue_team
--    product's WH_MM stock was invisible to this engine. Switched to
--    wh_available_for(machine_id, boonz_product_id), summed.
--
-- 2) find_substitutes_for_shelf: same class of gap in its `wh` CTE (scoped
--    to v_wh_pri/v_wh_sec only). Same fix.
--
-- 3) push_plan_to_dispatch: source_kind now mapped from source_origin at
--    insert time (warehouse->wh, vox_at_venue->venue, internal_transfer->m2m)
--    on both the ordinary Refill/Add-New/Remove paths (the M2M branch already
--    set 'm2m' explicitly). This is PRD-124 #38.
--
-- 4) refill_dispatching had two CHECK constraints that did not know about
--    'venue' as a source_kind value at all (refill_dispatching_source_kind_chk
--    was a plain enum list; refill_dispatching_source_consistency_chk's OR
--    branches had no venue case). Both extended to accept 'venue' with
--    source_warehouse_id/source_machine_id both NULL (venue stock is not
--    drawn from a warehouse row or a peer machine in this schema).
--
-- 5) Backfill: 09-14/09-15 rows that were 'unknown' purely because #38 never
--    ran get their real source_kind (329 -> wh, 69 -> venue; 12 rows with no
--    resolvable from_warehouse_id genuinely stay unknown -- not guessed).
--    Pure metadata: does not touch quantity/shelf_id/include, so the 09-15
--    canary fingerprint is unaffected (verified identical before/after:
--    9aba17f8fc6477fe50b4f2aadca47f62).
--
-- VERIFIED FALLOUT (PRD-124 G8d, "falls out of #38"): validate_refill_plan's
-- G8 check on 2026-09-15 dispatch went from 7 violations (Galaxy, Pepsi,
-- Aquafina, Maltesers, Ice Tea, VOX Lollies, Skittles all "need X, free 0")
-- to 0, purely because venue rows are now correctly excluded from the
-- CENTRAL-stock demand sum via is_venue (derived from source_kind). No
-- change to validate_refill_plan itself was needed for this -- that fix is
-- entirely upstream, in the data it reads.

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
      'title', format('engine_add_pod %s: %s drifted shelf(s) auto-planned from WEIMI identity (slot_lifecycle STALE — rebind)', p_plan_date, v_binding_drift),
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

  DELETE FROM public.pod_refills pr
   WHERE pr.plan_date = p_plan_date
     AND NOT public.is_cluster_authoritative_v3(pr.machine_id);
  DELETE FROM public.pod_swaps
   WHERE plan_date = p_plan_date
     AND reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16','engine_add_pod_v17','engine_add_pod_v18','engine_add_pod_v19_base_stock');

  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_add_pod: no picked/cs_added machines for %; run Stage 1 first', p_plan_date;
  END IF;

  PERFORM public._assert_gate_zero(p_plan_date);

  -- PRD-125 D3: availability now flows through wh_available_for, keyed by
  -- product source_of_supply (venue_team -> WH_MCC + WH_MM, else WH_CENTRAL)
  -- rather than each machine's own primary/secondary_warehouse_id columns
  -- (which, on this fleet's own data, e.g. ACTIVATE-2005, wires
  -- secondary_warehouse_id to WH_CENTRAL, not WH_MM -- so a venue-supplied
  -- product's WH_MM stock was invisible to this engine before this change).

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
       AND NOT public.is_cluster_authoritative_v3(mtv.machine_id)
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
  weimi_identity AS (
    SELECT DISTINCT ON (machine_id, shelf_id)
           machine_id, shelf_id, pod_product_id, match_method
      FROM public.v_shelf_slot_identity
     ORDER BY machine_id, shelf_id, snapshot_at DESC
  ),
  candidates AS (
    SELECT
      p.machine_id, p.official_name, sl.shelf_id, sc.shelf_code,
      COALESCE(NULLIF(ss.live_max_stock, 0), NULLIF(sc.max_capacity, 0),
               sms.max_stock_weimi, v_default_max)::int AS max_stock,
      wid.identity_pod AS pod_product_id, pp.pod_product_name, sl.signal,
      sl.pod_product_id AS lifecycle_pod_product_id,
      wid.identity_source,
      CASE WHEN wid.identity_source = 'weimi_override' THEN 0
           ELSE COALESCE(sl.velocity_7d, 0) END::numeric      AS v7,
      CASE WHEN wid.identity_source = 'weimi_override' THEN 0
           ELSE COALESCE(sl.velocity_30d, 0) END::numeric     AS v30,
      COALESCE(ss.current_stock, 0)::integer                  AS current_stock,
      COALESCE((SELECT SUM(waf.free_stock)
                  FROM public.wh_available_for(sl.machine_id, (
                    SELECT pm2.boonz_product_id FROM public.product_mapping pm2
                     WHERE pm2.pod_product_id = wid.identity_pod AND pm2.status = 'Active'
                       AND (pm2.machine_id IS NULL OR pm2.machine_id = sl.machine_id)
                     ORDER BY (pm2.machine_id = sl.machine_id) DESC NULLS LAST, pm2.is_global_default DESC
                     LIMIT 1
                  )) waf), 0)::int AS wh_avail,
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
               WHERE pm.pod_product_id = wid.identity_pod AND pm.status = 'Active'
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
             WHERE pm.pod_product_id = wid.identity_pod AND pm.status = 'Active'
           )
           ELSE NULL END                                      AS shelf_life_days,
      CASE WHEN wid.identity_source = 'weimi_override' THEN true
           WHEN v_mode = 'base_stock'
           THEN (sl.signal = 'RAMPING' OR COALESCE(sl.slot_age_days, 9999) < v_cold_days)
           ELSE false END                                     AS is_cold_start
    FROM picked p
    JOIN public.machines mwh ON mwh.machine_id = p.machine_id
    JOIN public.slot_lifecycle sl ON sl.machine_id = p.machine_id AND sl.archived = false AND sl.is_current = true
    JOIN public.shelf_configurations sc ON sc.shelf_id = sl.shelf_id AND sc.is_phantom = false
    LEFT JOIN weimi_identity wm
      ON wm.machine_id = sl.machine_id AND wm.shelf_id = sl.shelf_id
    CROSS JOIN LATERAL (
      SELECT CASE
               WHEN wm.pod_product_id IS NULL OR wm.match_method = 'unmatched' THEN 'lifecycle_fallback'
               WHEN wm.pod_product_id = sl.pod_product_id                      THEN 'weimi_confirmed'
               ELSE 'weimi_override'
             END AS identity_source,
             COALESCE(wm.pod_product_id, sl.pod_product_id) AS identity_pod
    ) wid
    JOIN public.pod_products pp ON pp.pod_product_id = wid.identity_pod
    LEFT JOIN public.v_shelf_max_stock sms ON sms.shelf_id = sl.shelf_id
    LEFT JOIN shelf_state ss ON ss.machine_id = sl.machine_id AND ss.shelf_id = sl.shelf_id
    LEFT JOIN public.v_driver_feedback_demand dfd ON dfd.machine_id = sl.machine_id AND dfd.pod_product_id = sl.pod_product_id
    LEFT JOIN blocked_intents bi ON bi.pod_product_id = wid.identity_pod
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
      COALESCE(SUM(CASE WHEN f.is_dead OR f.is_drain OR f.blocking_intent_id IS NOT NULL
                        THEN 0 ELSE f.need_raw END)
        OVER (PARTITION BY f.pod_product_id
              ORDER BY f.v30 DESC, f.u_final_score DESC NULLS LAST, f.shelf_id
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)          AS prior_need
    FROM flagged f
  ),
  final AS (
    SELECT a.*,
      CASE
        WHEN a.blocking_intent_id IS NOT NULL THEN 0
        WHEN a.is_dead                        THEN 0
        WHEN a.is_drain                       THEN 0
        ELSE LEAST(a.need_raw, GREATEST(a.wh_avail - a.prior_need, 0))
      END::int AS final_qty,
      CASE
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
        'identity_source',  f.identity_source,
        'decision',         f.decision
      ) || (CASE WHEN v_mode='base_stock'
                 THEN jsonb_build_object('base_stock', f.bs_decision, 'sizing_mode', 'base_stock')
                 ELSE '{}'::jsonb END)
        || (CASE WHEN f.identity_source = 'weimi_override'
                 THEN jsonb_build_object('lifecycle_pod_product_id', f.lifecycle_pod_product_id)
                 ELSE '{}'::jsonb END)
    FROM final f
    WHERE (NOT f.is_dead AND f.need_raw > 0)
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
    WHERE f.is_dead AND f.identity_source <> 'weimi_override'
    RETURNING 1
  ),
  gap_rows AS (
    SELECT f.official_name, f.shelf_code, f.pod_product_name, f.signal,
      f.v30::numeric(6,2) AS v30, f.current_stock, f.max_stock,
      f.max_stock AS target_stock, (f.need_raw - f.final_qty) AS gap_units,
      f.u_runway_days AS runway_days
    FROM final f
    WHERE NOT f.is_dead AND NOT f.is_drain AND f.blocking_intent_id IS NULL
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

CREATE OR REPLACE FUNCTION public.find_substitutes_for_shelf(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_anchor_pod_product_id uuid, p_top_n integer DEFAULT 5, p_aggressiveness_pct integer DEFAULT 50)
 RETURNS TABLE(rank integer, pod_product_id uuid, pod_product_name text, pearson_score numeric, source text, wh_stock_units numeric, reason text)
 LANGUAGE plpgsql
 STABLE
AS $function$
#variable_conflict use_column
DECLARE
  v_loc_type text;
  v_wh_pri   uuid;
  v_wh_sec   uuid;
BEGIN
  IF p_anchor_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_anchor_pod_product_id is required';
  END IF;
  SELECT m.location_type, m.primary_warehouse_id, m.secondary_warehouse_id
    INTO v_loc_type, v_wh_pri, v_wh_sec
    FROM public.machines m WHERE m.machine_id = p_machine_id;

  RETURN QUERY
  WITH present AS (
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
    UNION
    SELECT vls.pod_product_id FROM public.v_live_shelf_stock vls
     WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
  ),
  basket AS (
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
       AND (COALESCE(sl.velocity_7d,0) > 0 OR COALESCE(sl.velocity_30d,0) > 0)
  ),
  global_perf AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS global_v30
    FROM public.slot_lifecycle sl
    WHERE sl.archived = false AND sl.is_current = true
    GROUP BY sl.pod_product_id
  ),
  wh AS (
    -- PRD-125 D3: availability now flows through wh_available_for, keyed by
    -- each candidate's own source_of_supply (venue_team -> WH_MCC + WH_MM,
    -- else WH_CENTRAL) instead of this machine's primary/secondary_warehouse_id
    -- pair, which (as in engine_add_pod) does not necessarily cover WH_MM.
    SELECT pm.pod_product_id, SUM(waf.free_stock)::numeric AS wh_stock
    FROM (
      SELECT DISTINCT pm0.pod_product_id, pm0.boonz_product_id
      FROM public.product_mapping pm0
      WHERE pm0.status = 'Active'
        AND (pm0.machine_id IS NULL OR pm0.machine_id = p_machine_id)
    ) pm
    CROSS JOIN LATERAL public.wh_available_for(p_machine_id, pm.boonz_product_id) waf
    GROUP BY pm.pod_product_id
  ),
  cand AS (
    SELECT gp.pod_product_id AS cand, gp.global_v30, w.wh_stock
    FROM global_perf gp
    JOIN wh w ON w.pod_product_id = gp.pod_product_id AND w.wh_stock > 0
    JOIN public.pod_products pp ON pp.pod_product_id = gp.pod_product_id AND COALESCE(pp.is_catchall,false) = false
    WHERE gp.pod_product_id <> p_anchor_pod_product_id
      AND gp.global_v30 > 0
      AND gp.pod_product_id NOT IN (SELECT pod_product_id FROM present)
      AND NOT EXISTS (
        SELECT 1 FROM public.strategic_intents si
         WHERE si.intent_type = 'decommission'
           AND si.status IN ('queued','in_progress')
           AND si.scope_pod_product_id = gp.pod_product_id
      )
  ),
  scored AS (
    SELECT c.cand, c.global_v30, c.wh_stock,
      COALESCE(
        (SELECT AVG(cm.pearson) FROM public.correlation_pod_per_machine cm
          WHERE cm.machine_id = p_machine_id AND cm.pod_product_b = c.cand
            AND cm.pod_product_a IN (SELECT pod_product_id FROM basket)),
        (SELECT AVG(cl.pearson) FROM public.correlation_pod_per_loc_type cl
          WHERE cl.location_type = v_loc_type AND cl.pod_product_b = c.cand
            AND cl.pod_product_a IN (SELECT pod_product_id FROM basket))
      )::numeric AS basket_corr
    FROM cand c
  ),
  ranked AS (
    SELECT ROW_NUMBER() OVER (ORDER BY (COALESCE(s.basket_corr, 0.05) * ln(1 + s.wh_stock)) DESC, s.global_v30 DESC) AS rk,
           s.cand, s.basket_corr, s.global_v30, s.wh_stock
    FROM scored s
  )
  SELECT
    r.rk::int                                                                  AS rank,
    r.cand                                                                     AS pod_product_id,
    pp.pod_product_name                                                        AS pod_product_name,
    ROUND(r.basket_corr,3)                                                     AS pearson_score,
    CASE WHEN r.basket_corr > 0 THEN 'global_basket_fit' ELSE 'global_performer' END AS source,
    r.wh_stock                                                                 AS wh_stock_units,
    CASE WHEN r.basket_corr > 0
         THEN 'Global performer; fits this machine''s basket (corr ' || ROUND(r.basket_corr,2) || ')'
         ELSE 'Global performer (' || ROUND(r.global_v30,2) || '/day fleet), in stock' END AS reason
  FROM ranked r
  JOIN public.pod_products pp ON pp.pod_product_id = r.cand
  WHERE r.rk <= p_top_n
  ORDER BY r.rk;
END $function$;

ALTER TABLE public.refill_dispatching DROP CONSTRAINT refill_dispatching_source_kind_chk;
ALTER TABLE public.refill_dispatching ADD CONSTRAINT refill_dispatching_source_kind_chk
  CHECK (source_kind = ANY (ARRAY['wh'::text, 'venue'::text, 'm2m'::text, 'truck_transfer'::text, 'unknown'::text]));

ALTER TABLE public.refill_dispatching DROP CONSTRAINT refill_dispatching_source_consistency_chk;
ALTER TABLE public.refill_dispatching ADD CONSTRAINT refill_dispatching_source_consistency_chk CHECK (
  ((source_kind = 'wh'::text) AND (source_warehouse_id IS NOT NULL) AND (source_machine_id IS NULL))
  OR ((source_kind = 'venue'::text) AND (source_warehouse_id IS NULL) AND (source_machine_id IS NULL))
  OR ((source_kind = 'm2m'::text) AND (source_machine_id IS NOT NULL) AND (source_warehouse_id IS NULL))
  OR ((source_kind = 'truck_transfer'::text) AND (source_machine_id IS NOT NULL) AND (source_warehouse_id IS NULL))
  OR ((source_kind = 'unknown'::text) AND (source_warehouse_id IS NULL) AND (source_machine_id IS NULL))
) NOT VALID;

UPDATE public.refill_dispatching
SET source_kind = 'wh', source_warehouse_id = from_warehouse_id
WHERE dispatch_date IN ('2026-09-14','2026-09-15')
  AND source_kind = 'unknown' AND source_origin::text = 'warehouse'
  AND from_warehouse_id IS NOT NULL;

UPDATE public.refill_dispatching
SET source_kind = 'venue'
WHERE dispatch_date IN ('2026-09-14','2026-09-15')
  AND source_kind = 'unknown' AND source_origin::text = 'vox_at_venue';
