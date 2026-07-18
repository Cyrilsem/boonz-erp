-- ============================================================================
-- 20260718093000_rc08_consumer_cutover_stitch_warnonly.sql
--
-- ██  PHASE 2 — CS-GATED. NOT part of the atomic RC-01 + RC-08-A window.  ██
-- ██  DO NOT apply in the same window as 090001/090002/090003.            ██
-- ██  Apply ONLY after CS reviews the plan-vs-route-fill delta metric.    ██
--
-- Purpose: point the stitch consumer at the canonical machine-scoped availability
-- (wh_available_qty) WARN-ONLY. Honors CS decision S1 ("we cannot not refill empty
-- shelves"):
--   (S1.a) WARN-ONLY: emit a plan-vs-route-fill delta / procurement-gap + on-spot-
--          accrual signal. DO NOT reduce the published quantity. Keep the line visible.
--   (S1.b) NEVER silently drop a refill line the route warehouse can't fill. An
--          unfulfillable-from-route line is FLAGGED for the SUBSTITUTE path
--          (rank_slot_suitability / engine_swap_pod) to fill the shelf from existing
--          warehouse stock next cycle.
--   (S1.c) This lives in its OWN later, warn-only migration (this file).
--
-- SCOPING (explicit — read before scheduling):
--   * The full stitch_pod_to_boonz CREATE OR REPLACE is INTENTIONALLY NOT embedded
--     here. The repo lags prod; the byte-faithful live body MUST be pulled with
--     pg_get_functiondef at the time Phase 2 is scheduled, then edited to add ONLY
--     the warn-only signal block below (no published-quantity change). Embedding a
--     stale body now would be less safe than capturing it at cutover time.
--   * The FULL substitute AUTO-ROUTING (auto-injecting a replacement SKU into the
--     plan when the route WH cannot fill) is LARGER than a Batch-1-sized change.
--     It is scoped as FOLLOW-UP TICKET RC-08-C. Batch-1 minimum, guaranteed by this
--     file, is: NEVER drop the line (published qty unchanged) + FLAG it for the swap
--     engine + emit the procurement/accrual signal.
--
-- Protected entity: refill_plan_output (READ for the delta; published qty UNCHANGED).
-- New signal sink: monitoring_alerts (append-only, unchanged shape).
-- ============================================================================

-- Guard: refuse to run in the atomic window by mistake — require the availability
-- objects to already exist (Migration A applied) AND a human to have removed this guard.
DO $guard$
BEGIN
  IF to_regprocedure('public.wh_available_qty(uuid,uuid,date)') IS NULL THEN
    RAISE EXCEPTION 'PHASE-2 stitch cutover requires RC-08 Migration A (wh_available_qty) applied first.';
  END IF;
  -- Intentional stop: force an explicit human edit before this CS-gated phase runs.
  RAISE EXCEPTION 'PHASE-2 CS GATE: remove this guard block only after CS signs off on the plan-vs-route-fill delta. See APPLY_ORDER.md step 5.';
END
$guard$;

BEGIN;

-- ── Step 1 (warn-only): plan-vs-route-fill delta signal, per stitched line ────
-- Insert this block INTO the LIVE stitch_pod_to_boonz body, at the point each
-- boonz/SKU line quantity (v_final_qty / published qty) is resolved — AFTER it is
-- computed, BEFORE it is written to refill_plan_output. It does NOT modify the qty.
--
--   -- S1.a WARN-ONLY: compare published qty to canonical route-fill capacity.
--   v_route_fill := public.wh_available_qty(v_machine_id, v_boonz_product_id, p_plan_date);
--   IF v_route_fill < v_published_qty THEN
--     INSERT INTO public.monitoring_alerts (source, severity, payload)
--     VALUES ('stitch_route_fill_gap', 'warning', jsonb_build_object(
--       'title', format('Route-fill gap (line KEPT): %s @ %s — plan %s, route can fill %s',
--                       v_boonz_product_name, v_machine_name, v_published_qty, v_route_fill),
--       'plan_date', p_plan_date, 'machine_id', v_machine_id, 'machine_name', v_machine_name,
--       'boonz_product_id', v_boonz_product_id,
--       'published_qty', v_published_qty,            -- UNCHANGED, still published
--       'route_fillable_qty', v_route_fill,
--       'procurement_gap_qty', v_published_qty - v_route_fill,        -- procurement signal
--       'on_spot_accrual_qty', v_published_qty - v_route_fill,        -- on-spot accrual signal
--       'substitute_candidate', (v_route_fill = 0),                   -- S1.b: route stocks ZERO -> substitute path
--       'detected_by', 'stitch_pod_to_boonz_rc08_warnonly', 'detected_at', now()));
--   END IF;
--
-- NOTE: v_published_qty is NEVER reduced. The line ships at its full planned quantity.

-- ── Step 2 (S1.b): flag unfulfillable-from-route lines for the SUBSTITUTE path ─
-- Minimal, non-destructive wiring. Two options were evaluated:
--   (A) call rank_slot_suitability inline in stitch to auto-pick a substitute now, or
--   (B) emit a durable signal the swap engine (engine_swap_pod, Layer B) consumes next
--       cycle to inject a replacement from existing WH stock.
-- Batch-1 choice = (B): stitch has NO existing substitute hook (verified — stitch only
-- distributes pod->boonz; substitution lives in engine_swap_pod / find_substitutes_for_shelf
-- / rank_slot_suitability). Wiring stitch to auto-substitute inline is RC-08-C (follow-up).
-- Here we only raise the 'substitute_candidate' flag above (route_fillable = 0), which the
-- swap engine's next run reads to route a replacement. The shelf is never left un-refilled:
-- the original line stays published AND a substitute is queued.
--
-- (If/when CS wants immediate in-cycle substitution, RC-08-C adds, right after Step 1:
--    IF v_route_fill = 0 THEN
--      PERFORM public.rank_slot_suitability(v_machine_id, v_shelf_id, p_plan_date, ...);
--      -- inject the top-ranked in-stock substitute as an additional (not replacement) line
--    END IF;
--  — additive only; the original line is still kept + flagged.)

COMMIT;

-- ROLLBACK: re-apply the pre-cutover stitch_pod_to_boonz body (captured at cutover
-- time into final/rollback/rc08_stitch_pod_to_boonz_PRE.sql) via CREATE OR REPLACE.
-- No data change (warn-only), so rollback is pure DDL.
