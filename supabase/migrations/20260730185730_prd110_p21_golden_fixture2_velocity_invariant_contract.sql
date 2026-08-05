-- PRD-110 P2.1 · fixture 2 "Censored velocity cold-start" · golden schema only.
--
-- PREMISE RESTATED (S-04 house pattern; original spec text preserved in fixtures.notes).
-- GOLDEN-FIXTURES #2 says "shelf sells out in 6h daily ... assert v3 target >= 2x v19 qty".
-- Three measured reasons that cannot be asserted as written:
--   * WEIMI is a ~24h sampler (S-20): a 6-hour sell-out is invisible to it.
--   * The fleet-wide >=2x population is 2 shelves at >=10 units (leg 16). A fleet 2x is false.
--   * engine_add_pod_v3 does not exist yet, so there is no "v3 target" to compare.
-- So this fixture asserts the MECHANISM and the INVARIANT CONTRACT, per RISK 53's resolution:
-- anchor-independent laws only, and it RECORDS the anchor it ran against.
--
-- The mechanism is stronger than the spec's story. From the view body:
--     velocity_raw     = units_30d / 30.0            (fixed 30 calendar days)
--     velocity_instock = units_30d / (stock_hours/24)
-- so  velocity_instock / velocity_raw = 720 / stock_hours  -- an EXACT algebraic identity,
-- independent of the anchor, the numerator, and the fleet. That is seq 20, and it is the
-- real content of this fixture. I4 (>=) is the weaker corollary, true because stock_hours<=720.
--
-- The "censored shelves are faster" clause survives, CORRECTLY QUALIFIED: it holds for censored
-- series WITH SALES (77 of 77). The 2 apparent exceptions are zero-sales series where both
-- velocities are 0 -- measured, not assumed.
--
-- baseline_status='passing': unlike fixtures 2/3/10/26 at STEP 1, the objects this fixture
-- proves were built in legs 17-21, so a failing baseline is not available to capture honestly.
--
-- Reads each velocity object EXACTLY ONCE (S-26: never per-row, never per-machine).
-- Writes nothing outside golden.*. P2 fixtures take the 2030-02 plan_date block.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, notes, enabled, baseline_status, scenario_sql)
VALUES (2, 'Censored velocity cold-start', 'OMDBB Coca-Cola Zero (spec) / P2.1 velocity contract (as built)', 'P2', DATE '2030-02-02',
'ORIGINAL SPEC TEXT, preserved verbatim per the S-04 house pattern: "Shelf sells out in 6h daily; calendar velocity low, in-stock velocity high. Assert v3 target >= 2x v19 qty; stockout-decay guard keeps old velocity."

RESTATED because the premise is not observable (S-20): weimi is a ~24h sampler so a 6h sell-out is invisible; the fleet-wide >=2x population is 2 shelves, not a fleet property; and engine_add_pod_v3 does not exist yet.

STILL OWED by this fixture, to be re-derived from measurement (never from the spec guess) once engine_add_pod_v3 exists: the "v3 target vs v19 qty" clause and the stockout-decay guard. Add them as seq 60+ at that time. Tracked as S-20.',
 true, 'passing',
$fx$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'df_open', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'prp',     (SELECT count(*) FROM public.pod_refill_plan),
  'ev',      (SELECT count(*) FROM public.inventory_events),
  'comp',    (SELECT count(*) FROM public.shelf_composition),
  'anom',    (SELECT count(*) FROM public.inventory_anomalies));

-- POD GRAIN: one read of v_shelf_instock_velocity_v3 (S-26).
INSERT INTO golden.scratch (fixture_id, key, value)
WITH v AS (SELECT * FROM public.v_shelf_instock_velocity_v3)
SELECT {{fixture_id}}, 'pod', jsonb_build_object(
  'n_series',        (SELECT count(*) FROM v),
  'status_ok',       (SELECT count(*) FROM v WHERE velocity_status = 'ok'),
  'status_floor',    (SELECT count(*) FROM v WHERE velocity_status = 'below_floor'),
  'status_oocs',     (SELECT count(*) FROM v WHERE velocity_status = 'out_of_canonical_scope'),
  'status_other',    (SELECT count(*) FROM v WHERE velocity_status NOT IN ('ok','below_floor','out_of_canonical_scope') OR velocity_status IS NULL),
  'i1', (SELECT count(*) FROM v WHERE stock_hours > elapsed_hours),
  'i2', (SELECT count(*) FROM v WHERE stock_hours < 0 OR elapsed_hours < 0),
  'i3', (SELECT count(*) FROM v WHERE stock_censoring < 0 OR stock_censoring > 1),
  'i4', (SELECT count(*) FROM v WHERE velocity_instock IS NOT NULL AND velocity_raw IS NOT NULL AND velocity_instock < velocity_raw),
  'i5', (SELECT count(*) FROM v WHERE velocity_status = 'out_of_canonical_scope' AND (velocity_instock IS NOT NULL OR velocity_raw IS NOT NULL)),
  'i6', (SELECT count(*) FROM v WHERE velocity_status = 'below_floor' AND NOT (stock_hours < floor_hours AND velocity_instock IS NULL)),
  'i7', (SELECT count(*) FROM v WHERE velocity_status = 'ok' AND velocity_instock IS NULL),
  'i8', (SELECT count(*) FROM v WHERE n_case_a < 0 OR n_case_b < 0 OR n_case_c < 0 OR n_case_d < 0 OR n_case_x < 0),
  'i9', (SELECT count(*) FROM v WHERE n_case_a = 0 AND n_case_b = 0 AND n_case_c = 0 AND n_case_d = 0 AND n_case_x > 0 AND elapsed_hours IS NOT NULL),
  'identity_pop',  (SELECT count(*) FROM v WHERE velocity_instock IS NOT NULL AND velocity_raw > 0 AND stock_hours > 0),
  'identity_viol', (SELECT count(*) FROM v WHERE velocity_instock IS NOT NULL AND velocity_raw > 0 AND stock_hours > 0
                            AND abs(velocity_instock / velocity_raw - 720.0 / stock_hours) > 1e-4),
  'censored',            (SELECT count(*) FROM v WHERE stock_hours < elapsed_hours),
  'censored_sales',      (SELECT count(*) FROM v WHERE stock_hours < elapsed_hours AND units_30d_canonical > 0 AND velocity_instock IS NOT NULL),
  'censored_sales_slow', (SELECT count(*) FROM v WHERE stock_hours < elapsed_hours AND units_30d_canonical > 0 AND velocity_instock IS NOT NULL AND velocity_instock <= velocity_raw),
  'sh_over_720',   (SELECT count(*) FROM v WHERE stock_hours > 720),
  'case_a', (SELECT sum(n_case_a) FROM v), 'case_b', (SELECT sum(n_case_b) FROM v),
  'case_c', (SELECT sum(n_case_c) FROM v), 'case_d', (SELECT sum(n_case_d) FROM v),
  'floor_vals',  (SELECT count(DISTINCT floor_hours) FROM v),
  'floor_hours', (SELECT max(floor_hours) FROM v),
  'anchors',     (SELECT count(DISTINCT t_anchor) FROM v),
  't_anchor',    (SELECT max(t_anchor)::text FROM v),
  't_start',     (SELECT max(t_start)::text FROM v));

-- SHELF GRAIN: one read of v_shelf_instock_velocity_split_v3 (S-26).
INSERT INTO golden.scratch (fixture_id, key, value)
WITH s AS (SELECT * FROM public.v_shelf_instock_velocity_split_v3)
SELECT {{fixture_id}}, 'shelf', jsonb_build_object(
  'v1_rows',     (SELECT count(*) FROM s),
  'v1_shelves',  (SELECT count(DISTINCT shelf_id) FROM s),
  'v1_expected', (SELECT count(*) FROM public.v_shelf_state WHERE pod_product_id IS NOT NULL),
  'v2', (SELECT count(*) FROM (SELECT machine_id, pod_product_id, sum(w_instock) sw FROM s GROUP BY 1,2) t WHERE sw <> 1),
  'v3', (SELECT count(*) FROM (SELECT machine_id, pod_product_id, max(velocity_instock_pod) vp, sum(velocity_instock_shelf) vs
                                 FROM s WHERE velocity_instock_pod IS NOT NULL GROUP BY 1,2) t WHERE vs <> vp),
  'v3b',(SELECT count(*) FROM (SELECT machine_id, pod_product_id, max(velocity_raw_pod) vp, sum(velocity_raw_shelf) vs
                                 FROM s WHERE velocity_raw_pod IS NOT NULL GROUP BY 1,2) t WHERE vs <> vp),
  'v4', (SELECT count(*) FROM s WHERE w_instock < 0 OR w_instock > 1),
  'v5', (SELECT count(*) FROM s WHERE shelf_instock_hours > pod_instock_hours),
  'v6', (SELECT count(*) FROM s WHERE (velocity_instock_pod IS NULL) <> (velocity_instock_shelf IS NULL)),
  'v7', (SELECT count(*) FROM (SELECT machine_id, pod_product_id, count(*) FILTER (WHERE is_residual_absorber) n FROM s GROUP BY 1,2) t WHERE n <> 1),
  'method_unnamed', (SELECT count(*) FROM s WHERE split_method IS NULL OR split_method NOT IN ('single_shelf','instock_weighted','zero_instock','equal_fallback')),
  't_anchor',       (SELECT max(t_anchor)::text FROM s));
$fx$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(2,  1, 'premise: the censored population is real and large (not a 6h story, a measured one)',
     'SELECT value->>''censored'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '50', true, 'P2'),
(2,  2, 'I1: stock_hours <= elapsed_hours on every series',
     'SELECT value->>''i1'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2,  3, 'I2: neither hours column is ever negative',
     'SELECT value->>''i2'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2,  4, 'I3: stock_censoring stays inside [0,1]',
     'SELECT value->>''i3'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2,  5, 'I4 (strongest): velocity_instock >= velocity_raw wherever both are non-NULL',
     'SELECT value->>''i4'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2,  6, 'I5 / LAW 5: out_of_canonical_scope implies BOTH velocities NULL, never a silent zero',
     'SELECT value->>''i5'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2,  7, 'I6: below_floor implies stock_hours < floor_hours AND a NULL velocity (no divide-by-tiny)',
     'SELECT value->>''i6'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2,  8, 'I7: status ok implies a non-NULL velocity',
     'SELECT value->>''i7'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2,  9, 'I8: no negative case counts',
     'SELECT value->>''i8'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2, 10, 'I9: an all-X series carries a NULL elapsed_hours',
     'SELECT value->>''i9'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2, 11, 'velocity_status is one of exactly three named values - no silent fourth branch',
     'SELECT value->>''status_other'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2, 20, 'MECHANISM: velocity_instock/velocity_raw = 720/stock_hours EXACTLY (to the views own 6dp rounding). This is the fixture, not the 2x guess.',
     'SELECT value->>''identity_viol'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2, 21, 'and that identity is asserted over a large population, not a handful of rows',
     'SELECT value->>''identity_pop'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '300', true, 'P2'),
(2, 22, 'S-20 restated: censored series WITH SALES are strictly faster in-stock than on the calendar',
     'SELECT value->>''censored_sales_slow'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2, 23, 'and that clause has real subjects (the 2 apparent exceptions are zero-sales series, measured)',
     'SELECT value->>''censored_sales'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '50', true, 'P2'),
(2, 24, 'stock_hours never exceeds the 30d window - the ceiling that makes I4 true by construction',
     'SELECT value->>''sh_over_720'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '0', true, 'P2'),
(2, 25, 'the 48h floor is a single fleet-wide parameter, not a per-row accident',
     'SELECT value->>''floor_vals'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '1', true, 'P2'),
(2, 26, 'and it is 48 hours',
     'SELECT value->>''floor_hours'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '48.0', true, 'P2'),
(2, 27, 'the floor actually binds on real rows (below_floor is not an empty branch)',
     'SELECT value->>''status_floor'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '0', true, 'P2'),
(2, 28, 'case table exercised on real rows: case A non-empty',
     'SELECT value->>''case_a'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '0', true, 'P2'),
(2, 29, 'case table exercised: case B non-empty',
     'SELECT value->>''case_b'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '0', true, 'P2'),
(2, 30, 'case table exercised: case C (the depletion branch) non-empty',
     'SELECT value->>''case_c'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '0', true, 'P2'),
(2, 31, 'case table exercised: case D non-empty',
     'SELECT value->>''case_d'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'gt', '0', true, 'P2'),
(2, 40, 'ANCHOR RECORDED (RISK 53): the run reports the t_anchor it read, so a later investigation can separate "the anchor moved" from "the engine changed"',
     'SELECT value->>''t_anchor'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'ne', '', true, 'P2'),
(2, 41, 'the whole fleet shares ONE anchor - a per-machine anchor would silently mix windows',
     'SELECT value->>''anchors'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''', 'eq', '1', true, 'P2'),
(2, 42, 'CROSS-OBJECT: the shelf-split view reports the SAME anchor as its pod-grain parent',
     'SELECT ((SELECT value->>''t_anchor'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf'') = (SELECT value->>''t_anchor'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod''))::text', 'eq', 'true', true, 'P2'),
(2, 50, 'V1: one split row per pod-bound shelf, no fan-out',
     'SELECT ((SELECT value->>''v1_rows'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf'') = (SELECT value->>''v1_expected'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''))::text', 'eq', 'true', true, 'P2'),
(2, 51, 'V1b: and every row is a distinct shelf',
     'SELECT ((SELECT value->>''v1_rows'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf'') = (SELECT value->>''v1_shelves'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''))::text', 'eq', 'true', true, 'P2'),
(2, 52, 'V2 EXACT: weights sum to 1 per pod - equality, never a tolerance (RISK 62)',
     'SELECT value->>''v2'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 53, 'V3 EXACT: shelf in-stock velocities sum to the pod value - equality, never a tolerance',
     'SELECT value->>''v3'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 54, 'V3b EXACT: same conservation for the raw velocity',
     'SELECT value->>''v3b'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 55, 'V4: every weight lies in [0,1]',
     'SELECT value->>''v4'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 56, 'V5: a shelf never claims more in-stock hours than its pod',
     'SELECT value->>''v5'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 57, 'V6 / LAW 5: pod-NULL and shelf-NULL agree - a NULL pod velocity never becomes a shelf zero',
     'SELECT value->>''v6'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 58, 'V7: exactly one deterministic residual absorber per pod',
     'SELECT value->>''v7'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 59, 'every split row names its branch - no silent case (split_method is total)',
     'SELECT value->>''method_unnamed'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2'),
(2, 90, 'S-08 tripwire: open driver_feedback count unchanged by the fixture',
     'SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved = false) = (SELECT (value->>''df_open'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text', 'eq', 'true', true, 'P2'),
(2, 91, 'ADR 8.3 tripwire: pod_refill_plan row count unchanged across this run',
     'SELECT ((SELECT count(*) FROM public.pod_refill_plan) = (SELECT (value->>''prp'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text', 'eq', 'true', true, 'P2'),
(2, 95, 'RESIDUE: inventory_events row count unchanged (this fixture is read-only)',
     'SELECT ((SELECT count(*) FROM public.inventory_events) = (SELECT (value->>''ev'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text', 'eq', 'true', true, 'P2'),
(2, 96, 'RESIDUE: shelf_composition row count unchanged',
     'SELECT ((SELECT count(*) FROM public.shelf_composition) = (SELECT (value->>''comp'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text', 'eq', 'true', true, 'P2'),
(2, 97, 'RESIDUE: inventory_anomalies row count unchanged',
     'SELECT ((SELECT count(*) FROM public.inventory_anomalies) = (SELECT (value->>''anom'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text', 'eq', 'true', true, 'P2');
