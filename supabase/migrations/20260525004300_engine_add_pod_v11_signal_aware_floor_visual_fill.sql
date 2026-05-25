-- PRD-010 AC#1 + AC#3: engine_add_pod v11
-- Signal-aware performance floor + visual-fill minimum for healthy products.
--
-- AC#1: replace the uniform CEIL(max_stock * 0.80) performance_floor with a
-- per-signal lookup. WIND DOWN, ROTATE OUT, DEAD get 0 (no floor); STAR/DD
-- 0.80; KEEP GROWING 0.70; KEEP 0.60; RAMPING 0.50; WATCH 0.40. When the
-- signal floor activates AND signal is not WIND DOWN/ROTATE OUT/DEAD,
-- clamp_reason is 'signal_floor' (replaces 'performance_floor').
--
-- AC#1 also adds WIND DOWN to the velocity case so the engine still refills
-- at the natural drain rate (CEIL(v30 * days_cover) - current_stock), instead
-- of the previous ELSE NULL that produced no refill at all. WIND DOWN draws
-- the velocity_target clamp_reason.
--
-- AC#3: for signals in (STAR, DOUBLE DOWN, KEEP GROWING, KEEP) only, apply a
-- visual-fill minimum of CEIL(max_stock * 0.50) - current_stock. When the
-- visual floor beats both velocity and the signal floor, clamp_reason is
-- 'visual_fill_minimum'.
--
-- final raw_qty = GREATEST(velocity_raw_qty, signal_floor_qty, visual_floor_qty)
-- final_qty = LEAST(raw_qty, max_stock - current_stock)
--
-- engine_version bumps v10_wh_decoupled_perf_floor -> v11_signal_aware_floor_visual_fill.
-- Article 12 forward-only CREATE OR REPLACE; function identity, args, return
-- shape unchanged. No schema migration.

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
  candidates_with_machine_velocity AS (
    SELECT
      c.*,
      ROUND(SUM(c.v30) OVER (PARTITION BY c.machine_id) / 30.0, 2) AS machine_daily_velocity
    FROM candidates c
  ),
  sized AS (
    SELECT
      c.*,
      CASE c.signal
        WHEN 'STAR'         THEN CEIL(c.v30 * p_days_cover * 2.0)::int
        WHEN 'DOUBLE DOWN'  THEN CEIL(c.v30 * p_days_cover * 1.5)::int
        ELSE                     CEIL(c.v30 * p_days_cover * 1.0)::int
      END AS target_stock,
      CASE WHEN c.v30 > 0 THEN ROUND(c.current_stock / c.v30, 1) ELSE NULL END AS runway_days,
      CASE WHEN c.max_stock > 0 THEN ROUND(c.current_stock * 100.0 / c.max_stock, 1) ELSE NULL END AS fill_pct,
      -- v11 AC#1: signal-aware floor percentage.
      CASE c.signal
        WHEN 'STAR'         THEN 0.80
        WHEN 'DOUBLE DOWN'  THEN 0.80
        WHEN 'KEEP GROWING' THEN 0.70
        WHEN 'KEEP'         THEN 0.60
        WHEN 'WATCH'        THEN 0.40
        WHEN 'RAMPING'      THEN 0.50
        ELSE 0
      END AS signal_floor_pct,
      -- v11 AC#1: WIND DOWN now receives a velocity target (was ELSE NULL pre-v11
      -- which meant no refill at all; PRD wants natural drain via CEIL(v30 * days_cover)).
      CASE
        WHEN c.blocking_intent_id IS NOT NULL THEN NULL
        WHEN c.signal = 'STAR'         THEN GREATEST(CEIL(c.v30 * p_days_cover * 2.0)::int - c.current_stock, 0)
        WHEN c.signal = 'DOUBLE DOWN'  THEN GREATEST(CEIL(c.v30 * p_days_cover * 1.5)::int - c.current_stock, 0)
        WHEN c.signal = 'KEEP GROWING' THEN GREATEST(CEIL(c.v30 * p_days_cover)::int - c.current_stock, 0)
        WHEN c.signal = 'KEEP'         THEN GREATEST(CEIL(c.v30 * p_days_cover)::int - c.current_stock, 0)
        WHEN c.signal = 'RAMPING'      THEN LEAST(CEIL(c.v30 * 7)::int, GREATEST((c.max_stock / 2) - c.current_stock, 0))
        WHEN c.signal = 'WATCH'        THEN LEAST(CEIL(c.v30 * 7)::int, GREATEST((c.max_stock / 2) - c.current_stock, 0))
        WHEN c.signal = 'WIND DOWN'    THEN GREATEST(CEIL(c.v30 * p_days_cover)::int - c.current_stock, 0)
        ELSE NULL
      END AS velocity_raw_qty
    FROM candidates_with_machine_velocity c
  ),
  with_floor AS (
    SELECT
      s.*,
      -- v11 AC#1: signal-driven floor target. WIND DOWN/ROTATE OUT/DEAD -> 0 (no floor).
      GREATEST(CEIL(s.max_stock * s.signal_floor_pct)::int - s.current_stock, 0) AS signal_floor_qty,
      -- v11 AC#3: visual-fill minimum, healthy signals only.
      CASE
        WHEN s.signal IN ('STAR','DOUBLE DOWN','KEEP GROWING','KEEP')
          THEN GREATEST(CEIL(s.max_stock * 0.50)::int - s.current_stock, 0)
        ELSE 0
      END AS visual_floor_qty,
      (s.max_stock - s.current_stock) AS gap_units
    FROM sized s
  ),
  clamped AS (
    SELECT
      wf.*,
      -- v11 raw_qty composition: pick the maximum of the three drivers.
      CASE
        WHEN wf.blocking_intent_id IS NOT NULL THEN 0
        ELSE GREATEST(
          COALESCE(wf.velocity_raw_qty, 0),
          wf.signal_floor_qty,
          wf.visual_floor_qty
        )
      END AS raw_qty,
      LEAST(
        CASE
          WHEN wf.blocking_intent_id IS NOT NULL THEN 0
          ELSE GREATEST(
            COALESCE(wf.velocity_raw_qty, 0),
            wf.signal_floor_qty,
            wf.visual_floor_qty
          )
        END,
        GREATEST(wf.max_stock - wf.current_stock, 0)
      )::int AS final_qty,
      CASE
        WHEN wf.blocking_intent_id IS NOT NULL                                                 THEN 'skipped_strategic_intent'
        WHEN wf.velocity_raw_qty IS NULL
             AND wf.signal_floor_qty = 0
             AND wf.visual_floor_qty = 0                                                       THEN 'skipped_signal'
        WHEN wf.current_stock >= wf.max_stock AND wf.max_stock > 0                             THEN 'skipped_full'
        WHEN COALESCE(wf.velocity_raw_qty,0) = 0 AND wf.v30 > 0
             AND wf.current_stock >= wf.target_stock
             AND wf.signal_floor_qty = 0
             AND wf.visual_floor_qty = 0                                                       THEN 'skipped_runway_ok'
        WHEN COALESCE(wf.velocity_raw_qty,0) = 0
             AND wf.signal_floor_qty = 0
             AND wf.visual_floor_qty = 0                                                       THEN 'skipped_no_demand'
        WHEN wf.visual_floor_qty > COALESCE(wf.velocity_raw_qty, 0)
             AND wf.visual_floor_qty >= wf.signal_floor_qty
             AND wf.signal IN ('STAR','DOUBLE DOWN','KEEP GROWING','KEEP')                     THEN 'visual_fill_minimum'
        WHEN wf.signal_floor_qty > COALESCE(wf.velocity_raw_qty, 0)
             AND wf.signal NOT IN ('WIND DOWN','ROTATE OUT','DEAD')                            THEN 'signal_floor'
        WHEN GREATEST(COALESCE(wf.velocity_raw_qty,0), wf.signal_floor_qty, wf.visual_floor_qty)
             > (wf.max_stock - wf.current_stock)                                               THEN 'capped_by_max'
        ELSE 'velocity_target'
      END AS clamp_reason
    FROM with_floor wf
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
        'signal_floor_qty', c.signal_floor_qty,
        'signal_floor_pct', c.signal_floor_pct,
        'visual_floor_qty', c.visual_floor_qty,
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
    'engine_version',     'v11_signal_aware_floor_visual_fill',
    'duration_ms',        (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;
