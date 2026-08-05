-- PRD-110 leg 33 · S-37 · FIXTURE FIRST (LAW 1) · golden schema only, nothing else touched.
--
-- INCIDENT (S-37, found leg 32). `v_shelf_sales_identity` and `v_shelf_instock_velocity_v3`
-- both canonicalise a hardcoded pod alias (168aeb7e 'Hunter' -> 51e4600f 'Hunter Ridge').
-- `v_shelf_instock_velocity_split_v3` does NOT. Its final line joins
--     v.pod_product_id (CANONICAL)  =  f.pod_product_id (RAW, from v_shelf_state)
-- so every Hunter-keyed shelf misses the join and silently gets a NULL velocity.
-- Measured live this leg: 16 Hunter shelves / 16 machines, 10 Hunter Ridge, 26 in the family.
--
-- WHY THIS FIXTURE EXISTS AT ALL, given the suite is green: the three invariants that SHOULD
-- have caught this cannot, and it is worth being precise about why, because the same blind
-- spot will recur.
--   * seq 52/53 (conservation) cannot: the view has a RESIDUAL ABSORBER
--     (w_instock = w_raw + (1 - w_sum) on rank 1), so sum(w) is forced to exactly 1 by
--     construction, whatever the partition key is. Conservation is LAUNDERED, not proven.
--   * seq 57 (V6, pod-NULL <=> shelf-NULL) cannot: when the join misses, BOTH sides are NULL,
--     so the asymmetry looks perfectly self-consistent from inside the view.
--   * seq 50 (one row per pod-bound shelf) cannot: the row count is unaffected by the key.
--
-- THE TRAP THIS FIXTURE IS REALLY FOR (found THIS leg, not in leg 32's write-up).
-- Leg 32 dry-ran the fix and proved conservation exact (max |sum(w)-1| = 0.000000000, 0 pods
-- violating) and concluded the fix was proven. That proof is NECESSARY BUT NOT SUFFICIENT, for
-- exactly the absorber reason above. Measured this leg: ALL 26 family shelves carry
-- pod_shelf_count = 1, because v_shelf_state computes it as
--     count(*) OVER (PARTITION BY b.machine_id, i.pod_product_id)   -- RAW key
-- and 7 machines carry BOTH a Hunter and a Hunter Ridge shelf (ALJLT-1015-0100-B1,
-- ALJLT-1015-0200-O1, AMZ-1046-2406-O1, HUAWEI-2003-0000-B1, MC-2004-0100-O1,
-- USH-1008-0000-W1, WAVEMAKER-1006-4100-O1). So canonicalising ONLY the partition keys merges
-- two shelves that each still believe n = 1, each takes the 'single_shelf' branch and claims
-- w_raw = 1.0, w_sum becomes 2.0, and the absorber "repairs" it to
--     one shelf w = 0.0  and  the other w = 1.0.
-- Conservation stays EXACTLY 0. One real shelf silently receives ZERO velocity. That is a
-- LAW 5 silent zero wearing a passing conservation check.
-- => `n` must be recomputed over the MERGED group, not just the partition keys canonicalised.
--    seq 62 and 63 below are the assertions that make that non-negotiable.
--
-- COST. Adds ZERO reads. All five measurements come from the SINGLE existing read of
-- v_shelf_instock_velocity_split_v3 already in this fixture's scenario (S-26: read each
-- velocity object exactly once, never per-machine). A separate fixture would have added a
-- second full evaluation of the most expensive object in the schema to every suite run.
--
-- EXPECTED RED -- DECLARED LOUDLY, READ THIS BEFORE CRYING REGRESSION.
-- The suite's expected-red set was EMPTY before this migration. After it, seq 60 and 61 are
-- expected-red until the view is fixed, and they are THE ONLY TWO. They are gated on evidence
-- (does the split view's own definition canonicalise?), not on a hand-maintained phase label,
-- so they become binding automatically the instant the fix lands, with no second migration and
-- nobody having to remember. seq 62/63/64 are UNGATED regression tripwires: they pass TODAY
-- and must never stop passing -- 62/63 are precisely what a naive join-only fix would break.
--
-- Writes nothing outside golden.*. No protected entity, no RLS, no SECURITY DEFINER, no live
-- plan table, no engine body, no flag, no cron.

-- ---------------------------------------------------------------------------------------
-- 1. Extend the SHELF-grain scratch block with the five S-37 measurements.
--    Every pre-existing key is preserved byte-identically; only new keys are appended.
-- ---------------------------------------------------------------------------------------
UPDATE golden.fixtures SET scenario_sql = $fx$
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
  't_anchor',       (SELECT max(t_anchor)::text FROM s),
  -- ---- S-37 (leg 33). Same single read; no extra evaluation. ----
  -- The alias pair is written out literally on purpose: it is the SAME pair hardcoded in
  -- v_shelf_instock_velocity_v3 and v_shelf_sales_identity. If that production decision is
  -- ever revisited (see the flagged PRD-109 name-family concern), this fixture must be
  -- revisited in the same change -- and it will fail loudly rather than drift silently.
  's37_family',      (SELECT count(*) FROM s WHERE pod_product_id IN ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,'51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)),
  's37_raw_key',     (SELECT count(*) FROM s WHERE pod_product_id = '168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid),
  's37_family_null', (SELECT count(*) FROM s WHERE pod_product_id IN ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,'51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
                                             AND velocity_instock_shelf IS NULL),
  -- GENERAL law, not family-scoped: pod_shelf_count must equal the size of its own split
  -- group and be constant within it. Holds today; a join-only canonicalisation breaks it on
  -- all 14 shelves of the 7 dual machines. This is the trap-catcher.
  's37_n_mismatch',  (SELECT count(*) FROM (SELECT machine_id, pod_product_id, count(*) AS c,
                                                   min(pod_shelf_count) AS nmin, max(pod_shelf_count) AS nmax
                                            FROM s GROUP BY 1,2) t
                      WHERE t.c <> t.nmin OR t.nmin <> t.nmax),
  -- The absorber's laundering signature: a 'single_shelf' row is the ONLY row in its group, so
  -- its weight must be exactly 1. Under a join-only fix the absorber hands one of the two
  -- merged singletons w = 0.0 while conservation still reads exactly 0.
  's37_single_w',    (SELECT count(*) FROM s WHERE split_method = 'single_shelf' AND w_instock <> 1.0));
$fx$
WHERE fixture_id = 2;

-- ---------------------------------------------------------------------------------------
-- 2. The assertions.
--    60, 61 -> GATED (expected-red until the split view canonicalises). THE ONLY TWO.
--    62, 63, 64 -> UNGATED regression tripwires. Green today, must stay green.
-- ---------------------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql) VALUES
(2, 60, 'S-37: the split view resolves the pod alias, so NO split row is still keyed by the RAW alias pod. RED until v_shelf_instock_velocity_split_v3 canonicalises (16 rows today).',
     'SELECT value->>''s37_raw_key'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2',
     'SELECT pg_get_viewdef(''public.v_shelf_instock_velocity_split_v3''::regclass) LIKE ''%51e4600f-2c15-428b-92ef-85fdc783c3af%'''),
(2, 61, 'S-37: at most 2 shelves in the merged alias family lack a shelf velocity, and the 2 permitted are AMZ-1046 (D-13, stale Adyen metadata), NOT a join miss. RED until fixed (16 today).',
     'SELECT value->>''s37_family_null'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'lte', '2', true, 'P2',
     'SELECT pg_get_viewdef(''public.v_shelf_instock_velocity_split_v3''::regclass) LIKE ''%51e4600f-2c15-428b-92ef-85fdc783c3af%'''),
(2, 62, 'S-37 TRAP-CATCHER (ungated): pod_shelf_count equals its own split-group size and is constant within it. A join-only canonicalisation breaks this on 14 shelves while conservation still reads exactly 0.',
     'SELECT value->>''s37_n_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2', NULL),
(2, 63, 'S-37 TRAP-CATCHER (ungated) / LAW 5: a single_shelf row is alone in its group, so its weight is exactly 1. Catches the residual absorber laundering a merged pair into w=0.0 and w=1.0.',
     'SELECT value->>''s37_single_w'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '0', true, 'P2', NULL),
(2, 64, 'S-37 NON-VACUITY (ungated): the alias family is a real, conserved population of 26 shelves. Without this, seq 60 goes green the day the family empties out for an unrelated reason.',
     'SELECT value->>''s37_family'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''shelf''', 'eq', '26', true, 'P2', NULL);
