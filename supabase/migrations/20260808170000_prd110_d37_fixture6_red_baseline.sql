-- PRD-110 leg 155 - D-37 (+ the S-293 rider) : THE RED BASELINE.
--
-- LAW 1. This migration ships NO engine change. It restates fixture 6 to the world CS
-- ruled for, and fixture 44's ladder md5 pin, and then the fixture is RED until the two
-- migrations that follow it land. That red is the proof, not an accident.
--
-- CS RULING (PARKING-LOT, 2026-08-03 queue clear):
--   "D-37 -> BUILD PARAM `ladder_prefer_own_stock_transfer` AND DEFAULT TRUE: full-pod
--    own-stock transfer outranks substitution. Fixture 6 seq 22/25/26 re-baseline per the
--    parked note; the 3,017-unit stranded pool is the acceptance evidence."
--
-- BINDING RIDER (S-293, raised OPEN at leg 154): `resolve_supply_ladder_v3` classifies
-- sentinel stock with an INLINE, name-only filter and calls neither canonical helper.
-- `NULL NOT LIKE ...` is NULL and `NULL LIKE ...` is NULL, so a NULL-batch row landed in
-- NO bucket at all. The parking lot says D-37 "must not restate the function without
-- absorbing it", so this fixture absorbs it too: every filter in this scenario now asks
-- the canonical NULL-safe question.
--
-- ⛔ S-272: every restatement below moves expect_op/expect WITH the shape of its check.
-- ⛔ Numbers were MEASURED in an S-287 dry run (dial + engine applied and the fleet walked
--    inside one doomed transaction), never guessed. Measured there: anchor terminates
--    alt_wh, fleet walked 41 / alt_wh 32 / substitute 9, new ladder md5 011f83d81c46b8fc6a7b668bbc426b91.

-- ===========================================================================
-- (1) THE SCENARIO. Same anchors, same reads, one classification rule changed.
-- ===========================================================================
UPDATE golden.fixtures SET scenario_sql = $scn155$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (0) ANCHORS. All real, all probed live.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'anchors', jsonb_build_object(
  'machine',     '5289578e-3c8f-48ec-b80c-3ba35e4d0f74',
  'shelf',       '7a2c7e07-271a-4f01-aa21-b9929c7bd1bd',
  'pod',         '4901aaf4-a2f4-4d62-a089-d68178aa6c7f',
  'wh_mcc',      '4fcfb52c-271f-4aa7-a373-3495e3271cd3',
  'wh_central',  '4bebef68-9e36-4a5c-9c2c-142f8dbdae85',
  'need',        6);

-- ---------------------------------------------------------------------------
-- (1) PREMISE, read from BASE TABLES and never from the function under test.
--     S-67 fan-out guard: DISTINCT the variants BEFORE any stock is summed.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH variants AS (
  SELECT DISTINCT pm.boonz_product_id
    FROM public.product_mapping pm
   WHERE pm.pod_product_id = '4901aaf4-a2f4-4d62-a089-d68178aa6c7f'
     AND pm.status = 'Active'
     AND (pm.machine_id = '5289578e-3c8f-48ec-b80c-3ba35e4d0f74' OR pm.machine_id IS NULL)
),
stock AS (
  SELECT
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
        AND w.warehouse_id = '4fcfb52c-271f-4aa7-a373-3495e3271cd3'), 0)::int AS real_mcc,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
        AND w.warehouse_id = '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'), 0)::int AS real_central,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
        AND w.warehouse_id IS DISTINCT FROM '4fcfb52c-271f-4aa7-a373-3495e3271cd3'), 0)::int AS real_other,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)), 0)::int AS phantom,
    count(DISTINCT w.warehouse_id) FILTER (
      WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
        AND w.warehouse_id IS DISTINCT FROM '4fcfb52c-271f-4aa7-a373-3495e3271cd3')::int AS alt_wh_count
  FROM variants v
  LEFT JOIN public.v_wh_pickable w
         ON w.boonz_product_id = v.boonz_product_id
        AND (w.reserved_for_machine_id IS NULL
             OR w.reserved_for_machine_id = '5289578e-3c8f-48ec-b80c-3ba35e4d0f74')
)
SELECT {{fixture_id}}, 'premise', jsonb_build_object(
  'pod_on_shelf',  (SELECT count(*)::int FROM public.v_shelf_state
                     WHERE shelf_id  = '7a2c7e07-271a-4f01-aa21-b9929c7bd1bd'
                       AND machine_id= '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'
                       AND pod_product_id = '4901aaf4-a2f4-4d62-a089-d68178aa6c7f'),
  'primary_wh',    (SELECT primary_warehouse_id::text   FROM public.machines
                     WHERE machine_id = '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'),
  'secondary_wh',  (SELECT COALESCE(secondary_warehouse_id::text,'none') FROM public.machines
                     WHERE machine_id = '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'),
  'op_model',      (SELECT COALESCE(operating_model,'fully_managed') FROM public.machines
                     WHERE machine_id = '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'),
  'real_mcc',      (SELECT real_mcc      FROM stock),
  'real_central',  (SELECT real_central  FROM stock),
  'real_other',    (SELECT real_other    FROM stock),
  'phantom',       (SELECT phantom       FROM stock),
  'alt_wh_count',  (SELECT alt_wh_count  FROM stock),
  'variants',      (SELECT count(*)::int FROM variants));

-- ---------------------------------------------------------------------------
-- (2) THE FLEET CENSUS of stranded stock, again straight from base tables.
--     A shelf is STRANDED when its pod has ZERO real stock at the machine's own
--     primary warehouse and MORE THAN ZERO real stock somewhere else.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH shelf AS (
  SELECT s.machine_id, s.shelf_id, s.pod_product_id, m.primary_warehouse_id
    FROM public.v_shelf_state s
    JOIN public.machines m ON m.machine_id = s.machine_id
   WHERE m.primary_warehouse_id IS NOT NULL
     AND COALESCE(m.operating_model,'fully_managed') <> 'partner_managed'
),
variants AS (
  SELECT sh.machine_id, sh.shelf_id, sh.pod_product_id, sh.primary_warehouse_id, v.boonz_product_id
    FROM shelf sh
    CROSS JOIN LATERAL (
      SELECT DISTINCT pm.boonz_product_id FROM public.product_mapping pm
       WHERE pm.pod_product_id = sh.pod_product_id AND pm.status = 'Active'
         AND (pm.machine_id = sh.machine_id OR pm.machine_id IS NULL)) v
),
sup AS (
  SELECT vr.machine_id, vr.shelf_id, vr.pod_product_id,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
        AND w.warehouse_id = vr.primary_warehouse_id), 0)::int AS real_primary,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
        AND w.warehouse_id IS DISTINCT FROM vr.primary_warehouse_id), 0)::int AS real_other
  FROM variants vr
  LEFT JOIN public.v_wh_pickable w
         ON w.boonz_product_id = vr.boonz_product_id
        AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = vr.machine_id)
  GROUP BY 1,2,3
)
SELECT {{fixture_id}}, 'census', jsonb_build_object(
  'stranded_shelves',  (SELECT count(*)::int                       FROM sup WHERE real_primary = 0 AND real_other > 0),
  'stranded_pods',     (SELECT count(DISTINCT pod_product_id)::int FROM sup WHERE real_primary = 0 AND real_other > 0),
  'stranded_machines', (SELECT count(DISTINCT machine_id)::int     FROM sup WHERE real_primary = 0 AND real_other > 0),
  'stranded_units',    (SELECT COALESCE(SUM(real_other),0)::int    FROM sup WHERE real_primary = 0 AND real_other > 0),
  'zero_primary_all',  (SELECT count(*)::int                       FROM sup WHERE real_primary = 0),
  -- leg 155 / D-37: the rule is "own-stock transfer outranks substitution ONLY when the
  -- move covers the whole need". These two counts state that precondition from BASE TABLES,
  -- so the fleet walk's terminal-rung split is checked against an independent number rather
  -- than against itself. 6 is this fixture's need, the same one the walk asks for.
  'stranded_full_cover', (SELECT count(*)::int FROM sup WHERE real_primary = 0 AND real_other >= 6),
  'stranded_partial',    (SELECT count(*)::int FROM sup WHERE real_primary = 0 AND real_other > 0 AND real_other < 6));

-- ---------------------------------------------------------------------------
-- (3) THE LADDER on the anchor. to_regprocedure-guarded so a missing object
--     READS as absent and every population fact above still lands (fixture 40 idiom).
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)') IS NOT NULL THEN
    BEGIN
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 6, 'ladder', public.resolve_supply_ladder_v3(
        DATE '2030-01-07',
        '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'::uuid,
        '7a2c7e07-271a-4f01-aa21-b9929c7bd1bd'::uuid,
        '4901aaf4-a2f4-4d62-a089-d68178aa6c7f'::uuid, 6, 5);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (6, 'ladder', jsonb_build_object('threw', SQLERRM));
    END;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- (4) THE FLEET VERDICT: what does the ladder actually DO with the stranded
--     units? One ladder call per stranded shelf. This is the S-118 evidence.
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      WITH shelf AS (
        SELECT s.machine_id, s.shelf_id, s.pod_product_id, m.primary_warehouse_id
          FROM public.v_shelf_state s JOIN public.machines m ON m.machine_id = s.machine_id
         WHERE m.primary_warehouse_id IS NOT NULL
           AND COALESCE(m.operating_model,'fully_managed') <> 'partner_managed'),
      variants AS (
        SELECT sh.machine_id, sh.shelf_id, sh.pod_product_id, sh.primary_warehouse_id, v.boonz_product_id
          FROM shelf sh
          CROSS JOIN LATERAL (SELECT DISTINCT pm.boonz_product_id FROM public.product_mapping pm
             WHERE pm.pod_product_id = sh.pod_product_id AND pm.status='Active'
               AND (pm.machine_id = sh.machine_id OR pm.machine_id IS NULL)) v),
      sup AS (
        SELECT vr.machine_id, vr.shelf_id, vr.pod_product_id,
          COALESCE(SUM(w.warehouse_stock) FILTER (WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
                   AND w.warehouse_id = vr.primary_warehouse_id),0)::int AS real_primary,
          COALESCE(SUM(w.warehouse_stock) FILTER (WHERE NOT public._is_phantom_wh_row_v3(w.batch_id, w.expiration_date)
                   AND w.warehouse_id IS DISTINCT FROM vr.primary_warehouse_id),0)::int AS real_other
        FROM variants vr
        LEFT JOIN public.v_wh_pickable w ON w.boonz_product_id = vr.boonz_product_id
             AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = vr.machine_id)
        GROUP BY 1,2,3),
      stranded AS (SELECT * FROM sup WHERE real_primary = 0 AND real_other > 0),
      walked AS (
        SELECT r->>'resolved_rung' AS rung,
               (r->'ladder'->2->>'satisfiable')::boolean AS rung3_sat,
               COALESCE((r->'ladder'->2->>'qty_available')::int,0) AS rung3_av,
               COALESCE((r->'ladder'->1->>'attempted')::boolean, false) AS rung2_att,
               jsonb_array_length(r->'ladder') AS n_rungs
          FROM stranded s
          CROSS JOIN LATERAL public.resolve_supply_ladder_v3(
                 DATE '2030-01-07', s.machine_id, s.shelf_id, s.pod_product_id, 6, 5) AS r)
      SELECT 6, 'fleet', jsonb_build_object(
        'walked',            (SELECT count(*)::int FROM walked),
        'term_substitute',   (SELECT count(*)::int FROM walked WHERE rung = 'substitute'),
        'term_alt_wh',       (SELECT count(*)::int FROM walked WHERE rung = 'alt_wh'),
        'rung3_seen',        (SELECT count(*)::int FROM walked WHERE rung3_sat),
        'rung3_units_seen',  (SELECT COALESCE(SUM(rung3_av),0)::int FROM walked),
        'rung3_invisible',   (SELECT count(*)::int FROM walked WHERE NOT rung3_sat),
        'rung2_skipped',     (SELECT count(*)::int FROM walked WHERE NOT rung2_att),
        'incomplete_ladders',(SELECT count(*)::int FROM walked WHERE n_rungs <> 6))
      $x$;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (6, 'fleet', jsonb_build_object('threw', SQLERRM));
    END;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- (5) THE RUNG-3 MACHINERY, proven directly (fixture 45's precedent for a rung
--     no live input can reach). THREE probes, each in its OWN guarded block so a
--     throw in one cannot collide on the scratch PK with a key already written:
--       bind_far     = the fixture's own 2030 plan_date -> LAW 7 artefact
--       bind_near    = CURRENT_DATE + 2                 -> the real binding proof
--       bind_primary = the same near call at rung variant -> the mirror
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public.resolve_fefo_sku_legs_v3(date,uuid,uuid,uuid,integer,text)') IS NOT NULL THEN
    BEGIN
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 6, 'bind_far', public.resolve_fefo_sku_legs_v3(
        DATE '2030-01-07', '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'::uuid,
        '7a2c7e07-271a-4f01-aa21-b9929c7bd1bd'::uuid,
        '4901aaf4-a2f4-4d62-a089-d68178aa6c7f'::uuid, 6, 'alt_wh');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (6, 'bind_far', jsonb_build_object('threw', SQLERRM));
    END;
  END IF;
END $do$;

DO $do$
BEGIN
  IF to_regprocedure('public.resolve_fefo_sku_legs_v3(date,uuid,uuid,uuid,integer,text)') IS NOT NULL THEN
    BEGIN
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 6, 'bind_near', public.resolve_fefo_sku_legs_v3(
        CURRENT_DATE + 2, '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'::uuid,
        '7a2c7e07-271a-4f01-aa21-b9929c7bd1bd'::uuid,
        '4901aaf4-a2f4-4d62-a089-d68178aa6c7f'::uuid, 6, 'alt_wh');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (6, 'bind_near', jsonb_build_object('threw', SQLERRM));
    END;
  END IF;
END $do$;

-- The PRIMARY-scope mirror. Same call, rung 'variant': it must find NOTHING,
-- because the whole point is that MCC is empty. Without this the alt-scope proof
-- above could be passing on stock the primary rung would have found anyway.
DO $do$
BEGIN
  IF to_regprocedure('public.resolve_fefo_sku_legs_v3(date,uuid,uuid,uuid,integer,text)') IS NOT NULL THEN
    BEGIN
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 6, 'bind_primary', public.resolve_fefo_sku_legs_v3(
        CURRENT_DATE + 2, '5289578e-3c8f-48ec-b80c-3ba35e4d0f74'::uuid,
        '7a2c7e07-271a-4f01-aa21-b9929c7bd1bd'::uuid,
        '4901aaf4-a2f4-4d62-a089-d68178aa6c7f'::uuid, 6, 'variant');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (6, 'bind_primary', jsonb_build_object('threw', SQLERRM));
    END;
  END IF;
END $do$;

-- Every warehouse the near-date binder actually touched, resolved from the batch
-- objects themselves rather than trusted from the seam's summary fields.
INSERT INTO golden.scratch (fixture_id, key, value)
WITH b AS (
  SELECT (bt->>'warehouse_id')          AS wh,
         (bt->>'expiration_date')::date AS exp,
         (bt->>'batch_id')              AS batch
    FROM golden.scratch s
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.value->'legs','[]'::jsonb)) AS lg
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(lg->'batches','[]'::jsonb))   AS bt
   WHERE s.fixture_id = 6 AND s.key = 'bind_near'
)
SELECT 6, 'bound_wh', jsonb_build_object(
  'n_batches',    (SELECT count(*)::int FROM b),
  'n_primary_wh', (SELECT count(*)::int FROM b WHERE b.wh = '4fcfb52c-271f-4aa7-a373-3495e3271cd3'),
  'n_central',    (SELECT count(*)::int FROM b WHERE b.wh = '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'),
  'n_expired',    (SELECT count(*)::int FROM b WHERE b.exp < CURRENT_DATE + 2),
  'n_sentinel',   (SELECT count(*)::int FROM b WHERE b.batch LIKE 'VOXSOURCE-%'),
  -- leg 153: the SHAPE-based twin of n_sentinel above. n_sentinel asks the NAME question and
  -- is NULL-blind by construction; this one asks the question that actually matters.
  'n_exp2099',    (SELECT count(*)::int FROM b WHERE b.exp = DATE '2099-12-31'));

-- ---------------------------------------------------------------------------
-- (6) LAW 3 / LAW 4 / LAW 12 attribution: this fixture is read-only, and says so
--     with numbers rather than with a promise.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT 6, 'writes', jsonb_build_object(
  'rpo_live',    (SELECT count(*)::int FROM public.refill_plan_output        WHERE plan_date = DATE '2030-01-07'),
  'rpo_shadow',  (SELECT count(*)::int FROM public.refill_plan_output_shadow WHERE plan_date = DATE '2030-01-07'),
  'pod_shadow',  (SELECT count(*)::int FROM public.pod_refills_shadow        WHERE plan_date = DATE '2030-01-07'),
  'blocked',     (SELECT count(*)::int FROM public.blocked_demand            WHERE plan_date = DATE '2030-01-07'),
  'ladder_vol',  (SELECT p.provolatile::text FROM pg_proc p WHERE p.proname='resolve_supply_ladder_v3'
                    AND p.pronamespace='public'::regnamespace ORDER BY p.oid LIMIT 1),
  'ladder_def',  (SELECT p.prosecdef::text   FROM pg_proc p WHERE p.proname='resolve_supply_ladder_v3'
                    AND p.pronamespace='public'::regnamespace ORDER BY p.oid LIMIT 1),
  'binder_vol',  (SELECT p.provolatile::text FROM pg_proc p WHERE p.proname='resolve_fefo_sku_legs_v3'
                    AND p.pronamespace='public'::regnamespace ORDER BY p.oid LIMIT 1),
  'ladder_md5',  (SELECT md5(p.prosrc)       FROM pg_proc p WHERE p.proname='resolve_supply_ladder_v3'
                    AND p.pronamespace='public'::regnamespace ORDER BY p.oid LIMIT 1),
  'binder_md5',  (SELECT md5(p.prosrc)       FROM pg_proc p WHERE p.proname='resolve_fefo_sku_legs_v3'
                    AND p.pronamespace='public'::regnamespace ORDER BY p.oid LIMIT 1),
  'stitch_alt',  (SELECT CASE WHEN p.prosrc LIKE '%''variant'',''substitute'',''alt_wh''%'
                              THEN 'ROUTED' ELSE 'ABSENT' END
                    FROM pg_proc p WHERE p.proname='stitch_v3'
                     AND p.pronamespace='public'::regnamespace ORDER BY p.oid LIMIT 1),
  'stitch_xfer', (SELECT CASE WHEN p.prosrc LIKE '%ELSE ''Transfer''%'
                              THEN 'TRANSFER' ELSE 'ABSENT' END
                    FROM pg_proc p WHERE p.proname='stitch_v3'
                     AND p.pronamespace='public'::regnamespace ORDER BY p.oid LIMIT 1));


-- ---------------------------------------------------------------------------
-- (7) leg 153: THE CLASSIFIER TRUTH TABLE, EXECUTED rather than inspected (S-273).
--     Guarded in the fixture-40 idiom so a missing object READS as absent instead of
--     throwing the whole scenario.
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public._is_phantom_wh_row_v3(text,date)') IS NOT NULL THEN
    BEGIN
      EXECUTE $x$
        INSERT INTO golden.scratch (fixture_id, key, value)
        SELECT 6, 'classifier', jsonb_build_object(
          'null_batch_sentinel_exp', public._is_phantom_wh_row_v3(NULL, DATE '2099-12-31'),
          'named_sentinel',          public._is_phantom_wh_row_v3('VOXSOURCE-42', DATE '2099-12-31'),
          'real_named_batch',        public._is_phantom_wh_row_v3('BATCH-1', DATE '2027-01-01'),
          'null_batch_real_exp',     public._is_phantom_wh_row_v3(NULL, DATE '2027-01-01'),
          'both_null',               public._is_phantom_wh_row_v3(NULL, NULL))
      $x$;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO golden.scratch (fixture_id, key, value)
      VALUES (6, 'classifier', jsonb_build_object('threw', SQLERRM));
    END;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- (8) leg 155: D-37 + S-293 SENSORS. The dial is read through DYNAMIC SQL on purpose:
--     this scenario has to run on a database where the column does not exist yet, which
--     is exactly the state between the red-baseline migration and the engine migration
--     (and the state a from-scratch replay passes through). A static column reference
--     would fail to PARSE there and take the whole scenario down with it.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_dial text := 'ABSENT';
BEGIN
  BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'refill_policy_params'
                  AND column_name = 'ladder_prefer_own_stock_transfer') THEN
      EXECUTE 'SELECT COALESCE(ladder_prefer_own_stock_transfer::text, ''NULL'')
                 FROM public.refill_policy_params ORDER BY id LIMIT 1' INTO v_dial;
    END IF;
    INSERT INTO golden.scratch (fixture_id, key, value)
    SELECT 6, 'd37', jsonb_build_object(
      'dial', v_dial,
      -- S-293's population, from the base view. `unbucketed_old` is the count the RETIRED
      -- name-only filter placed in NEITHER bucket: both `batch_id NOT LIKE ...` and
      -- `batch_id LIKE ...` evaluate to NULL on a NULL batch_id, so the row was neither
      -- real supply nor a reported phantom - it simply disappeared.
      'null_batch_rows',    (SELECT count(*)::int FROM public.v_wh_pickable WHERE batch_id IS NULL),
      'null_batch_phantom', (SELECT count(*)::int FROM public.v_wh_pickable
                              WHERE batch_id IS NULL
                                AND public._is_phantom_wh_row_v3(batch_id, expiration_date)),
      'null_batch_real',    (SELECT count(*)::int FROM public.v_wh_pickable
                              WHERE batch_id IS NULL
                                AND NOT public._is_phantom_wh_row_v3(batch_id, expiration_date)),
      'unbucketed_old',     (SELECT count(*)::int FROM public.v_wh_pickable
                              WHERE (batch_id NOT LIKE 'VOXSOURCE-%') IS NULL
                                AND (batch_id LIKE 'VOXSOURCE-%') IS NULL),
      'ladder_inline_name_filter',
        (SELECT CASE WHEN position('NOT LIKE ''VOXSOURCE-%''' IN p.prosrc) > 0
                     THEN 'INLINE_NAME_FILTER' ELSE 'DELEGATES' END
           FROM pg_proc p WHERE p.proname = 'resolve_supply_ladder_v3'
            AND p.pronamespace = 'public'::regnamespace ORDER BY p.oid LIMIT 1));
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (6, 'd37', jsonb_build_object('threw', SQLERRM));
  END;
END $do$;
$scn155$ WHERE fixture_id = 6;

UPDATE golden.fixtures
   SET name = 'Stranded stock reroute: real own-pod stock at a NON-primary warehouse is seen by the ladder at rung 3, and under D-37 (ladder_prefer_own_stock_transfer, CS DEFAULT TRUE) a FULL-cover transfer now outranks substitution, so the stranded units move instead of the customer''s assortment changing (P3.1b / S-118 / D-37 / S-293)'
 WHERE fixture_id = 6;

-- ===========================================================================
-- (2) THE RESTATEMENTS. Restated, never deleted (the parked D-37 note).
-- ===========================================================================
UPDATE golden.assertions SET expect_op = $q$gte$q$, expect = $q$1$q$,
       description = $q$PREMISE, RESTATED at leg 155 (was: premise key `sentinel`, eq 0 - and it was VACUOUSLY GREEN, S-289). The retired name-only filter read ZERO phantom units behind this pod because both of its phantom rows carry a NULL batch_id; the NULL-safe shape test finds them and the units they hold. The fixture's point does not rest on this number - it rests on seq 6, that the CENTRAL units being rerouted are REAL. This assertion is now the guard a revert to a name-only test would trip, because such a test reads 0 here.$q$,
       check_sql = $q$SELECT (value->>'phantom') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$q$
 WHERE fixture_id = 6 AND seq = 7;

UPDATE golden.assertions SET expect_op = $q$eq$q$, expect = $q$alt_wh$q$,
       description = $q$D-37, RESTATED at leg 155 (was 'substitute'). CS ruled ladder_prefer_own_stock_transfer DEFAULT TRUE: a FULL-cover transfer of the shelf's OWN pod outranks rewriting the shelf to a different product. The anchor's 6 units are fully covered at CENTRAL, so the terminal rung moves from 2 to 3 and the stranded units finally move. S-118 is not deleted by this - it is CLOSED by it, and the old expectation is preserved in this sentence.$q$
 WHERE fixture_id = 6 AND seq = 22;

UPDATE golden.assertions SET expect_op = $q$eq$q$, expect = $q$POD_PRESERVED$q$,
       description = $q$D-37, RESTATED at leg 155 (was 'DIFFERENT_POD'). The whole business point of the ruling: the customer-visible assortment is PRESERVED. The terminal payload names no substitute pod at all, because no substitution happened. The two substitution outcomes are kept as distinguishable failure values rather than collapsed, so a regression reads as SAME_POD or DIFFERENT_POD and not as a bare false.$q$,
       check_sql = $q$SELECT CASE WHEN (value->'payload'->>'substitute_pod_product_id') IS NULL THEN 'POD_PRESERVED'
            WHEN (value->'payload'->>'substitute_pod_product_id') = '4901aaf4-a2f4-4d62-a089-d68178aa6c7f' THEN 'SAME_POD'
            ELSE 'DIFFERENT_POD' END
   FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$q$
 WHERE fixture_id = 6 AND seq = 23;

UPDATE golden.assertions SET expect_op = $q$eq$q$, expect = $q$EXACT$q$,
       description = $q$D-37 FLEET, RESTATED at leg 155 (was: term_alt_wh eq 0, 'rung 3 is unreachable'). It is reachable now, and the assertion states the RULE rather than a count that would decay with the data: the number of stranded shelves terminating at alt_wh must EQUAL the number whose own pod is transferable IN FULL, counted independently from base tables in the census. Not one more (that would mean a partial transfer was taken) and not one fewer (that would mean a full-cover transfer was passed over for a substitution).$q$,
       check_sql = $q$SELECT CASE WHEN (SELECT (value->>'term_alt_wh') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')
               = (SELECT (value->>'stranded_full_cover') FROM golden.scratch WHERE fixture_id=6 AND key='census')
          THEN 'EXACT' ELSE 'MISMATCH' END$q$
 WHERE fixture_id = 6 AND seq = 25;

UPDATE golden.assertions SET expect_op = $q$eq$q$, expect = $q$PARTITIONED$q$,
       description = $q$D-37 FLEET, RESTATED at leg 155 (was 'ALL_SUBSTITUTE': rung 2 was an absorbing state). It no longer absorbs everything, so the assertion moves to the property that must hold whatever the data does: every walked stranded shelf terminates at alt_wh or at substitute and nowhere else. A shelf falling through to m2m, spot_buy or blocked_demand would mean the ladder lost stock it had already reported as satisfiable, and that reads as LEAKED.$q$,
       check_sql = $q$SELECT CASE WHEN ((SELECT (value->>'term_alt_wh') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')::int
                + (SELECT (value->>'term_substitute') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')::int)
               = (SELECT (value->>'walked') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')::int
          THEN 'PARTITIONED' ELSE 'LEAKED' END$q$
 WHERE fixture_id = 6 AND seq = 26;

UPDATE golden.assertions SET expect_op = $q$gte$q$, expect = $q$1$q$,
       description = $q$LAW 5, description restated at leg 155 (the check and its bar are unchanged): the fleet-wide transferable units the ladder REPORTS are a positive, auditable number. Before D-37 the ladder reported them and then declined to spend them; it now spends the full-cover ones. Either way the reporting must never fall to zero, because a zero here would mean rung 3 had gone silently invisible again.$q$
 WHERE fixture_id = 6 AND seq = 28;

UPDATE golden.assertions SET expect_op = $q$eq$q$, expect = $q$011f83d81c46b8fc6a7b668bbc426b91$q$,
       description = $q$LAW 3: resolve_supply_ladder_v3 carries the D-37 body and no other. Restated at leg 155 (was 056cca45..., the D-27(a) body). The authorised movement is TWO changes in one reviewed unit: D-37's rung-order preference behind ladder_prefer_own_stock_transfer, and S-293's replacement of the inline name-only sentinel filter with the canonical NULL-safe predicate. This value was taken from the S-287 dry run that produced the body, not from a guess. ⛔ Any OTHER movement of this md5 is an unreviewed engine edit.$q$
 WHERE fixture_id = 6 AND seq = 50;

UPDATE golden.assertions SET expect_op = $q$eq$q$, expect = $q$011f83d81c46b8fc6a7b668bbc426b91$q$,
       description = $q$The ladder carries the D-37 body and no other (LAW 3). Restated at leg 155 (was 056cca45..., the D-27(a) body): D-37's rung-order preference plus S-293's NULL-safe sentinel classification. ⛔ Any OTHER movement of this md5 is an unreviewed engine edit.$q$
 WHERE fixture_id = 44 AND seq = 28;

-- ===========================================================================
-- (3) THE NEW SENSORS. Seq 58..66; fixture 6 sat at max(seq) = 57.
-- ===========================================================================
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 58, $q$D-37 NON-VACUITY: seq 25 is an equality between two numbers, and two zeroes would satisfy it while proving nothing. At least one stranded shelf must actually terminate at alt_wh on live data. If this reds while 25 stays green, the ruling has stopped firing rather than the rule having broken.$q$, $q$SELECT (value->>'term_alt_wh') FROM golden.scratch WHERE fixture_id=6 AND key='fleet'$q$, $q$gte$q$, $q$1$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 59, $q$D-37 SELF-REPORT: the ladder SAYS the preference is what moved this decision, in its own supply object, rather than leaving the reader to infer it from a rung number. An alt_wh terminal reached by rung 2 simply having no candidate is a different outcome with the same name, and this is what tells the two apart.$q$, $q$SELECT (value->'supply'->>'own_stock_transfer_preempted_substitution') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$q$, $q$eq$q$, $q$true$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 60, $q$D-37 SHORT-CIRCUIT: rung 2's expensive selector is NOT run when a full-cover own-stock transfer already outranks it. This is the BUILD-SPEC's existing short-circuit idiom (the only rung permitted to skip, and only when it says so explicitly), extended to the second case where the answer cannot change the outcome. The rung is still LOGGED - seq 21 keeps proving all six are there.$q$, $q$SELECT (value->'ladder'->1->>'attempted') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$q$, $q$eq$q$, $q$false$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 61, $q$D-37 SHORT-CIRCUIT, FLEET-WIDE: the selector is skipped on exactly the shelves D-37 preempted - no more (a skip on a shelf that then substituted would mean a substitution was chosen without a selector ever running) and no fewer (a preempted shelf that still paid for the selector is wasted work, which is the other half of what this change is for).$q$, $q$SELECT CASE WHEN (SELECT (value->>'rung2_skipped') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')
               = (SELECT (value->>'term_alt_wh') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')
          THEN 'EXACT' ELSE 'MISMATCH' END$q$, $q$eq$q$, $q$EXACT$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 62, $q$THE DIAL IS THE RULING: ladder_prefer_own_stock_transfer reads true on the live single-row policy table. CS ruled DEFAULT TRUE, so this fixture asserts the STATE and not merely the column's existence. Reads ABSENT between this migration and the dial migration, which is the intended red.$q$, $q$SELECT (value->>'dial') FROM golden.scratch WHERE fixture_id=6 AND key='d37'$q$, $q$eq$q$, $q$true$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 63, $q$S-293 CLOSED, BY SHAPE: the ladder's body no longer contains the inline name-only sentinel test at all. Pinned as a body property rather than as an output number so it cannot be satisfied by data that happens to have no NULL batch_ids that day. The sibling idiom is fixture 40 seq 32 ('DELEGATES').$q$, $q$SELECT (value->>'ladder_inline_name_filter') FROM golden.scratch WHERE fixture_id=6 AND key='d37'$q$, $q$eq$q$, $q$DELEGATES$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 64, $q$S-293 WAS A LIVE DEFECT, NOT A THEORETICAL ONE: this counts the pickable rows the RETIRED filter placed in NEITHER bucket - both its predicates evaluate NULL on a NULL batch_id, so those rows were neither real supply nor a reported phantom. They simply vanished. This is a DATA sensor: it stays informative after the fix and tells the next leg how much a revert would cost.$q$, $q$SELECT (value->>'unbucketed_old') FROM golden.scratch WHERE fixture_id=6 AND key='d37'$q$, $q$gte$q$, $q$1$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 65, $q$S-293's ACTUAL INVARIANT: the two buckets are a PARTITION over the rows that broke the old one. Every NULL-batch pickable row is classified phantom or real, exactly once, never neither. This is the property the name-only filter violated, stated over the exact population that violated it.$q$, $q$SELECT CASE WHEN ((SELECT (value->>'null_batch_phantom') FROM golden.scratch WHERE fixture_id=6 AND key='d37')::int
                + (SELECT (value->>'null_batch_real') FROM golden.scratch WHERE fixture_id=6 AND key='d37')::int)
               = (SELECT (value->>'null_batch_rows') FROM golden.scratch WHERE fixture_id=6 AND key='d37')::int
          THEN 'PARTITION' ELSE 'LEAK' END$q$, $q$eq$q$, $q$PARTITION$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (6, 66, $q$AUDITABILITY: the terminal payload NAMES the ruling that produced it, so a Transfer line stitched from this rung can be traced back to a CS decision rather than to an unexplained rung number. The same discipline as the rung reasons - no bare verdicts.$q$, $q$SELECT (value->'payload'->>'rule') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$q$, $q$contains$q$, $q$D-37$q$, true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description = EXCLUDED.description,
  check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

-- ===========================================================================
-- (4) READ-BACK, IN THIS TRANSACTION. A migration that silently matched zero rows
--     is the failure mode this block exists to make impossible.
-- ===========================================================================
DO $do$
DECLARE
  v_n int; v_scn text; v_bad text;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 6;
  IF v_n <> 66 THEN
    RAISE EXCEPTION 'fixture 6 carries % assertion(s), expected 66', v_n;
  END IF;

  SELECT string_agg(fixture_id || ':' || seq, ', ' ORDER BY fixture_id, seq) INTO v_bad
    FROM golden.assertions
   WHERE (fixture_id = 6 AND seq = 7  AND (expect <> '1'            OR expect_op <> 'gte'))
      OR (fixture_id = 6 AND seq = 22 AND (expect <> 'alt_wh'       OR expect_op <> 'eq'))
      OR (fixture_id = 6 AND seq = 23 AND (expect <> 'POD_PRESERVED'OR expect_op <> 'eq'))
      OR (fixture_id = 6 AND seq = 25 AND (expect <> 'EXACT'        OR expect_op <> 'eq'))
      OR (fixture_id = 6 AND seq = 26 AND (expect <> 'PARTITIONED'  OR expect_op <> 'eq'))
      OR (fixture_id = 6 AND seq = 50 AND expect <> '011f83d81c46b8fc6a7b668bbc426b91')
      OR (fixture_id = 44 AND seq = 28 AND expect <> '011f83d81c46b8fc6a7b668bbc426b91');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'restatement did not land on: %', v_bad;
  END IF;

  SELECT scenario_sql INTO v_scn FROM golden.fixtures WHERE fixture_id = 6;
  -- ⛔ S-291(c) IN ANGER, AGAIN: the first form of this guard searched for the bare token
  -- and REFUSED - because the (8) sensor block below quotes that very token in order to ask
  -- whether the ENGINE still carries it. The guard was reworded, not relaxed: what must be
  -- gone is the ALIASED filter form every retired predicate in this scenario used, and the
  -- two counts were measured on the new text (0 and 0) before being written here.
  IF position('w.batch_id NOT LIKE' IN v_scn) > 0 OR position('w.batch_id LIKE' IN v_scn) > 0 THEN
    RAISE EXCEPTION 'S-293: a retired name-only FILTER still survives in fixture 6 scenario_sql';
  END IF;
  IF position('_is_phantom_wh_row_v3' IN v_scn) < 1 THEN
    RAISE EXCEPTION 'S-293: fixture 6 scenario_sql does not call the canonical predicate';
  END IF;
  IF position('stranded_full_cover' IN v_scn) < 1 OR position('rung2_skipped' IN v_scn) < 1 THEN
    RAISE EXCEPTION 'the new census / fleet keys did not land in scenario_sql';
  END IF;

  -- ⛔ The engine has NOT moved yet, and this migration asserts that on purpose: it is the
  -- statement that the reds about to appear are LAW 1's proof and not a half-applied unit.
  IF (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'resolve_supply_ladder_v3'
        AND pronamespace = 'public'::regnamespace) <> '056cca45077bb00f31ab663409d4c573' THEN
    RAISE EXCEPTION 'the ladder body moved before its red baseline was recorded - abort';
  END IF;
END $do$;

SELECT 'prd110_leg155_d37_fixture6_red_baseline' AS applied;
