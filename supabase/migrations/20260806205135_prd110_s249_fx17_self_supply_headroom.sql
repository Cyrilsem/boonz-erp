-- PRD-110 · S-249 · leg 136
-- Fixture 17 stopped being able to SET ITSELF UP: production filled VML-1003-0400-O1 A01 to
-- stock=14 max=14, so `v_facing < 1` and the scenario raised before a single assertion ran.
-- That is not an assertion failure - it is a fixture that INHERITED its own precondition from
-- live data. The build's answer to this class is the leg-114/115 idiom: the fixture SELF-SUPPLIES
-- the precondition inside its rolled-back probe block.
--
-- Two objects:
--   1. golden.plant_shelf_stock(shelf, stock) - the named, reusable planter. Fixtures 2 and 8
--      already hand-rolled this JSONB navigation inline; naming it once means the zero-pad law
--      and the read-back-through-the-view proof live in ONE place instead of four copies.
--   2. Fixture 17's setup, which now plants when live has no headroom.
--
-- NOT loosened: every fixture-17 assertion that touches the planted value (seq 9, 10, 14) is
-- RELATIVE to v_facing, so the planted level cannot bias any of them. Two NEW assertions
-- (26, 27) exist because the plant itself must be proven: that it bit, and that it was undone.

-- ============================================================================================
-- 1. The planter.
-- ============================================================================================
-- SECURITY INVOKER on purpose: the fixture runner already holds the rights to write
-- weimi_device_status (fixtures 2 and 8 do it inline today), so this grants NO new privilege.
-- It is a harness helper and lives in `golden`, never in `public`.
CREATE OR REPLACE FUNCTION golden.plant_shelf_stock(p_shelf_id uuid, p_stock integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $fn$
DECLARE
  v_dev     text;
  v_code    text;
  v_show    text;
  v_sid     uuid;
  v_ci      int; v_li int; v_ai int;
  v_matches int;
  v_planted int := 0;
  v_seen    int;
BEGIN
  IF p_stock IS NULL OR p_stock < 0 THEN
    RAISE EXCEPTION 'plant_shelf_stock: refusing negative/NULL stock (%)', p_stock;
  END IF;

  SELECT m.official_name, s.shelf_code
    INTO v_dev, v_code
    FROM public.v_shelf_state s
    JOIN public.machines m ON m.machine_id = s.machine_id
   WHERE s.shelf_id = p_shelf_id;

  IF v_dev IS NULL THEN
    RAISE EXCEPTION 'plant_shelf_stock: shelf % does not resolve to a machine', p_shelf_id;
  END IF;

  -- ZERO-PAD LAW, applied in reverse: shelf_code 'A07' is WEIMI showName 'A7'. The pad is real
  -- on our side and absent on theirs - do NOT "fix" either one.
  v_show := regexp_replace(v_code, '^([A-Za-z]+)0*([0-9]+)$', '\1\2');

  -- Indices are RE-DERIVED every call, never cached: a WEIMI reshuffle must move the plant with
  -- it rather than silently plant a different aisle.
  SELECT count(*) INTO v_matches
    FROM (SELECT DISTINCT ON (device_name) status_id, door_statuses
            FROM public.weimi_device_status WHERE device_name = v_dev
           ORDER BY device_name, snapshot_at DESC) ws,
      LATERAL jsonb_array_elements(ws.door_statuses)      WITH ORDINALITY cab(value, ci),
      LATERAL jsonb_array_elements(cab.value->'layers')   WITH ORDINALITY layer(value, li),
      LATERAL jsonb_array_elements(layer.value->'aisles') WITH ORDINALITY aisle(value, ai)
   WHERE aisle.value->>'showName' = v_show;

  -- Stricter than the inline precedent: an ambiguous showName would let the planter write a
  -- shelf nobody named, and every downstream assertion would still pass.
  IF v_matches <> 1 THEN
    RAISE EXCEPTION 'plant_shelf_stock: device % showName % (shelf_code %) matched % aisles, need exactly 1',
      v_dev, v_show, v_code, v_matches;
  END IF;

  SELECT ws.status_id, cab.ci - 1, layer.li - 1, aisle.ai - 1
    INTO v_sid, v_ci, v_li, v_ai
    FROM (SELECT DISTINCT ON (device_name) status_id, door_statuses
            FROM public.weimi_device_status WHERE device_name = v_dev
           ORDER BY device_name, snapshot_at DESC) ws,
      LATERAL jsonb_array_elements(ws.door_statuses)      WITH ORDINALITY cab(value, ci),
      LATERAL jsonb_array_elements(cab.value->'layers')   WITH ORDINALITY layer(value, li),
      LATERAL jsonb_array_elements(layer.value->'aisles') WITH ORDINALITY aisle(value, ai)
   WHERE aisle.value->>'showName' = v_show;

  UPDATE public.weimi_device_status
     SET door_statuses = jsonb_set(door_statuses,
           ARRAY[v_ci::text, 'layers', v_li::text, 'aisles', v_ai::text, 'currStock'],
           to_jsonb(p_stock))
   WHERE status_id = v_sid;
  GET DIAGNOSTICS v_planted = ROW_COUNT;

  -- Read back THROUGH the canonical view, not off the JSONB: what the engine will see is
  -- v_shelf_state, and only that proves the plant actually reached sizing.
  SELECT current_stock INTO v_seen FROM public.v_shelf_state WHERE shelf_id = p_shelf_id;

  IF v_planted <> 1 OR v_seen IS DISTINCT FROM p_stock THEN
    RAISE EXCEPTION 'plant_shelf_stock: plant did not reach sizing (rows=% seen=% wanted=%)',
      v_planted, v_seen, p_stock;
  END IF;

  RETURN v_seen;
END
$fn$;

REVOKE ALL ON FUNCTION golden.plant_shelf_stock(uuid, integer) FROM PUBLIC;

COMMENT ON FUNCTION golden.plant_shelf_stock(uuid, integer) IS
  'PRD-110 S-249. Golden-harness planter for shelf stock. MUST be called only inside a fixture''s '
  'rolled-back probe block - it writes public.weimi_device_status. Re-derives WEIMI indices every '
  'call, refuses an ambiguous showName, and verifies the plant through v_shelf_state.';

-- ============================================================================================
-- 2. Fixture 17 self-supplies its headroom.
-- ============================================================================================
-- Named substitutions with a hard anchor check on each: a replacement that silently matches
-- nothing would leave the fixture unchanged while this migration reported success.
DO $mig$
DECLARE
  v_sql text;
  v_old text;
  v_new text;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 17;
  IF v_sql IS NULL THEN RAISE EXCEPTION 'FX17: fixture not found'; END IF;

  -- ---- sub 1: declarations for the restore proof ----
  v_old := '  v_prp_before bigint; v_prp_after bigint;';
  v_new := '  v_prp_before bigint; v_prp_after bigint;' || E'\n'
        || '  v_weimi_before int; v_weimi_after int; v_planted_to int := -1;';
  IF position(v_old in v_sql) = 0 THEN RAISE EXCEPTION 'FX17 sub1 anchor not found'; END IF;
  v_sql := replace(v_sql, v_old, v_new);

  -- ---- sub 2: plant the headroom instead of inheriting it ----
  v_old := '    v_facing := LEAST(3, GREATEST(v_max_p - v_stock_p, 0));' || E'\n'
        || '    IF v_facing < 1 THEN' || E'\n'
        || '      RAISE EXCEPTION ''FX17 setup: no headroom on A01 (stock=% max=%) - a facing pin could not bite'', v_stock_p, v_max_p;' || E'\n'
        || '    END IF;';
  v_new := '    -- SELF-SUPPLY (S-249): production keeps this shelf full, so the fixture no longer' || E'\n'
        || '    -- INHERITS its own precondition - it PLANTS it, inside the rolled-back probe block.' || E'\n'
        || '    -- Every assertion that reads the planted value is RELATIVE to v_facing (seq 9, 10,' || E'\n'
        || '    -- 14), so the level planted here cannot bias any of them.' || E'\n'
        || '    v_weimi_before := v_stock_p;' || E'\n'
        || '    IF v_max_p - v_stock_p < 1 THEN' || E'\n'
        || '      v_planted_to := GREATEST(v_max_p - 3, 0);' || E'\n'
        || '      v_stock_p := golden.plant_shelf_stock(sh_p, v_planted_to);' || E'\n'
        || '    END IF;' || E'\n'
        || '    v_facing := LEAST(3, GREATEST(v_max_p - v_stock_p, 0));' || E'\n'
        || '    IF v_facing < 1 THEN' || E'\n'
        || '      RAISE EXCEPTION ''FX17 setup: no headroom on A01 (stock=% max=%) even after planting - a facing pin could not bite'', v_stock_p, v_max_p;' || E'\n'
        || '    END IF;';
  IF position(v_old in v_sql) = 0 THEN RAISE EXCEPTION 'FX17 sub2 anchor not found'; END IF;
  v_sql := replace(v_sql, v_old, v_new);

  -- ---- sub 3: measure the restore AFTER the probe block, and publish both ----
  v_old := '  SELECT count(*) INTO v_prp_after FROM public.pod_refill_plan;';
  v_new := '  -- The plant lives inside the rolled-back block; this re-read proves it was undone.' || E'\n'
        || '  SELECT current_stock INTO v_weimi_after FROM public.v_shelf_state WHERE shelf_id = sh_p;' || E'\n'
        || '  SELECT count(*) INTO v_prp_after FROM public.pod_refill_plan;';
  IF position(v_old in v_sql) = 0 THEN RAISE EXCEPTION 'FX17 sub3 anchor not found'; END IF;
  v_sql := replace(v_sql, v_old, v_new);

  v_old := '    ''prp_delta'',   v_prp_after - v_prp_before));';
  v_new := '    ''prp_delta'',   v_prp_after - v_prp_before,' || E'\n'
        || '    ''planted_to'',  v_planted_to,' || E'\n'
        || '    ''weimi_restored'', CASE WHEN v_weimi_after IS NOT DISTINCT FROM v_weimi_before THEN 1 ELSE 0 END));';
  IF position(v_old in v_sql) = 0 THEN RAISE EXCEPTION 'FX17 sub4 anchor not found'; END IF;
  v_sql := replace(v_sql, v_old, v_new);

  UPDATE golden.fixtures SET scenario_sql = v_sql WHERE fixture_id = 17;
END
$mig$;

-- ============================================================================================
-- 3. The plant must be PROVEN, both that it bit and that it was undone.
-- ============================================================================================
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
  (17, 26,
   'NON-VACUITY (S-249): the setup produced a facing pin that can actually bite. Live data filled A01 to capacity on 2026-08-05; this reads >= 1 whether the headroom was inherited or planted',
   'SELECT (value->>''facing'')::int FROM golden.scratch WHERE fixture_id=17 AND key=''obs''',
   'gte', '1', true, 'P4'),
  (17, 27,
   'RESIDUE (S-249): the WEIMI plant did NOT outlive the probe block. A planter that leaked would silently rewrite live shelf state for every later fixture in the sweep',
   'SELECT (value->>''weimi_restored'')::int FROM golden.scratch WHERE fixture_id=17 AND key=''obs''',
   'eq', '1', true, 'P4')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description = EXCLUDED.description,
      check_sql   = EXCLUDED.check_sql,
      expect_op   = EXCLUDED.expect_op,
      expect      = EXCLUDED.expect,
      enabled     = EXCLUDED.enabled;
