-- PRD-110 · PHASE 3 GATE · golden fixture 6 - "Stranded stock reroute" (Pepsi Black)
--
-- GOLDEN-FIXTURES row 6: "Stock in CENTRAL, machine draws MCC. Assert ladder emits transfer
-- line or reroute, NOT unbound dispatch."
--
-- THE POINTER'S RE-MAP WAS HALF RIGHT AND IS CORRECTED HERE. Leg 74's pointer proposed
--   "6 -> ladder rung 3 alt_wh inside fixture 40". Probed, not assumed: fixture 40's only
--   two rung-3 assertions (seq 25, 26) are NEGATIVE, proving phantom VOXSOURCE stock does
--   NOT rescue anchor A. No fixture anywhere asserted a POSITIVE alt-WH reroute, so
--   fixture 6's premise was genuinely unproven. It is built here.
--
-- AND BUILDING IT SURFACED S-118. The incident geometry is live and exact:
--     IFLYMCC-1024-0000-W0 (5289578e) shelf A07 (7a2c7e07) pod Pepsi Black (4901aaf4)
--     primary_warehouse_id = WH_MCC 4fcfb52c      -> "machine draws MCC"
--     ALL 89 real units, 4 batches, exp 2027-01-01, sit at WH_CENTRAL 4bebef68
--     -> "stock in CENTRAL". Zero at MCC. Zero sentinels (NOT the fixture-40 case).
--   The ladder SEES those units at rung 3 (satisfiable, qty_available = 6) and then does
--   NOT spend them: it terminates at rung 2 and substitutes Coca Cola Mix instead.
--   Measured fleet-wide at build time: 55 shelves / 21 pods / 23 machines hold 3,017 real
--   units of their OWN pod at a non-primary warehouse, and 55 of 55 terminate at
--   'substitute'. Across ALL 161 zero-primary-stock shelves it is 161 of 161, so rungs
--   3, 4, 5 and 6 are unreachable through the ladder on live data.
--
-- NO ENGINE IS TOUCHED BY THIS UNIT (LAW 1, LAW 3, LAW 10). The rung ORDER is BUILD-SPEC
--   line 88 verbatim (variant > substitute > alt_wh > ...) and is pinned by fixture 40
--   seq 17. Whether moving your OWN stock should outrank swapping the customer's product
--   is a CS judgment, raised as D-37 and PARKED. This fixture's job is to make the
--   stranding VISIBLE and to prove the rung-3 machinery works when it IS reached, the
--   same service fixture 45 performed for the unreachable rung 4 (S-91).
--
-- LAW 7 ARTEFACT PINNED (seq 30/31). At the fixture's own 2030 plan_date the alt-WH binder
--   returns 'unbound' / 'no_pickable_batch_in_scope', because wh_fefo_for_line binds only
--   batches in date ON the plan date and the real stock expires 2027-01-01. That is the
--   seam's documented far-future behaviour, NOT a defect. It is asserted explicitly so a
--   later leg cannot mistake it for one. The binding proof therefore runs on a NEAR date.

DELETE FROM golden.assertions WHERE fixture_id = 6;
DELETE FROM golden.fixtures   WHERE fixture_id = 6;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
6,
'Stranded stock reroute: real own-pod stock at a NON-primary warehouse is seen by the ladder at rung 3 and binds to a real CENTRAL batch when reached, but on live data rung 2 substitutes the product first, so the stranded units are never moved (P3.1b / S-118 / D-37)',
'PRD-110 GOLDEN-FIXTURES row 6 (Pepsi Black: stock in CENTRAL, machine draws MCC) + BUILD-SPEC P0.6(e) routing gap. Probed live at leg 75: 55 shelves / 3,017 real units stranded at non-primary warehouses, 55 of 55 answered with a substitution rather than a transfer.',
'P3',
DATE '2030-01-07',
true,
'passing',
'GREEN AT BASELINE ON PURPOSE, and that is not a LAW 1 shortcut. This fixture drives NO engine change: it (a) proves machinery that already exists - the rung-3 alt-WH scope of resolve_fefo_sku_legs_v3, which no fixture had ever exercised positively - and (b) RECORDS an open incident rather than closing one. Seq 22, 25 and 26 are the open-incident record: they assert what the system DOES today, which is not what GOLDEN-FIXTURES row 6 wants it to do. The LAW 1 driver for changing it is a FUTURE fixture behind D-37. Anchor is the literal incident, re-probed live: IFLYMCC-1024-0000-W0 / A07 / Pepsi Black, primary WH = MCC, all 89 real units at CENTRAL - which is the machine SECONDARY warehouse, so the transfer route is declared rather than invented. READ-ONLY throughout: resolve_supply_ladder_v3 and resolve_fefo_sku_legs_v3 are both STABLE and SECURITY INVOKER, so LAW 4 and LAW 12 hold by construction rather than by care, and the fixture appends to no ledger at all (hence re-runnable by construction, S-116/S-117). The near-date binder probe uses CURRENT_DATE + 2; it stays honest until the CENTRAL batches expire 2027-01-01, at which point seq 32-37 red and the ANCHOR should be re-picked - do NOT weaken them. Seq 22-29 record the S-118 finding as observed truth; if a later leg flips the rung order behind D-37, seq 22, 25 and 26 are the assertions that must be RESTATED, not deleted.',
$scen$
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
      WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
        AND w.warehouse_id = '4fcfb52c-271f-4aa7-a373-3495e3271cd3'), 0)::int AS real_mcc,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
        AND w.warehouse_id = '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'), 0)::int AS real_central,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
        AND w.warehouse_id IS DISTINCT FROM '4fcfb52c-271f-4aa7-a373-3495e3271cd3'), 0)::int AS real_other,
    COALESCE(SUM(w.warehouse_stock) FILTER (WHERE w.batch_id LIKE 'VOXSOURCE-%'), 0)::int AS sentinel,
    count(DISTINCT w.warehouse_id) FILTER (
      WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
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
  'sentinel',      (SELECT sentinel      FROM stock),
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
      WHERE w.batch_id NOT LIKE 'VOXSOURCE-%' AND w.warehouse_id = vr.primary_warehouse_id), 0)::int AS real_primary,
    COALESCE(SUM(w.warehouse_stock) FILTER (
      WHERE w.batch_id NOT LIKE 'VOXSOURCE-%' AND w.warehouse_id IS DISTINCT FROM vr.primary_warehouse_id), 0)::int AS real_other
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
  'zero_primary_all',  (SELECT count(*)::int                       FROM sup WHERE real_primary = 0));

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
          COALESCE(SUM(w.warehouse_stock) FILTER (WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
                   AND w.warehouse_id = vr.primary_warehouse_id),0)::int AS real_primary,
          COALESCE(SUM(w.warehouse_stock) FILTER (WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
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
  'n_sentinel',   (SELECT count(*)::int FROM b WHERE b.batch LIKE 'VOXSOURCE-%'));

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
$scen$
);

-- ---------------------------------------------------------------------------
-- ASSERTIONS. BARE INSERTs (S-78). check_sql returns TEXT.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ---- PREMISE: the incident geometry is live and exact (green even at RED baseline) ----
(6, 1, 'PREMISE: Pepsi Black is still assorted on IFLYMCC-1024 shelf A07',
 $$SELECT (value->>'pod_on_shelf') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'eq', '1', true, 'P3'),
(6, 2, 'PREMISE: the machine draws MCC - its primary warehouse is WH_MCC, not CENTRAL',
 $$SELECT (value->>'primary_wh') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'eq', '4fcfb52c-271f-4aa7-a373-3495e3271cd3', true, 'P3'),
(6, 3, 'PREMISE: CENTRAL is the machine DECLARED secondary warehouse, so the reroute is a configured route rather than an invented one',
 $$SELECT (value->>'secondary_wh') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'eq', '4bebef68-9e36-4a5c-9c2c-142f8dbdae85', true, 'P3'),
(6, 4, 'PREMISE: the machine is not partner_managed, so both warehouse rungs are applicable rather than inapplicable',
 $$SELECT (value->>'op_model') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'ne', 'partner_managed', true, 'P3'),
(6, 5, 'PREMISE (the gap is REAL): zero real Pepsi Black units at the primary warehouse',
 $$SELECT (value->>'real_mcc') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'eq', '0', true, 'P3'),
(6, 6, 'PREMISE (the stock is REAL): CENTRAL holds at least the 6 units this fixture asks for. If this reds, re-pick the anchor - do NOT weaken seq 32-37',
 $$SELECT (value->>'real_central') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'gte', '6', true, 'P3'),
(6, 7, 'PREMISE (NOT the fixture-40 case): zero sentinel units, so this is genuine stranded stock and not a VOXSOURCE phantom',
 $$SELECT (value->>'sentinel') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'eq', '0', true, 'P3'),
(6, 8, 'PREMISE: every real unit sits at exactly ONE non-primary warehouse, so "alt WH" is unambiguous here',
 $$SELECT (value->>'alt_wh_count') FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'eq', '1', true, 'P3'),
(6, 9, 'PREMISE: real_other and real_central agree, so all the stranded stock IS the CENTRAL stock',
 $$SELECT CASE WHEN (value->>'real_other') = (value->>'real_central') THEN 'AGREE' ELSE 'DISAGREE' END
   FROM golden.scratch WHERE fixture_id=6 AND key='premise'$$,
 'eq', 'AGREE', true, 'P3'),

-- ---- CENSUS: the incident is a CLASS, not one shelf ----
(6, 10, 'CENSUS (non-vacuity): at least one shelf fleet-wide has zero primary-WH stock and real stock elsewhere',
 $$SELECT (value->>'stranded_shelves') FROM golden.scratch WHERE fixture_id=6 AND key='census'$$,
 'gte', '1', true, 'P3'),
(6, 11, 'CENSUS: the stranded units are a material quantity, not a rounding error',
 $$SELECT (value->>'stranded_units') FROM golden.scratch WHERE fixture_id=6 AND key='census'$$,
 'gte', '100', true, 'P3'),
(6, 12, 'CENSUS: the class spans more than one pod, so it is not a Pepsi Black peculiarity',
 $$SELECT (value->>'stranded_pods') FROM golden.scratch WHERE fixture_id=6 AND key='census'$$,
 'gte', '2', true, 'P3'),
(6, 13, 'CENSUS: the class spans more than one machine',
 $$SELECT (value->>'stranded_machines') FROM golden.scratch WHERE fixture_id=6 AND key='census'$$,
 'gte', '2', true, 'P3'),

-- ---- THE LADDER SEES IT (LAW 5 in the visibility dimension) ----
(6, 14, 'The ladder returned an object rather than throwing on the anchor',
 $$SELECT CASE WHEN (SELECT count(*) FROM golden.scratch WHERE fixture_id=6 AND key='ladder')=0 THEN 'ABSENT'
               WHEN (SELECT value->>'threw' FROM golden.scratch WHERE fixture_id=6 AND key='ladder') IS NOT NULL THEN 'THREW'
               ELSE 'RETURNED' END$$,
 'eq', 'RETURNED', true, 'P3'),
(6, 15, 'Rung 1 is UNSATISFIABLE on the anchor: the primary warehouse genuinely cannot serve it',
 $$SELECT (value->'ladder'->0->>'satisfiable') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'eq', 'false', true, 'P3'),
(6, 16, 'RUNG 3 IS SATISFIABLE: the stranded CENTRAL units are VISIBLE to the ladder and are never silently invisible',
 $$SELECT (value->'ladder'->2->>'satisfiable') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'eq', 'true', true, 'P3'),
(6, 17, 'Rung 3 offers the full 6 units asked for, capped at the need',
 $$SELECT (value->'ladder'->2->>'qty_available') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'eq', '6', true, 'P3'),
(6, 18, 'Rung 3 NAMES the units as transferable rather than logging a bare verdict',
 $$SELECT (value->'ladder'->2->>'reason') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'contains', 'transferable', true, 'P3'),
(6, 19, 'The ladder rung-3 gross figure MATCHES the independent base-table read, so the function is never asked to confirm its own arithmetic',
 $$SELECT CASE WHEN (SELECT (value->'ladder'->2->'detail'->>'gross_real_other') FROM golden.scratch WHERE fixture_id=6 AND key='ladder')
               = (SELECT (value->>'real_other') FROM golden.scratch WHERE fixture_id=6 AND key='premise')
          THEN 'MATCH' ELSE 'MISMATCH' END$$,
 'eq', 'MATCH', true, 'P3'),
(6, 20, 'Rung 3 names CENTRAL as the secondary warehouse in its own detail',
 $$SELECT (value->'ladder'->2->'detail'->>'secondary_warehouse_id') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'eq', '4bebef68-9e36-4a5c-9c2c-142f8dbdae85', true, 'P3'),
(6, 21, 'All SIX rungs are still logged on this path, so completeness holds for a stranded-stock line too',
 $$SELECT jsonb_array_length(value->'ladder')::text FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'eq', '6', true, 'P3'),

-- ---- S-118, RECORDED AS OBSERVED TRUTH (see D-37) ----
(6, 22, 'S-118: the anchor terminates at rung 2 SUBSTITUTE, not rung 3. BUILD-SPEC line 88 orders substitute BEFORE alt_wh, so this is spec-conformant, and it is exactly why the stranded units never move. D-37 is the CS decision that would change it',
 $$SELECT (value->>'resolved_rung') FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'eq', 'substitute', true, 'P3'),
(6, 23, 'S-118: the substitution rewrites the shelf to a DIFFERENT pod, so the customer-visible assortment changes instead of the stock moving',
 $$SELECT CASE WHEN (value->'payload'->>'substitute_pod_product_id') IS NULL THEN 'NONE'
               WHEN (value->'payload'->>'substitute_pod_product_id') = '4901aaf4-a2f4-4d62-a089-d68178aa6c7f' THEN 'SAME_POD'
               ELSE 'DIFFERENT_POD' END
   FROM golden.scratch WHERE fixture_id=6 AND key='ladder'$$,
 'eq', 'DIFFERENT_POD', true, 'P3'),
(6, 24, 'S-118 FLEET (non-vacuity): the fleet walk actually ran over every stranded shelf the census found',
 $$SELECT CASE WHEN (SELECT (value->>'walked') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')
               = (SELECT (value->>'stranded_shelves') FROM golden.scratch WHERE fixture_id=6 AND key='census')
          THEN 'ALL' ELSE 'PARTIAL' END$$,
 'eq', 'ALL', true, 'P3'),
(6, 25, 'S-118 FLEET: ZERO stranded shelves terminate at alt_wh. Rung 3 is unreachable through the ladder on live data, the same class of dead branch S-91 found at rung 4',
 $$SELECT (value->>'term_alt_wh') FROM golden.scratch WHERE fixture_id=6 AND key='fleet'$$,
 'eq', '0', true, 'P3'),
(6, 26, 'S-118 FLEET: rung 2 is an ABSORBING state, because every stranded shelf terminates there',
 $$SELECT CASE WHEN (SELECT (value->>'term_substitute') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')
               = (SELECT (value->>'walked') FROM golden.scratch WHERE fixture_id=6 AND key='fleet')
          THEN 'ALL_SUBSTITUTE' ELSE 'MIXED' END$$,
 'eq', 'ALL_SUBSTITUTE', true, 'P3'),
(6, 27, 'LAW 5 SURVIVES S-118: not one stranded shelf hides its rung-3 stock. Every single one reports it satisfiable, so the units are unspent but never unseen',
 $$SELECT (value->>'rung3_invisible') FROM golden.scratch WHERE fixture_id=6 AND key='fleet'$$,
 'eq', '0', true, 'P3'),
(6, 28, 'LAW 5: the fleet-wide transferable units the ladder reports and then declines to spend are a positive, auditable number',
 $$SELECT (value->>'rung3_units_seen') FROM golden.scratch WHERE fixture_id=6 AND key='fleet'$$,
 'gte', '1', true, 'P3'),
(6, 29, 'Every ladder in the fleet walk logged all six rungs, 0 incomplete',
 $$SELECT (value->>'incomplete_ladders') FROM golden.scratch WHERE fixture_id=6 AND key='fleet'$$,
 'eq', '0', true, 'P3'),

-- ---- THE RUNG-3 MACHINERY WORKS WHEN REACHED (fixture 45 precedent) ----
(6, 30, 'LAW 7 ARTEFACT, PINNED: at the far-future plan_date the alt-WH binder finds no in-date batch and says so by name. That is wh_fefo_for_line honouring the expiry rule, NOT a binder defect - do not chase it',
 $$SELECT (value->>'unbound_reason') FROM golden.scratch WHERE fixture_id=6 AND key='bind_far'$$,
 'eq', 'no_pickable_batch_in_scope', true, 'P3'),
(6, 31, 'LAW 7 ARTEFACT: and the far-date call still REPORTS the units as unbound rather than dropping them',
 $$SELECT (value->>'qty_unbound') FROM golden.scratch WHERE fixture_id=6 AND key='bind_far'$$,
 'eq', '6', true, 'P3'),
(6, 32, 'THE REROUTE PROOF: on a near plan_date the alt-WH binder succeeds',
 $$SELECT (value->>'status') FROM golden.scratch WHERE fixture_id=6 AND key='bind_near'$$,
 'eq', 'ok', true, 'P3'),
(6, 33, 'THE REROUTE PROOF: it binds ALL 6 units, a full reroute rather than a partial one',
 $$SELECT (value->>'qty_bound') FROM golden.scratch WHERE fixture_id=6 AND key='bind_near'$$,
 'eq', '6', true, 'P3'),
(6, 34, 'THE REROUTE PROOF: NOT unbound dispatch. Zero units are left without a batch, which is the exact failure GOLDEN-FIXTURES row 6 forbids',
 $$SELECT (value->>'qty_unbound') FROM golden.scratch WHERE fixture_id=6 AND key='bind_near'$$,
 'eq', '0', true, 'P3'),
(6, 35, 'THE REROUTE PROOF: the binder used the rung OWN warehouse scope, alt and not primary',
 $$SELECT (value->>'warehouse_scope') FROM golden.scratch WHERE fixture_id=6 AND key='bind_near'$$,
 'eq', 'alt', true, 'P3'),
(6, 36, 'THE REROUTE PROOF (independent read): every batch bound sits at CENTRAL, so the stock really is being moved from where it is stranded',
 $$SELECT CASE WHEN (SELECT (value->>'n_batches') FROM golden.scratch WHERE fixture_id=6 AND key='bound_wh') = '0' THEN 'NONE'
               WHEN (SELECT (value->>'n_batches') FROM golden.scratch WHERE fixture_id=6 AND key='bound_wh')
                  = (SELECT (value->>'n_central')  FROM golden.scratch WHERE fixture_id=6 AND key='bound_wh')
          THEN 'ALL_CENTRAL' ELSE 'MIXED' END$$,
 'eq', 'ALL_CENTRAL', true, 'P3'),
(6, 37, 'THE REROUTE PROOF: ZERO bound batches came from the primary warehouse, so the alt-scope proof cannot be passing on stock rung 1 would have found anyway',
 $$SELECT (value->>'n_primary_wh') FROM golden.scratch WHERE fixture_id=6 AND key='bound_wh'$$,
 'eq', '0', true, 'P3'),
(6, 38, 'THE MIRROR: the SAME near-date call at rung variant, primary scope, finds nothing, because MCC is empty. The two scopes are genuinely different searches',
 $$SELECT (value->>'status') FROM golden.scratch WHERE fixture_id=6 AND key='bind_primary'$$,
 'eq', 'unbound', true, 'P3'),
(6, 39, 'LAW 7: no bound batch is expired on the plan date it was bound for',
 $$SELECT (value->>'n_expired') FROM golden.scratch WHERE fixture_id=6 AND key='bound_wh'$$,
 'eq', '0', true, 'P3'),
(6, 40, 'S-63: no sentinel batch was bound, because phantom stock is not a reroute',
 $$SELECT (value->>'n_sentinel') FROM golden.scratch WHERE fixture_id=6 AND key='bound_wh'$$,
 'eq', '0', true, 'P3'),
(6, 41, 'stitch_v3 ROUTES rung alt_wh through the same placement branch as variant and substitute, so the reroute has a consumer and is not advisory-only',
 $$SELECT (value->>'stitch_alt') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', 'ROUTED', true, 'P3'),
(6, 42, 'stitch_v3 labels that branch Transfer, so the reroute becomes a Transfer leg, which is what GOLDEN-FIXTURES row 6 asks for',
 $$SELECT (value->>'stitch_xfer') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', 'TRANSFER', true, 'P3'),

-- ---- LAW 3 / LAW 4 / LAW 12: nothing was touched ----
(6, 43, 'LAW 4: the ladder is STABLE, so Postgres itself enforces that this fixture wrote nothing through it',
 $$SELECT (value->>'ladder_vol') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', 's', true, 'P3'),
(6, 44, 'S-104 and least privilege: the ladder is SECURITY INVOKER, so RLS applies as the caller',
 $$SELECT (value->>'ladder_def') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', 'false', true, 'P3'),
(6, 45, 'LAW 4: the FEFO binder is STABLE too',
 $$SELECT (value->>'binder_vol') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', 's', true, 'P3'),
(6, 46, 'LAW 12: ZERO rows on the live plan table for this fixture plan_date',
 $$SELECT (value->>'rpo_live') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', '0', true, 'P3'),
(6, 47, 'LAW 4: ZERO rows on the shadow plan table either, because this fixture stitches nothing',
 $$SELECT (value->>'rpo_shadow') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', '0', true, 'P3'),
(6, 48, 'ZERO source-run rows written: unlike fixture 44 this one needs no shadow run, so it appends to no ledger and is re-runnable by construction (S-116 and S-117)',
 $$SELECT (value->>'pod_shadow') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', '0', true, 'P3'),
(6, 49, 'ZERO blocked_demand rows: the ladder is advisory and this fixture promotes nothing',
 $$SELECT (value->>'blocked') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', '0', true, 'P3'),
(6, 50, 'LAW 3: resolve_supply_ladder_v3 is BYTE-UNTOUCHED by this unit. Fixture 6 RECORDS the rung order, it does not change it - that is D-37',
 $$SELECT (value->>'ladder_md5') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', '920b32d09cb4582076da775a0f5123e3', true, 'P3'),
(6, 51, 'LAW 3: resolve_fefo_sku_legs_v3 is BYTE-UNTOUCHED by this unit',
 $$SELECT (value->>'binder_md5') FROM golden.scratch WHERE fixture_id=6 AND key='writes'$$,
 'eq', '229a8970fb3329750893738f9bf70f26', true, 'P3');
