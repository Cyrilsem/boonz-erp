-- PRD-110 leg 114 - fixture 8 seq 26/29: SELF-SUPPLY THE EMPTY SHELF (S-205)
--
-- CONTEXT. 8/29 is the LAST member of the S-200 red set. S-203 reclassified it correctly (seq 29
-- is a live tripwire; seq 26 is the vacuous one) but prescribed the WRONG remedy: "plant a
-- near-expiry warehouse_inventory batch". S-205 measured that and proved it a NO-OP -
-- fixture 8's plan_date is 2030-01-09 and every real WH batch expires 2026-2027, so
--   expiry_days = GREATEST(COALESCE(earliest_expiry - p_plan_date, 0), 0)
-- is ALREADY 0 on all 32 lines and expiry_ceiling_units is ALREADY 0 on all 20 WH lines.
-- No Appendix A plant is needed and none is made here.
--
-- THE ACTUAL MISSING INGREDIENT is floor_units > 0, which is a SHELF-STATE property:
--   floor_units = CASE WHEN stock_clamped = 0 AND basis <> 'partner' AND max_stock > 0
--                      THEN GREATEST(1, LEAST(v_min_facing, max_stock)) ELSE 0 END
-- and stock_clamped = LEAST(GREATEST(v_shelf_state.current_stock,0), GREATEST(max_stock,0)).
-- It requires an EMPTY shelf. Both facts re-derived from engine_add_pod_v3's body this leg,
-- not assumed (S-205 obligation 1).
--
-- S-205 obligation 2 - that need_raw keeps the floor UNDER a zero ceiling - also re-derived
-- from the engine body:
--   need_raw = LEAST(GREATEST(LEAST(cover_units, COALESCE(expiry_ceiling_units, cover_units)),
--                             floor_units, pin_floor_units), fill_to_cap)
-- so ceiling 0 -> LEAST(cover,0)=0 -> GREATEST(0, floor 2)=2 -> LEAST(2, cap 6)=2. The floor
-- survives. That IS the contract seq 26 asserts, and it is now witnessed rather than vacuous.
--
-- WHY THE FLOOR WENT INERT HERE. Of the 2409 fleet lines carrying floor_units > 0, 552 sit on
-- fixture 8's own MPMCC-1058-0000-R0 - but every one is basis='venue' with ceil_u = NULL, and
-- venue lines never receive an expiry ceiling at all. That population can NEVER satisfy seq 29.
-- Rather than wait for the fleet to hand over a qualifying shelf (S-204: never pin an assertion
-- on a population you do not write), the fixture SUPPLIES its own.
--
-- WHAT THIS MIGRATION DOES. golden.* only:
--   1. fixture 8 scenario_sql: a plant block before the engine call and a restore block after it.
--      The plant is ONE integer (currStock 3 -> 0) on ONE aisle (showName 'A7' = shelf_code A07,
--      zero-pad law) of ONE weimi_device_status snapshot row. The whole door_statuses is banked
--      into golden.scratch first and restored BYTE-IDENTICAL immediately after the engine run.
--   2. fixture 8 eng payload: 'floorful' added - the non-vacuity witness seq 26 always lacked.
--   3. assertions 32-35: plant landed / plant reached shelf state / restore byte-identical /
--      seq-26 non-vacuity. Every one is fail-loud; none can go green by accident.
--
-- WHY WEIMI AND NOT A ROLLBACK PROBE. Both were live options (S-205 named this the unit's first
-- design decision). The fixture-2 rollback-probe idiom would have had to swallow the ENGINE RUN
-- itself, deleting fixture 8's 32 pod_refills_shadow rows from the DB - a population eight other
-- fixtures (3, 5, 11, 14, 37, 44, 54, 105) assert over. Changing that blind is a far larger blast
-- radius than one restored integer. The plant path keeps fixture 8's observable output identical
-- in shape to what it is today and changes only one shelf-state input.
--
-- SAFETY, in four independent layers:
--   a. weimi_device_status carries NO triggers (verified leg 112), so nothing escapes a rollback.
--   b. run_fixture wraps the whole rendered scenario in a subtransaction with EXCEPTION WHEN
--      OTHERS - any error anywhere rolls the plant back with everything else.
--   c. the restore writes back the banked jsonb WHOLESALE and re-reads it for byte equality.
--   d. seq 34 pins that equality, so a silent half-restore reds the fixture.
-- The plant window is one engine run (~31s measured). WEIMI syncs this device ONCE DAILY at
-- 22:00 UTC, so an n8n row landing inside the window is vanishingly unlikely - and if it ever
-- did, seq 33 names it exactly rather than letting seq 29 fail with no cause.
--
-- NOT touched: warehouse_inventory, pod_inventory, refill_plan_output, pod_refill_plan, any RPC,
-- any flag, any cron, machines_to_visit outside fixture 8's own 2030-01-09 (LAW 12).
--
-- DRY-PROVEN READ-ONLY BEFORE WRITING, via a rollback probe that planted, ran the engine and
-- reverted:  floor_protected 1 · zeroed_despite_floor 0 · floorful 1 · zero_ceiling_lines 20 ·
-- ceiling_lifted 0 · mislabelled_full 0 · formula_mismatch 0 · lines 32.
-- A07 line: basis boonz_wh · esrc wh_fefo_batch · edays 0 · ceil_u 0 · cover 5 · floor_u 2 ·
-- fill_to_cap 6 · need_raw 2 · need_raw_no_expiry 5 · qty 2 · clamp_reason 'expiry_ceiling'.
-- WEIMI verified back at current_stock 3 after the probe.

-- ── 1. scenario_sql: plant before the engine call, restore after ────────────────────────────
UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
         'SELECT golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 14);',
$NEWTXT$-- ── SELF-SUPPLY PLANT for seq 26/29 (leg 114, S-205) ────────────────────────────
-- seq 26 says the expiry ceiling caps the COVER term and NEVER the min-facing floor; seq 29
-- is its positive form. Both were VACUOUS because floor_units needs stock_clamped = 0 - an
-- EMPTY shelf - and neither of this fixture's two machines carries one that also gets a
-- ceiling (their 552 floor-bearing lines are all basis='venue', which never gets one).
-- ⛔ The plant target is WEIMI because WEIMI is shelf state (DATA-SOURCE LAW). ONE integer,
-- ONE aisle, ONE snapshot row. The whole door_statuses is banked below and restored
-- byte-identical right after the engine call; seq 34 pins that restore.
DO $fx8plant$
DECLARE
  v_dev   text := 'MPMCC-1058-0000-R0';
  v_slot  text := 'A7';   -- WEIMI showName. shelf_code is A07 - zero-pad law, do not "fix".
  v_shelf uuid := '8b2a7cb9-9c98-4e7c-8a16-12fa4c93ec61';
  v_sid   uuid;
  v_orig  jsonb;
  v_ci int; v_li int; v_ai int;
  v_planted int := 0;
  v_seen    int;
BEGIN
  -- Indices are RE-DERIVED every run, never hardcoded: a WEIMI reshuffle must move the plant
  -- with it, not silently plant the wrong aisle.
  SELECT ws.status_id, ws.door_statuses, cab.ci - 1, layer.li - 1, aisle.ai - 1
    INTO v_sid, v_orig, v_ci, v_li, v_ai
    FROM (SELECT DISTINCT ON (device_name) status_id, door_statuses
            FROM public.weimi_device_status
           WHERE device_name = v_dev
           ORDER BY device_name, snapshot_at DESC) ws,
      LATERAL jsonb_array_elements(ws.door_statuses)      WITH ORDINALITY cab(value, ci),
      LATERAL jsonb_array_elements(cab.value->'layers')   WITH ORDINALITY layer(value, li),
      LATERAL jsonb_array_elements(layer.value->'aisles') WITH ORDINALITY aisle(value, ai)
   WHERE aisle.value->>'showName' = v_slot;

  IF v_sid IS NOT NULL THEN
    UPDATE public.weimi_device_status
       SET door_statuses = jsonb_set(door_statuses,
             ARRAY[v_ci::text, 'layers', v_li::text, 'aisles', v_ai::text, 'currStock'],
             to_jsonb(0))
     WHERE status_id = v_sid;
    GET DIAGNOSTICS v_planted = ROW_COUNT;
  END IF;

  -- Read the plant back THROUGH the canonical view, not off the JSONB: what the engine will
  -- see is v_shelf_state, and only that proves the plant actually reached sizing.
  SELECT current_stock INTO v_seen FROM public.v_shelf_state WHERE shelf_id = v_shelf;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'weimi', jsonb_build_object(
    'status_id',  v_sid,
    'planted',    v_planted,
    'path',       jsonb_build_array(v_ci, v_li, v_ai),
    'stock_seen', COALESCE(v_seen, -1),
    'restored',   'not_yet',
    'orig',       v_orig))
  ON CONFLICT (fixture_id, key) DO UPDATE
    SET value = EXCLUDED.value, written_at = now();
END
$fx8plant$;

SELECT golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 14);

-- ── RESTORE. Byte-identical, verified, immediately after the run ────────────────────────────
-- Wholesale write-back of the banked jsonb rather than "set currStock back to 3": the banked
-- value cannot drift from what was there, and equality is then decidable rather than inferred.
-- 'orig' is dropped from scratch ONLY on a proven-good restore, so a failure leaves the
-- evidence needed to repair it by hand.
DO $fx8restore$
DECLARE
  v_bak  jsonb;
  v_sid  uuid;
  v_orig jsonb;
  v_n    int := 0;
  v_ok   boolean := false;
  v_seen int;
BEGIN
  SELECT value INTO v_bak FROM golden.scratch
   WHERE fixture_id = {{fixture_id}} AND key = 'weimi';

  v_sid  := (v_bak->>'status_id')::uuid;
  v_orig := v_bak->'orig';

  IF v_sid IS NOT NULL AND v_orig IS NOT NULL THEN
    UPDATE public.weimi_device_status SET door_statuses = v_orig WHERE status_id = v_sid;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    SELECT (door_statuses = v_orig) INTO v_ok
      FROM public.weimi_device_status WHERE status_id = v_sid;
  END IF;

  SELECT current_stock INTO v_seen FROM public.v_shelf_state
   WHERE shelf_id = '8b2a7cb9-9c98-4e7c-8a16-12fa4c93ec61';

  UPDATE golden.scratch
     SET value = (CASE WHEN COALESCE(v_ok, false) THEN value - 'orig' ELSE value END)
                 || jsonb_build_object('restored',            COALESCE(v_ok, false),
                                       'restored_rows',       v_n,
                                       'stock_after_restore', COALESCE(v_seen, -1)),
         written_at = now()
   WHERE fixture_id = {{fixture_id}} AND key = 'weimi';
END
$fx8restore$;$NEWTXT$)
 WHERE fixture_id = 8;

-- ── 2. eng payload: add the non-vacuity witness seq 26 always lacked ────────────────────────
UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
         E'    ''floor_protected'',    (SELECT count(*) FROM fx8_l WHERE ceil_u = 0 AND need_raw > 0),',
         E'    ''floor_protected'',    (SELECT count(*) FROM fx8_l WHERE ceil_u = 0 AND need_raw > 0),\n'
      || E'    -- ⭐ THE witness seq 26 lacked (leg 114). seq 28 shows the ceiling population is\n'
      || E'    -- non-empty; only THIS shows the FLOOR population is, and seq 26 is an assertion\n'
      || E'    -- about the floor. Without it, "no line was zeroed despite its floor" was true\n'
      || E'    -- only because no line HAD a floor.\n'
      || E'    ''floorful'',           (SELECT count(*) FROM fx8_l WHERE floor_units > 0),')
 WHERE fixture_id = 8;

-- ── 3. fail-loud guard: replace() is SILENT on a missed needle (leg 112/113 tool lesson) ────
DO $guard$
DECLARE v_s text;
BEGIN
  SELECT scenario_sql INTO v_s FROM golden.fixtures WHERE fixture_id = 8;
  IF position('$fx8plant$'   in v_s) = 0 THEN RAISE EXCEPTION 'leg114: plant block did not land'; END IF;
  IF position('$fx8restore$' in v_s) = 0 THEN RAISE EXCEPTION 'leg114: restore block did not land'; END IF;
  IF position('''floorful''' in v_s) = 0 THEN RAISE EXCEPTION 'leg114: floorful did not land'; END IF;
  -- exactly ONE engine call (a double-replace would run the engine twice and silently
  -- double the shadow rows), and the plant is before it while the restore is after it
  IF (length(v_s) - length(replace(v_s, 'run_engine_v3_if_built', ''))) / length('run_engine_v3_if_built') <> 1 THEN
    RAISE EXCEPTION 'leg114: expected exactly one run_engine_v3_if_built call';
  END IF;
  IF (length(v_s) - length(replace(v_s, '$fx8plant$', ''))) / length('$fx8plant$') <> 2 THEN
    RAISE EXCEPTION 'leg114: plant block is not present exactly once';
  END IF;
  IF NOT (position('$fx8plant$' in v_s) < position('run_engine_v3_if_built' in v_s)
          AND position('run_engine_v3_if_built' in v_s) < position('$fx8restore$' in v_s)) THEN
    RAISE EXCEPTION 'leg114: plant/engine/restore are out of order';
  END IF;
END
$guard$;

-- ── 4. assertions 32-35 (max(seq) for fixture 8 was 31, taken UNFILTERED) ───────────────────
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (8, 32,
  'PLANT LANDED: the self-supply empty shelf reached exactly ONE weimi_device_status snapshot row. 0 means the A7 aisle was not found (a WEIMI reshuffle) and seq 26/29 below are running on an unplanted fleet',
  'SELECT COALESCE((SELECT value->>''planted'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''weimi''),''-1'')',
  'eq', '1', true, 'P2'),
 (8, 33,
  'PLANT REACHED SIZING: v_shelf_state.current_stock for the planted shelf is 0 as the engine reads it, not merely 0 in the JSONB. ⛔ If this ever fires with planted=1 the cause is an n8n WEIMI snapshot landing INSIDE the run window (this device syncs once daily, 22:00 UTC) - re-run rather than restate seq 26/29',
  'SELECT COALESCE((SELECT value->>''stock_seen'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''weimi''),''-1'')',
  'eq', '0', true, 'P2'),
 (8, 34,
  'NO RESIDUE: the banked door_statuses was restored BYTE-IDENTICAL after the engine run. This fixture borrows one integer of shelf state and gives it back - a false here means live WEIMI is left falsified and must be repaired from golden.scratch key ''weimi'' -> ''orig''',
  'SELECT COALESCE((SELECT value->>''restored'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''weimi''),''false'')',
  'eq', 'true', true, 'P2'),
 (8, 35,
  'NON-VACUITY for seq 26, the term seq 28 never covered: the min-facing FLOOR population is non-empty. seq 28 proves lines carry a zero CEILING; only this proves any line carries a FLOOR at all. Without it "nothing was zeroed despite its floor" is trivially true on a fleet with no floors',
  'SELECT COALESCE((SELECT value->>''floorful'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''eng''),''-1'')',
  'gt', '0', true, 'P2');
