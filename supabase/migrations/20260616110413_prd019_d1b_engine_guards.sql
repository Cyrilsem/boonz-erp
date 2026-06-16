-- PRD-019 D1b: guard the pod engine against rebuilding a committed/locked plan.
-- NOT APPLIED. Author-only; apply after CS sign-off (after D1a + the helper).
-- Each function below is the LIVE body verbatim with exactly ONE line added:
--   PERFORM public._assert_refill_plan_writable(...);
-- inserted after input validation and BEFORE the first destructive statement
-- (the pod_refills/pod_swaps DELETE, or the pod_refill_plan UPDATE), so the
-- engine refuses cleanly without destroying the working set.
--   engine_add_pod   v17_cover_capped      (md5 of live body recorded in CHANGELOG)
--   engine_swap_pod  v10_2_ws1_guards
--   engine_finalize_pod(date,uuid[]) v14_preserve_approved
-- The 1-arg engine_finalize_pod(date) wrapper is unchanged (delegates here).

-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.engine_add_pod(p_plan_date date DEFAULT (CURRENT_DATE + 1), p_days_cover integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_user_id          uuid;
  v_refills          integer := 0;
  v_dead_tags        integer := 0;
  v_skipped_intent   integer := 0;
  v_procurement_gaps jsonb   := '[]'::jsonb;
  v_t0               timestamptz := clock_timestamp();
  v_default_max      integer := 10;
  v_qty0_rows        integer := 0;
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

  -- PRD-019 D1b: refuse to rebuild an approved/locked plan before any DELETE.
  PERFORM public._assert_refill_plan_writable(p_plan_date);

  DELETE FROM public.pod_refills WHERE plan_date = p_plan_date;
  DELETE FROM public.pod_swaps
   WHERE plan_date = p_plan_date
     AND reasoning->>'tagged_by' IN ('engine_add_pod_v15','engine_add_pod_v16','engine_add_pod_v17');

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
    SELECT machine_id, official_name FROM public.machines_to_visit
     WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')
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
      bi.intent_type AS blocking_intent_type
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
  covered AS (
    SELECT dc.*,
      -- PRD-031 WS-3 Hybrid (CS 2026-06-14): cover is the target, capacity is the ceiling.
      -- cover_units = stance-aware velocity cover top-up (velocity_target = velocity*days_cover*cover_mult).
      -- Wind-down/rotate-out/dead -> 0 (no refill); every other live selling shelf floored at 1.
      CASE WHEN dc.u_stance IN ('WIND DOWN','ROTATE OUT','DEAD') THEN 0
           ELSE GREATEST(ROUND(COALESCE(dc.u_velocity_target,0))::int, 1) END AS cover_units
    FROM decided dc
  ),
  flagged AS (
    SELECT cv.*,
      (cv.v7 = 0 AND cv.v30 = 0) AS is_dead,
      false                      AS is_drain,
      GREATEST(cv.max_stock - cv.current_stock, 0)                           AS fill_to_cap,
      LEAST(GREATEST(cv.cover_units, COALESCE(cv.driver_req_qty,0)),
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
        'machine_daily_velocity', f.machine_daily_velocity,
        'wh_avail',         f.wh_avail,
        'wh_warning',       CASE WHEN f.wh_avail < f.need_raw THEN true ELSE false END,
        'max_stock_source', 'weimi_live_v5',
        'engine_calibration', 'refillv2_v17_cover_capped',
        'decision',         f.decision
      )
    FROM final f
    WHERE NOT f.is_dead AND f.need_raw > 0
    RETURNING qty
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
        'tagged_by',     'engine_add_pod_v17'
      )
    FROM final f
    WHERE f.is_dead
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
    COALESCE(jsonb_agg(jsonb_build_object(
      'machine', gap_rows.official_name, 'shelf', gap_rows.shelf_code,
      'product', gap_rows.pod_product_name, 'signal', gap_rows.signal,
      'velocity_30d', gap_rows.v30, 'current_stock', gap_rows.current_stock,
      'max_stock', gap_rows.max_stock, 'target_signal', gap_rows.target_stock,
      'gap_units', gap_rows.gap_units, 'runway_days', gap_rows.runway_days
    ) ORDER BY gap_rows.gap_units DESC) FILTER (WHERE gap_rows.gap_units > 0), '[]'::jsonb)
  INTO v_refills, v_qty0_rows, v_dead_tags, v_procurement_gaps FROM gap_rows;

  UPDATE public.driver_feedback df
     SET resolved = true, resolved_at = now(), resolved_by_engine = 'engine_add_pod_v17'
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
    'skipped_strategic_intent', v_skipped_intent,
    'procurement_gaps_count', jsonb_array_length(v_procurement_gaps),
    'procurement_gaps', v_procurement_gaps,
    'engine_version', 'v17_cover_capped',
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
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

  -- PRD-019 D1b: refuse to rebuild an approved/locked plan before any DELETE.
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
      AND NOT EXISTS (SELECT 1 FROM _swaps_disabled_machines d WHERE d.machine_id = mtv.machine_id)),
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
             (SELECT pil.shelf_id FROM public.v_pod_inventory_latest pil
                JOIN public.product_mapping pm ON pm.boonz_product_id = pil.boonz_product_id
                                                AND pm.status='Active' AND pm.pod_product_id = tc.pod_out
               WHERE pil.machine_id = tc.machine_id AND pil.status='Active'
               ORDER BY pil.current_stock DESC LIMIT 1)
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
                       'engine_version','v10_narrow_trigger')
  FROM tag_resolved tr WHERE tr.shelf_id_final IS NOT NULL
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
     ORDER BY ps.machine_id, COALESCE(sls.current_stock, 0) ASC, ps.swap_id
  LOOP
    -- WS1b (v10.2): per-machine cap across passes. Strategic tags consumed the
    -- budget first; dead-tags resolve worst-shelf-first until it is exhausted.
    SELECT COUNT(*) INTO v_machine_swap_n
      FROM public.pod_swaps psx
     WHERE psx.plan_date = p_plan_date
       AND psx.machine_id = r.machine_id
       AND ((psx.reasoning->>'source') = 'strategic_machine_tag'
            OR (psx.pod_product_id_in IS NOT NULL AND psx.reasoning ? 'resolved_by'));
    IF v_machine_swap_n >= p_max_swaps_per_machine THEN
      UPDATE public.pod_swaps
         SET reasoning = reasoning || jsonb_build_object(
               'resolved_by','engine_swap_pod_v10_2',
               'deferred_by_cap', true,
               'cap', p_max_swaps_per_machine)
       WHERE swap_id = r.swap_id;
      v_dead_deferred := v_dead_deferred + 1;
      CONTINUE;
    END IF;

    -- WS1a (v10.2): prefer candidates meeting p_min_pearson; fall back to the
    -- best remaining candidate EXPLICITLY (never silently).
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
                                   'resolved_by','engine_swap_pod_v10_2',
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
                           'resolved_by','engine_swap_pod_v10_2',
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
                         'rec_id', r.rec_id, 'resolved_by','engine_swap_pod_v10_2',
                         'return_to_warehouse', true, 'engine_version','v10_narrow_trigger')
    )
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id_out) DO UPDATE
      SET pod_product_id_in = EXCLUDED.pod_product_id_in,
          qty_in            = EXCLUDED.qty_in,
          reason            = 'rotate_out',
          substitute_source = 'driver_recommendation',
          reasoning         = public.pod_swaps.reasoning || EXCLUDED.reasoning;
    v_driver_rec_swaps := v_driver_rec_swaps + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'plan_date',p_plan_date, 'max_swaps_per_machine',p_max_swaps_per_machine,
    'min_pearson',p_min_pearson, 'days_cover',p_days_cover,
    'tag_swaps', v_tag_swaps, 'tag_m2w', v_tag_m2w,
    'dead_tags_resolved', v_dead_resolved, 'dead_tags_m2w', v_dead_m2w,
    'dead_tags_deferred_by_cap', v_dead_deferred,
    'dead_tags_below_pearson_fallback', v_dead_fallback,
    'driver_rec_swaps', v_driver_rec_swaps,
    'total_swaps', v_tag_swaps + v_dead_resolved + v_driver_rec_swaps,
    'total_m2w', v_tag_m2w + v_dead_m2w,
    'engine_version','v10_2_ws1_guards',
    'duration_ms',(EXTRACT(EPOCH FROM (clock_timestamp()-v_t0))*1000)::int);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.engine_finalize_pod(p_plan_date date, p_machine_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  v_m2w_suppressed       jsonb := '[]'::jsonb;
  v_m2w_suppressed_n     integer := 0;
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

  -- PRD-019 D1b: scoped guard. Refuse to re-finalize machines whose boonz output
  -- is already approved, or while the plan is locked by another context.
  PERFORM public._assert_refill_plan_writable(p_plan_date, p_machine_ids);

  UPDATE public.pod_refill_plan
     SET status = 'superseded', updated_at = now()
   WHERE plan_date = p_plan_date AND status = 'draft'
     AND (p_machine_ids IS NULL OR machine_id = ANY(p_machine_ids));

  SELECT COUNT(*) INTO v_refills_in FROM public.pod_refills WHERE plan_date = p_plan_date
     AND (p_machine_ids IS NULL OR machine_id = ANY(p_machine_ids));
  SELECT COUNT(*) INTO v_swaps_in   FROM public.pod_swaps   WHERE plan_date = p_plan_date
     AND (p_machine_ids IS NULL OR machine_id = ANY(p_machine_ids));

  WITH swap_shelves AS (
    SELECT DISTINCT machine_id, shelf_id FROM public.pod_swaps WHERE plan_date = p_plan_date
      AND (p_machine_ids IS NULL OR machine_id = ANY(p_machine_ids))
  ),
  refill_lines AS (
    SELECT pr.plan_date, pr.machine_id, pr.shelf_id, pr.pod_product_id,
           'REFILL'::text AS action, pr.qty,
           jsonb_build_object(
             'shelf_code', pr.reasoning->>'shelf_code',
             'signal', pr.signal, 'velocity_30d', pr.velocity_30d,
             'days_cover', pr.days_cover, 'clamp_reason', pr.clamp_reason,
             'decision', pr.reasoning->'decision',
             'source','engine_add_pod') AS reasoning,
           (pr.reasoning->'decision') AS decision,
           (pr.plan_date::text||':'||pr.machine_id::text||':'||pr.shelf_id::text||':'||pr.pod_product_id::text) AS linked_refill_pk
    FROM public.pod_refills pr
    LEFT JOIN swap_shelves ss
      ON ss.machine_id = pr.machine_id AND ss.shelf_id = pr.shelf_id
    WHERE pr.plan_date = p_plan_date AND ss.shelf_id IS NULL
      AND (p_machine_ids IS NULL OR pr.machine_id = ANY(p_machine_ids))
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
      AND (p_machine_ids IS NULL OR ps.machine_id = ANY(p_machine_ids))
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
      AND (p_machine_ids IS NULL OR ps.machine_id = ANY(p_machine_ids))
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
      AND (p_machine_ids IS NULL OR ps.machine_id = ANY(p_machine_ids))
  ),
  unioned AS (
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           decision, linked_refill_pk, NULL::uuid AS linked_swap_id FROM refill_lines
    UNION ALL
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           NULL::jsonb, NULL::text, swap_id FROM swap_remove_lines
    UNION ALL
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           NULL::jsonb, NULL, swap_id FROM swap_add_lines
    UNION ALL
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action, qty, reasoning,
           NULL::jsonb, NULL, swap_id FROM swap_m2w_lines
  ),
  inserted AS (
    INSERT INTO public.pod_refill_plan(
      plan_date, machine_id, shelf_id, pod_product_id, action,
      qty, reasoning, decision, linked_refill_pk, linked_swap_id, status,
      source_origin
    )
    SELECT plan_date, machine_id, shelf_id, pod_product_id, action,
           qty, reasoning, decision, linked_refill_pk, linked_swap_id, 'draft',
           'warehouse'::public.source_origin_enum
      FROM unioned
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id, action) DO UPDATE
      SET qty = EXCLUDED.qty, reasoning = EXCLUDED.reasoning,
          decision = EXCLUDED.decision,
          linked_refill_pk = EXCLUDED.linked_refill_pk,
          linked_swap_id = EXCLUDED.linked_swap_id,
          status = CASE
                     WHEN pod_refill_plan.status = 'approved'
                      AND pod_refill_plan.qty = EXCLUDED.qty
                      AND pod_refill_plan.action = EXCLUDED.action
                     THEN 'approved'
                     ELSE 'draft'
                   END,
          updated_at = now()
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
     AND (p_machine_ids IS NULL OR prp.machine_id = ANY(p_machine_ids))
     AND NOT EXISTS (
       SELECT 1 FROM paired_shelves ps
        WHERE ps.machine_id = prp.machine_id AND ps.shelf_id = prp.shelf_id
     );
  GET DIAGNOSTICS v_empty_shelf_flag = ROW_COUNT;

  WITH replacement_shelves AS (
    SELECT DISTINCT machine_id, shelf_id
      FROM public.pod_refill_plan
     WHERE plan_date = p_plan_date
       AND status    = 'draft'
       AND action    IN ('ADD_NEW','REFILL')
       AND qty       > 0
  ),
  decom_tagged AS (
    SELECT DISTINCT smt.machine_id, smt.pod_product_id
      FROM public.strategic_machine_tags smt
     WHERE smt.action_directive = 'swap_out_m2w'
       AND smt.status           = 'approved'
  ),
  orphan_m2w AS (
    SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id,
           prp.action, prp.qty,
           m.official_name        AS machine_name,
           sc.shelf_code          AS shelf_code,
           pp.pod_product_name    AS pod_product_name
      FROM public.pod_refill_plan prp
      JOIN public.machines              m  ON m.machine_id      = prp.machine_id
      JOIN public.shelf_configurations  sc ON sc.shelf_id       = prp.shelf_id
      JOIN public.pod_products          pp ON pp.pod_product_id = prp.pod_product_id
     WHERE prp.plan_date = p_plan_date
       AND prp.status    = 'draft'
       AND prp.action    IN ('M2W','REMOVE')
       AND (p_machine_ids IS NULL OR prp.machine_id = ANY(p_machine_ids))
       AND NOT EXISTS (
         SELECT 1 FROM replacement_shelves rs
          WHERE rs.machine_id = prp.machine_id AND rs.shelf_id = prp.shelf_id
       )
       AND NOT EXISTS (
         SELECT 1 FROM decom_tagged dt
          WHERE dt.machine_id     = prp.machine_id
            AND dt.pod_product_id = prp.pod_product_id
       )
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'warning_type', 'm2w_no_replacement',
      'machine_id',   om.machine_id,
      'machine_name', om.machine_name,
      'shelf_id',     om.shelf_id,
      'shelf_code',   om.shelf_code,
      'pod_product_id',   om.pod_product_id,
      'pod_product_name', om.pod_product_name,
      'action',       om.action,
      'qty',          om.qty,
      'reason',       'auto_suppressed: no replacement for shelf'
    ) ORDER BY om.machine_name, om.shelf_code), '[]'::jsonb),
    COUNT(*)
  INTO v_m2w_suppressed, v_m2w_suppressed_n
  FROM orphan_m2w om;

  IF v_m2w_suppressed_n > 0 THEN
    WITH replacement_shelves AS (
      SELECT DISTINCT machine_id, shelf_id
        FROM public.pod_refill_plan
       WHERE plan_date = p_plan_date
         AND status    = 'draft'
         AND action    IN ('ADD_NEW','REFILL')
         AND qty       > 0
    ),
    decom_tagged AS (
      SELECT DISTINCT smt.machine_id, smt.pod_product_id
        FROM public.strategic_machine_tags smt
       WHERE smt.action_directive = 'swap_out_m2w'
         AND smt.status           = 'approved'
    )
    UPDATE public.pod_refill_plan prp
       SET status     = 'superseded',
           reasoning  = COALESCE(prp.reasoning, '{}'::jsonb)
                        || jsonb_build_object(
                             'auto_suppressed', 'no replacement for shelf',
                             'auto_suppressed_at', now(),
                             'auto_suppressed_by', 'engine_finalize_pod_v13'),
           updated_at = now()
     WHERE prp.plan_date = p_plan_date
       AND prp.status    = 'draft'
       AND prp.action    IN ('M2W','REMOVE')
       AND (p_machine_ids IS NULL OR prp.machine_id = ANY(p_machine_ids))
       AND NOT EXISTS (
         SELECT 1 FROM replacement_shelves rs
          WHERE rs.machine_id = prp.machine_id AND rs.shelf_id = prp.shelf_id
       )
       AND NOT EXISTS (
         SELECT 1 FROM decom_tagged dt
          WHERE dt.machine_id     = prp.machine_id
            AND dt.pod_product_id = prp.pod_product_id
       );
  END IF;

  SELECT COUNT(*) INTO v_overruled
    FROM public.pod_refills pr
    JOIN public.pod_swaps ps
      ON ps.plan_date = pr.plan_date
     AND ps.machine_id = pr.machine_id AND ps.shelf_id = pr.shelf_id
   WHERE pr.plan_date = p_plan_date
     AND (p_machine_ids IS NULL OR pr.machine_id = ANY(p_machine_ids));

  WITH slot_counts AS (
    SELECT machine_id, COUNT(*) AS slot_n
      FROM public.slot_lifecycle WHERE archived=false AND is_current=true
     GROUP BY machine_id
  ), swap_counts AS (
    SELECT machine_id, COUNT(DISTINCT shelf_id) AS swap_n
      FROM public.pod_swaps WHERE plan_date = p_plan_date
        AND (p_machine_ids IS NULL OR machine_id = ANY(p_machine_ids)) GROUP BY machine_id
  )
  SELECT COUNT(*) INTO v_shelf_cap_hit
    FROM slot_counts sc JOIN swap_counts sw USING(machine_id)
   WHERE sw.swap_n * 1.0 / GREATEST(sc.slot_n,1) > 0.60;

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
      AND (p_machine_ids IS NULL OR prp.machine_id = ANY(p_machine_ids))
      AND prp.action    = 'REFILL'
      AND (prp.reasoning->>'signal')        IN ('STAR','DOUBLE DOWN','KEEP GROWING','KEEP')
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

  IF v_m2w_suppressed_n > 0 THEN
    v_capacity_warnings   := v_capacity_warnings || v_m2w_suppressed;
    v_capacity_warning_n  := v_capacity_warning_n + v_m2w_suppressed_n;
  END IF;

  RETURN jsonb_build_object(
    'plan_date', p_plan_date, 'rows_finalized', v_inserted,
    'refills_in', v_refills_in, 'swaps_in', v_swaps_in,
    'r4_overruled_refills', v_overruled,
    'r7_machines_over_60pct', v_shelf_cap_hit,
    'empty_shelf_after_removal_flagged', v_empty_shelf_flag,
    'capacity_mismatch_warnings_count', v_capacity_warning_n,
    'capacity_mismatch_warnings', v_capacity_warnings,
    'm2w_no_replacement_warnings_count', v_m2w_suppressed_n,
    'm2w_no_replacement_warnings', v_m2w_suppressed,
    'engine_version', 'v14_preserve_approved',
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;
