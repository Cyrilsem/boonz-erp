-- PRD-110 · leg 158 · LAW 8 · FIXTURE 41 RE-ANCHORED — the last standing golden red.
--
-- ⛔ NO ENGINE BODY IS TOUCHED. resolve_m2m_sku_legs_v3 is not modified, and nothing here writes to
--    a live plan table, a protected entity, or a flag. This migration edits golden.fixtures and
--    golden.assertions only.
--
-- THE DEFECT WAS IN THE FIXTURE, NOT THE ENGINE. Fixture 41 was GREEN 66/0 and went RED 59/7 in the
-- 2026-08-08 12:48-12:52Z window. Leg 157 bisected it in full and deliberately did not start the
-- repair (RELAY: never begin a unit you cannot finish). All seven failures descend from ONE reading:
--
--   seq 6  got 'A06|Sunbites|9acce2bf'   want 'A06|Zigi|9acce2bf'
--   seq 24 got 0 want 6 · seq 25 got 14 want 8 · seq 28 got 0 want 3 · seq 29 got 7 want 4
--   seq 31 got 'Sunbites' want 'Zigi'    · seq 43 got 2 want 5
--
-- Anchor A's hardcoded destination shelf b2145d8e (MPMCC-1058-0000-R0 A06) was re-podded from Zigi
-- to Sunbites on the physical wall. The pod comes from v_shelf_state -> WEIMI, and NOTHING IN THIS
-- LOOP MOVED IT: planogram holds no row for that shelf and write_audit_log shows no planogram write
-- since Aug 6. Real-world drift. With a Sunbites destination none of the 7 input SKUs is assortable,
-- so 0 units transferred, all 14 took a return leg, and the six downstream seqs fell over together.
--
-- THE FIX IS THE S-256 IDIOM, APPLIED TO THE ANCHOR THAT NEVER GOT IT. The source shelf was already
-- predicate-resolved into golden.scratch (key anchor_src) precisely because a hardcoded shelf id is
-- a hostage to the physical wall. Anchor A's DESTINATION kept its literal and became the next
-- hostage. It is now resolved the same way, into key anchor_dstA, and read from scratch everywhere:
-- the POD (Zigi, da115e6f) is the premise anchor A actually needs, not the shelf that carries it.
-- Resolution order is deliberate - the destination resolves FIRST, because the source predicate must
-- exclude the destination's machine, and that dependency cannot run both ways.
--
-- ⛔⛔ THE ONE THING THAT HAD TO BE ARGUED, NOT SLIPPED IN: ANCHOR A'S HEADROOM DROPS 9 -> 6.
--    EXACTLY ONE SHELF IN THE FLEET STILL CARRIES THE ZIGI POD - ALJLT-1015-0200-O1 A08
--    (10c1f09f-a784-49cd-a286-47b9aee9d119) - and its max_stock is 6, against anchor A's designed
--    headroom of 9. max_stock is shelf configuration, a protected entity this loop does not write,
--    so 6 is the ceiling. That CHANGES WHAT ANCHOR A PROVES and the change is a STRENGTHENING:
--      - anchor A transfers 6 units. At headroom 9 there were 3 units of slack, so a clamp that
--        fired on `units >= headroom` instead of `units > headroom` stayed invisible.
--      - at headroom 6 the units meet capacity EXACTLY, so that off-by-one now reds seq 30.
--      - the three anchors now bracket the clamp on both sides and at the boundary:
--        A = 6 into 6 (at capacity, no clamp) · B = 8 into 1 (over, clamps 7) · C = 8 into 0 (clamps 8).
--    ⭐ Every other anchor-A expectation survives the move UNCHANGED, verified live before writing:
--       3 of the 7 input SKUs are Active in the Zigi pod (Honey Mustard, Sweet Chilli, Teryaki) and
--       4 are Krambals -> transfer 6 units / 3 SKUs, return 8 units / 4 legs, dest_skus_any_scope 5.
--       ⛔ Checked under the resolver's REAL eligibility predicate, which is machine-scoped
--       (pm.machine_id = dst.machine_id OR pm.machine_id IS NULL) - moving anchor A to a different
--       machine could have changed the eligible set and did not: scoped 5 = any-scope 5.
--
-- ⭐ A LATENT DEFECT FOUND AND FIXED IN THE SAME UNIT: seq 8 ("source and destination are genuinely
--    different machines") still hardcoded the source shelf 31894963 after S-256 made the source
--    predicate-resolved, so it was asserting the precondition of a pair that need not be the pair
--    the resolver was actually given. Both sides now read the anchors from scratch.
--
-- ⭐ IDENTITY IS RECORDED, NOT ASSERTED (S-301 / S-302). anchor_dstA's shelf code, machine and SKU
--    count land in golden.scratch every run; no assertion pins them. seq 6 keeps a real drift guard
--    by asserting the resolved shelf's POD, which is the premise, and block (0a) RAISEs with a
--    diagnostic if the fleet ever loses its last Zigi shelf rather than letting seqs fail obscurely.
--
-- ⛔ NOT DONE HERE: the fixture's `notes` also described the SOURCE as a "Krambals & Zigi, 7 SKUs"
--    pod. The source shelf's pod drifted to "G&H Popped Chips" too. That is harmless to the result
--    (the input set is caller-supplied and the split is decided by the DESTINATION pod), but the
--    notes were false, so they are corrected in the same migration. Pod 098f5c0c is now deployed on
--    ZERO shelves while its 7 Active mappings survive and still match the input set exactly.

DO $mig$
DECLARE
  v_scen text;
  v_new  text;
  k      text;
  v_b    text;
BEGIN
  SELECT scenario_sql INTO v_scen FROM golden.fixtures WHERE fixture_id = 41;
  IF v_scen IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 41 has no scenario_sql.'; END IF;

  IF position('anchor_dstA' in v_scen) > 0 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 already carries anchor_dstA - it has already been re-anchored.';
  END IF;
  IF md5(v_scen) <> '604700e1ed419a62ce16885c6815a9a2' THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 scenario_sql md5 is %, not the image this rewrite was derived and diffed against. Re-derive the rewrite against the live scenario rather than forcing it.', md5(v_scen);
  END IF;

  v_new := v_scen;

  -- ---- R1 ----------------------------------------------------------------------
  k := 'DO $fx41s$
DECLARE
  v_dstA uuid := ''b2145d8e-93a2-447e-933d-207d17952c07'';
  v_dstB uuid := ''81820a63-8272-485e-bab8-5793d212b297'';
  v_dstm uuid := ''9acce2bf-0e65-48f4-bf44-cefa0326f2c5'';
  s_id uuid; s_code text; s_mid uuid; s_mname text; s_pod text; s_skus int; s_comp int;
  a_cur int; a_max int; b_cur int; b_max int;
BEGIN
  SELECT s.shelf_id, s.shelf_code, s.machine_id, m.official_name, s.pod_name,';
  IF (length(v_new) - length(replace(v_new, k, ''))) / length(k) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 re-anchor R1: its anchor text is not present exactly once. The scenario has drifted from the image this migration was derived against; re-derive rather than force.';
  END IF;
  v_new := replace(v_new, k, 'DO $fx41s$
DECLARE
  v_dstA uuid;
  v_dstB uuid := ''81820a63-8272-485e-bab8-5793d212b297'';
  v_dstm uuid := ''9acce2bf-0e65-48f4-bf44-cefa0326f2c5'';
  v_zigi uuid := ''da115e6f-8d9b-48ab-b998-531cb81d3faa'';
  a_code text; a_mid uuid; a_mname text; a_pod text; a_skus int;
  s_id uuid; s_code text; s_mid uuid; s_mname text; s_pod text; s_skus int; s_comp int;
  a_cur int; a_max int; b_cur int; b_max int;
BEGIN
  -- (0a) ANCHOR A''S DESTINATION IS NOW RESOLVED BY PREDICATE TOO (leg 158, S-256 idiom).
  --      It used to be the hardcoded shelf b2145d8e (MPMCC-1058 A06), which WEIMI re-podded to
  --      Sunbites; six of fixture 41''s seven failures followed from that one reading. The POD --
  --      not the shelf id -- is what anchor A actually needs, so the pod is what is pinned.
  --      Resolved BEFORE the source, because the source predicate must exclude this machine.
  SELECT s.shelf_id, s.shelf_code, s.machine_id, m.official_name, s.pod_name,
         (SELECT count(DISTINCT pm.boonz_product_id) FROM public.product_mapping pm
           WHERE pm.pod_product_id = s.pod_product_id AND pm.status = ''Active'')
    INTO v_dstA, a_code, a_mid, a_mname, a_pod, a_skus
    FROM public.v_shelf_state s
    JOIN public.machines m ON m.machine_id = s.machine_id
   WHERE s.pod_product_id = v_zigi
     AND s.machine_id <> v_dstm
     AND s.max_stock >= 6
   ORDER BY s.max_stock DESC, m.official_name, s.shelf_code
   LIMIT 1;

  IF v_dstA IS NULL THEN
    RAISE EXCEPTION ''FX41 setup: no shelf outside machine 9acce2bf carries the Zigi pod (da115e6f) with max_stock >= 6, so anchor A has no destination able to hold its 6 eligible units without a clamp. Anchor A proves that eligible units transfer while non-assortable ones do not; re-derive that premise against a live pod rather than re-baselining the expectations.'';
  END IF;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (41, ''anchor_dstA'', jsonb_build_object(
    ''shelf_id'', v_dstA, ''shelf_code'', a_code, ''machine_id'', a_mid,
    ''machine_name'', a_mname, ''pod_name'', a_pod, ''pod_skus'', a_skus));

  -- (0b) THE SOURCE SHELF, unchanged except that it must now also stay off anchor A''s machine.
  SELECT s.shelf_id, s.shelf_code, s.machine_id, m.official_name, s.pod_name,');

  -- ---- R2 ----------------------------------------------------------------------
  k := '   WHERE s.pod_product_id IS NOT NULL
     AND s.machine_id <> v_dstm
';
  IF (length(v_new) - length(replace(v_new, k, ''))) / length(k) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 re-anchor R2: its anchor text is not present exactly once. The scenario has drifted from the image this migration was derived against; re-derive rather than force.';
  END IF;
  v_new := replace(v_new, k, '   WHERE s.pod_product_id IS NOT NULL
     AND s.machine_id <> v_dstm
     AND s.machine_id <> a_mid
');

  -- ---- R3 ----------------------------------------------------------------------
  k := '  IF a_max < 9 OR b_max < 1 THEN
    RAISE EXCEPTION ''FX41 setup: destination capacity can no longer hold the designed headrooms (A max=% needs >= 9, B max=% needs >= 1)'', a_max, b_max;';
  IF (length(v_new) - length(replace(v_new, k, ''))) / length(k) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 re-anchor R3: its anchor text is not present exactly once. The scenario has drifted from the image this migration was derived against; re-derive rather than force.';
  END IF;
  v_new := replace(v_new, k, '  IF a_max < 6 OR b_max < 1 THEN
    RAISE EXCEPTION ''FX41 setup: destination capacity can no longer hold the designed headrooms (A max=% needs >= 6, B max=% needs >= 1)'', a_max, b_max;');

  -- ---- R4 ----------------------------------------------------------------------
  k := '  PERFORM golden.plant_shelf_stock(v_dstA, a_max - 9);';
  IF (length(v_new) - length(replace(v_new, k, ''))) / length(k) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 re-anchor R4: its anchor text is not present exactly once. The scenario has drifted from the image this migration was derived against; re-derive rather than force.';
  END IF;
  v_new := replace(v_new, k, '  PERFORM golden.plant_shelf_stock(v_dstA, a_max - 6);');

  -- ---- R5 ----------------------------------------------------------------------
  k := '  ''dstA_headroom'',         (SELECT max_stock - current_stock FROM public.v_shelf_state
                            WHERE shelf_id=''b2145d8e-93a2-447e-933d-207d17952c07''),';
  IF (length(v_new) - length(replace(v_new, k, ''))) / length(k) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 re-anchor R5: its anchor text is not present exactly once. The scenario has drifted from the image this migration was derived against; re-derive rather than force.';
  END IF;
  v_new := replace(v_new, k, '  ''dstA_headroom'',         (SELECT max_stock - current_stock FROM public.v_shelf_state
                            WHERE shelf_id=(SELECT (value->>''shelf_id'')::uuid FROM golden.scratch WHERE fixture_id = 41 AND key = ''anchor_dstA'')),');

  -- ---- R6 ----------------------------------------------------------------------
  k := '        (''A'',''b2145d8e-93a2-447e-933d-207d17952c07''::uuid),';
  IF (length(v_new) - length(replace(v_new, k, ''))) / length(k) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 re-anchor R6: its anchor text is not present exactly once. The scenario has drifted from the image this migration was derived against; re-derive rather than force.';
  END IF;
  v_new := replace(v_new, k, '        (''A'',(SELECT (value->>''shelf_id'')::uuid FROM golden.scratch WHERE fixture_id = 41 AND key = ''anchor_dstA'')),');

  -- ---- R7 ----------------------------------------------------------------------
  k := 'DECLARE
  v_dstA uuid := ''b2145d8e-93a2-447e-933d-207d17952c07'';
  v_dstB uuid := ''81820a63-8272-485e-bab8-5793d212b297'';
  a_orig int; b_orig int;
BEGIN
  SELECT (value->>''dstA_current'')::int, (value->>''dstB_current'')::int';
  IF (length(v_new) - length(replace(v_new, k, ''))) / length(k) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 re-anchor R7: its anchor text is not present exactly once. The scenario has drifted from the image this migration was derived against; re-derive rather than force.';
  END IF;
  v_new := replace(v_new, k, 'DECLARE
  v_dstA uuid;
  v_dstB uuid := ''81820a63-8272-485e-bab8-5793d212b297'';
  a_orig int; b_orig int;
BEGIN
  SELECT (value->>''shelf_id'')::uuid INTO v_dstA
    FROM golden.scratch WHERE fixture_id = 41 AND key = ''anchor_dstA'';
  IF v_dstA IS NULL THEN
    RAISE EXCEPTION ''FX41 restore: anchor_dstA is missing from scratch, so block (0) planted a shelf this block cannot name. Refusing to finish and leave a planted headroom live.'';
  END IF;

  SELECT (value->>''dstA_current'')::int, (value->>''dstB_current'')::int');

  -- ---- post-image proofs ----------------------------------------------------------
  IF position('b2145d8e-93a2-447e-933d-207d17952c07' in v_new) > 0 THEN
    RAISE EXCEPTION 'REFUSED: the retired anchor-A shelf id still appears in the post-image.';
  END IF;
  IF (length(v_new) - length(replace(v_new, 'anchor_dstA', ''))) / length('anchor_dstA') <> 5 THEN
    RAISE EXCEPTION 'REFUSED: post-image does not carry anchor_dstA exactly 5 times (1 insert + 4 reads).';
  END IF;
  IF md5(v_new) <> 'dd64ee1c59a2415c5648cd4a00f3df02' THEN
    RAISE EXCEPTION 'REFUSED: post-image md5 is %, not the byte-for-byte rewrite verified and diffed offline.', md5(v_new);
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 41;
  UPDATE golden.fixtures SET notes = 'P3.2. Source resolved BY PREDICATE (S-256): pod-bound, off BOTH destination machines, MIXED pod (>= 2 Active SKUs), zero shelf_composition rows; resolved once into scratch key anchor_src, with the incumbent 31894963 (VML-1004-0500-O1 A07) only an ORDER BY preference. Anchor A dest is ALSO resolved by predicate as of leg 158, into scratch key anchor_dstA: the shelf carrying the Zigi pod da115e6f with max_stock >= 6, off machine 9acce2bf. Today that is ALJLT-1015-0200-O1 A08 (max_stock 6). It proves pure eligibility with NO clamp. Anchor B dest = MPMCC-1058 A05 Krambals, hardcoded (mirror eligibility + hard clamp, headroom 1). HEADROOM: anchor A is planted to 6, not the original 9, because exactly one Zigi shelf remains fleet-wide and its max_stock is 6. 6 units into 6 of headroom is the TIGHTEST no-clamp boundary there is: an off-by-one in the clamp (>= where > is meant) now reds seq 30, which headroom 9 could never catch. See leg 158. The 7-SKU / 14-unit input line set is CALLER-SUPPLIED and is exactly the 7 Active SKUs of pod 098f5c0c (a Krambals & Zigi mix that is currently deployed on ZERO shelves - the mapping cohort survives the pod''s retirement, which is why block (1) still measures it honestly). The source SHELF is only a handle: the resolver reads its pod for source_skus_any_scope reporting, never for the split, which is decided entirely by the DESTINATION pod''s machine-scoped assortment. resolve_m2m_sku_legs_v3 is READ-ONLY (STABLE, SECURITY INVOKER): it writes nothing, so LAW 4 and LAW 12 hold by construction. It reads product_mapping ONLY as a pod-to-SKU assortment map and never to size warehouse stock (LAW 6). D-23 (CS 2026-08-01: KEEP THE CLAMP): anchor C adds the zero-headroom boundary via golden.pin_machine_stock(MPMCC-1058, 99) -> A05 reads 99/6 so headroom floors to 0. Pin and restore live inside run_fixture''s scenario subtransaction, so a mid-scenario raise rolls the pin back rather than leaving a live WEIMI observation modified. Both destination headrooms are PLANTED (A to 6, B to 1) via golden.plant_shelf_stock and restored by block (4); seq 64/65 prove the restore.' WHERE fixture_id = 41;

  -- ---- seq 6 ------------------------------------------------------------------
  SELECT check_sql INTO v_b FROM golden.assertions WHERE fixture_id = 41 AND seq = 6;
  IF v_b IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 41 seq 6 does not exist.'; END IF;
  IF v_b NOT LIKE '%b2145d8e%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 seq 6 no longer pins the retired anchor-A shelf id (reads: %). It has been restated or renumbered; re-derive before overwriting.', v_b;
  END IF;
  UPDATE golden.assertions
     SET check_sql = 'SELECT s.pod_name FROM public.v_shelf_state s
 WHERE s.shelf_id = (SELECT (value->>''shelf_id'')::uuid FROM golden.scratch WHERE fixture_id=41 AND key=''anchor_dstA'')',
         expect = 'Zigi',
         description = 'DRIFT GUARD, RESTATED FOR A PREDICATE-RESOLVED ANCHOR (leg 158): whatever shelf block (0a) resolved as anchor A''s destination is carrying the Zigi pod. This seq used to pin the literal ''A06|Zigi|9acce2bf'' on the hardcoded shelf b2145d8e, and it is the assertion that correctly caught the real-world drift at leg 156 when WEIMI re-podded that shelf to Sunbites - six of the other failures were downstream of this one reading. It is no longer an identity pin because the identity is no longer the premise: the POD is. The resolved shelf''s code, machine and SKU count are RECORDED to golden.scratch under anchor_dstA and asserted by nobody, because pinning a live identity is what S-301/S-302 were raised for. If the fleet ever loses its last Zigi shelf, block (0a) RAISEs with a diagnostic instead of letting this seq report a confusing NULL.'
   WHERE fixture_id = 41 AND seq = 6;

  -- ---- seq 8 ------------------------------------------------------------------
  SELECT check_sql INTO v_b FROM golden.assertions WHERE fixture_id = 41 AND seq = 8;
  IF v_b IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 41 seq 8 does not exist.'; END IF;
  IF v_b NOT LIKE '%31894963%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 seq 8 no longer hardcodes the source shelf id (reads: %). It has been restated or renumbered; re-derive before overwriting.', v_b;
  END IF;
  UPDATE golden.assertions
     SET check_sql = 'SELECT (src.machine_id <> dst.machine_id)::text FROM public.v_shelf_state src, public.v_shelf_state dst
 WHERE src.shelf_id=(SELECT (value->>''shelf_id'')::uuid FROM golden.scratch WHERE fixture_id=41 AND key=''anchor_src'')
   AND dst.shelf_id=(SELECT (value->>''shelf_id'')::uuid FROM golden.scratch WHERE fixture_id=41 AND key=''anchor_dstA'')',
         description = 'M2M precondition: source and destination are genuinely different machines - the whole reason resolve_m2m_sku_legs_v3 refuses a same-machine pair as a shelf move rather than a transfer. FIXED AT LEG 158: this seq hardcoded the source shelf 31894963 even though S-256 had already made the source predicate-resolved, so it was silently asserting the precondition of a DIFFERENT pair than the one actually handed to the resolver. Both sides now read the anchors the scenario really used. Block (0b)''s predicate excludes both destination machines, so this is the assertion that proves that exclusion is doing its job.'
   WHERE fixture_id = 41 AND seq = 8;

  -- ---- seq 18 ------------------------------------------------------------------
  SELECT check_sql INTO v_b FROM golden.assertions WHERE fixture_id = 41 AND seq = 18;
  IF v_b IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 41 seq 18 does not exist.'; END IF;
  IF v_b NOT LIKE '%dstA_headroom%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 seq 18 does not read dstA_headroom (reads: %). It has been restated or renumbered; re-derive before overwriting.', v_b;
  END IF;
  UPDATE golden.assertions
     SET expect = '6',
         description = 'Anchor A headroom is 6, so its 6 eligible units fit EXACTLY and the capacity clamp must not fire. CHANGED FROM 9 AT LEG 158, and the change strengthens the fixture rather than relaxing it. Exactly one shelf in the fleet still carries the Zigi pod (ALJLT-1015-0200-O1 A08) and its max_stock is 6, so 6 is the largest headroom anchor A can be planted with; max_stock belongs to shelf configuration and is a protected entity this loop does not write. At headroom 9 there were three spare units of slack, which meant an off-by-one in the clamp - firing on units >= headroom where units > headroom is meant - stayed invisible. At headroom 6 the boundary is exact and seq 30 reds on it. This is the tightest no-clamp test the fixture has ever run, not a weakened one, and it is the reason anchor A can honestly keep its ''no clamp'' claim on a smaller shelf.'
   WHERE fixture_id = 41 AND seq = 18;

  -- ---- seq 30 ------------------------------------------------------------------
  SELECT check_sql INTO v_b FROM golden.assertions WHERE fixture_id = 41 AND seq = 30;
  IF v_b IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 41 seq 30 does not exist.'; END IF;
  IF v_b NOT LIKE '%clamped_units%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 41 seq 30 does not read clamped_units (reads: %). It has been restated or renumbered; re-derive before overwriting.', v_b;
  END IF;
  UPDATE golden.assertions
     SET description = 'Anchor A applied NO capacity clamp: 6 eligible units into EXACTLY 6 of headroom (leg 158; it was 6 into 9 before the re-anchor). The clamp must fire only when demand EXCEEDS headroom, never when it meets it exactly, so this is now a true boundary assertion - it reds on an off-by-one that three units of slack used to hide. Anchor B (headroom 1, seq 36) and anchor C (headroom 0, seq 56) cover the other side, so the three anchors now bracket the clamp at over, at, and under capacity.'
   WHERE fixture_id = 41 AND seq = 30;

END
$mig$;
