-- PRD-110 P2.1 · GOLDEN FIXTURE 14 — "Sensor lie" (WEIMI count > capacity)
-- Golden-schema only. No public object is created, altered or dropped.
-- Population is REAL (41 shelves / 16 machines fleet-wide; 5 on MPMCC-1058), no synthetic data.
-- plan_date 2030-01-15 = golden.render's DATE '2030-01-01' + fixture_id. Verified free.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  14,
  'Sensor lie (WEIMI count > capacity)',
  'S-07 (leg 1, shelf-by-shelf) + D-08 first live estimator run 2026-07-30 18:40 UTC (5 count_above_capacity on MPMCC-1058)',
  'P2',
  DATE '2030-01-15',
$sc$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- Baseline FIRST, before this fixture writes anything. t0 scopes the residue tripwires
-- to this run's own window so a concurrent cron-44 firing cannot flake them (RISK 65).
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  't0',      clock_timestamp()::text,
  'df_open', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'prp',     (SELECT count(*) FROM public.pod_refill_plan),
  'rpo',     (SELECT count(*) FROM public.refill_plan_output));

-- The sensor-lie population, MEASURED AT RUN TIME. Never hardcode 5 or 41: the WEIMI
-- anchor moves (RISK 53) and D-08 goes fleet-wide in ~3 days (S-28).
INSERT INTO golden.scratch (fixture_id, key, value)
WITH s AS (SELECT * FROM public.v_shelf_state WHERE pod_product_id IS NOT NULL),
     lie AS (SELECT * FROM s WHERE current_stock > max_stock)
SELECT {{fixture_id}}, 'lie', jsonb_build_object(
  'fleet_shelves',  (SELECT count(*) FROM lie),
  'fleet_machines', (SELECT count(DISTINCT machine_id) FROM lie),
  'target_shelves', (SELECT count(*) FROM lie WHERE machine_name = 'MPMCC-1058-0000-R0'),
  'target_excess',  (SELECT COALESCE(sum(current_stock - max_stock),0) FROM lie WHERE machine_name = 'MPMCC-1058-0000-R0'),
  't_anchor',       (SELECT max(stock_as_of)::text FROM s));   -- record the anchor we ran against (RISK 53)

DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_14']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_14'
FROM public.machines WHERE official_name = 'MPMCC-1058-0000-R0';

SELECT public.engine_add_pod({{plan_date}}, 7);
$sc$,
$nt$SPEC (GOLDEN-FIXTURES #14, verbatim): "Sensor lie | WEIMI count > capacity | Assert anomaly row +
plan uses clamped value; no negative/absurd qty."

BUILT AS SPECIFIED, in two halves, because the two halves are owned by two different subsystems:

(a) THE ESTIMATOR HALF is live and green (P1.4 / D-08). Measured 2026-07-30 19:2x UTC: MPMCC-1058
    A10 17/12, A12 21/18, A13 20/18, A14 21/18, A16 21/16 - all Aquafina pods. shelf_composition
    totals on those five are 12/18/18/18/16, i.e. EXACTLY capacity, never the WEIMI count. Fleet-wide
    the class is 41 shelves across 16 machines.

(b) THE PLAN HALF is an acceptance criterion for engine_add_pod_v3 and is expected-red until it
    exists (seq 30/31/32, gated on pg_proc). MEASURED BASELINE on v19: the five over-capacity
    shelves receive NO plan line at all - not a clamped line, not a qty=0 line, nothing. That is
    S-05's silent-drop class, and it is why "plan uses the clamped value" cannot be asserted as
    satisfied today. v19 does NOT emit a negative qty (0 across every pod_refills row ever written),
    so the "no negative/absurd qty" clause IS green today and is asserted unconditionally.

Assertions are written as INVARIANTS (violation counts that must be 0) and as run-time-measured
premises, never as absolute row counts, so that D-08's fleet-wide expansion cannot red them (S-28 /
RISK 65) and the moving WEIMI anchor cannot flake them (RISK 53). t_anchor is recorded per run.

plan_date 2030-01-15 = golden.render's DATE '2030-01-01' + fixture_id, matching fixtures 3 (01-04)
and 10 (01-11). The leg-22 pointer proposed 2030-02-14; that would have DIVERGED from the macro,
since golden.render derives {{plan_date}} from fixture_id and ignores the fixtures.plan_date column.
Fixture 2's 2030-02-02 is inert only because fixture 2 never uses the macro. Corrected per LAW 13.

CODY REVIEW (leg 23) — three disclosures a future leg must read BEFORE bisecting a red:
1. seq 91/92/93/94 are IDLENESS assertions (RISK 65) on tables with a live daily writer: cron 13
   fires at 16:00 UTC and runs the same engine on the real plan_date. A run that collides with that
   cycle can red them. That is a COLLISION, not a regression - re-run the fixture and it goes green.
   seq 91's total-count form is ADR 8.3 verbatim, so it is kept as written rather than narrowed.
2. engine_add_pod writes four tables: pod_refills (seq 93), pod_swaps (seq 94), driver_feedback
   (seq 90) and monitoring_alerts. monitoring_alerts is DELIBERATELY untripwired - it is an alerting
   sink, not state. Do not read its absence here as an oversight.
3. seq 8 joins shelf_composition to v_shelf_state, so its coverage narrows for any composition row
   whose shelf has left the view. It is a violation detector, not a fleet-completeness claim.$nt$,
  true,
  'failing_expected')
ON CONFLICT (fixture_id) DO UPDATE SET
  name = EXCLUDED.name, source_incident = EXCLUDED.source_incident,
  phase_required = EXCLUDED.phase_required, plan_date = EXCLUDED.plan_date,
  scenario_sql = EXCLUDED.scenario_sql, notes = EXCLUDED.notes,
  enabled = EXCLUDED.enabled, baseline_status = EXCLUDED.baseline_status;

DELETE FROM golden.assertions WHERE fixture_id = 14;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
VALUES

-- ── PREMISE: the sensor lie is live and real, at both grains ───────────────────────────────
(14, 1, 'PREMISE: the planned machine has at least one shelf whose WEIMI count exceeds capacity',
 $q$SELECT count(*)::text FROM public.v_shelf_state
    WHERE machine_name = 'MPMCC-1058-0000-R0' AND pod_product_id IS NOT NULL
      AND current_stock > max_stock$q$, 'gte', '1', true, 'P1', NULL),

(14, 2, 'PREMISE: the sensor-lie class spans MORE THAN ONE machine, so it is a class and not a quirk (needs no synthetic data)',
 $q$SELECT count(DISTINCT machine_id)::text FROM public.v_shelf_state
    WHERE pod_product_id IS NOT NULL AND current_stock > max_stock$q$, 'gte', '2', true, 'P1', NULL),

-- ── THE ANOMALY ROW (spec clause 1) ────────────────────────────────────────────────────────
(14, 3, 'ANOMALY ROW: every over-capacity shelf the estimator has touched carries a count_above_capacity anomaly (0 missing)',
 $q$SELECT count(*)::text FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock > s.max_stock
      AND EXISTS (SELECT 1 FROM public.shelf_composition c WHERE c.shelf_id = s.shelf_id)
      AND NOT EXISTS (SELECT 1 FROM public.inventory_anomalies a
                      WHERE a.shelf_id = s.shelf_id AND a.kind = 'count_above_capacity')$q$,
 'eq', '0', true, 'P1', NULL),

(14, 4, 'ANOMALY ROW is a genuine lie: observed_qty > expected_qty on every one (0 violations)',
 $q$SELECT count(*)::text FROM public.inventory_anomalies a
    JOIN public.v_shelf_state s ON s.shelf_id = a.shelf_id
    WHERE a.kind = 'count_above_capacity' AND s.machine_name = 'MPMCC-1058-0000-R0'
      AND NOT (a.observed_qty > a.expected_qty)$q$, 'eq', '0', true, 'P1', NULL),

(14, 5, 'ANOMALY ROW names CAPACITY as the clamp target: expected_qty = shelf max_stock (0 violations)',
 $q$SELECT count(*)::text FROM public.inventory_anomalies a
    JOIN public.v_shelf_state s ON s.shelf_id = a.shelf_id
    WHERE a.kind = 'count_above_capacity' AND s.machine_name = 'MPMCC-1058-0000-R0'
      AND a.expected_qty IS DISTINCT FROM s.max_stock$q$, 'eq', '0', true, 'P1', NULL),

(14, 10, 'ANOMALY ROW carries snapshot provenance (weimi_snapshot_at + source_ref) (0 missing)',
 $q$SELECT count(*)::text FROM public.inventory_anomalies a
    JOIN public.v_shelf_state s ON s.shelf_id = a.shelf_id
    WHERE a.kind = 'count_above_capacity' AND s.machine_name = 'MPMCC-1058-0000-R0'
      AND (a.weimi_snapshot_at IS NULL OR COALESCE(a.detail->>'source_ref','') = '')$q$,
 'eq', '0', true, 'P1', NULL),

-- ── THE CLAMP (spec clause 2, estimator side) ──────────────────────────────────────────────
(14, 6, 'CLAMP: composition total on every over-capacity shelf equals CAPACITY, not the WEIMI count (0 violations)',
 $q$SELECT count(*)::text FROM (
      SELECT s.max_stock mx, (SELECT sum(c.est_qty) FROM public.shelf_composition c WHERE c.shelf_id = s.shelf_id) tot
      FROM public.v_shelf_state s
      WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
        AND s.current_stock > s.max_stock) t
    WHERE t.tot IS NOT NULL AND t.tot <> t.mx$q$, 'eq', '0', true, 'P1', NULL),

(14, 7, 'CLAMP BIT: composition total is strictly BELOW the raw WEIMI count on those shelves (0 violations)',
 $q$SELECT count(*)::text FROM (
      SELECT s.current_stock cs, (SELECT sum(c.est_qty) FROM public.shelf_composition c WHERE c.shelf_id = s.shelf_id) tot
      FROM public.v_shelf_state s
      WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
        AND s.current_stock > s.max_stock) t
    WHERE t.tot IS NOT NULL AND NOT (t.tot < t.cs)$q$, 'eq', '0', true, 'P1', NULL),

(14, 8, 'CLAMP IS UNIVERSAL: no shelf anywhere in the fleet holds a composition total above its capacity (0 violations)',
 $q$SELECT count(*)::text FROM (
      SELECT c.shelf_id, s.max_stock mx, sum(c.est_qty) tot
      FROM public.shelf_composition c JOIN public.v_shelf_state s ON s.shelf_id = c.shelf_id
      GROUP BY c.shelf_id, s.max_stock) t
    WHERE t.tot > t.mx$q$, 'eq', '0', true, 'P1', NULL),

(14, 9, 'NO NEGATIVE COMPOSITION anywhere in the fleet (0 violations)',
 $q$SELECT count(*)::text FROM public.shelf_composition WHERE est_qty < 0$q$, 'eq', '0', true, 'P1', NULL),

-- ── THE PLAN: "no negative / absurd qty" (spec clause 3) — GREEN ON v19 TODAY ───────────────
(14, 20, 'PLAN EXISTS: the fixture engine run produced at least one line on its own plan_date',
 $q$SELECT count(*)::text FROM public.pod_refills WHERE plan_date = {{plan_date}}$q$,
 'gte', '1', true, 'P1', NULL),

(14, 21, 'NO NEGATIVE QTY on this fixture plan (0 lines)',
 $q$SELECT count(*)::text FROM public.pod_refills WHERE plan_date = {{plan_date}} AND qty < 0$q$,
 'eq', '0', true, 'P1', NULL),

(14, 22, 'NO ABSURD QTY: no line asks for more than the shelf headroom (max_stock - current_stock) (0 violations)',
 $q$SELECT count(*)::text FROM public.pod_refills
    WHERE plan_date = {{plan_date}} AND max_stock IS NOT NULL AND current_stock IS NOT NULL
      AND qty > (max_stock - current_stock)$q$, 'eq', '0', true, 'P1', NULL),

(14, 23, 'NO ABSURD QTY: no line asks for more than the whole shelf capacity (0 violations)',
 $q$SELECT count(*)::text FROM public.pod_refills
    WHERE plan_date = {{plan_date}} AND max_stock IS NOT NULL AND qty > max_stock$q$,
 'eq', '0', true, 'P1', NULL),

(14, 24, 'STANDING INVARIANT: no negative qty has EVER been written to pod_refills, fleet-wide, all dates',
 $q$SELECT count(*)::text FROM public.pod_refills WHERE qty < 0$q$, 'eq', '0', true, 'P1', NULL),

-- ── ACCEPTANCE CRITERIA for engine_add_pod_v3 — expected-red until it exists ────────────────
-- Gate returns FALSE today => a failure counts as expected_red, not fail (leg 22 …190326).
-- MEASURED v19 BASELINE for all three: 5 (every over-capacity shelf is silently dropped).
(14, 30, 'v3 TARGET: no over-capacity shelf is silently dropped — each one receives a plan line (0 uncovered)',
 $q$SELECT count(*)::text FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock > s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills pr
                      WHERE pr.plan_date = {{plan_date}} AND pr.shelf_id = s.shelf_id)$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod_v3')$g$),

(14, 31, 'v3 TARGET: THE PLAN USES THE CLAMPED VALUE — the line records current_stock <= capacity, never the raw lie (0 violations; a missing line counts as one)',
 $q$SELECT count(*)::text FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock > s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills pr
                      WHERE pr.plan_date = {{plan_date}} AND pr.shelf_id = s.shelf_id
                        AND pr.current_stock <= pr.max_stock)$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod_v3')$g$),

(14, 32, 'v3 TARGET: an over-full shelf says qty=0 WITH a clamp_reason — explicit, never silent (LAW 5) (0 violations; a missing line counts as one)',
 $q$SELECT count(*)::text FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock > s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills pr
                      WHERE pr.plan_date = {{plan_date}} AND pr.shelf_id = s.shelf_id
                        AND pr.qty = 0 AND pr.clamp_reason IS NOT NULL)$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod_v3')$g$),

-- ── TRIPWIRES ──────────────────────────────────────────────────────────────────────────────
(14, 90, 'S-08 tripwire: open driver_feedback count unchanged by the fixture',
 $q$SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved = false)
          = (SELECT (value->>'df_open')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'before'))::text$q$,
 'eq', 'true', true, 'P1', NULL),

(14, 91, 'ADR 8.3 tripwire: pod_refill_plan row count unchanged across this run',
 $q$SELECT ((SELECT count(*) FROM public.pod_refill_plan)
          = (SELECT (value->>'prp')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'before'))::text$q$,
 'eq', 'true', true, 'P1', NULL),

(14, 92, 'LAW 12 tripwire: refill_plan_output row count unchanged across this run',
 $q$SELECT ((SELECT count(*) FROM public.refill_plan_output)
          = (SELECT (value->>'rpo')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'before'))::text$q$,
 'eq', 'true', true, 'P1', NULL),

(14, 93, 'LAW 12 tripwire: this fixture wrote pod_refills on NO plan_date other than its own 2030 date',
 $q$SELECT count(*)::text FROM public.pod_refills
    WHERE plan_date <> {{plan_date}}
      AND created_at >= (SELECT (value->>'t0')::timestamptz FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'before')$q$,
 'eq', '0', true, 'P1', NULL),

(14, 94, 'LAW 12 tripwire: this fixture wrote pod_swaps on NO plan_date other than its own 2030 date',
 $q$SELECT count(*)::text FROM public.pod_swaps
    WHERE plan_date <> {{plan_date}}
      AND created_at >= (SELECT (value->>'t0')::timestamptz FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'before')$q$,
 'eq', '0', true, 'P1', NULL),

-- Residue tripwires are scoped to this run's own window AND exclude the estimator's source_ref
-- prefix, so cron 44 firing mid-fixture cannot flake them (RISK 65 / S-28).
(14, 95, 'RESIDUE: the engine wrote no inventory_events (excluding the estimator, the only other writer)',
 $q$SELECT count(*)::text FROM public.inventory_events
    WHERE ts >= (SELECT (value->>'t0')::timestamptz FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'before')
      AND COALESCE(source_ref,'') NOT LIKE 'estimator:%'$q$, 'eq', '0', true, 'P1', NULL),

(14, 96, 'RESIDUE: the engine raised no inventory_anomalies (excluding the estimator)',
 $q$SELECT count(*)::text FROM public.inventory_anomalies
    WHERE detected_at >= (SELECT (value->>'t0')::timestamptz FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'before')
      AND COALESCE(detail->>'source_ref','') NOT LIKE 'estimator:%'$q$, 'eq', '0', true, 'P1', NULL),

(14, 99, 'PROVENANCE: the run recorded the WEIMI anchor it measured against (RISK 53)',
 $q$SELECT value->>'t_anchor' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'lie'$q$,
 'not_null', NULL, true, 'P1', NULL);
