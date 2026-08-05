-- PRD-110 P3.2 · golden fixture 41 — M2M transfers match on boonz_product_id, and a
-- mixed-SKU source shelf SPLITS ITS LEGS PER SKU instead of dumping the whole pod.
-- LAW 1: applied and run RED before resolve_m2m_sku_legs_v3 exists.
-- plan_date anchor = DATE '2030-01-01' + 41 = 2030-02-11 (free; 2030-02-10 is fixture 40's).
--
-- BUILD-SPEC line 90 (P3.2): "M2M SKU-level (fixture 4): transfers match on
-- boonz_product_id; mixed-SKU source shelves split legs per SKU."
-- GOLDEN-FIXTURES #4: "Mixed-SKU source shelf -> transfer to Zigi shelf. Assert only Zigi
-- SKUs transfer; Krambals SKUs -> return leg; qty-balanced pairing."
--
-- ROOT CAUSE, READ FROM THE LIVE FUNCTION BODY (leg 57, not inferred):
--   convert_removes_to_m2m_transfer(uuid[],uuid,uuid,text) copies v_row.pod_product_id AND
--   v_row.boonz_product_id VERBATIM onto the destination shelf:
--       INSERT INTO refill_dispatching (... pod_product_id, boonz_product_id ...)
--       VALUES (... v_row.pod_product_id, v_row.boonz_product_id ...)
--   There is NO check that the SKU is assortable on the destination shelf's pod. Converting
--   Removes from a 'Krambals & Zigi' shelf into a 'Zigi' shelf therefore mints destination
--   rows carrying the SOURCE pod and Krambals SKUs. All 36 live is_m2m rows already carry a
--   boonz_product_id, so the grain was never the defect -- the PAIRING PREDICATE was.
--
-- LIVE POPULATION (measured before a line of the function was written):
--   pod 'Krambals & Zigi' 098f5c0c = 253 product_mapping rows, 21 Active, 7 DISTINCT Active
--   SKUs (4 Krambals + 3 Zigi). The 253 -> 7 collapse is the documented fan-out trap.
--
-- TWO ANCHORS, ONE SOURCE, MIRROR-IMAGE RESULTS. MPMCC-1058-0000-R0 (9acce2bf) carries BOTH
-- a Krambals shelf (A05) and a Zigi shelf (A06), so the same 7-SKU input resolves two
-- different ways against two different destination pods:
--
--  (A) THE INCIDENT      src VML-1004-0500-O1 A07 'Krambals & Zigi' -> dst A06 'Zigi'
--      Zigi pod has 5 Active SKUs; intersection with the source pod = 3.
--      Expect 3 Zigi SKUs transfer (6u), 4 Krambals SKUs return (8u). Headroom 15-6 = 9,
--      so 6 <= 9 and NO clamp fires: anchor A is the PURE eligibility case.
--
--  (B) THE MIRROR + THE CLAMP   same src -> dst A05 'Krambals'
--      Krambals pod has 4 Active SKUs; intersection = 4. The eligible set is now the exact
--      COMPLEMENT of anchor A's. Expect Krambals transfers and Zigi returns -- which proves
--      eligibility is computed from the DESTINATION POD and not from a name pattern.
--      Headroom is 6-5 = 1, so 8 eligible units clamp to 1 and 7 spill to the return leg.
--
-- Both anchors must conserve exactly: input = transfer + return, always.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes,
   enabled, baseline_status)
VALUES (
  41,
  'M2M transfers match on boonz_product_id: a mixed-SKU source shelf splits per SKU, non-assortable SKUs take a return leg instead of contaminating the destination pod, destination capacity clamps rather than overflows, and every input unit is conserved (P3.2)',
  'PRD-110 leg 57 / GOLDEN-FIXTURES #4: K&Z -> Zigi failure 2026-07-30. convert_removes_to_m2m_transfer copies the source pod_product_id and boonz_product_id verbatim onto the destination shelf with no assortment check, so Krambals SKUs land on a Zigi shelf.',
  'P3',
  DATE '2030-02-11',
$SCEN$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (1) POPULATION EVIDENCE, derived INDEPENDENTLY of the function under test,
--     straight from base tables. This is what lets the assertions below say
--     "the contamination was possible" and "the eligible sets are complements"
--     without asking the function to confirm its own arithmetic.
--     product_mapping is DISTINCT-ed before anything is counted (fan-out guard).
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'pop', jsonb_build_object(
  'src_pod_active_skus',   (SELECT count(DISTINCT boonz_product_id) FROM public.product_mapping
                            WHERE pod_product_id = '098f5c0c-28b1-46c3-869a-2da87297c4d5'
                              AND status = 'Active'),
  'zigi_pod_active_skus',  (SELECT count(DISTINCT boonz_product_id) FROM public.product_mapping
                            WHERE pod_product_id = 'da115e6f-8d9b-48ab-b998-531cb81d3faa'
                              AND status = 'Active'),
  'kram_pod_active_skus',  (SELECT count(DISTINCT boonz_product_id) FROM public.product_mapping
                            WHERE pod_product_id = '27444f0d-7d3c-4480-bbdc-4faf60acbdbc'
                              AND status = 'Active'),
  'intersect_src_zigi',    (SELECT count(*) FROM (
                              SELECT DISTINCT boonz_product_id FROM public.product_mapping
                               WHERE pod_product_id='098f5c0c-28b1-46c3-869a-2da87297c4d5' AND status='Active'
                              INTERSECT
                              SELECT DISTINCT boonz_product_id FROM public.product_mapping
                               WHERE pod_product_id='da115e6f-8d9b-48ab-b998-531cb81d3faa' AND status='Active') t),
  'intersect_src_kram',    (SELECT count(*) FROM (
                              SELECT DISTINCT boonz_product_id FROM public.product_mapping
                               WHERE pod_product_id='098f5c0c-28b1-46c3-869a-2da87297c4d5' AND status='Active'
                              INTERSECT
                              SELECT DISTINCT boonz_product_id FROM public.product_mapping
                               WHERE pod_product_id='27444f0d-7d3c-4480-bbdc-4faf60acbdbc' AND status='Active') t),
  -- the fan-out the DISTINCT guard exists to defeat
  'pm_rows_raw',           (SELECT count(*) FROM public.product_mapping
                            WHERE pod_product_id='098f5c0c-28b1-46c3-869a-2da87297c4d5'),
  'pm_rows_active',        (SELECT count(*) FROM public.product_mapping
                            WHERE pod_product_id='098f5c0c-28b1-46c3-869a-2da87297c4d5' AND status='Active'),
  -- NON-VACUITY: source SKUs that are NOT assortable on the Zigi destination. If this is 0
  -- the whole fixture proves nothing, because there would be nothing to contaminate with.
  'src_not_in_zigi',       (SELECT count(*) FROM (
                              SELECT DISTINCT boonz_product_id FROM public.product_mapping
                               WHERE pod_product_id='098f5c0c-28b1-46c3-869a-2da87297c4d5' AND status='Active'
                              EXCEPT
                              SELECT DISTINCT boonz_product_id FROM public.product_mapping
                               WHERE pod_product_id='da115e6f-8d9b-48ab-b998-531cb81d3faa' AND status='Active') t),
  'dstA_headroom',         (SELECT max_stock - current_stock FROM public.v_shelf_state
                            WHERE shelf_id='b2145d8e-93a2-447e-933d-207d17952c07'),
  'dstB_headroom',         (SELECT max_stock - current_stock FROM public.v_shelf_state
                            WHERE shelf_id='81820a63-8272-485e-bab8-5793d212b297'),
  -- the source shelf is NOT covered by shelf_composition (16 of 656 shelves are), which is
  -- why the caller-supplied line set is the honest input path here, not an estimator read.
  'src_shelf_comp_rows',   (SELECT count(*) FROM public.shelf_composition
                            WHERE shelf_id='31894963-0ef0-44f2-9970-773a2836b9bf')
);

-- ---------------------------------------------------------------------------
-- (2) THE FUNCTION UNDER TEST. Guarded by to_regprocedure so the RED baseline still
--     completes and every population fact above lands in scratch -- the RED then
--     isolates exactly the object being built (fixture 39/40 idiom).
--     One call per anchor, whole jsonb result stored, so all assertions read ONE
--     consistent snapshot. golden.scratch.value is JSONB: store the object directly.
--     Input is the SAME 7-SKU / 14-unit mixed set for both anchors.
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public.resolve_m2m_sku_legs_v3(uuid,uuid,jsonb)') IS NOT NULL THEN
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 41, 'legs_' || t.tag,
             public.resolve_m2m_sku_legs_v3(
               '31894963-0ef0-44f2-9970-773a2836b9bf'::uuid,
               t.dst,
               $lines$[
                 {"boonz_product_id":"4678bf8c-e3d3-47e0-87ac-84f654508944","qty":2},
                 {"boonz_product_id":"60b527c9-05db-45f7-a130-b01b3bf6abbd","qty":2},
                 {"boonz_product_id":"167b0d57-4c24-4502-bb81-ee852a4d5d5f","qty":2},
                 {"boonz_product_id":"1bc836b3-c881-4da5-898b-2d4e152776fe","qty":2},
                 {"boonz_product_id":"9f47ace5-0577-44b9-b058-438dbb8e306b","qty":2},
                 {"boonz_product_id":"51c132ff-7d8e-463a-9324-03903105da4c","qty":2},
                 {"boonz_product_id":"9f098f7d-2ec6-4c0a-b858-595030d544df","qty":2}
               ]$lines$::jsonb)
      FROM (VALUES
        ('A','b2145d8e-93a2-447e-933d-207d17952c07'::uuid),
        ('B','81820a63-8272-485e-bab8-5793d212b297'::uuid)
      ) AS t(tag,dst)
    $x$;
  END IF;
END
$do$;
$SCEN$,
  'P3.2. Source VML-1004-0500-O1 A07 (Krambals & Zigi, 7 Active SKUs). Anchor A dest = MPMCC-1058 A06 Zigi (pure eligibility, headroom 9, no clamp). Anchor B dest = MPMCC-1058 A05 Krambals (mirror eligibility + hard clamp, headroom 1). resolve_m2m_sku_legs_v3 is READ-ONLY (STABLE, SECURITY INVOKER): it writes nothing, so LAW 4 and LAW 12 hold by construction. It reads product_mapping ONLY as a pod-to-SKU assortment map and never to size warehouse stock (LAW 6).',
  true,
  'failing_expected'
);

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES

-- ---- drift guards: if any of these move, every number below means something else ----
(41, 1, 'Drift guard: {{plan_date}} still renders as the fixture-41 anchor 2030-02-11',
 $q$SELECT {{plan_date}}::text$q$, 'eq', '2030-02-11', true, 'P3'),

(41, 2, 'Drift guard: source pod 098f5c0c is still the mixed pod "Krambals & Zigi"',
 $q$SELECT pod_product_name FROM public.pod_products
    WHERE pod_product_id = '098f5c0c-28b1-46c3-869a-2da87297c4d5'$q$,
 'eq', 'Krambals & Zigi', true, 'P3'),

(41, 3, 'Drift guard: destination pod da115e6f is still "Zigi"',
 $q$SELECT pod_product_name FROM public.pod_products
    WHERE pod_product_id = 'da115e6f-8d9b-48ab-b998-531cb81d3faa'$q$,
 'eq', 'Zigi', true, 'P3'),

(41, 4, 'Drift guard: mirror destination pod 27444f0d is still "Krambals"',
 $q$SELECT pod_product_name FROM public.pod_products
    WHERE pod_product_id = '27444f0d-7d3c-4480-bbdc-4faf60acbdbc'$q$,
 'eq', 'Krambals', true, 'P3'),

(41, 5, 'Drift guard: source shelf 31894963 is still VML-1004-0500-O1 A07 carrying the mixed pod',
 $q$SELECT s.shelf_code || '|' || s.pod_name FROM public.v_shelf_state s
    WHERE s.shelf_id = '31894963-0ef0-44f2-9970-773a2836b9bf'$q$,
 'eq', 'A07|Krambals & Zigi', true, 'P3'),

(41, 6, 'Drift guard: anchor A destination b2145d8e is still A06 / Zigi on machine 9acce2bf',
 $q$SELECT s.shelf_code || '|' || s.pod_name || '|' || s.machine_id::text FROM public.v_shelf_state s
    WHERE s.shelf_id = 'b2145d8e-93a2-447e-933d-207d17952c07'$q$,
 'eq', 'A06|Zigi|9acce2bf-0e65-48f4-bf44-cefa0326f2c5', true, 'P3'),

(41, 7, 'Drift guard: anchor B destination 81820a63 is still A05 / Krambals on the SAME machine 9acce2bf',
 $q$SELECT s.shelf_code || '|' || s.pod_name || '|' || s.machine_id::text FROM public.v_shelf_state s
    WHERE s.shelf_id = '81820a63-8272-485e-bab8-5793d212b297'$q$,
 'eq', 'A05|Krambals|9acce2bf-0e65-48f4-bf44-cefa0326f2c5', true, 'P3'),

(41, 8, 'M2M precondition: source and destination are genuinely different machines',
 $q$SELECT (src.machine_id <> dst.machine_id)::text
    FROM public.v_shelf_state src, public.v_shelf_state dst
    WHERE src.shelf_id='31894963-0ef0-44f2-9970-773a2836b9bf'
      AND dst.shelf_id='b2145d8e-93a2-447e-933d-207d17952c07'$q$,
 'eq', 'true', true, 'P3'),

-- ---- population evidence, computed independently of the function under test ----
(41, 9, 'Population: the mixed source pod has exactly 7 DISTINCT Active SKUs (4 Krambals + 3 Zigi)',
 $q$SELECT value->>'src_pod_active_skus' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '7', true, 'P3'),

(41, 10, 'Population: the Zigi destination pod has 5 Active SKUs',
 $q$SELECT value->>'zigi_pod_active_skus' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '5', true, 'P3'),

(41, 11, 'Population: the Krambals destination pod has 4 Active SKUs',
 $q$SELECT value->>'kram_pod_active_skus' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '4', true, 'P3'),

(41, 12, 'Population: source pod INTERSECT Zigi pod = 3 SKUs - the only ones anchor A may legally transfer',
 $q$SELECT value->>'intersect_src_zigi' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '3', true, 'P3'),

(41, 13, 'Population: source pod INTERSECT Krambals pod = 4 SKUs - the only ones anchor B may legally transfer',
 $q$SELECT value->>'intersect_src_kram' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '4', true, 'P3'),

(41, 14, 'NON-VACUITY: 4 source SKUs are NOT assortable on the Zigi destination - so contamination was genuinely possible',
 $q$SELECT value->>'src_not_in_zigi' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '4', true, 'P3'),

(41, 15, 'MIRROR PROOF (independent of the function): the two eligible sets partition the source pod exactly, 3 + 4 = 7',
 $q$SELECT ((value->>'intersect_src_zigi')::int + (value->>'intersect_src_kram')::int)::text
    FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '7', true, 'P3'),

(41, 16, 'Fan-out trap is real: 253 raw product_mapping rows for this one pod collapse to 7 distinct Active SKUs',
 $q$SELECT value->>'pm_rows_raw' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'gte', '200', true, 'P3'),

(41, 17, 'Fan-out trap: even Active-only rows (21) exceed the 7 distinct SKUs, so DISTINCT is load-bearing not cosmetic',
 $q$SELECT value->>'pm_rows_active' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'gt', '7', true, 'P3'),

(41, 18, 'Anchor A headroom is 9, so 6 eligible units fit and the capacity clamp must NOT fire',
 $q$SELECT value->>'dstA_headroom' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '9', true, 'P3'),

(41, 19, 'Anchor B headroom is 1, so 8 eligible units MUST clamp - this is what makes B the overflow anchor',
 $q$SELECT value->>'dstB_headroom' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '1', true, 'P3'),

(41, 20, 'Honest-input evidence: the source shelf is NOT covered by shelf_composition, so caller-supplied lines are the only truthful SKU input here',
 $q$SELECT value->>'src_shelf_comp_rows' FROM golden.scratch WHERE fixture_id=41 AND key='pop'$q$,
 'eq', '0', true, 'P3'),

-- ---- ANCHOR A: the incident. Only Zigi SKUs may cross. ----
(41, 21, 'Anchor A produced a result at all (RED tripwire: this is the assertion that fails when the function is absent)',
 $q$SELECT count(*)::text FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', '1', true, 'P3'),

(41, 22, 'Anchor A status is ok',
 $q$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', 'ok', true, 'P3'),

(41, 23, 'Anchor A consumed all 14 input units',
 $q$SELECT value#>>'{totals,input_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', '14', true, 'P3'),

(41, 24, 'Anchor A transfers exactly 6 units (3 Zigi SKUs x 2), not the whole 14-unit pod',
 $q$SELECT value#>>'{totals,transfer_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', '6', true, 'P3'),

(41, 25, 'Anchor A returns the other 8 units rather than dropping them (LAW 5: no silent qty-0)',
 $q$SELECT value#>>'{totals,return_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', '8', true, 'P3'),

(41, 26, 'Anchor A conserves exactly: input = transfer + return',
 $q$SELECT value#>>'{totals,conserved}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', 'true', true, 'P3'),

(41, 27, 'THE INCIDENT ASSERTION: ZERO Krambals SKUs appear on any anchor-A transfer leg',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_A'
      AND l->>'leg'='transfer' AND l->>'boonz_product_name' ILIKE 'Krambals%'$q$,
 'eq', '0', true, 'P3'),

(41, 28, 'Anchor A transfers exactly 3 SKUs, and all 3 are Zigi',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_A'
      AND l->>'leg'='transfer' AND l->>'boonz_product_name' ILIKE 'Zigi%'$q$,
 'eq', '3', true, 'P3'),

(41, 29, 'Anchor A return legs are the 4 Krambals SKUs, each flagged not_assortable_at_destination',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_A'
      AND l->>'leg'='return_to_wh' AND l->>'reason'='not_assortable_at_destination'$q$,
 'eq', '4', true, 'P3'),

(41, 30, 'Anchor A applied NO capacity clamp (6 units into 9 of headroom)',
 $q$SELECT value#>>'{totals,clamped_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', '0', true, 'P3'),

(41, 31, 'Anchor A names the destination pod it validated against',
 $q$SELECT value#>>'{dest,pod_name}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', 'Zigi', true, 'P3'),

-- ---- ANCHOR B: the mirror + the clamp. Krambals cross, Zigi returns. ----
(41, 32, 'Anchor B produced a result at all',
 $q$SELECT count(*)::text FROM golden.scratch WHERE fixture_id=41 AND key='legs_B'$q$,
 'eq', '1', true, 'P3'),

(41, 33, 'THE MIRROR ASSERTION: against a Krambals destination, ZERO Zigi SKUs transfer - eligibility follows the destination pod, not a name pattern',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_B'
      AND l->>'leg'='transfer' AND l->>'boonz_product_name' ILIKE 'Zigi%'$q$,
 'eq', '0', true, 'P3'),

(41, 34, 'Anchor B transfers only 1 unit: 8 eligible units clamped by 1 unit of headroom',
 $q$SELECT value#>>'{totals,transfer_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_B'$q$,
 'eq', '1', true, 'P3'),

(41, 35, 'Anchor B returns the remaining 13 units (6 non-assortable Zigi + 7 clamped Krambals)',
 $q$SELECT value#>>'{totals,return_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_B'$q$,
 'eq', '13', true, 'P3'),

(41, 36, 'Anchor B reports 7 clamped units EXPLICITLY rather than silently overflowing the shelf',
 $q$SELECT value#>>'{totals,clamped_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_B'$q$,
 'eq', '7', true, 'P3'),

(41, 37, 'Anchor B conserves exactly despite the clamp',
 $q$SELECT value#>>'{totals,conserved}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_B'$q$,
 'eq', 'true', true, 'P3'),

(41, 38, 'Anchor B distinguishes its two return reasons: clamp overflow is NOT mislabelled as non-assortable',
 $q$SELECT count(DISTINCT l->>'reason')::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_B' AND l->>'leg'='return_to_wh'$q$,
 'eq', '2', true, 'P3'),

(41, 39, 'Anchor B reports the destination headroom it clamped to',
 $q$SELECT value#>>'{dest,headroom}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_B'$q$,
 'eq', '1', true, 'P3'),

(41, 40, 'Anchor B names the mirror destination pod',
 $q$SELECT value#>>'{dest,pod_name}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_B'$q$,
 'eq', 'Krambals', true, 'P3'),

-- ---- cross-anchor: the sets are genuinely complementary, not coincidentally equal ----
(41, 41, 'CROSS-ANCHOR DISJOINTNESS: no SKU transfers in BOTH anchors - the same input resolved two opposite ways',
 $q$SELECT count(*)::text FROM (
      SELECT l->>'boonz_product_id' sku FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
       WHERE s.fixture_id=41 AND s.key='legs_A' AND l->>'leg'='transfer'
      INTERSECT
      SELECT l->>'boonz_product_id' FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
       WHERE s.fixture_id=41 AND s.key='legs_B' AND l->>'leg'='transfer') t$q$,
 'eq', '0', true, 'P3'),

(41, 42, 'LAW 5 end-to-end: across BOTH anchors every one of the 28 input units landed on some leg, none vanished',
 $q$SELECT sum((l->>'qty')::int)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key IN ('legs_A','legs_B')$q$,
 'eq', '28', true, 'P3'),

(41, 43, 'The resolver reports the assortment scope it used, so a widening decision can never be silent',
 $q$SELECT value#>>'{eligibility,dest_skus_any_scope}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_A'$q$,
 'eq', '5', true, 'P3'),

-- ---- LAW pins: the live writers were NOT touched, and the new object is read-only ----
(41, 44, 'LAW 3 PIN: live writer convert_removes_to_m2m_transfer is byte-untouched by this leg',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE proname='convert_removes_to_m2m_transfer'$q$,
 'eq', 'a1db24441ba1cd77e08fe3b6658fb51a', true, 'P3'),

(41, 45, 'LAW 3 PIN: live writer pair_internal_transfer_m2m is byte-untouched by this leg',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE proname='pair_internal_transfer_m2m'$q$,
 'eq', '12e4e38b620a4b17267a5125b9813a90', true, 'P3'),

(41, 46, 'LAW 4 PIN: resolve_m2m_sku_legs_v3 is STABLE and SECURITY INVOKER, so Postgres itself enforces "writes nothing"',
 $q$SELECT provolatile || '|' || prosecdef::text FROM pg_proc
    WHERE proname='resolve_m2m_sku_legs_v3'$q$,
 'eq', 's|false', true, 'P3');
