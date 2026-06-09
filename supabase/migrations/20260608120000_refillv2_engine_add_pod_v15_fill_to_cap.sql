-- ============================================================================
-- PRD-REFILL-V2 · Item 1 · engine_add_pod  v14 -> v15  "fill-to-capacity"
-- ============================================================================
-- CORE PRINCIPLE: quantity is DECOUPLED from score. compute_refill_decision is
-- still called, but its target_units / refill_qty NO LONGER cap the fill.
-- final_score / velocity are used for RANKING only (WH scarcity allocation order).
--
-- CHANGES vs v14 (diff-gate summary):
--   1. FILL FORMULA. v14: final_qty = LEAST( GREATEST(u_refill_qty, driver_req),
--      max_stock-current_stock )  -- velocity-capped via compute_refill_decision.
--      v15: need_raw = GREATEST( max_stock-current_stock, driver_req );
--      capped ONLY by the warehouse pool (see #3). Velocity never caps fill.
--   2. DEAD detection + tag (REVISED CS 2026-06-08). Dead = GENUINELY no sales
--      (velocity_7d = 0 AND velocity_30d = 0) -> final_qty = 0 AND a swap-candidate tag
--      to public.pod_swaps. Lifecycle stance does NOT gate refill (CS distrusts it); a
--      selling shelf ALWAYS fills. Item 2 swaps a performer into the dead slot so it
--      never stays empty.
--   3. SHARED-WH scarcity throttle (the ONLY throttle). When the warehouse pool for
--      a pod_product is smaller than the sum of competing shelves' need, units are
--      allocated to the best shelves first (velocity_30d DESC, final_score DESC);
--      losers fall to 0 / partial and emit a procurement_gap. Implemented as a
--      window (prior_need) over PARTITION BY pod_product_id.
--   4. procurement_gap output shape preserved (machine/shelf/product/.../gap_units).
--   5. KEPT verbatim: GUCs app.via_rpc / app.rpc_name, operator_admin role gate,
--      _assert_gate_zero, strategic_intents blocking, driver_feedback resolution,
--      capacity clamp, decision jsonb in reasoning, max_stock resolution (weimi live).
--
-- DARA NOTE (schema): the swap-candidate tag goes to public.pod_swaps (NOT
--   planned_swaps: that table is a name-based, CS-curated forward queue with a
--   different lifecycle). pod_swaps is already plan_date-scoped, id-based, and is
--   the exact table engine_swap_pod (Item 2) reads -> clean same-day engine->engine
--   handoff, no new table (Article 14).
--   *** PRD DEVIATION (CS please confirm) *** The PRD asked for reason
--   ='dead_tagged_by_add', but pod_swaps has CHECK reason IN
--   ('rotate_out','dead','wind_down','m2w','intent_driven'). 'dead_tagged_by_add'
--   is PROVENANCE, not a reason. v15 therefore writes reason = 'rotate_out' (for
--   ROTATE OUT stance) else 'dead', leaves pod_product_id_in NULL (= awaiting
--   swap-in), and records reasoning->>'tagged_by' = 'engine_add_pod_v15'. The swap
--   engine handoff keys on (pod_product_id_in IS NULL AND tagged_by). This avoids a
--   DDL ALTER on the protected pod_swaps.reason constraint. If you would rather add
--   the literal 'dead_tagged_by_add' value, say so and I will ship a one-line
--   constraint ALTER instead.
--
-- WIND DOWN (CS decision 2026-06-08): NOT drained. A WIND DOWN shelf that still sells
--   fills to capacity like any seller. The is_drain branch is retired (always false).
--   Lifecycle stance is out of the refill decision entirely.
--
-- DRY-RUN PROOF (plan_date 2026-06-09, 30 picked machines):
--   * AC1 unchanged: every selling shelf the WH can fill reaches capacity; all
--     shortfalls are WH-limited, never engine-limited -> procurement_gap.
--   * AC2 REVISED (sales-based dead): dead drops 137 -> ~50 (v7=0 AND v30=0). The 42
--     lifecycle-false-deads and the 61 selling WIND DOWN shelves now FILL instead of
--     being starved (~103 sellers recovered). Re-confirm on a fresh plan_date.
--
-- GOVERNANCE: canonical writer -> diff-gated, CS green light required before apply.
--   Articles 1, 4, 5, 8, 12, 14. Forward-only. No warehouse_inventory.status write.
-- ============================================================================

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
  -- idempotent: clear ALL of THIS engine's own dead tags for the date — resolved or not.
  -- (REFILL-V2 fix 2026-06-08 scenario: a re-run after swap previously collided on
  -- uq_pod_swaps_slot because swap-resolved tags (pod_product_id_in set) survived the
  -- cleanup. add owns these shelf-tags and regenerates them; swap re-runs after add.)
  DELETE FROM public.pod_swaps
   WHERE plan_date = p_plan_date
     AND reasoning->>'tagged_by' = 'engine_add_pod_v15';

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
    -- compute_refill_decision RETAINED for stance / final_score / velocity (RANKING
    -- + reasoning only). u_target_units / u_refill_qty are NOT used to cap fill.
    SELECT c.*,
      d.decision,
      (d.decision->>'stance')                                 AS u_stance,
      (d.decision->>'cover_mult')::numeric                    AS u_cover_mult,
      (d.decision->>'floor_pct')::numeric                     AS u_floor_pct,
      (d.decision->>'velocity')::numeric                      AS u_velocity,
      (d.decision->>'target_units')::int                      AS u_target_units,
      (d.decision->>'refill_qty')::int                        AS u_refill_qty,
      (d.decision->>'runway_days')::numeric                   AS u_runway_days,
      (d.decision->>'final_score')::numeric                   AS u_final_score
    FROM candidates_with_machine_velocity c
    CROSS JOIN LATERAL (
      SELECT public.compute_refill_decision(c.machine_id, c.shelf_id, NULL::uuid, 10) AS decision
    ) d
  ),
  flagged AS (
    SELECT dc.*,
      -- REFILL-V2 dead test (CS 2026-06-08): dead = GENUINELY no sales (7d AND 30d).
      -- The lifecycle stance (DEAD/ROTATE OUT/WIND DOWN) no longer gates refill — CS
      -- distrusts it, and on 2026-06-09 it falsely tagged 42 selling shelves dead and
      -- drained 61 selling WIND DOWN shelves (~103 sellers starved). A shelf that sells
      -- ALWAYS fills to capacity; only true no-sellers are tagged for swap (Item 2 fills
      -- them with a performer, so they never stay empty). is_drain retired (always false).
      (dc.v7 = 0 AND dc.v30 = 0) AS is_dead,
      false                      AS is_drain,
      GREATEST(dc.max_stock - dc.current_stock, 0)                           AS fill_to_cap,
      GREATEST(GREATEST(dc.max_stock - dc.current_stock, 0), COALESCE(dc.driver_req_qty,0)) AS need_raw
    FROM decided dc
  ),
  allocated AS (
    -- Shared-WH scarcity throttle: how many units of this pod_product's warehouse
    -- pool are already claimed by higher-priority shelves (best sellers first).
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
        WHEN COALESCE(a.driver_req_qty,0) > a.fill_to_cap                  THEN 'driver_request'
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
        'engine_calibration', 'refillv2_v15_fill_to_cap',
        'decision',         f.decision
      )
    FROM final f
    WHERE f.final_qty > 0
    RETURNING 1
  ),
  dead_tags AS (
    INSERT INTO public.pod_swaps(
      plan_date, machine_id, shelf_id, pod_product_id_out, qty_out, reason, reasoning)
    SELECT p_plan_date, f.machine_id, f.shelf_id, f.pod_product_id,
      GREATEST(f.current_stock, 1),  -- qty_out CHECK (> 0); pull whatever is on the shelf
      CASE WHEN f.u_stance = 'ROTATE OUT' THEN 'rotate_out' ELSE 'dead' END,
      jsonb_build_object(
        'shelf_code',    f.shelf_code,
        'official_name', f.official_name,
        'stance',        f.u_stance,
        'velocity_30d',  f.v30,
        'current_stock', f.current_stock,
        'reason_detail', 'no_sales_7d_30d',
        'tagged_by',     'engine_add_pod_v15'
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
         (SELECT COUNT(*) FROM dead_tags),
    COALESCE(jsonb_agg(jsonb_build_object(
      'machine', gap_rows.official_name, 'shelf', gap_rows.shelf_code,
      'product', gap_rows.pod_product_name, 'signal', gap_rows.signal,
      'velocity_30d', gap_rows.v30, 'current_stock', gap_rows.current_stock,
      'max_stock', gap_rows.max_stock, 'target_signal', gap_rows.target_stock,
      'gap_units', gap_rows.gap_units, 'runway_days', gap_rows.runway_days
    ) ORDER BY gap_rows.gap_units DESC) FILTER (WHERE gap_rows.gap_units > 0), '[]'::jsonb)
  INTO v_refills, v_dead_tags, v_procurement_gaps FROM gap_rows;

  UPDATE public.driver_feedback df
     SET resolved = true, resolved_at = now(), resolved_by_engine = 'engine_add_pod_v15'
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
    'dead_tags_written', v_dead_tags,
    'skipped_strategic_intent', v_skipped_intent,
    'procurement_gaps_count', jsonb_array_length(v_procurement_gaps),
    'procurement_gaps', v_procurement_gaps,
    'engine_version', 'v15_fill_to_cap',
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;
