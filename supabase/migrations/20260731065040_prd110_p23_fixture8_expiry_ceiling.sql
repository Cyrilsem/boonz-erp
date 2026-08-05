-- PRD-110 P2.3 / LAW 1. Fixture 8 "Expiry ceiling" (GOLDEN-FIXTURES #8).
-- Spec verbatim: "Product with 6 sellable days, cover target 14d. Assert qty capped by expiry
-- ceiling; reasoning shows ceiling clamp."
--
-- BUILT IN TWO HALVES, and the halves are deliberate:
--
-- (a) THE MAP HALF is live and asserts fleet-wide TODAY. It pins the pod-grain FEFO expiry
--     resolution contract - the predicate, the plan-time anchoring, sentinel handling, and the
--     no-batch population - independently of whether the engine consumes it yet. It reads NO
--     velocity object, so it is not subject to RISK 88.
--
-- (b) THE ENGINE HALF is gated on the engine actually carrying expiry provenance and is
--     EXPECTED-RED until prd110_p23_engine_expiry_ceiling lands. A fixture that goes green on
--     its first run proves nothing (the S-48 vacuity lesson), so the gate is on the FEATURE
--     (prosrc carries expiry_source), not merely on the function existing - fixture 14's
--     pg_proc gate would have passed vacuously here since engine_add_pod_v3 already exists.
--
-- ⚠️ WHY plan_date 2030-01-09 IS THE HARDEST CASE, NOT AN ARTEFACT. golden.render derives
-- {{plan_date}} = DATE '2030-01-01' + fixture_id and IGNORES fixtures.plan_date (leg 22 lesson).
-- Every real batch in this database expires in 2026, so at a 2030 plan_date EVERY WH-constrained
-- shelf resolves days_to_expiry = 0 and therefore an expiry ceiling of ZERO. That is not a
-- degenerate accident - it is the maximum-stress form of the one rule that matters most here:
-- a zero ceiling must cap the COVER term and must NOT zero the min-facing floor (Cody revision 2,
-- LAW 5). If the ceiling is ever wired to also cap the floor, this fixture goes red fleet-wide.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  8,
  'Expiry ceiling',
  'PRD-110 P2.3 / BUILD SPEC: "Ceiling: min(S, capacity, days_to_expiry_available x sell_rate x safety) - expiry from WH batch (FEFO candidate) at plan time." Blast radius measured read-only over all 544 pod-bound shelves at plan_date CURRENT_DATE+1 before any code changed: 469 WH-constrained, ceiling binds on 4 (0.9%) removing 4 units, 0 FEFO batches already expired, real FEFO shelf-life p10 77d / median 148d / p90 289d, 72 WH-constrained shelves with no expiry row, 48 resolving to the 2099-12-31 sentinel date, 68 lines whose ceiling is 0 purely because velocity is 0.',
  'P2',
  DATE '2030-01-09',
$scen$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- Baseline FIRST (RISK 65): scope the idleness tripwires to this run's own window.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  't0',  clock_timestamp()::text,
  'prp', (SELECT count(*) FROM public.pod_refill_plan),
  'wi',  (SELECT count(*) FROM public.warehouse_inventory),
  'pi',  (SELECT count(*) FROM public.pod_inventory));

-- ---------------------------------------------------------------------------------------------
-- HALF (a) THE MAP. The fixture's OWN re-derivation, written out in full rather than reusing the
-- engine, so an edit that changes the MEANING is caught rather than mirrored (the fixture-29
-- house rule). Reference date is CURRENT_DATE+1 = the live nightly plan date, so this half
-- measures REAL shelf-life rather than the 2030 stress date used by half (b).
-- ---------------------------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH pods AS (
  SELECT DISTINCT ss.machine_id, ss.pod_product_id,
         m.primary_warehouse_id, m.secondary_warehouse_id
    FROM public.v_shelf_state ss
    JOIN public.machines m ON m.machine_id = ss.machine_id
   WHERE ss.pod_product_id IS NOT NULL
), xp AS (
  -- The pod->WH predicate is COPIED VERBATIM from the shipped v_shelf_availability_v3 `wh` CTE.
  -- v3 must have exactly ONE pod->WH resolution, not two that can drift apart.
  SELECT p.machine_id, p.pod_product_id, MIN(sl.earliest_expiry) AS earliest_expiry
    FROM pods p
    JOIN public.product_mapping pm
      ON pm.pod_product_id = p.pod_product_id
     AND pm.status = 'Active'
     AND (pm.machine_id IS NULL OR pm.machine_id = p.machine_id)
    JOIN public.v_product_shelf_life sl
      ON sl.boonz_product_id = pm.boonz_product_id
     AND sl.warehouse_id = ANY (ARRAY[p.primary_warehouse_id, p.secondary_warehouse_id])
   GROUP BY 1, 2
), j AS (
  SELECT ss.shelf_id, ss.machine_id, ss.pod_product_id,
         COALESCE(a.sourcing, 'unknown') AS basis,
         x.earliest_expiry,
         GREATEST(x.earliest_expiry - (CURRENT_DATE + 1), 0) AS expiry_days
    FROM public.v_shelf_state ss
    LEFT JOIN public.v_shelf_availability_v3 a ON a.shelf_id = ss.shelf_id
    LEFT JOIN xp x ON x.machine_id = ss.machine_id AND x.pod_product_id = ss.pod_product_id
   WHERE ss.pod_product_id IS NOT NULL
)
SELECT {{fixture_id}}, 'map', jsonb_build_object(
  'shelves',              (SELECT count(*) FROM j),
  'wh_constrained',       (SELECT count(*) FROM j WHERE basis IN ('boonz_wh','mixed')),
  'with_expiry_row',      (SELECT count(*) FROM j WHERE earliest_expiry IS NOT NULL),
  'wh_without_expiry',    (SELECT count(*) FROM j WHERE basis IN ('boonz_wh','mixed') AND earliest_expiry IS NULL),
  'sentinel_dated',       (SELECT count(*) FROM j WHERE earliest_expiry >= DATE '2090-01-01'),
  'fefo_already_expired', (SELECT count(*) FROM j WHERE earliest_expiry IS NOT NULL AND earliest_expiry <= CURRENT_DATE + 1),
  'negative_days',        (SELECT count(*) FROM j WHERE expiry_days < 0),
  'dup_keys',             (SELECT count(*) FROM (SELECT machine_id, pod_product_id FROM xp GROUP BY 1,2 HAVING count(*) > 1) d),
  'ref_date',             (CURRENT_DATE + 1)::text);

-- ---------------------------------------------------------------------------------------------
-- HALF (b) THE ENGINE.
-- ---------------------------------------------------------------------------------------------
DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group = 'VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_8']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_8'
FROM public.machines
 WHERE official_name IN ('MPMCC-1058-0000-R0','AMZ-1046-2406-O1');

SELECT golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 14);

-- Read the engine's own output back and score the P2.3 contract against it. Everything below is
-- internal to the engine's recorded reasoning, so it costs one indexed scan and no view reads.
DO $fx8$
DECLARE
  v_run     uuid := golden.v3_run_id({{fixture_id}});
  v_factor  numeric;
  v_payload jsonb;
BEGIN
  IF v_run IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES ({{fixture_id}}, 'eng', jsonb_build_object('ran','false'));
    RETURN;
  END IF;

  SELECT base_stock_expiry_safety_factor INTO v_factor
    FROM public.refill_policy_params WHERE id = 1;

  CREATE TEMP TABLE fx8_l ON COMMIT DROP AS
  SELECT s.shelf_id, s.machine_id, s.pod_product_id, s.qty, s.clamp_reason,
         (s.reasoning->>'sourcing')                          AS basis,
         (s.reasoning->>'expiry_source')                     AS expiry_source,
         (s.reasoning->>'expiry_days')::numeric              AS expiry_days,
         (s.reasoning->>'expiry_ceiling_units')::int         AS ceil_u,
         (s.reasoning->>'expiry_safety_factor')::numeric     AS factor,
         (s.reasoning ? 'earliest_expiry')                   AS has_exp_key,
         (s.reasoning->>'cover_units')::int                  AS cover_units,
         (s.reasoning->>'floor_units')::int                  AS floor_units,
         (s.reasoning->>'fill_to_cap')::int                  AS fill_to_cap,
         (s.reasoning->>'need_raw')::int                     AS need_raw,
         (s.reasoning->>'velocity_effective_daily')::numeric AS vel_eff
    FROM public.pod_refills_shadow s
   WHERE s.run_id = v_run;

  v_payload := jsonb_build_object(
    'ran',  'true',
    'lines', (SELECT count(*) FROM fx8_l),

    -- LAW 5, same shape as the horizon/sigma guards: a sized line must name its expiry basis.
    'unnamed_source', (SELECT count(*) FROM fx8_l
                        WHERE expiry_source IS NULL
                           OR expiry_source NOT IN
                              ('wh_fefo_batch','no_wh_batch','not_wh_sourced','unknown_sourcing')),

    -- Provenance completeness: every line carries the whole expiry block, not a subset.
    'missing_keys', (SELECT count(*) FROM fx8_l
                      WHERE expiry_days IS NULL OR factor IS NULL OR NOT has_exp_key),

    -- The factor the engine used is the PARAM, never a literal.
    'factor_mismatch', (SELECT count(*) FROM fx8_l WHERE factor IS DISTINCT FROM v_factor),

    -- The published arithmetic, re-derived from the engine's own recorded inputs.
    'formula_mismatch', (SELECT count(*) FROM fx8_l
                          WHERE expiry_source = 'wh_fefo_batch'
                            AND ceil_u IS DISTINCT FROM FLOOR(expiry_days * vel_eff * v_factor)::int),

    -- A ceiling may only ever REDUCE. It must never lift a quantity.
    'ceiling_lifted', (SELECT count(*) FROM fx8_l
                        WHERE ceil_u IS NOT NULL AND need_raw > GREATEST(cover_units, floor_units)),

    -- ⭐ THE CORE ASSERTION (Cody revision 2 / LAW 5). At this plan_date every WH-constrained
    -- shelf has a ZERO ceiling. Not one of them may be zeroed where a min-facing floor applies.
    'zeroed_despite_floor', (SELECT count(*) FROM fx8_l
                              WHERE floor_units > 0 AND need_raw < LEAST(floor_units, fill_to_cap)),

    -- ⭐ THE MISLABEL TRIPWIRE. 'skipped_full' means "the shelf is full". A line driven to zero by
    -- the expiry ceiling is NOT full, and saying so would hide the whole clamp class.
    'mislabelled_full', (SELECT count(*) FROM fx8_l
                          WHERE clamp_reason = 'skipped_full'
                            AND ceil_u IS NOT NULL AND ceil_u < cover_units),

    -- Non-vacuity: the zero-ceiling population this fixture exists to protect is non-empty.
    'zero_ceiling_lines', (SELECT count(*) FROM fx8_l WHERE ceil_u = 0),
    'floor_protected',    (SELECT count(*) FROM fx8_l WHERE ceil_u = 0 AND need_raw > 0),
    'binding_lines',      (SELECT count(*) FROM fx8_l WHERE clamp_reason = 'expiry_ceiling'),
    'wh_fefo_lines',      (SELECT count(*) FROM fx8_l WHERE expiry_source = 'wh_fefo_batch'),
    'not_wh_lines',       (SELECT count(*) FROM fx8_l WHERE expiry_source = 'not_wh_sourced'),

    -- LAW 7: sizing may not consume, write off, or otherwise move expired stock.
    'wi_after', (SELECT count(*) FROM public.warehouse_inventory),
    'pi_after', (SELECT count(*) FROM public.pod_inventory));

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'eng', v_payload);
END
$fx8$;
$scen$,
  'P2.3. Pins the expiry-ceiling contract: the pod-grain FEFO map (predicate copied verbatim from v_shelf_availability_v3), plan-time anchoring, the published arithmetic floor(days x rate x factor), the safety factor read from refill_policy_params rather than a literal, and - the two that matter most - that a zero ceiling never zeroes the min-facing floor and never mislabels itself as skipped_full. Half (a) reads no velocity object and is not subject to RISK 88. Half (b) is gated on prosrc carrying expiry_source, NOT merely on engine_add_pod_v3 existing, because the function already exists and a pg_proc gate would pass vacuously (S-48).',
  true,
  'failing_expected'
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
VALUES
-- ---- half (a): the map, asserts today, no gate -------------------------------------------------
(8, 1, 'NON-VACUITY: the fleet has pod-bound shelves at all, so every =0 assertion below is earned',
 'SELECT value->>''shelves'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''map''',
 'gt', '0', true, 'P2', NULL),
(8, 2, 'NON-VACUITY: the WH-constrained population the ceiling applies to is non-empty',
 'SELECT value->>''wh_constrained'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''map''',
 'gt', '0', true, 'P2', NULL),
(8, 3, 'NON-VACUITY: shelves actually resolve a FEFO expiry date - a broken pod->WH predicate returns 0 here and every ceiling silently disappears',
 'SELECT value->>''with_expiry_row'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''map''',
 'gt', '0', true, 'P2', NULL),
(8, 4, 'GRAIN: the pod-grain FEFO map is keyed one row per (machine, pod) - a fan-out through product_mapping would duplicate keys and silently pick an arbitrary expiry',
 'SELECT value->>''dup_keys'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''map''',
 'eq', '0', true, 'P2', NULL),
(8, 5, 'days_to_expiry is floored at zero, never negative - a negative would flip the ceiling''s sign and hand a short-dated shelf MORE stock',
 'SELECT value->>''negative_days'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''map''',
 'eq', '0', true, 'P2', NULL),
(8, 6, 'LAW 7 premise: no FEFO candidate is already expired at the live plan date. If this ever reds, expired stock is sitting in v_wh_pickable and the ceiling is the SYMPTOM, not the bug',
 'SELECT value->>''fefo_already_expired'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''map''',
 'eq', '0', true, 'P2', NULL),
(8, 7, 'The 2099-12-31 sentinel population is visible and non-empty - sentinels must resolve a NON-binding ceiling, which is what keeps venue-sourced pods unconstrained (fixture 5''s contract, seen from the expiry side)',
 'SELECT value->>''sentinel_dated'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''map''',
 'gt', '0', true, 'P2', NULL),
-- ---- half (b): the engine, gated on the FEATURE not the function -------------------------------
(8, 20, 'v3 TARGET: the engine ran and produced lines at this plan_date',
 'SELECT CASE WHEN (SELECT value->>''ran'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng'')=''true'' THEN (SELECT value->>''lines'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng'') ELSE ''-1'' END',
 'gt', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 21, 'LAW 5: every sized line NAMES its expiry basis. An unnamed source means a quantity moved on an expiry nobody can trace',
 'SELECT COALESCE((SELECT value->>''unnamed_source'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 22, 'PROVENANCE: every line carries the COMPLETE expiry block (days, factor, earliest_expiry), never a subset',
 'SELECT COALESCE((SELECT value->>''missing_keys'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 23, 'The safety factor comes from refill_policy_params, never a hardcoded 0.8 - otherwise tuning the param is a silent no-op',
 'SELECT COALESCE((SELECT value->>''factor_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 24, 'ARITHMETIC: ceiling_units = floor(days_to_expiry x sell_rate x safety), re-derived from the engine''s OWN recorded inputs',
 'SELECT COALESCE((SELECT value->>''formula_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 25, 'MONOTONIC: a ceiling may only REDUCE. need_raw may never exceed max(cover, floor) once the ceiling exists',
 'SELECT COALESCE((SELECT value->>''ceiling_lifted'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 26, 'CORE (LAW 5 / Cody rev 2): the expiry ceiling caps the COVER term and NEVER the min-facing floor. At this plan_date every WH-constrained shelf carries a ZERO ceiling, so a build that also capped the floor reds this fleet-wide',
 'SELECT COALESCE((SELECT value->>''zeroed_despite_floor'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 27, 'MISLABEL: a line the expiry ceiling pushed below its cover may never report clamp_reason=''skipped_full''. That label means the shelf is FULL and would hide the entire clamp class from procurement',
 'SELECT COALESCE((SELECT value->>''mislabelled_full'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 28, 'NON-VACUITY for seq 26: the zero-ceiling population is non-empty at this plan_date, so seq 26 is earned rather than vacuous',
 'SELECT COALESCE((SELECT value->>''zero_ceiling_lines'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'gt', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 29, 'NON-VACUITY for seq 26, the positive form: shelves WITH a zero ceiling still receive stock, which is the floor surviving - measured, not hoped for',
 'SELECT COALESCE((SELECT value->>''floor_protected'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
 'gt', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 30, 'LAW 7 (EXPIRY IRON RULE): sizing is READ-ONLY over inventory. warehouse_inventory row count is unchanged across the engine run - no expired unit exits by assumption',
 'SELECT CASE WHEN (SELECT value->>''ran'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng'')<>''true'' THEN ''-1'' WHEN (SELECT value->>''wi_after'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng'') = (SELECT value->>''wi'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before'') THEN ''0'' ELSE ''1'' END',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')'),
(8, 31, 'LAW 7 + DATA-SOURCE LAW: pod_inventory is expiry HISTORY only. Its row count is unchanged across the engine run',
 'SELECT CASE WHEN (SELECT value->>''ran'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng'')<>''true'' THEN ''-1'' WHEN (SELECT value->>''pi_after'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng'') = (SELECT value->>''pi'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before'') THEN ''0'' ELSE ''1'' END',
 'eq', '0', true, 'P2',
 'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname=''engine_add_pod_v3'' AND prosrc LIKE ''%expiry_source%'')');

-- Post-guard: the fixture landed with both halves and the engine half is genuinely gated.
DO $g$
DECLARE v_a int; v_gated int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE acceptance_gate_sql IS NOT NULL)
    INTO v_a, v_gated FROM golden.assertions WHERE fixture_id = 8;
  IF v_a <> 19 OR v_gated <> 12 THEN
    RAISE EXCEPTION 'fixture 8 guard: expected 19 assertions with 12 gated, got % / %', v_a, v_gated;
  END IF;
END $g$;
