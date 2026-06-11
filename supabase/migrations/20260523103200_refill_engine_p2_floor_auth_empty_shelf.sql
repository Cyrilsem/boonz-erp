-- PRD: Refill Engine Emergency Fix — Phase 2 (P1)
-- FR-005: engine_add_pod — performance-based fill floor (machine-velocity-derived)
-- FR-006: auto_generate_draft — NULL-safe auth (callable from operator session, cron, or service-role)
-- FR-007: engine_finalize_pod — flag REMOVE/M2W rows with no paired ADD_NEW (empty_shelf_after_removal)
-- Constitutional articles: 1 (canonical writers), 4 (DEFINER validates), 6 (warehouse_inventory.status untouched), 12 (forward-only).

-- ============================================================
-- FR-005: engine_add_pod v10 — performance-based fill floor
-- ============================================================
CREATE OR REPLACE FUNCTION public.engine_add_pod(
  p_plan_date date DEFAULT (CURRENT_DATE + 1),
  p_days_cover integer DEFAULT 14
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id          uuid;
  v_refills          integer := 0;
  v_skipped_intent   integer := 0;
  v_procurement_gaps jsonb   := '[]'::jsonb;
  v_t0               timestamptz := clock_timestamp();
  v_default_max      integer := 10;
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

  DELETE FROM public.pod_refills WHERE plan_date = p_plan_date;

  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_add_pod: no picked/cs_added machines for %; run Stage 1 first', p_plan_date;
  END IF;

  PERFORM public._assert_gate_zero(p_plan_date);

  WITH shelf_state AS (
    SELECT
      vls.machine_id,
      sc.shelf_id,
      MAX(vls.current_stock)::int AS current_stock,
      MAX(vls.max_stock)::int     AS live_max_stock
    FROM public.v_live_shelf_stock vls
    JOIN public.shelf_configurations sc
      ON sc.machine_id = vls.machine_id
     AND sc.is_phantom = false
     AND vls.slot_name = LEFT(sc.shelf_code,1) || (SUBSTR(sc.shelf_code,2)::int)::text
    GROUP BY vls.machine_id, sc.shelf_id
  ),
  picked AS (
    SELECT machine_id, official_name
      FROM public.machines_to_visit
     WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')
  ),
  blocked_intents AS (
    SELECT DISTINCT si.scope_pod_product_id AS pod_product_id, si.intent_id, si.intent_type,
           si.scope_machine_ids
      FROM public.strategic_intents si
     WHERE si.intent_type IN ('decommission','rebalance')
       AND si.status IN ('queued','in_progress')
       AND si.scope_pod_product_id IS NOT NULL
  ),
  candidates AS (
    SELECT
      p.machine_id,
      p.official_name,
      sl.shelf_id,
      sc.shelf_code,
      COALESCE(NULLIF(ss.live_max_stock, 0),
               NULLIF(sc.max_capacity, 0),
               sms.max_stock_weimi,
               v_default_max)::int AS max_stock,
      sl.pod_product_id,
      pp.pod_product_name,
      sl.signal,
      COALESCE(sl.velocity_30d, 0)::numeric                   AS v30,
      COALESCE(ss.current_stock, 0)::integer                  AS current_stock,
      COALESCE(wpr.total_stock, 0)::integer                   AS wh_avail,
      bi.intent_id                                            AS blocking_intent_id,
      bi.intent_type                                          AS blocking_intent_type
    FROM picked p
    JOIN public.slot_lifecycle sl
      ON sl.machine_id = p.machine_id
     AND sl.archived = false
     AND sl.is_current = true
    JOIN public.shelf_configurations sc
      ON sc.shelf_id = sl.shelf_id
     AND sc.is_phantom = false
    JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id
    LEFT JOIN public.v_shelf_max_stock sms
      ON sms.shelf_id = sl.shelf_id
    LEFT JOIN shelf_state ss
      ON ss.machine_id = sl.machine_id AND ss.shelf_id = sl.shelf_id
    LEFT JOIN public.v_warehouse_pod_rollup wpr
      ON wpr.pod_product_id = sl.pod_product_id
    LEFT JOIN blocked_intents bi
      ON bi.pod_product_id = sl.pod_product_id
     AND (bi.scope_machine_ids IS NULL OR sl.machine_id = ANY(bi.scope_machine_ids))
  ),
  -- v10 FR-005: machine-level daily velocity drives the per-machine performance floor.
  candidates_with_machine_velocity AS (
    SELECT
      c.*,
      ROUND(SUM(c.v30) OVER (PARTITION BY c.machine_id) / 30.0, 2) AS machine_daily_velocity
    FROM candidates c
  ),
  sized AS (
    SELECT
      c.*,
      -- v8: per-signal target_stock. STAR x2, DOUBLE DOWN x1.5, otherwise x1.
      CASE c.signal
        WHEN 'STAR'         THEN CEIL(c.v30 * p_days_cover * 2.0)::int
        WHEN 'DOUBLE DOWN'  THEN CEIL(c.v30 * p_days_cover * 1.5)::int
        ELSE                     CEIL(c.v30 * p_days_cover * 1.0)::int
      END AS target_stock,
      CASE WHEN c.v30 > 0 THEN ROUND(c.current_stock / c.v30, 1) ELSE NULL END AS runway_days,
      -- v10 FR-005: fill_pct for floor logic
      CASE WHEN c.max_stock > 0 THEN ROUND(c.current_stock * 100.0 / c.max_stock, 1) ELSE NULL END AS fill_pct,
      -- v10 FR-005: machine-performance-derived fill-floor threshold.
      -- Higher-traffic machines (more units/day) demand higher absolute fill floors.
      CASE
        WHEN c.machine_daily_velocity >= 10 THEN 70.0
        WHEN c.machine_daily_velocity >=  3 THEN 50.0
        ELSE                                      25.0
      END AS fill_floor_threshold,
      CASE
        WHEN c.blocking_intent_id IS NOT NULL THEN NULL
        WHEN c.signal = 'STAR'         THEN GREATEST(CEIL(c.v30 * p_days_cover * 2.0)::int - c.current_stock, 0)
        WHEN c.signal = 'DOUBLE DOWN'  THEN GREATEST(CEIL(c.v30 * p_days_cover * 1.5)::int - c.current_stock, 0)
        WHEN c.signal = 'KEEP GROWING' THEN GREATEST(CEIL(c.v30 * p_days_cover)::int - c.current_stock, 0)
        WHEN c.signal = 'KEEP'         THEN GREATEST(CEIL(c.v30 * p_days_cover)::int - c.current_stock, 0)
        WHEN c.signal = 'RAMPING'      THEN LEAST(CEIL(c.v30 * 7)::int, GREATEST((c.max_stock / 2) - c.current_stock, 0))
        WHEN c.signal = 'WATCH'        THEN LEAST(CEIL(c.v30 * 7)::int, GREATEST((c.max_stock / 2) - c.current_stock, 0))
        ELSE NULL
      END AS velocity_raw_qty
    FROM candidates_with_machine_velocity c
  ),
  -- v10 FR-005: second-pass fill-floor target. Refill to 80% of max_stock when shelf is below the
  -- performance-derived floor or hits the AC-6 safety net (fill_pct <= 25% AND gap >= 2).
  with_floor AS (
    SELECT
      s.*,
      (CEIL(s.max_stock * 0.80)::int - s.current_stock) AS floor_target_raw,
      (s.max_stock - s.current_stock)                   AS gap_units
    FROM sized s
  ),
  with_floor_eligible AS (
    SELECT
      wf.*,
      CASE
        WHEN wf.blocking_intent_id IS NOT NULL THEN 0
        -- AC-6 safety net: gap>=2 AND fill_pct<=25% always gets a refill regardless of machine perf.
        WHEN wf.gap_units >= 2 AND wf.fill_pct IS NOT NULL AND wf.fill_pct <= 25.0
          THEN GREATEST(wf.floor_target_raw, 0)
        -- Performance-tier floor: shelf below machine's perf-derived fill floor.
        WHEN wf.gap_units >= 2 AND wf.fill_pct IS NOT NULL AND wf.fill_pct <= wf.fill_floor_threshold
          THEN GREATEST(wf.floor_target_raw, 0)
        ELSE 0
      END AS floor_target
    FROM with_floor wf
  ),
  clamped AS (
    SELECT
      wfe.*,
      -- v10 FR-005: combined target = GREATEST(velocity_target, floor_target).
      GREATEST(COALESCE(wfe.velocity_raw_qty, 0), wfe.floor_target) AS raw_qty,
      LEAST(
        GREATEST(COALESCE(wfe.velocity_raw_qty, 0), wfe.floor_target),
        GREATEST(wfe.max_stock - wfe.current_stock, 0)
      )::int AS final_qty,
      CASE
        WHEN wfe.blocking_intent_id IS NOT NULL                                       THEN 'skipped_strategic_intent'
        WHEN wfe.velocity_raw_qty IS NULL AND wfe.floor_target = 0                    THEN 'skipped_signal'
        WHEN wfe.current_stock >= wfe.max_stock AND wfe.max_stock > 0                 THEN 'skipped_full'
        WHEN COALESCE(wfe.velocity_raw_qty,0) = 0 AND wfe.v30 > 0
             AND wfe.current_stock >= wfe.target_stock
             AND wfe.floor_target = 0                                                 THEN 'skipped_runway_ok'
        WHEN COALESCE(wfe.velocity_raw_qty,0) = 0 AND wfe.floor_target = 0            THEN 'skipped_no_demand'
        -- Performance floor fired (and outweighs or equals velocity target).
        WHEN wfe.floor_target > COALESCE(wfe.velocity_raw_qty, 0)                     THEN 'performance_floor'
        WHEN GREATEST(COALESCE(wfe.velocity_raw_qty,0), wfe.floor_target)
             > (wfe.max_stock - wfe.current_stock)                                    THEN 'capped_by_max'
        ELSE 'velocity_target'
      END AS clamp_reason
    FROM with_floor_eligible wfe
  ),
  inserted AS (
    INSERT INTO public.pod_refills(
      plan_date, machine_id, shelf_id, pod_product_id,
      qty, current_stock, max_stock,
      velocity_30d, days_cover, signal,
      wh_available_pod, clamp_reason, reasoning
    )
    SELECT
      p_plan_date, c.machine_id, c.shelf_id, c.pod_product_id,
      c.final_qty, c.current_stock, c.max_stock,
      c.v30, p_days_cover, c.signal,
      c.wh_avail, c.clamp_reason,
      jsonb_build_object(
        'shelf_code',       c.shelf_code,
        'official_name',    c.official_name,
        'raw_qty',          c.raw_qty,
        'velocity_raw_qty', c.velocity_raw_qty,
        'floor_target',     c.floor_target,
        'target_stock',     c.target_stock,
        'runway_days',      c.runway_days,
        'max_stock_source', 'weimi_live_v5',
        'signal_boost',     CASE c.signal
                              WHEN 'STAR'        THEN 2.0
                              WHEN 'DOUBLE DOWN' THEN 1.5
                              ELSE                    1.0
                            END,
        'fill_pct_before',  c.fill_pct,
        'machine_daily_velocity', c.machine_daily_velocity,
        'fill_floor_threshold',   c.fill_floor_threshold,
        'wh_avail',         c.wh_avail,
        'wh_warning',       CASE WHEN c.wh_avail < c.final_qty THEN true ELSE false END
      )
    FROM clamped c
    WHERE c.final_qty > 0
      AND c.clamp_reason <> 'skipped_strategic_intent'
    RETURNING 1
  ),
  gap_rows AS (
    SELECT
      c.official_name,
      c.shelf_code,
      c.pod_product_name,
      c.signal,
      c.v30::numeric(6,2) AS v30,
      c.current_stock,
      c.max_stock,
      c.target_stock,
      (c.target_stock - c.current_stock) AS gap_units,
      c.runway_days
    FROM clamped c
    WHERE c.wh_avail = 0
      AND c.v30 > 0
      AND c.current_stock < c.target_stock
      AND c.blocking_intent_id IS NULL
  )
  SELECT
    (SELECT COUNT(*) FROM inserted),
    COALESCE(jsonb_agg(jsonb_build_object(
      'machine',        gap_rows.official_name,
      'shelf',          gap_rows.shelf_code,
      'product',        gap_rows.pod_product_name,
      'signal',         gap_rows.signal,
      'velocity_30d',   gap_rows.v30,
      'current_stock',  gap_rows.current_stock,
      'max_stock',      gap_rows.max_stock,
      'target_14d',     gap_rows.target_stock,
      'target_signal',  gap_rows.target_stock,
      'gap_units',      gap_rows.gap_units,
      'runway_days',    gap_rows.runway_days
    ) ORDER BY gap_rows.gap_units DESC), '[]'::jsonb)
  INTO v_refills, v_procurement_gaps
  FROM gap_rows;

  SELECT COUNT(*) INTO v_skipped_intent
  FROM public.slot_lifecycle sl
  JOIN public.machines_to_visit mtv
    ON mtv.machine_id = sl.machine_id AND mtv.plan_date = p_plan_date AND mtv.status IN ('picked','cs_added')
  JOIN public.strategic_intents si
    ON si.scope_pod_product_id = sl.pod_product_id
   AND si.intent_type IN ('decommission','rebalance')
   AND si.status IN ('queued','in_progress')
   AND (si.scope_machine_ids IS NULL OR sl.machine_id = ANY(si.scope_machine_ids))
  WHERE sl.archived=false AND sl.is_current=true;

  RETURN jsonb_build_object(
    'plan_date',          p_plan_date,
    'days_cover',         p_days_cover,
    'refills_inserted',   v_refills,
    'skipped_strategic_intent', v_skipped_intent,
    'procurement_gaps_count', jsonb_array_length(v_procurement_gaps),
    'procurement_gaps',   v_procurement_gaps,
    'engine_version',     'v10_wh_decoupled_perf_floor',
    'duration_ms',        (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;


-- ============================================================
-- FR-006: auto_generate_draft — NULL-safe role gate.
-- Matches the canonical pattern (engine_add_pod / stitch_pod_to_boonz): only enforce the role
-- check when auth.uid() IS NOT NULL. Service-role (cron) and conductor / service-key sessions
-- skip the check because the function is SECURITY DEFINER and already runs elevated.
-- ============================================================
CREATE OR REPLACE FUNCTION public.auto_generate_draft(
  p_plan_date date DEFAULT (CURRENT_DATE + 1)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pick_result   jsonb;
  v_add_result    jsonb;
  v_swap_result   jsonb;
  v_picked_count  int;
  v_user_id       uuid;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'auto_generate_draft', true);

  -- v2 FR-006: NULL-safe auth. Only enforce when caller has an authenticated user id.
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id
      AND up.role IN ('operator_admin', 'superadmin', 'manager')
  ) THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'unauthorized: requires operator_admin, superadmin, or manager role'
    );
  END IF;

  BEGIN
    v_pick_result := pick_machines_for_refill(p_plan_date);
    v_picked_count := COALESCE((v_pick_result->>'machines_picked')::int, 0);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'stage', 'pick_machines_for_refill',
      'message', SQLERRM,
      'plan_date', p_plan_date
    );
  END;

  IF v_picked_count = 0 THEN
    RETURN jsonb_build_object(
      'status', 'no_machines',
      'plan_date', p_plan_date,
      'message', 'No machines need a visit on this date'
    );
  END IF;

  BEGIN
    v_add_result := engine_add_pod(p_plan_date, 14);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'stage', 'engine_add_pod',
      'message', SQLERRM,
      'plan_date', p_plan_date,
      'machines_picked', v_picked_count
    );
  END;

  BEGIN
    v_swap_result := engine_swap_pod(p_plan_date, 2, 0.30, 14);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'status', 'partial',
      'stage', 'engine_swap_pod_failed',
      'message', SQLERRM,
      'plan_date', p_plan_date,
      'machines_picked', v_picked_count,
      'stage_2a', v_add_result
    );
  END;

  RETURN jsonb_build_object(
    'status', 'draft_ready',
    'plan_date', p_plan_date,
    'machines_picked', v_picked_count,
    'stage_1', v_pick_result,
    'stage_2a', v_add_result,
    'stage_2b', v_swap_result
  );
END;
$function$;


-- ============================================================
-- FR-007: engine_finalize_pod — flag REMOVE/M2W rows with no paired ADD_NEW
-- on the same (plan_date, machine_id, shelf_id). Adds reasoning.warning='empty_shelf_after_removal'.
-- ============================================================
CREATE OR REPLACE FUNCTION public.engine_finalize_pod(
  p_plan_date date DEFAULT (CURRENT_DATE + 1)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id           uuid;
  v_t0                timestamptz := clock_timestamp();
  v_inserted          integer := 0;
  v_refills_in        integer := 0;
  v_swaps_in          integer := 0;
  v_overruled         integer := 0;
  v_shelf_cap_hit     integer := 0;
  v_empty_shelf_flag  integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'engine_finalize_pod', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'engine_finalize_pod: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;

  UPDATE public.pod_refill_plan
     SET status = 'superseded', updated_at = now()
   WHERE plan_date = p_plan_date AND status = 'draft';

  SELECT COUNT(*) INTO v_refills_in FROM public.pod_refills WHERE plan_date = p_plan_date;
  SELECT COUNT(*) INTO v_swaps_in   FROM public.pod_swaps   WHERE plan_date = p_plan_date;

  WITH swap_shelves AS (
    SELECT DISTINCT machine_id, shelf_id FROM public.pod_swaps WHERE plan_date = p_plan_date
  ),
  refill_lines AS (
    SELECT pr.plan_date, pr.machine_id, pr.shelf_id, pr.pod_product_id,
           'REFILL'::text AS action, pr.qty,
           jsonb_build_object(
             'shelf_code', pr.reasoning->>'shelf_code',
             'signal', pr.signal, 'velocity_30d', pr.velocity_30d,
             'days_cover', pr.days_cover, 'clamp_reason', pr.clamp_reason,
             'source','engine_add_pod') AS reasoning,
           (pr.plan_date::text||':'||pr.machine_id::text||':'||pr.shelf_id::text||':'||pr.pod_product_id::text) AS linked_refill_pk
    FROM public.pod_refills pr
    LEFT JOIN swap_shelves ss
      ON ss.machine_id = pr.machine_id AND ss.shelf_id = pr.shelf_id
    WHERE pr.plan_date = p_plan_date AND ss.shelf_id IS NULL
  ),
  swap_remove_lines AS (
    SELECT ps.plan_date, ps.machine_id, ps.shelf_id, ps.pod_product_id_out AS pod_product_id,
           'REMOVE'::text AS action, ps.qty_out AS qty,
           jsonb_build_object(
             'reason', ps.reason, 'substitute_source', ps.substitute_source,
             'substitute_score', ps.substitute_score, 'source','engine_swap_pod') AS reasoning,
           ps.swap_id
    FROM public.pod_swaps ps
    WHERE ps.plan_date = p_plan_date
      AND ps.pod_product_id_in IS NOT NULL
  ),
  swap_add_lines AS (
    SELECT ps.plan_date, ps.machine_id, ps.shelf_id, ps.pod_product_id_in AS pod_product_id,
           'ADD_NEW'::text AS action, ps.qty_in AS qty,
           jsonb_build_object(
             'reason', ps.reason, 'substitute_source', ps.substitute_source,
             'substitute_score', ps.substitute_score,
             'pod_product_id_out', ps.pod_product_id_out, 'source','engine_swap_pod') AS reasoning,
           ps.swap_id
    FROM public.pod_swaps ps
    WHERE ps.plan_date = p_plan_date
      AND ps.pod_product_id_in IS NOT NULL
      AND ps.qty_in IS NOT NULL
  ),
  swap_m2w_lines AS (
    SELECT ps.plan_date, ps.machine_id, ps.shelf_id, ps.pod_product_id_out AS pod_product_id,
           'M2W'::text AS action, ps.qty_out AS qty,
           jsonb_build_object(
             'reason', ps.reason, 'source','engine_swap_pod',
             'note','return-to-warehouse, no substitute') AS reasoning,
           ps.swap_id
    FROM public.pod_swaps ps
    WHERE ps.plan_date = p_plan_date AND ps.pod_product_id_in IS NULL
  ),
  unioned AS (
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           linked_refill_pk, NULL::uuid AS linked_swap_id FROM refill_lines
    UNION ALL
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           NULL::text, swap_id FROM swap_remove_lines
    UNION ALL
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           NULL, swap_id FROM swap_add_lines
    UNION ALL
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           NULL, swap_id FROM swap_m2w_lines
  ),
  inserted AS (
    INSERT INTO public.pod_refill_plan(
      plan_date, machine_id, shelf_id, pod_product_id, action,
      qty, reasoning, linked_refill_pk, linked_swap_id, status,
      source_origin
    )
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action,
           qty, reasoning, linked_refill_pk, linked_swap_id, 'draft',
           'warehouse'::public.source_origin_enum
      FROM unioned
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id, action) DO UPDATE
      SET qty = EXCLUDED.qty, reasoning = EXCLUDED.reasoning,
          linked_refill_pk = EXCLUDED.linked_refill_pk,
          linked_swap_id = EXCLUDED.linked_swap_id,
          status = 'draft', updated_at = now()
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_inserted FROM inserted;

  -- v10 FR-007: Annotate REMOVE/M2W rows with no paired ADD_NEW for same (machine, shelf).
  -- Critical FE signal: driver should treat these as "shelf goes empty after action".
  WITH paired_shelves AS (
    SELECT DISTINCT machine_id, shelf_id
      FROM public.pod_refill_plan
     WHERE plan_date = p_plan_date AND action = 'ADD_NEW'
  )
  UPDATE public.pod_refill_plan prp
     SET reasoning = COALESCE(prp.reasoning, '{}'::jsonb)
                     || jsonb_build_object('warning', 'empty_shelf_after_removal'),
         updated_at = now()
   WHERE prp.plan_date = p_plan_date
     AND prp.action IN ('REMOVE','M2W')
     AND NOT EXISTS (
       SELECT 1 FROM paired_shelves ps
        WHERE ps.machine_id = prp.machine_id AND ps.shelf_id = prp.shelf_id
     );
  GET DIAGNOSTICS v_empty_shelf_flag = ROW_COUNT;

  SELECT COUNT(*) INTO v_overruled
    FROM public.pod_refills pr
    JOIN public.pod_swaps ps
      ON ps.plan_date = pr.plan_date
     AND ps.machine_id = pr.machine_id AND ps.shelf_id = pr.shelf_id
   WHERE pr.plan_date = p_plan_date;

  WITH slot_counts AS (
    SELECT machine_id, COUNT(*) AS slot_n
      FROM public.slot_lifecycle WHERE archived=false AND is_current=true
     GROUP BY machine_id
  ), swap_counts AS (
    SELECT machine_id, COUNT(DISTINCT shelf_id) AS swap_n
      FROM public.pod_swaps WHERE plan_date = p_plan_date GROUP BY machine_id
  )
  SELECT COUNT(*) INTO v_shelf_cap_hit
    FROM slot_counts sc JOIN swap_counts sw USING(machine_id)
   WHERE sw.swap_n * 1.0 / GREATEST(sc.slot_n,1) > 0.60;

  RETURN jsonb_build_object(
    'plan_date', p_plan_date, 'rows_finalized', v_inserted,
    'refills_in', v_refills_in, 'swaps_in', v_swaps_in,
    'r4_overruled_refills', v_overruled,
    'r7_machines_over_60pct', v_shelf_cap_hit,
    'empty_shelf_after_removal_flagged', v_empty_shelf_flag,
    'engine_version', 'v10_empty_shelf_warning',
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;
