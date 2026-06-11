-- PRD-UNIFY Step 3 (refill-brain) — CALIBRATE engine_add_pod to the unified dials + emit the decision.
--
-- ⚠️ HARD RULE 10: engine_add_pod is a CORE canonical writer. This is its SECOND rewrite — it needs CS
-- green light + this diff review BEFORE apply. APPLY NOTHING. This file is for CS review.
--
-- PRD-UNIFY-CAL (2026-06-06): the LATERAL sizing call now passes the calibrated days_cover = 10 (was
-- p_days_cover, engine default 14) to compute_refill_decision, and the visual_floor clamp heuristic uses
-- 10 to match. compute_refill_decision's dials are already locked (days_cover 10, KEEP 0.70, RAMPING 0.60
-- — applied). The delta on plan 2026-06-05 (129 REFILL/ADD rows): total 375 -> 316, KEEP -26, drains 0 —
-- the validated Tuned profile. STILL HELD: applying this delegates sizing fleet-wide (every shelf's qty
-- now comes from compute_refill_decision, not v13's inline math), so per Cody §(a)/Hard Rule 10 it needs
-- CS green light. The 375->316 by-stance table IS the per-row delta CS signs off on.
--
-- ============================ DIFF vs LIVE (v13_driver_feedback_demand) ============================
-- This is a CALIBRATION, not a rebuild. The orchestration is byte-identical: role/GUC guard, DELETE
-- pod_refills, picked-machines gate, _assert_gate_zero, shelf_state, candidates (joins, wh_avail,
-- driver_req, blocking_intents), the wh-clamp, driver_request floor, strategic-intent skip, the INSERT
-- into pod_refills, driver_feedback resolve, and the return shape — ALL UNCHANGED.
--
-- ONLY these change (dials + decision emission):
--   1. candidates: + v7 (slot_lifecycle.velocity_7d) alongside the existing v30.   [for the dosage blend]
--   2. The per-signal sizing CTEs `sized` / `with_floor` / `clamped` qty math are REPLACED by a single
--      LATERAL call to public.compute_refill_decision(machine_id, shelf_id, NULL, p_days_cover) — so the
--      engine's qty and the card's number are literally the SAME function (Article 1 / E8: one brain).
--      • velocity 0.6·v7+0.4·v30 (was v30 only)
--      • cover_mult/floor_pct = the PRD dials table (was: STAR/DD 2.0/1.5 cover + separate 0.50 visual_floor)
--      • WIND DOWN/ROTATE OUT/DEAD now DRAIN: target ≤ current → refill 0 (was: WIND DOWN refilled UP to
--        v30·days_cover — the Rice Cake bug this PRD exists to fix; A2)
--   3. pod_refills.reasoning now carries the full `decision` jsonb (incl final_score) under key 'decision'
--      so engine_finalize_pod can propagate it to pod_refill_plan.decision (follow-up patch, below).
--
-- The wh_avail clamp, driver_request floor (GREATEST(refill, driver_req)), blocking-intent → 0, and the
-- capacity clamp are PRESERVED — they wrap the decision's refill_qty exactly as they wrapped the old
-- velocity math. clamp_reason is preserved and extended with a 'decision' reason.
--
-- compute_refill_decision is SECURITY INVOKER; called from this SECURITY DEFINER writer it runs in the
-- writer-owner context (read-only; no privilege escalation). It does not need p_boonz_product_id (it
-- resolves the pod from the shelf), so the engine passes NULL.
--
-- CODY verdict (engine change): ⚠️ Approve PENDING CS GREEN LIGHT (Hard Rule 10) + this diff.
--   Article 1 — sizing now has ONE authority (compute_refill_decision); the engine consumes it. ✅
--   Article 4 — GUCs (app.via_rpc/app.rpc_name), operator_admin gate, input validation all PRESERVED. ✅
--   Article 8 — pod_refills audited by tg_audit (unchanged); decision rides in reasoning. ✅
--   Article 12 — forward-only CREATE OR REPLACE; identity signature (date,int) unchanged. ✅
--   Article 14 — no parallel table. ✅
-- ====================================================================================================

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
      COALESCE(sl.velocity_7d, 0)::numeric                    AS v7,   -- CALIBRATION: + v7 for the dosage blend
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
  -- CALIBRATION: sizing delegated to the single source of truth. One LATERAL call per shelf.
  decided AS (
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
      -- PRD-UNIFY-CAL: size at the calibrated days_cover = 10 (delta-validated; total 375->316, drains 0).
      SELECT public.compute_refill_decision(c.machine_id, c.shelf_id, NULL::uuid, 10) AS decision
    ) d
  ),
  clamped AS (
    SELECT dc.*,
      -- raw demand = the unified decision's refill, floored by an explicit driver request (preserved)
      GREATEST(COALESCE(dc.u_refill_qty,0), COALESCE(dc.driver_req_qty,0)) AS raw_qty,
      CASE WHEN dc.wh_avail = 0 THEN 0
           WHEN dc.blocking_intent_id IS NOT NULL THEN 0
        ELSE LEAST(
          GREATEST(COALESCE(dc.u_refill_qty,0), COALESCE(dc.driver_req_qty,0)),
          GREATEST(dc.max_stock - dc.current_stock, 0)
        )
      END::int AS final_qty,
      CASE
        WHEN dc.blocking_intent_id IS NOT NULL                                          THEN 'skipped_strategic_intent'
        WHEN dc.wh_avail = 0                                                            THEN 'blocked_no_wh'
        WHEN COALESCE(dc.driver_req_qty,0) > 0 AND COALESCE(dc.driver_req_qty,0) >= COALESCE(dc.u_refill_qty,0) THEN 'driver_request'
        WHEN dc.u_stance IN ('WIND DOWN','ROTATE OUT','DEAD') AND COALESCE(dc.u_refill_qty,0) = 0 THEN 'drain_no_refill'
        WHEN COALESCE(dc.u_refill_qty,0) = 0                                            THEN 'skipped_no_demand'
        WHEN dc.current_stock >= dc.max_stock AND dc.max_stock > 0                      THEN 'skipped_full'
        WHEN COALESCE(dc.u_refill_qty,0) > (dc.max_stock - dc.current_stock)            THEN 'capped_by_max'
        WHEN (dc.u_velocity * 10 * dc.u_cover_mult) < (dc.u_floor_pct * dc.max_stock) THEN 'visual_floor'
        ELSE 'velocity_target'
      END AS clamp_reason
    FROM decided dc
  ),
  inserted AS (
    INSERT INTO public.pod_refills(
      plan_date, machine_id, shelf_id, pod_product_id,
      qty, current_stock, max_stock, velocity_30d, days_cover, signal,
      wh_available_pod, clamp_reason, reasoning)
    SELECT p_plan_date, c.machine_id, c.shelf_id, c.pod_product_id,
      c.final_qty, c.current_stock, c.max_stock, c.v30, p_days_cover, c.signal,
      c.wh_avail, c.clamp_reason,
      jsonb_build_object(
        'shelf_code',       c.shelf_code,
        'official_name',    c.official_name,
        'raw_qty',          c.raw_qty,
        'driver_req_qty',   c.driver_req_qty,
        'target_stock',     c.u_target_units,
        'runway_days',      c.u_runway_days,
        'stance',           c.u_stance,
        'cover_mult',       c.u_cover_mult,
        'floor_pct',        c.u_floor_pct,
        'velocity_blend',   c.u_velocity,
        'final_score',      c.u_final_score,
        'machine_daily_velocity', c.machine_daily_velocity,
        'wh_avail',         c.wh_avail,
        'wh_warning',       CASE WHEN c.wh_avail < c.final_qty THEN true ELSE false END,
        'max_stock_source', 'weimi_live_v5',
        'engine_calibration', 'prd_unify_v14',
        'decision',         c.decision   -- PRD-UNIFY: full decision rides here for finalize -> pod_refill_plan.decision
      )
    FROM clamped c
    WHERE c.final_qty > 0 AND c.clamp_reason <> 'skipped_strategic_intent'
    RETURNING 1
  ),
  gap_rows AS (
    SELECT c.official_name, c.shelf_code, c.pod_product_name, c.signal,
      c.v30::numeric(6,2) AS v30, c.current_stock, c.max_stock, c.u_target_units AS target_stock,
      (c.u_target_units - c.current_stock) AS gap_units, c.u_runway_days AS runway_days
    FROM clamped c
    WHERE c.wh_avail = 0 AND c.u_velocity > 0 AND c.current_stock < c.u_target_units
      AND c.blocking_intent_id IS NULL
  )
  SELECT (SELECT COUNT(*) FROM inserted),
    COALESCE(jsonb_agg(jsonb_build_object(
      'machine', gap_rows.official_name, 'shelf', gap_rows.shelf_code,
      'product', gap_rows.pod_product_name, 'signal', gap_rows.signal,
      'velocity_30d', gap_rows.v30, 'current_stock', gap_rows.current_stock,
      'max_stock', gap_rows.max_stock, 'target_signal', gap_rows.target_stock,
      'gap_units', gap_rows.gap_units, 'runway_days', gap_rows.runway_days
    ) ORDER BY gap_rows.gap_units DESC), '[]'::jsonb)
  INTO v_refills, v_procurement_gaps FROM gap_rows;

  UPDATE public.driver_feedback df
     SET resolved = true, resolved_at = now(), resolved_by_engine = 'engine_add_pod_v14'
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
    'skipped_strategic_intent', v_skipped_intent,
    'procurement_gaps_count', jsonb_array_length(v_procurement_gaps),
    'procurement_gaps', v_procurement_gaps,
    'engine_version', 'v14_prd_unify_decision',
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;

-- -------------------------------------------------------------------------------------------------
-- FOLLOW-UP PATCH (same Step 3 intent) — engine_finalize_pod: carry the decision to pod_refill_plan.
-- Two surgical edits to the live engine_finalize_pod(date, uuid[]) body (NOT reproduced here in full to
-- avoid transcribing 200 unrelated lines — fetch the live def, apply these two changes, CREATE OR REPLACE):
--   (1) In CTE `refill_lines`, add to its reasoning jsonb:  'decision', pr.reasoning->'decision'
--       and to the SELECT list add:  (pr.reasoning->'decision') AS decision
--   (2) In `unioned` add a `decision jsonb` column (NULL for swap_* lines, pr.reasoning->'decision' for
--       refill_lines) and in the final INSERT INTO public.pod_refill_plan add the `decision` column +
--       `decision = EXCLUDED.decision` in the ON CONFLICT DO UPDATE SET.
-- NOTE: NOT strictly required for the card (Step 4's reader calls compute_refill_decision live, so the
-- card already shows the unified number). This patch makes the PERSISTED pod_refill_plan.decision match,
-- satisfying A1 for committed drafts + the diff/audit trail. Cody: Articles 1, 8, 12 — additive.
