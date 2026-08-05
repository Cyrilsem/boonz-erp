-- PRD-110 leg 111 · UNIT A · S-200 class (A), fixture 24 seq 29 (S-55)
-- Fixture 24's S-50 phantom-consumer-drain leg had gone VACUOUS: it borrowed its
-- precondition from the live fleet, and the fleet cleaned itself (40 sentinel rows,
-- ALL Active with warehouse stock, ZERO carrying consumer_stock). seq 29 therefore went
-- red while seq 30/32/33 stayed green for the worst possible reason - 0 = 0.
--
-- Remedy per S-200 (A): SELF-SUPPLY the precondition inside the fixture's OWN rollback
-- probe (fixture 31's idiom, already proven in this build), so the drain leg is exercised
-- on state the fixture owns rather than on state it merely hopes for.
-- The plant matches the exact production shape S-50 found: Active sentinel rows that hold
-- warehouse stock and carry phantom consumer_stock from dispatch_pack of sentinel units.
--
-- NOT relaxed to gte 0. That is the S-48/S-52/S-55 vacuity mode, already burned four times.
-- Every statement below is fail-loud per Cody's Article 12 "and idempotent" half: a
-- replace() that matches nothing would otherwise report ok while changing nothing (S-193).

DO $mig$
DECLARE
  v_sql   text;
  v_new   text;
  v_n     integer;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 24;
  IF v_sql IS NULL THEN RAISE EXCEPTION 'leg111 UNIT A: fixture 24 not found'; END IF;

  ---------------------------------------------------------------- 1. declares
  v_new := replace(v_sql,
    E'  v_cr record; v_cd_rows int := 0; v_cd_units numeric := 0;\nBEGIN',
    E'  v_cr record; v_cd_rows int := 0; v_cd_units numeric := 0;\n  v_planted int := 0; v_probe_rows int := 0;\nBEGIN');
  IF v_new = v_sql THEN RAISE EXCEPTION 'leg111 UNIT A: anchor 1 (declares) matched nothing'; END IF;
  v_sql := v_new;

  ---------------------------------------------------------------- 2. the plant
  v_new := replace(v_sql,
    E'  BEGIN\n    -- GUARD A: the canonical Article 6 writer refuses a stocked row (spec correction 2, first half)',
    E'  BEGIN\n'
    || E'    -- S-200 (A): SELF-SUPPLY the S-50 precondition rather than borrow it from the live fleet.\n'
    || E'    -- Every sentinel is currently Active WITH warehouse stock and WITHOUT consumer stock, so the\n'
    || E'    -- drain leg below had nothing to drain and seq 30/32/33 were passing on 0 = 0. This plants the\n'
    || E'    -- exact production shape S-50 found - phantom consumer_stock on a stocked, Active sentinel,\n'
    || E'    -- originating from dispatch_pack of sentinel units - and it is discarded with the whole probe.\n'
    || E'    -- Direct UPDATE is deliberate: no canonical writer RAISES consumer_stock (production sets it\n'
    || E'    -- via dispatch_pack), and trg_detect_silent_warehouse_write alerts only on Inactive/0 -> Active/N,\n'
    || E'    -- which this is not, so no monitoring_alerts row is minted even transiently.\n'
    || E'    -- \xe2\x9b\x94 DO NOT "fix" this by setting app.via_rpc/app.rpc_name. It is NOT an RPC, and per S-197 a\n'
    || E'    -- \xe2\x9b\x94 set flag leaves the canonical-writer gate OPEN for the rest of the transaction - which would\n'
    || E'    -- \xe2\x9b\x94 mask the canonical drain and retirement calls this fixture exists to prove. Cody, leg 111.\n'
    || E'    WITH pick AS (\n'
    || E'      SELECT wi.wh_inventory_id FROM public.warehouse_inventory wi\n'
    || E'       WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)\n'
    || E'         AND wi.status = ''Active'' AND COALESCE(wi.warehouse_stock,0) > 0\n'
    || E'         AND COALESCE(wi.consumer_stock,0) = 0\n'
    || E'       ORDER BY wi.wh_inventory_id LIMIT 3)\n'
    || E'    UPDATE public.warehouse_inventory w SET consumer_stock = 7\n'
    || E'      FROM pick WHERE w.wh_inventory_id = pick.wh_inventory_id;\n'
    || E'    GET DIAGNOSTICS v_planted = ROW_COUNT;\n'
    || E'\n'
    || E'    -- The precondition, measured AFTER the plant and INSIDE the probe. seq 29 reads this.\n'
    || E'    SELECT count(*) INTO v_probe_rows FROM public.warehouse_inventory wi\n'
    || E'     WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)\n'
    || E'       AND COALESCE(wi.consumer_stock,0) > 0;\n'
    || E'\n'
    || E'    -- GUARD A: the canonical Article 6 writer refuses a stocked row (spec correction 2, first half)');
  IF v_new = v_sql THEN RAISE EXCEPTION 'leg111 UNIT A: anchor 2 (plant) matched nothing'; END IF;
  v_sql := v_new;

  ---------------------------------------------------------------- 3. payload keys
  v_new := replace(v_sql,
    E'      ''consumer_drained_rows'',  v_cd_rows::text,',
    E'      ''planted_consumer_rows'',  v_planted::text,\n'
    || E'      ''probe_consumer_rows'',    v_probe_rows::text,\n'
    || E'      ''consumer_drained_rows'',  v_cd_rows::text,');
  IF v_new = v_sql THEN RAISE EXCEPTION 'leg111 UNIT A: anchor 3 (payload) matched nothing'; END IF;
  v_sql := v_new;

  UPDATE golden.fixtures SET scenario_sql = v_sql WHERE fixture_id = 24;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'leg111 UNIT A: fixture update hit % rows, expected 1', v_n; END IF;
END $mig$;

-- seq 29: read the SELF-SUPPLIED precondition, not the borrowed one.
DO $a29$
DECLARE v_n integer;
BEGIN
  UPDATE golden.assertions
     SET check_sql   = 'SELECT (value->>''probe_consumer_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
         description = 'PRECONDITION (non-vacuity, S-200 (A) restated): at least one sentinel carries phantom consumer_stock AT THE MOMENT THE DRAIN RUNS, self-supplied by the fixture inside its own rollback probe. The original borrowed this from live fleet state, which cleaned itself, leaving the whole S-50 drain leg passing on 0 = 0.'
   WHERE fixture_id = 24 AND seq = 29;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'leg111 UNIT A: assertion (24,29) hit % rows, expected 1', v_n; END IF;
END $a29$;

-- seq 32: the "none was skipped" equality must compare against the same self-supplied count.
DO $a32$
DECLARE v_n integer;
BEGIN
  UPDATE golden.assertions
     SET check_sql   = 'SELECT ((SELECT (value->>''consumer_drained_rows'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs'') = (SELECT (value->>''probe_consumer_rows'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''))::text',
         description = 'S-50: every sentinel that carried phantom consumer_stock went through the canonical writer - the drained count equals the precondition count, so none was skipped. Re-pointed by S-200 (A) at the self-supplied precondition; it previously compared two ambient zeroes.'
   WHERE fixture_id = 24 AND seq = 32;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'leg111 UNIT A: assertion (24,32) hit % rows, expected 1', v_n; END IF;
END $a32$;

-- seq 35 NEW: the plant itself must bite. Without this, a plant that silently matched zero
-- rows would drag seq 29 red with no indication of WHY - the S-193 class, one level up.
-- Seq 35, not 34: fixture 24 already occupies 1..34 contiguously (then 90, 94..99). The bare
-- INSERT is deliberate - a PK collision here is the fail-loud signal that the seq was taken.
INSERT INTO golden.assertions (fixture_id, seq, check_sql, expect_op, expect, description)
VALUES (24, 35,
  'SELECT (value->>''planted_consumer_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
  'eq', '3',
  'SETUP INTEGRITY (S-200 (A)): the fixture''s own plant seeded exactly the 3 sentinel rows it asked for. This pins what the FIXTURE owns (its LIMIT 3), not what the fleet happens to hold, and it separates "the drain is broken" from "the scenario never got set up" - the S-193 failure mode one level up.');
