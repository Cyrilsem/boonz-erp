-- PRD-010 AC#4: engine_finalize_pod v11
-- Add capacity_mismatch_warnings jsonb array to the function's return
-- diagnostics. Each warning surfaces a shelf-swap opportunity inside one
-- machine: a high-velocity product is jammed onto a small shelf while a
-- low-velocity product occupies a larger shelf on the same machine.
--
-- A warning is emitted when ALL of the following are true:
--   1. A pod_refill_plan REFILL row (the high-velocity product) has
--      reasoning->>'signal' IN ('STAR','DOUBLE DOWN','KEEP GROWING'),
--      shelf_configurations.max_capacity <= 14, AND
--      reasoning->>'clamp_reason' = 'capped_by_max'.
--   2. Same machine has another shelf with shelf_configurations.max_capacity >= 20
--      occupied by a slot_lifecycle product whose signal is in
--      ('WIND DOWN','ROTATE OUT','DEAD','WATCH', plus 'DEAD - SWAP NOW' variant).
--
-- The warnings are advisory only: surfaced for CS to manually move a planogram
-- via the FE. The engine never auto-executes shelf swaps.
--
-- engine_version bumps v10_empty_shelf_warning -> v11_capacity_mismatch_warnings.
-- Article 12 forward-only CREATE OR REPLACE; function identity, args unchanged.
-- Return JSONB shape adds one new key (capacity_mismatch_warnings).

CREATE OR REPLACE FUNCTION public.engine_finalize_pod(
  p_plan_date date DEFAULT (CURRENT_DATE + 1)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id              uuid;
  v_t0                   timestamptz := clock_timestamp();
  v_inserted             integer := 0;
  v_refills_in           integer := 0;
  v_swaps_in             integer := 0;
  v_overruled            integer := 0;
  v_shelf_cap_hit        integer := 0;
  v_empty_shelf_flag     integer := 0;
  v_capacity_warnings    jsonb := '[]'::jsonb;
  v_capacity_warning_n   integer := 0;
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

  -- ==========================================================================
  -- v11 AC#4: capacity_mismatch_warnings
  -- Per machine, surface a (high-velocity-on-small-shelf, candidate-large-shelf)
  -- pair when the engine had to capped_by_max the high-velocity product.
  -- ==========================================================================
  WITH high_velocity_constrained AS (
    SELECT
      prp.machine_id,
      m.official_name                              AS machine_name,
      prp.shelf_id                                 AS hv_shelf_id,
      sc.shelf_code                                AS hv_shelf_code,
      sc.max_capacity                              AS hv_max,
      pp.pod_product_name                          AS hv_product_name,
      (prp.reasoning->>'signal')                   AS hv_signal,
      (prp.reasoning->>'velocity_30d')::numeric    AS hv_v30
    FROM public.pod_refill_plan prp
    JOIN public.machines m              ON m.machine_id      = prp.machine_id
    JOIN public.shelf_configurations sc ON sc.shelf_id       = prp.shelf_id
                                        AND sc.is_phantom    = false
    JOIN public.pod_products pp         ON pp.pod_product_id = prp.pod_product_id
    WHERE prp.plan_date = p_plan_date
      AND prp.action    = 'REFILL'
      AND (prp.reasoning->>'signal')        IN ('STAR','DOUBLE DOWN','KEEP GROWING')
      AND (prp.reasoning->>'clamp_reason')   = 'capped_by_max'
      AND COALESCE(sc.max_capacity, 0)      <= 14
  ),
  low_velocity_large AS (
    SELECT
      sl.machine_id,
      sl.shelf_id                                  AS lv_shelf_id,
      sc.shelf_code                                AS lv_shelf_code,
      sc.max_capacity                              AS lv_max,
      pp.pod_product_name                          AS lv_product_name,
      sl.signal                                    AS lv_signal,
      COALESCE(sl.velocity_30d, 0)::numeric        AS lv_v30
    FROM public.slot_lifecycle sl
    JOIN public.shelf_configurations sc ON sc.shelf_id       = sl.shelf_id
                                        AND sc.is_phantom    = false
    JOIN public.pod_products pp         ON pp.pod_product_id = sl.pod_product_id
    WHERE sl.archived    = false
      AND sl.is_current  = true
      AND sl.signal      IN ('WIND DOWN','ROTATE OUT','DEAD','DEAD — SWAP NOW','WATCH')
      AND COALESCE(sc.max_capacity, 0) >= 20
  ),
  pairs AS (
    SELECT
      hv.machine_name,
      hv.hv_product_name,
      hv.hv_shelf_code,
      hv.hv_max,
      hv.hv_v30,
      hv.hv_signal,
      lv.lv_shelf_code,
      lv.lv_max,
      lv.lv_product_name,
      lv.lv_signal,
      lv.lv_v30,
      CASE
        WHEN hv.hv_v30 > 0 THEN ROUND((lv.lv_max - hv.hv_max)::numeric / hv.hv_v30, 1)
        ELSE NULL
      END AS days_gained,
      ROW_NUMBER() OVER (
        PARTITION BY hv.machine_name, hv.hv_shelf_code
        ORDER BY lv.lv_max DESC, lv.lv_v30 ASC, lv.lv_shelf_code
      ) AS pair_rank
    FROM high_velocity_constrained hv
    JOIN low_velocity_large lv ON lv.machine_id = hv.machine_id
  ),
  best_pair_per_hv AS (
    SELECT * FROM pairs WHERE pair_rank = 1
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'machine_name',          bpp.machine_name,
      'high_velocity_product', bpp.hv_product_name,
      'current_shelf',         bpp.hv_shelf_code,
      'current_max',           bpp.hv_max,
      'v30',                   bpp.hv_v30,
      'signal',                bpp.hv_signal,
      'candidate_shelf',       bpp.lv_shelf_code,
      'candidate_max',         bpp.lv_max,
      'candidate_product',     bpp.lv_product_name,
      'candidate_signal',      bpp.lv_signal,
      'candidate_v30',         bpp.lv_v30,
      'days_gained',           bpp.days_gained
    ) ORDER BY bpp.machine_name, bpp.hv_shelf_code), '[]'::jsonb),
    COUNT(*)
  INTO v_capacity_warnings, v_capacity_warning_n
  FROM best_pair_per_hv bpp;

  RETURN jsonb_build_object(
    'plan_date', p_plan_date, 'rows_finalized', v_inserted,
    'refills_in', v_refills_in, 'swaps_in', v_swaps_in,
    'r4_overruled_refills', v_overruled,
    'r7_machines_over_60pct', v_shelf_cap_hit,
    'empty_shelf_after_removal_flagged', v_empty_shelf_flag,
    'capacity_mismatch_warnings_count', v_capacity_warning_n,
    'capacity_mismatch_warnings', v_capacity_warnings,
    'engine_version', 'v11_capacity_mismatch_warnings',
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;
