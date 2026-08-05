-- PRD-110 leg 117 - STEP 7 / S6: blocked_demand volume, procurement view + aging correct.
--
-- WHAT S6 MUST PROVE (goal command STEP 7): "blocked_demand volume: 500 open rows -
-- procurement view + aging correct."
--
-- ── WHY THIS IS A ROLLBACK PROBE AND NOT A RESERVED-DATE PLANT ────────────────────────────
-- The leg-116 STEP-7 design reserved 2030-11-06 for S6 and then correctly killed its own
-- reservation. Re-derived live this leg from pg_get_viewdef rather than inherited (LAW 13):
--
--   v_blocked_demand_open ... WHERE bd.resolved_at IS NULL AND bd.plan_date < '2030-01-01'
--
-- The view DELIBERATELY excludes the whole synthetic 2030 band - that guard is what keeps every
-- fixture's synthetic blocked rows out of the live procurement worklist. Planting 500 rows on
-- 2030-11-06 therefore yields ZERO view rows and S6 passes VACUOUSLY (the S-132 sin).
-- ⛔ The fix is NOT to relax the 2030 guard. S6 plants on REAL dates inside a rolled-back
-- subtransaction (the fixture-31 / fixture-8 idiom, now proven five times). Nothing persists.
--
-- ── THE CONSTRAINT THE DESIGN DID NOT HAVE, AND IT SHAPES THE WHOLE PLANT ──────────────────
--   uq_blocked_demand_open UNIQUE (plan_date, machine_id, shelf_id, pod_product_id, source)
--                          WHERE resolved_at IS NULL
-- 500 open rows must therefore be 500 DISTINCT key tuples. The plant sources 500 distinct
-- (machine_id, shelf_id, pod_product_id) triples from shelf_configurations x slot_lifecycle
-- (1369 available, measured) and holds source constant, so distinctness is structural rather
-- than hoped for. It ALSO anti-joins live open rows on the exact unique key, so the probe can
-- never collide with production no matter what date it runs on.
--
-- ── AGING: RE-DERIVED, NOT ASSUMED ────────────────────────────────────────────────────────
-- age_bucket is computed off plan_date, NOT created_at:
--   CURRENT_DATE - bd.plan_date, bucketed >=14 critical / >=7 aging / >=3 watch / else fresh.
-- So the plant controls the bucket by choosing plan_date OFFSETS FROM CURRENT_DATE. Offsets,
-- never absolute dates: an absolute date would make this assertion true only on the day it was
-- written, which is exactly the S-200 class (anchored to a moment, not to an invariant).
-- The offset array pins BOTH SIDES of all three edges - 2/3, 6/7, 13/14 - because an edge test
-- that only samples one side proves nothing about where the boundary actually sits.
-- ⛔ Offset 5 is deliberately ABSENT: the 20 live open rows sit at CURRENT_DATE - 5 today
-- (2026-07-30). The anti-join already makes collision impossible; omitting 5 means the probe
-- does not even contend for the index entry.
--
-- ── WHAT "PROCUREMENT VIEW" MEANS HERE, CORRECTED ─────────────────────────────────────────
-- ⛔ v_procurement_blocked_products is NOT the blocked_demand consumer. Read live: it selects
-- from boonz_products WHERE boonz_product_block_reason(product_id) IS NOT NULL and never
-- references blocked_demand at all - a product-level block-reason report with a confusingly
-- similar name. Asserting over it would prove nothing about blocked demand. The consumer is
-- v_blocked_demand_open plus the weekly-procurement skill that reads it.
--
-- ── DRY-PROVEN BEFORE THIS FILE WAS WRITTEN (leg 117, full 500-row probe) ──────────────────
--   inserted 500 · planted_tbl 500 · view_planted 500 · view_planted_d 500 (NO FAN-OUT)
--   view_total 520 = 500 planted + 20 pre-existing · buckets fresh 80 / watch 97 / aging 171 /
--   critical 152 (sum 500 exactly) · bucket_mismatch 0 · age_days_mismatch 0
--   edges 2->[fresh] 3->[watch] 6->[watch] 7->[aging] 13->[aging] 14->[critical], all n>=38
--   leak_2030 0 · before 44 -> after 44 · residue 0.
--
-- ── SAFETY ────────────────────────────────────────────────────────────────────────────────
--   a. The plant lives in a plpgsql subtransaction that ALWAYS ends in RAISE, so it is rolled
--      back on the success path and on every error path alike. There is no path that commits it.
--   b. plpgsql VARIABLES survive a subtransaction rollback; DB rows do not. That is the whole
--      mechanism - the metric is read out of variables after the rows are gone.
--   c. blocked_demand's only trigger is tg_audit_blocked_demand (audit_log_write) - a plain
--      AFTER-row INSERT into write_audit_log, so its 500 audit rows roll back too. Verified from
--      pg_get_triggerdef; there is no write-guard trigger to satisfy and none is bypassed.
--   d. assert_residue re-counts blocked_demand after the rollback and the function RAISES if a
--      single row survived. A silent half-rollback cannot read as a pass.
--   e. record_blocked_demand_v3 is the table's only deleter (delete-then-insert per
--      (plan_date, source)). It is never called here, and inside the probe it could not bite.
--
-- NOT touched: warehouse_inventory, pod_inventory, refill_plan_output, pod_refill_plan,
-- machines_to_visit, any RPC, any flag, any cron. No fixture and no assertion is added or
-- changed - S1-S6 stay OUT of golden.fixtures on purpose (adding them would make S7 measure
-- itself and push the sweep past the transport ceiling).

CREATE OR REPLACE FUNCTION golden.stress_s6_v1(
  p_n      integer DEFAULT 500,
  p_record boolean DEFAULT true,
  p_note   text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path = golden, public, pg_temp
AS $fn$
DECLARE
  v_started  timestamptz := clock_timestamp();
  v_before   bigint;
  v_after    bigint;
  v_residue  bigint;
  v_metric   jsonb;
  v_ins      int;
  v_pass     int := 0;
  v_fail     int := 0;
  v_fails    text[] := ARRAY[]::text[];
  v_ok       boolean;
  -- both sides of every edge: 2/3 (fresh|watch), 6/7 (watch|aging), 13/14 (aging|critical)
  v_offs     int[] := ARRAY[0,1,2,2,3,3,4,6,6,7,7,8,9,10,11,12,13,13,14,14,15,16,17,18,19,20];
  v_edges    jsonb;
  v_run      uuid;

  PROCEDURE_MARKER constant text := 'golden.stress_s6_v1';
BEGIN
  IF p_n IS NULL OR p_n < 1 THEN
    RAISE EXCEPTION 'golden.stress_s6_v1: p_n must be >= 1 (got %)', p_n;
  END IF;

  SELECT count(*) INTO v_before FROM public.blocked_demand;

  -- ── PLANT + MEASURE, inside a subtransaction that is always rolled back ─────────────────
  BEGIN
    WITH triples AS (
      SELECT sc.machine_id, sc.shelf_id, sl.pod_product_id,
             row_number() OVER (ORDER BY sc.shelf_id, sl.pod_product_id) AS rn
        FROM public.shelf_configurations sc
        JOIN public.slot_lifecycle    sl ON sl.shelf_id       = sc.shelf_id
        JOIN public.machines           m ON m.machine_id      = sc.machine_id
        JOIN public.pod_products      pp ON pp.pod_product_id = sl.pod_product_id
       WHERE sl.pod_product_id IS NOT NULL
       GROUP BY sc.machine_id, sc.shelf_id, sl.pod_product_id
    ), cand AS (
      SELECT t.*, v_offs[1 + ((t.rn - 1) % array_length(v_offs,1))] AS off
        FROM triples t
    ), filtered AS (
      SELECT c.*, (CURRENT_DATE - c.off) AS pdate,
             row_number() OVER (ORDER BY c.rn) AS k
        FROM cand c
       WHERE NOT EXISTS (                      -- can never collide with a live open row
               SELECT 1 FROM public.blocked_demand b
                WHERE b.resolved_at IS NULL
                  AND b.plan_date      = CURRENT_DATE - c.off
                  AND b.machine_id     = c.machine_id
                  AND b.shelf_id       = c.shelf_id
                  AND b.pod_product_id = c.pod_product_id
                  AND b.source         = 'engine_add')
    )
    INSERT INTO public.blocked_demand
      (plan_date, machine_id, shelf_id, pod_product_id, qty_blocked, reason, source, detected_by, reasoning)
    SELECT f.pdate, f.machine_id, f.shelf_id, f.pod_product_id,
           1 + (f.k % 9), 'blocked_no_wh', 'engine_add', PROCEDURE_MARKER,
           jsonb_build_object('probe','S6','off',f.off)
      FROM filtered f
     WHERE f.k <= p_n;
    GET DIAGNOSTICS v_ins = ROW_COUNT;

    SELECT jsonb_build_object(
      'n_requested',      p_n,
      'inserted',         v_ins,
      'planted_tbl',      (SELECT count(*) FROM public.blocked_demand WHERE detected_by = PROCEDURE_MARKER),
      'view_planted',     (SELECT count(*) FROM public.v_blocked_demand_open v
                             JOIN public.blocked_demand b ON b.blocked_demand_id = v.blocked_demand_id
                            WHERE b.detected_by = PROCEDURE_MARKER),
      'view_planted_d',   (SELECT count(DISTINCT v.blocked_demand_id) FROM public.v_blocked_demand_open v
                             JOIN public.blocked_demand b ON b.blocked_demand_id = v.blocked_demand_id
                            WHERE b.detected_by = PROCEDURE_MARKER),
      'view_total',       (SELECT count(*) FROM public.v_blocked_demand_open),
      'preexisting',      (SELECT count(*) FROM public.v_blocked_demand_open v
                             JOIN public.blocked_demand b ON b.blocked_demand_id = v.blocked_demand_id
                            WHERE b.detected_by IS DISTINCT FROM PROCEDURE_MARKER),
      'buckets',          (SELECT jsonb_object_agg(x.age_bucket, x.n) FROM (
                             SELECT v.age_bucket, count(*) n FROM public.v_blocked_demand_open v
                               JOIN public.blocked_demand b ON b.blocked_demand_id = v.blocked_demand_id
                              WHERE b.detected_by = PROCEDURE_MARKER GROUP BY 1) x),
      'bucket_mismatch',  (SELECT count(*) FROM public.v_blocked_demand_open v
                             JOIN public.blocked_demand b ON b.blocked_demand_id = v.blocked_demand_id
                            WHERE b.detected_by = PROCEDURE_MARKER
                              AND v.age_bucket <> CASE WHEN (CURRENT_DATE - b.plan_date) >= 14 THEN 'critical'
                                                       WHEN (CURRENT_DATE - b.plan_date) >= 7  THEN 'aging'
                                                       WHEN (CURRENT_DATE - b.plan_date) >= 3  THEN 'watch'
                                                       ELSE 'fresh' END),
      'age_days_mismatch',(SELECT count(*) FROM public.v_blocked_demand_open v
                             JOIN public.blocked_demand b ON b.blocked_demand_id = v.blocked_demand_id
                            WHERE b.detected_by = PROCEDURE_MARKER
                              AND v.age_days <> (CURRENT_DATE - b.plan_date)),
      'edges',            (SELECT jsonb_object_agg(e.age_days::text, jsonb_build_array(e.n, e.buckets)) FROM (
                             SELECT v.age_days, count(*) n, array_agg(DISTINCT v.age_bucket) buckets
                               FROM public.v_blocked_demand_open v
                               JOIN public.blocked_demand b ON b.blocked_demand_id = v.blocked_demand_id
                              WHERE b.detected_by = PROCEDURE_MARKER AND v.age_days IN (2,3,6,7,13,14)
                              GROUP BY 1) e),
      'leak_2030',        (SELECT count(*) FROM public.v_blocked_demand_open WHERE plan_date >= DATE '2030-01-01')
    ) INTO v_metric;

    RAISE EXCEPTION 'S6_ROLLBACK_PROBE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'S6_ROLLBACK_PROBE' THEN
      RAISE;                                   -- a real error is never swallowed
    END IF;
  END;
  -- rows are gone here; v_metric survived because it is a variable, not a row.

  SELECT count(*) INTO v_after FROM public.blocked_demand;
  SELECT count(*) INTO v_residue FROM public.blocked_demand WHERE detected_by = PROCEDURE_MARKER;

  IF v_residue <> 0 OR v_after <> v_before THEN
    RAISE EXCEPTION 'golden.stress_s6_v1: PROBE LEAKED - before=% after=% residue=%. '
                    'The subtransaction rollback did not hold; investigate before re-running.',
                    v_before, v_after, v_residue;
  END IF;

  v_edges := COALESCE(v_metric->'edges', '{}'::jsonb);

  -- ── ASSERTIONS (16) ─────────────────────────────────────────────────────────────────────
  -- helper-free and explicit: each one names itself on failure.
  v_ok := (v_metric->>'inserted')::int = p_n;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A01 inserted <> p_n'; END IF;

  v_ok := (v_metric->>'planted_tbl')::int = p_n;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A02 planted_tbl <> p_n'; END IF;

  v_ok := (v_metric->>'view_planted')::int = p_n;   -- every planted row reaches the view
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A03 view_planted <> p_n'; END IF;

  v_ok := (v_metric->>'view_planted_d')::int = p_n; -- and none of them fanned out
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A04 fan-out in view join'; END IF;

  v_ok := (v_metric->>'view_total')::int = p_n + (v_metric->>'preexisting')::int;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A05 view_total <> planted+preexisting'; END IF;

  v_ok := (SELECT COALESCE(sum(value::int),0) FROM jsonb_each_text(v_metric->'buckets')) = p_n;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A06 buckets do not partition p_n'; END IF;

  v_ok := (v_metric->>'bucket_mismatch')::int = 0;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A07 age_bucket disagrees with plan_date'; END IF;

  v_ok := (v_metric->>'age_days_mismatch')::int = 0;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A08 age_days <> CURRENT_DATE-plan_date'; END IF;

  v_ok := (SELECT count(*) FROM jsonb_each_text(v_metric->'buckets') WHERE value::int > 0) = 4;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A09 not all four buckets populated'; END IF;

  -- A10..A15: both sides of all three edges. n>0 is the non-vacuity form; the bucket array
  -- must be EXACTLY the one expected, so a row landing in the wrong bucket cannot hide.
  v_ok := v_edges ? '2'  AND (v_edges->'2'->>0)::int  > 0 AND v_edges->'2'->1  = '["fresh"]'::jsonb;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A10 age 2 not exactly fresh'; END IF;

  v_ok := v_edges ? '3'  AND (v_edges->'3'->>0)::int  > 0 AND v_edges->'3'->1  = '["watch"]'::jsonb;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A11 age 3 not exactly watch'; END IF;

  v_ok := v_edges ? '6'  AND (v_edges->'6'->>0)::int  > 0 AND v_edges->'6'->1  = '["watch"]'::jsonb;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A12 age 6 not exactly watch'; END IF;

  v_ok := v_edges ? '7'  AND (v_edges->'7'->>0)::int  > 0 AND v_edges->'7'->1  = '["aging"]'::jsonb;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A13 age 7 not exactly aging'; END IF;

  v_ok := v_edges ? '13' AND (v_edges->'13'->>0)::int > 0 AND v_edges->'13'->1 = '["aging"]'::jsonb;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A14 age 13 not exactly aging'; END IF;

  v_ok := v_edges ? '14' AND (v_edges->'14'->>0)::int > 0 AND v_edges->'14'->1 = '["critical"]'::jsonb;
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A15 age 14 not exactly critical'; END IF;

  v_ok := (v_metric->>'leak_2030')::int = 0;        -- the synthetic band stays out of procurement
  IF v_ok THEN v_pass := v_pass+1; ELSE v_fail := v_fail+1; v_fails := v_fails||'A16 2030 band leaked into the open view'; END IF;

  v_metric := v_metric
            || jsonb_build_object('bd_before', v_before, 'bd_after', v_after, 'residue', v_residue,
                                  'n_pass', v_pass, 'n_fail', v_fail, 'failures', to_jsonb(v_fails));

  IF p_record THEN
    v_run := golden.record_stress(
      p_suite      => 'S6',
      p_passed     => (v_fail = 0),
      p_started_at => v_started,
      p_metric     => v_metric,
      p_detail     => NULL,
      p_note       => COALESCE(p_note,
                        'S6 blocked_demand volume. Rollback-restored probe on REAL dates - the open '
                        'view excludes plan_date >= 2030 by design, so the reserved 2030-11-06 band '
                        'would have passed vacuously. Nothing persists.'),
      p_driver     => 'sql',
      p_n_pass     => v_pass,
      p_n_fail     => v_fail);
    v_metric := v_metric || jsonb_build_object('stress_run_id', v_run);
  END IF;

  RETURN v_metric;
END
$fn$;

REVOKE ALL ON FUNCTION golden.stress_s6_v1(integer, boolean, text) FROM PUBLIC;

COMMENT ON FUNCTION golden.stress_s6_v1(integer, boolean, text) IS
  'PRD-110 STEP 7 / S6. Plants p_n (default 500) distinct open blocked_demand rows on '
  'CURRENT_DATE-relative offsets inside a rolled-back subtransaction, then asserts 16 properties '
  'of v_blocked_demand_open: every planted row visible, no fan-out, the four age buckets partition '
  'the plant exactly, both sides of all three bucket edges (2/3, 6/7, 13/14) land correctly, and '
  'the 2030 synthetic band stays excluded. Offsets not absolute dates, so it is re-runnable on any '
  'day. Records into golden.stress_runs unless p_record=false. Nothing persists in blocked_demand; '
  'the function RAISES if a single planted row survives the rollback.';
