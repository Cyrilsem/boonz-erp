-- PRD-110 P3.5 · fixture 42, two assertions added for a gap the GREEN run exposed.
--
-- ⛔ THE FINDING (S-71). A machine the picker cannot MEASURE scores exactly the same as a
-- machine with nothing at risk: both come out at 0.00 AED. Measured live on the first GREEN
-- run of rank_machines_by_value_at_risk_v3:
--
--   AMZ-1029-3003-O1  40 shelves, 24 with NO velocity and NO price   VAR 0.00  rank 21
--   AMZ-1038-3001-O1  40 shelves, 24 with NO velocity                VAR 0.00  rank 22
--   AMZ-1046-2406-O1  32 shelves, 16 with NO velocity                VAR 0.00  rank 23
--   AMZ-1057-2403-O1  40 shelves, 24 with NO velocity                VAR 0.00  rank 24
--   AMZ-1068-2401-O1  40 shelves, 24 with NO velocity                VAR 0.00  rank 25
--
-- 60% of each of those machines is invisible (the 112 NULL-pod_product_id shelves across 5
-- machines), and the ranking sinks all five to the bottom as though that were a verdict of
-- "safe". It is not a verdict, it is an absence - the same shape as PRD-110 fixture 3's blind
-- machine and the same family as LAW 5's "silent qty-0 is a build failure".
--
-- ⚠️ WHAT IS AND IS NOT FIXED HERE. Imputing demand for unmeasured shelves is P2.5 cold-start
-- work and changing the ranking for it would be scope drift, so the MODEL is unchanged. What
-- these assertions guarantee is that the absence is never invisible: the per-machine
-- no_velocity_shelves / no_price_basis_shelves counters sit beside every zero, and the number
-- in the reasoning blob can never drift away from the number in the column. A consumer that
-- reads 0.00 without reading the coverage counters is then making an explicit mistake rather
-- than being misled. The ranking question itself is CS decision D-25.
--
-- Both bodies carry the NO_PICKER_OUTPUT guard from S-70, applied here at authoring time
-- rather than after a RED caught it.

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES

(42, 52, 'BLIND-MACHINE SENSOR, NON-VACUOUS: machines exist right now that score 0.00 AED purely because the picker cannot see most of their shelves, and every one of them carries a non-zero no_velocity_shelves count beside the zero. If this ever reads 0 the sensor has stopped sensing, not the fleet stopped being blind',
 $q$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out')
                THEN '-1'
                ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
                       WHERE s.fixture_id=42 AND s.key='out'
                         AND (e->>'value_at_risk_aed')::numeric = 0
                         AND (e->>'no_velocity_shelves')::int > 0) END$q$,
 'gt', '0', true, 'P3'),

(42, 53, 'The coverage counters are ONE number, not two that can drift: no_velocity_shelves and no_price_basis_shelves in the reasoning blob equal the top-level columns on every row',
 $q$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out')
                THEN 'NO_PICKER_OUTPUT'
                ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
                       WHERE s.fixture_id=42 AND s.key='out'
                         AND ( (e->>'no_velocity_shelves')::int
                               IS DISTINCT FROM (e->'reasoning'->'coverage_gaps'->>'no_velocity_shelves')::int
                            OR (e->>'no_price_basis_shelves')::int
                               IS DISTINCT FROM (e->'reasoning'->'coverage_gaps'->>'no_price_basis_shelves')::int )) END$q$,
 'eq', '0', true, 'P3');
