-- PRD-110 leg 137 / S-256 - fixture 41 stops inheriting three preconditions from live data.
--
-- THREE REDS, THREE DIFFERENT DECAYS, ONE CLASS (S-249):
--   seq 5  - the source shelf VML-1004-0500-O1 A07 was RE-PODDED, Krambals & Zigi -> G&H Popped
--            Chips. The drift guard asserted the pod NAME, so it fired.
--   seq 18 - anchor A headroom drifted 9 -> 10 -> 11 (it moved AGAIN between leg 136's diagnosis
--            and this leg, which is the clearest possible evidence that pinning a live headroom
--            to a literal is unwinnable).
--   seq 19 - anchor B headroom drifted 1 -> 2. Leg 136 had not yet observed this one.
--
-- WHAT IS NOT WRONG, AND THIS IS WHY NOTHING IS RE-BASELINED: the 7-SKU / 14-unit INPUT SET is
-- intact. Pod 098f5c0c still exists with exactly 7 distinct Active SKUs across 21 mapping rows, and
-- it still partitions 3/4 against the Zigi and Krambals destinations. Every assertion that proves
-- the actual subject - per-SKU splitting, the no-contamination incident assertion, conservation,
-- the clamp - was green throughout and is untouched here.
--
-- SOURCE SHELF: SELECTED BY PREDICATE, and seq 5 now asserts the STRUCTURE instead of the name.
-- No shelf in the fleet carries pod 098f5c0c any more, so re-pointing at "the same pod" is not
-- available. It is also not needed: resolve_m2m_sku_legs_v3 takes the line set from the CALLER
-- (v_input_source = 'caller_lines'; the real call site hands over the source Remove dispatch rows),
-- and consults the source shelf only for identity. What the source shelf must actually be is:
-- pod-bound, on a machine OTHER than the destinations, carrying a MIXED pod (>= 2 Active SKUs, so
-- the fixture's own title stays true), and NOT covered by shelf_composition - which is precisely
-- what makes the caller-supplied path the honest input path (seq 20). Those four properties are now
-- the selection rule AND the assertion. The incumbent shelf still satisfies all four, so it is
-- preferred in ORDER BY and continuity is kept; the predicate simply means the fixture survives the
-- next re-podding without a human.
--
-- HEADROOMS: SELF-SUPPLIED, NOT LOOSENED. seq 18 stays `eq 9` and seq 19 stays `eq 1` - the exact
-- numbers anchors A and B were designed around, because 9 makes the clamp impossible and 1 makes it
-- inevitable. They are now PLANTED via golden.plant_shelf_stock rather than hoped for. Loosening
-- them to a range would have quietly dissolved the A-versus-B contrast the whole fixture rests on.
--
-- RESTORE: this fixture has no rolled-back probe block - it COMMITS and restores explicitly (pin ->
-- call -> restore, anchor C). So the plants are undone at the end and seq 64/65 prove both shelves
-- read back their exact pre-plant live values. The plants sit BEFORE the anchor-C pin, so
-- pin_machine_stock banks the planted blob and restore_machine_stock returns to it, leaving seq
-- 61/62's pre-pin-versus-post-restore proof intact.
--
-- ORDER OF OPERATIONS NOTE: the uuid substitutions run BEFORE the setup block is spliced in. The
-- setup block contains the incumbent shelf id itself (as the ORDER BY preference), so splicing
-- first would make the occurrence count 3 and the substitution would rewrite the preference into a
-- self-referential lookup. The count guard caught exactly that during authoring.

DO $mig41$
DECLARE
  v_src text;
  v_new text;
  v_n   int;

  c_del CONSTANT text := $q$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
$q$;

  c_setup CONSTANT text := $q$
-- ---------------------------------------------------------------------------
-- (0) PRECONDITIONS THIS FIXTURE OWNS INSTEAD OF INHERITING (S-256).
--     The source shelf is resolved BY PREDICATE and both destination headrooms
--     are PLANTED to the exact values anchors A and B were designed around.
--     Everything written here is undone by block (4) at the end of the scenario.
-- ---------------------------------------------------------------------------
DO $fx41s$
DECLARE
  v_dstA uuid := 'b2145d8e-93a2-447e-933d-207d17952c07';
  v_dstB uuid := '81820a63-8272-485e-bab8-5793d212b297';
  v_dstm uuid := '9acce2bf-0e65-48f4-bf44-cefa0326f2c5';
  s_id uuid; s_code text; s_mid uuid; s_mname text; s_pod text; s_skus int; s_comp int;
  a_cur int; a_max int; b_cur int; b_max int;
BEGIN
  SELECT s.shelf_id, s.shelf_code, s.machine_id, m.official_name, s.pod_name,
         (SELECT count(DISTINCT pm.boonz_product_id) FROM public.product_mapping pm
           WHERE pm.pod_product_id = s.pod_product_id AND pm.status = 'Active'),
         (SELECT count(*) FROM public.shelf_composition sc WHERE sc.shelf_id = s.shelf_id)
    INTO s_id, s_code, s_mid, s_mname, s_pod, s_skus, s_comp
    FROM public.v_shelf_state s
    JOIN public.machines m ON m.machine_id = s.machine_id
   WHERE s.pod_product_id IS NOT NULL
     AND s.machine_id <> v_dstm
     AND (SELECT count(DISTINCT pm.boonz_product_id) FROM public.product_mapping pm
           WHERE pm.pod_product_id = s.pod_product_id AND pm.status = 'Active') >= 2
     AND NOT EXISTS (SELECT 1 FROM public.shelf_composition sc WHERE sc.shelf_id = s.shelf_id)
   ORDER BY (s.shelf_id = '31894963-0ef0-44f2-9970-773a2836b9bf'::uuid) DESC,
            m.official_name, s.shelf_code
   LIMIT 1;

  IF s_id IS NULL THEN
    RAISE EXCEPTION 'FX41 setup: no shelf off machine 9acce2bf carries a MIXED pod (>= 2 Active SKUs) while staying outside shelf_composition. The caller-supplied line set would no longer be the honest input path, so seq 20 and the whole per-SKU split premise must be re-derived rather than re-baselined.';
  END IF;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (41, 'anchor_src', jsonb_build_object(
    'shelf_id', s_id, 'shelf_code', s_code, 'machine_id', s_mid,
    'machine_name', s_mname, 'pod_name', s_pod, 'pod_skus', s_skus, 'comp_rows', s_comp));

  SELECT current_stock, max_stock INTO a_cur, a_max FROM public.v_shelf_state WHERE shelf_id = v_dstA;
  SELECT current_stock, max_stock INTO b_cur, b_max FROM public.v_shelf_state WHERE shelf_id = v_dstB;

  IF a_max < 9 OR b_max < 1 THEN
    RAISE EXCEPTION 'FX41 setup: destination capacity can no longer hold the designed headrooms (A max=% needs >= 9, B max=% needs >= 1)', a_max, b_max;
  END IF;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (41, 'live_pre', jsonb_build_object(
    'dstA_current', a_cur, 'dstA_max', a_max,
    'dstB_current', b_cur, 'dstB_max', b_max));

  PERFORM golden.plant_shelf_stock(v_dstA, a_max - 9);
  PERFORM golden.plant_shelf_stock(v_dstB, b_max - 1);
END
$fx41s$;
$q$;

  c_restore CONSTANT text := $q$

-- ---------------------------------------------------------------------------
-- (4) UNDO block (0)'s plants. This fixture commits, so a plant that is not
--     restored is live WEIMI corruption. seq 64/65 prove the read-back.
-- ---------------------------------------------------------------------------
DO $fx41r$
DECLARE
  v_dstA uuid := 'b2145d8e-93a2-447e-933d-207d17952c07';
  v_dstB uuid := '81820a63-8272-485e-bab8-5793d212b297';
  a_orig int; b_orig int;
BEGIN
  SELECT (value->>'dstA_current')::int, (value->>'dstB_current')::int
    INTO a_orig, b_orig
    FROM golden.scratch WHERE fixture_id = 41 AND key = 'live_pre';

  PERFORM golden.plant_shelf_stock(v_dstA, a_orig);
  PERFORM golden.plant_shelf_stock(v_dstB, b_orig);

  INSERT INTO golden.scratch (fixture_id, key, value)
  SELECT 41, 'live_post', jsonb_build_object(
    'dstA_current', (SELECT current_stock FROM public.v_shelf_state WHERE shelf_id = v_dstA),
    'dstB_current', (SELECT current_stock FROM public.v_shelf_state WHERE shelf_id = v_dstB));
END
$fx41r$;
$q$;

  c_cast_old CONSTANT text := $q$'31894963-0ef0-44f2-9970-773a2836b9bf'::uuid$q$;
  c_cast_new CONSTANT text := $q$(SELECT (value->>'shelf_id')::uuid FROM golden.scratch WHERE fixture_id = 41 AND key = 'anchor_src')$q$;

  c_comp_old CONSTANT text := $q$shelf_id='31894963-0ef0-44f2-9970-773a2836b9bf'$q$;
  c_comp_new CONSTANT text := $q$shelf_id=(SELECT (value->>'shelf_id')::uuid FROM golden.scratch WHERE fixture_id = 41 AND key = 'anchor_src')$q$;
BEGIN
  SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = 41;
  IF v_src IS NULL THEN RAISE EXCEPTION 'fixture 41 not found'; END IF;
  v_new := v_src;

  -- Substitutions FIRST, splice SECOND (see the order-of-operations note in the header).
  v_n := (length(v_new) - length(replace(v_new, c_cast_old, ''))) / length(c_cast_old);
  IF v_n <> 2 THEN RAISE EXCEPTION 'sub 1: expected exactly 2 cast occurrences of the source shelf, found %', v_n; END IF;
  v_new := replace(v_new, c_cast_old, c_cast_new);

  IF position(c_comp_old IN v_new) = 0 THEN RAISE EXCEPTION 'sub 2 (shelf_composition clause) did not match'; END IF;
  v_new := replace(v_new, c_comp_old, c_comp_new);

  v_n := (length(v_new) - length(replace(v_new, '31894963-0ef0-44f2-9970-773a2836b9bf', ''))) / 36;
  IF v_n <> 0 THEN RAISE EXCEPTION 'sub 1/2 left % source-shelf literal(s) behind before splicing', v_n; END IF;

  IF position(c_del IN v_new) = 0 THEN RAISE EXCEPTION 'sub 0 (delete anchor) did not match'; END IF;
  v_new := replace(v_new, c_del, c_del || c_setup);

  v_new := v_new || c_restore;

  -- The source shelf id must now survive EXACTLY once: as the ORDER BY incumbent preference.
  v_n := (length(v_new) - length(replace(v_new, '31894963-0ef0-44f2-9970-773a2836b9bf', ''))) / 36;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'S-256: the source shelf id must appear exactly once (the ORDER BY preference), found %', v_n;
  END IF;

  UPDATE golden.fixtures
     SET scenario_sql = v_new,
         notes = notes || ' | S-256 (leg 137): the source shelf is SELECTED BY PREDICATE (pod-bound, off the '
              || 'destination machine, MIXED pod with >= 2 Active SKUs, zero shelf_composition rows) and resolved '
              || 'once into scratch key anchor_src; the incumbent is only an ORDER BY preference. Both destination '
              || 'headrooms are PLANTED to the designed 9 and 1 via golden.plant_shelf_stock and restored by block '
              || '(4); seq 18/19 keep their exact expectations and seq 64/65 prove the restore. The 7-SKU/14-unit '
              || 'input set was never the problem and is untouched.'
   WHERE fixture_id = 41;

  UPDATE golden.assertions
     SET description = 'STRUCTURAL drift guard (S-256), replacing a pod-NAME guard that fired when the source shelf was re-podded Krambals & Zigi -> G&H Popped Chips: the predicate-selected source shelf carries a MIXED pod (so the fixture title stays true), sits on a machine other than the destinations (M2M precondition), and is NOT covered by shelf_composition (which is what makes the caller-supplied line set the honest input path)',
         check_sql = 'SELECT CASE WHEN (value->>''pod_skus'')::int >= 2 THEN ''mixed'' ELSE ''single'' END || ''|'' || CASE WHEN (value->>''machine_id'') <> ''9acce2bf-0e65-48f4-bf44-cefa0326f2c5'' THEN ''offmachine'' ELSE ''samemachine'' END || ''|'' || CASE WHEN (value->>''comp_rows'')::int = 0 THEN ''uncomposed'' ELSE ''composed'' END FROM golden.scratch WHERE fixture_id = 41 AND key = ''anchor_src''',
         expect_op = 'eq',
         expect = 'mixed|offmachine|uncomposed'
   WHERE fixture_id = 41 AND seq = 5;

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES
   (41, 64,
    'RESIDUE PROOF (S-256): anchor A destination reads back the EXACT stock it held before this fixture planted its headroom. This fixture commits, so an unrestored plant is live WEIMI corruption, not a test artifact',
    'SELECT ((SELECT (value->>''dstA_current'')::int FROM golden.scratch WHERE fixture_id=41 AND key=''live_post'') = (SELECT (value->>''dstA_current'')::int FROM golden.scratch WHERE fixture_id=41 AND key=''live_pre''))::text',
    'eq', 'true', true, 'P3'),
   (41, 65,
    'RESIDUE PROOF (S-256): anchor B destination reads back its exact pre-plant stock too. Distinct from seq 62, which only proves the anchor-C pin was undone back to the PLANTED value',
    'SELECT ((SELECT (value->>''dstB_current'')::int FROM golden.scratch WHERE fixture_id=41 AND key=''live_post'') = (SELECT (value->>''dstB_current'')::int FROM golden.scratch WHERE fixture_id=41 AND key=''live_pre''))::text',
    'eq', 'true', true, 'P3'),
   (41, 66,
    'ATTRIBUTABILITY (S-256, METRICS_REGISTRY line 46): a predicate-selected anchor must name itself, or a future red cannot be traced to the shelf it actually measured',
    'SELECT CASE WHEN COALESCE(value->>''machine_name'','''') = '''' OR COALESCE(value->>''shelf_code'','''') = '''' THEN ''UNRECORDED'' ELSE ''RECORDED'' END FROM golden.scratch WHERE fixture_id = 41 AND key = ''anchor_src''',
    'eq', 'RECORDED', true, 'P3');
END $mig41$;