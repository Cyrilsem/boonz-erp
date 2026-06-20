-- PRD-040 B3 part 2: engine_swap_pod V() consumes the canonical landed cost.
-- Forward-only. Value-model-affecting (changes which products win swaps). swaps_enabled stays false.
-- engine_add_pod UNTOUCHED (PRD-035 made ADD qty stance-free/velocity-driven; it does not consume margin),
-- so T12 (ADD byte-identical) holds with NO re-baseline. No parallel _v14 function (evolves canonical engine_swap_pod).
--
-- Cost type note: B3-part1's v_product_landed_cost.landed_cost is double precision (percentile_cont returns
-- float8), which would break engine round(v_cand,2). CREATE OR REPLACE VIEW cannot change an existing column's
-- type, and the view has no consumer but this engine, so rather than DROP+CREATE the view we cast
-- lc.landed_cost::numeric at the read site. (A future view-numeric pass would DROP+CREATE.)
--
-- engine_swap_pod V(): replace the inline `price - boonz_products.avg_30days_cost` margin (incumbent KEEP cap +
-- candidate margin) with `price - v_product_landed_cost.landed_cost::numeric`. Surgical DO-block (fetch live def,
-- 2 regexp_replace, bump v13->v14, guard avg_30days_cost gone, EXECUTE) - same pattern as B4, avoids 400-line
-- transcription.
--
-- REPLAY (BEGIN..ROLLBACK, swaps forced true, plan_date 2026-06-21, baseline v13 vs landed v14): same swap count
-- 10=10; 7 swaps changed (intended value-model delta from closing the 90/307 cost gaps via 4-source coalesce +
-- category-median impute); all guardrails hold: A1 uniqueness=1, R1 TCCC leak=0, R1 coexistence leak=0, R1 rate<=2,
-- H1 homogenisation<=3 (U/C/A/H + R1 + PRD-037 T1-T13 are cost-independent structural invariants; only V ranking
-- shifts). engine_add_pod v18 untouched (T12).

DO $do$
DECLARE v text;
BEGIN
  SELECT pg_get_functiondef('public.engine_swap_pod(date,integer,numeric,integer)'::regprocedure) INTO v;
  -- incumbent KEEP cap margin
  v := regexp_replace(v,
    '\(SELECT bp\.avg_30days_cost FROM public\.boonz_products bp WHERE bp\.product_id = k\.inc_boonz\)',
    '(SELECT lc.landed_cost::numeric FROM public.v_product_landed_cost lc WHERE lc.boonz_product_id = k.inc_boonz)', 'g');
  -- candidate margin
  v := regexp_replace(v,
    'COALESCE\(bp\.avg_30days_cost,0\)',
    'COALESCE((SELECT lc.landed_cost::numeric FROM public.v_product_landed_cost lc WHERE lc.boonz_product_id=w.boonz),0)', 'g');
  v := replace(v, 'v13_value_model_broad', 'v14_landed_cost_margin');
  IF v ILIKE '%avg_30days_cost%' THEN
    RAISE EXCEPTION 'PRD-040 B3-p2: avg_30days_cost still present after rewrite (engine body drifted).';
  END IF;
  EXECUTE v;
END $do$;
