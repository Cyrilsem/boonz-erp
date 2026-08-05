-- PRD-110 · P2 · D-12 remainder (WMAPE half) · GOLDEN FIXTURE 36 — RED BASELINE
--
-- LAW 1: this fixture lands and runs RED **before** any WMAPE object exists.
-- All references to the not-yet-built objects go through golden.probe_scalar(), which
-- degrades a missing relation/function to a 'MISSING: …' sentinel so the assertion FAILS
-- cleanly instead of dying at PARSE time as an ERROR (leg-51 harness addition).
--
-- WHAT THIS FIXTURE PINS
--   (a) VACUITY DISCIPLINE (RISK 102). WMAPE needs ACTUALS. A synthetic 2030 plan_date can
--       never have them, so the object must say "I measured nothing" out loud — wmape NULL,
--       is_vacuous TRUE, vacuous_reason 'horizon_not_elapsed'. A 0.0 there would read as a
--       PERFECT forecast, which is the exact failure class RISK 102 names.
--   (b) ARITHMETIC TRUTH on real data. 2026-06-26 is a real v19 plan_date whose 14-day
--       horizon has fully elapsed, so its actuals are settled. The fixture recomputes the
--       whole WMAPE independently from the base tables with a CORRELATED-SUBQUERY form and
--       requires the object (which uses a JOIN form) to reproduce every number.
--   (c) THE DOUBLE-COUNT GUARD. 2026-06-26 carries 11 (machine, pod) groups spanning more
--       than one shelf. Actuals resolve at machine x pod grain, so a shelf-grain WMAPE would
--       count the same sales twice. The snapshot must collapse those to ONE row each.
--
-- No assertion compares the object against itself.

BEGIN;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes,
   enabled, baseline_status)
VALUES (
  36,
  'WMAPE tracking is honest about missing actuals (P2 D-12)',
  'RISK 102 generalised: a measurement with an empty side must not report a good score. '
  'WMAPE is NULL until a shadow date''s horizon has elapsed; synthetic 2030 dates never elapse.',
  'P2',
  DATE '2030-02-06',
$scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- Baseline FIRST, before this fixture writes anything.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  't0',   clock_timestamp()::text,
  'prp',  (SELECT count(*) FROM public.pod_refills),
  'prps', (SELECT count(*) FROM public.pod_refills_shadow),
  'bd',   (SELECT count(*) FROM public.blocked_demand));

-- ---------------------------------------------------------------------------
-- (1) SYNTHETIC FUTURE DATE — both engines run; actuals cannot exist, ever.
-- ---------------------------------------------------------------------------
DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_36']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_36'
FROM public.machines
 WHERE official_name IN ('MPMCC-1058-0000-R0','AMZ-1046-2406-O1');

SELECT public.engine_add_pod({{plan_date}}, 7);
SELECT golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 7);

-- INDEPENDENT TRUTH, synthetic date. machine x pod grain on BOTH sides.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'truth_synth', jsonb_build_object(
  'v19_series', (SELECT count(*) FROM (SELECT machine_id, pod_product_id
                   FROM public.pod_refills
                  WHERE plan_date = {{plan_date}} AND pod_product_id IS NOT NULL
                  GROUP BY 1,2) a),
  'v3_series',  (SELECT count(*) FROM (SELECT machine_id, pod_product_id
                   FROM public.pod_refills_shadow
                  WHERE run_id = golden.v3_run_id({{fixture_id}}) AND plan_date = {{plan_date}}
                    AND pod_product_id IS NOT NULL
                  GROUP BY 1,2) b));

-- ---------------------------------------------------------------------------
-- (2) REAL ELAPSED DATE 2026-06-26 — the arithmetic proof.
--     Correlated-subquery form on purpose: the object under test uses a join form,
--     so agreement is evidence, not a restatement of the same expression.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH pl AS (
  SELECT p.machine_id, p.pod_product_id,
         count(DISTINCT p.shelf_id)            AS ns,
         max(p.days_cover)                     AS dc,
         sum(p.velocity_30d * p.days_cover)    AS fc
    FROM public.pod_refills p
   WHERE p.plan_date = DATE '2026-06-26' AND p.pod_product_id IS NOT NULL
   GROUP BY 1,2
), a AS (
  SELECT pl.*,
         COALESCE((SELECT sum(s.qty) FROM public.v_sales_history_resolved s
                    WHERE s.machine_id      = pl.machine_id
                      AND s.pod_product_id  = pl.pod_product_id
                      AND s.delivery_status = 'Successful'
                      AND s.transaction_date >= (DATE '2026-06-26'::timestamp AT TIME ZONE 'Asia/Dubai')
                      AND s.transaction_date <  ((DATE '2026-06-26' + pl.dc)::timestamp AT TIME ZONE 'Asia/Dubai')
                  ),0)::numeric AS act
    FROM pl
)
SELECT {{fixture_id}}, 'truth_real', jsonb_build_object(
  'n_series', (SELECT count(*) FROM a),
  'n_multi',  (SELECT count(*) FROM a WHERE ns > 1),
  'fc',       (SELECT round(sum(fc),4)::text FROM a),
  'act',      (SELECT round(sum(act),4)::text FROM a),
  'abs_err',  (SELECT round(sum(abs(fc-act)),4)::text FROM a),
  'wmape',    (SELECT round(sum(abs(fc-act))/NULLIF(sum(act),0),4)::text FROM a),
  'multi_key',(SELECT (machine_id::text || '|' || pod_product_id::text)
                 FROM a WHERE ns > 1 ORDER BY machine_id, pod_product_id LIMIT 1));

-- ---------------------------------------------------------------------------
-- (3) Drive the not-yet-existing refresh writer through probe_scalar.
--     Third call on the SAME date is the idempotency probe.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'refresh', jsonb_build_object(
  'synth', golden.probe_scalar('SELECT public.refresh_engine_forecast_error_v3(DATE ''2030-02-06'')::text'),
  'real1', golden.probe_scalar('SELECT public.refresh_engine_forecast_error_v3(DATE ''2026-06-26'')::text'),
  'real2', golden.probe_scalar('SELECT public.refresh_engine_forecast_error_v3(DATE ''2026-06-26'')::text'));
$scenario$,
  'D-12 WMAPE half. Anchor dates: synthetic 2030-02-06 (never elapses) and real 2026-06-26 '
  '(141 series, 11 multi-shelf groups, 14d horizon settled well before 2026-07-31). '
  'RISK 88: the actuals source v_sales_history_resolved resolves pod_product_id by NAME and '
  'costs ~13.5s to scan whole — every probe here is date-bounded.',
  true, 'failing_expected');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- ---- setup non-vacuity: without these the rest proves nothing --------------
(36, 1,'Drift guard: {{plan_date}} still renders as the fixture-36 anchor 2030-02-06',
 'SELECT {{plan_date}}::text','eq','2030-02-06',true,'P2'),
(36, 2,'NON-VACUITY: the v3 engine actually ran and recorded a run_id',
 'SELECT golden.v3_run_id({{fixture_id}})::text','not_null',NULL,true,'P2'),
(36, 3,'NON-VACUITY: the v3 engine reported no error',
 'SELECT COALESCE((SELECT value->>''error'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''engine_v3''),''none'')','eq','none',true,'P2'),
(36, 4,'NON-VACUITY: v19 produced series on the synthetic date',
 'SELECT (value->>''v19_series'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_synth''','gt','0',true,'P2'),
(36, 5,'NON-VACUITY: v3 produced series on the synthetic date',
 'SELECT (value->>''v3_series'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_synth''','gt','0',true,'P2'),
(36, 6,'NON-VACUITY: the real anchor date has v19 series to measure',
 'SELECT (value->>''n_series'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real''','gt','0',true,'P2'),
(36, 7,'NON-VACUITY: the real anchor date really does carry multi-shelf (machine,pod) groups — the double-count test is live',
 'SELECT (value->>''n_multi'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real''','gt','0',true,'P2'),
(36, 8,'NON-VACUITY: the real anchor date has NON-ZERO actuals — a zero denominator would make WMAPE untestable',
 'SELECT (value->>''act'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real''','gt','0',true,'P2'),
(36, 9,'NON-VACUITY: v19 is not a perfect forecaster — a WMAPE of exactly 0 would mean the truth calc is tautological',
 'SELECT (value->>''wmape'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real''','gt','0',true,'P2'),
-- ---- the writer exists and is callable ------------------------------------
(36,10,'The refresh writer exists and ran on the synthetic date (no MISSING sentinel)',
 'SELECT (value->>''synth'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''refresh''','not_null',NULL,true,'P2'),
(36,11,'The refresh writer did not degrade to MISSING on the synthetic date',
 'SELECT CASE WHEN (value->>''synth'') LIKE ''MISSING:%'' OR (value->>''synth'') LIKE ''ERROR:%'' THEN ''absent'' ELSE ''present'' END FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''refresh''','eq','present',true,'P2'),
(36,12,'The refresh writer did not degrade to MISSING on the real date',
 'SELECT CASE WHEN (value->>''real1'') LIKE ''MISSING:%'' OR (value->>''real1'') LIKE ''ERROR:%'' THEN ''absent'' ELSE ''present'' END FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''refresh''','eq','present',true,'P2'),
-- ---- (b) ARITHMETIC TRUTH on the real elapsed date -------------------------
(36,13,'Snapshot reproduces the independently computed v19 SERIES COUNT on the real date',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','eq',
 '{{truth_real.n_series}}',true,'P2'),
(36,14,'Snapshot reproduces the independently computed SUM(forecast_units)',
 'SELECT golden.probe_scalar(''SELECT round(sum(forecast_units),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','eq',
 '{{truth_real.fc}}',true,'P2'),
(36,15,'Snapshot reproduces the independently computed SUM(actual_units) — the double-count guard in numeric form',
 'SELECT golden.probe_scalar(''SELECT round(sum(actual_units),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','eq',
 '{{truth_real.act}}',true,'P2'),
(36,16,'Snapshot reproduces the independently computed SUM(abs_error)',
 'SELECT golden.probe_scalar(''SELECT round(sum(abs_error),4)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','eq',
 '{{truth_real.abs_err}}',true,'P2'),
(36,17,'v_engine_wmape_v3 reproduces the independently computed WMAPE on the real date',
 'SELECT golden.probe_scalar(''SELECT wmape::text FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','eq',
 '{{truth_real.wmape}}',true,'P2'),
(36,18,'A real elapsed date is NOT vacuous',
 'SELECT golden.probe_scalar(''SELECT is_vacuous::text FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','eq','false',true,'P2'),
(36,19,'A non-vacuous row carries NO vacuous_reason',
 'SELECT golden.probe_scalar(''SELECT vacuous_reason FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','is_null',NULL,true,'P2'),
-- ---- (c) THE DOUBLE-COUNT GUARD, structurally -----------------------------
(36,20,'GRAIN: the snapshot holds exactly ONE row per (machine,pod) — a multi-shelf group is collapsed, not duplicated',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''' AND machine_id::text||''''|''''||pod_product_id::text = '''''' || (SELECT value->>''multi_key'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') || '''''''')','eq','1',true,'P2'),
(36,21,'GRAIN: that collapsed row records n_shelves > 1, so the collapse is visible rather than silent',
 'SELECT golden.probe_scalar(''SELECT n_shelves::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''' AND machine_id::text||''''|''''||pod_product_id::text = '''''' || (SELECT value->>''multi_key'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''truth_real'') || '''''''')','gt','1',true,'P2'),
(36,22,'GRAIN: no (plan_date,engine,machine,pod) key appears twice anywhere in the snapshot',
 'SELECT golden.probe_scalar(''SELECT (count(*) - count(DISTINCT (plan_date,engine_tag,machine_id,pod_product_id)))::text FROM public.engine_forecast_error_v3'')','eq','0',true,'P2'),
-- ---- (a) VACUITY DISCIPLINE — the whole point of the fixture ---------------
(36,23,'SYNTHETIC DATE: v19 WMAPE is NULL, not 0.0 — there are no actuals to score against',
 'SELECT golden.probe_scalar(''SELECT wmape::text FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2030-02-06'''' AND engine_tag=''''v19'''''')','is_null',NULL,true,'P2'),
(36,24,'SYNTHETIC DATE: v3 WMAPE is NULL, not 0.0',
 'SELECT golden.probe_scalar(''SELECT wmape::text FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2030-02-06'''' AND engine_tag=''''v3'''''')','is_null',NULL,true,'P2'),
(36,25,'SYNTHETIC DATE: v3 row says is_vacuous = true out loud',
 'SELECT golden.probe_scalar(''SELECT is_vacuous::text FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2030-02-06'''' AND engine_tag=''''v3'''''')','eq','true',true,'P2'),
(36,26,'SYNTHETIC DATE: the reason is named as horizon_not_elapsed, not left blank',
 'SELECT golden.probe_scalar(''SELECT vacuous_reason FROM public.v_engine_wmape_v3 WHERE plan_date=DATE ''''2030-02-06'''' AND engine_tag=''''v3'''''')','eq','horizon_not_elapsed',true,'P2'),
(36,27,'SYNTHETIC DATE: every snapshot row is marked actuals_settled = false',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2030-02-06'''' AND actuals_settled'')','eq','0',true,'P2'),
(36,28,'SYNTHETIC DATE: the head-to-head GATE view refuses to declare a winner on a vacuous date',
 'SELECT golden.probe_scalar(''SELECT COALESCE(v3_meets_gate::text,''''null'''') FROM public.v_engine_wmape_v3_gate WHERE plan_date=DATE ''''2030-02-06'''''')','ne','true',true,'P2'),
(36,29,'SYNTHETIC DATE: the GATE view marks itself vacuous',
 'SELECT golden.probe_scalar(''SELECT is_vacuous::text FROM public.v_engine_wmape_v3_gate WHERE plan_date=DATE ''''2030-02-06'''''')','eq','true',true,'P2'),
-- ---- idempotency + exposure ----------------------------------------------
(36,30,'IDEMPOTENT: re-measuring the same date a third time leaves the series count unchanged',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM public.engine_forecast_error_v3 WHERE plan_date=DATE ''''2026-06-26'''' AND engine_tag=''''v19'''''')','eq',
 '{{truth_real.n_series}}',true,'P2'),
(36,31,'anon holds NO privilege on the measurement table',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM information_schema.role_table_grants WHERE grantee=''''anon'''' AND table_schema=''''public'''' AND table_name=''''engine_forecast_error_v3'''''')','eq','0',true,'P2');

COMMIT;
