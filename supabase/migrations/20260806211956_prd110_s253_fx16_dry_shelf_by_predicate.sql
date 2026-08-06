-- PRD-110 leg 137 / S-253 - fixture 16 selects its dry shelf BY PREDICATE, and self-supplies
-- the headroom the always_stock pin needs in order to bite.
--
-- WHY (S-249): fixture 16 hardcoded shelf_code 'A07' as its "zero availability" probe. On
-- 2026-07-22 production created a warehouse row for "Freakin Healthy Bites 2P"; by 2026-08-06 that
-- shelf read 16 Active, in-date, unreserved WH units. Nothing in the engine changed
-- (engine_add_pod_v3 md5 e9f3caff, byte-identical to the last-green run) - the fixture's PREMISE
-- decayed underneath it, and three assertions went red: seq 16 clamp_z blocked_no_wh -> pin_floor,
-- seq 15 qb_z 0 -> 1, seq 13 moved 1 -> 2.
--
-- Re-baselining those three would have deleted the proof that AVAILABILITY OUTRANKS A PIN -
-- the money rule that stops a pin from conjuring warehouse stock. The shelf is the accident; the
-- dryness is the subject. So the shelf is now chosen by the property it must have.
--
-- THE SPLIT, and it is deliberate:
--   * ZERO WH AVAILABILITY is selected BY PREDICATE, never planted. Planting it would mean writing
--     warehouse_inventory - a protected entity - to manufacture a shortage. The fixture asserts
--     over a shelf production genuinely cannot serve.
--   * HEADROOM is SELF-SUPPLIED via golden.plant_shelf_stock (leg 136), because it is a shelf
--     property and it is exactly what fixture 17 taught: a precondition inherited from live data
--     eventually cannot be met at all.
--
-- The predicate mirrors the engine's OWN availability arithmetic rather than restating it loosely:
-- engine_add_pod_v3 computes avail_units as
--     CASE WHEN a.shelf_id IS NULL THEN 0
--          WHEN a.is_constrained  THEN COALESCE(a.available_units, 0)
--          ELSE NULL END
-- so `blocked_no_wh` needs is_constrained = true AND available_units = 0 AND need_raw > 0. All
-- three are now conditions of selection, not hopes.
--
-- stock is kept STRICTLY ABOVE ZERO on purpose. floor_units fires only when stock_clamped = 0;
-- an empty shelf would take the P2.5 min-facing floor and lift need_raw without any pin, making
-- seq 14 pass for a reason that has nothing to do with pins.
--
-- Nothing is loosened. Two assertions are ADDED (32, 33) because the new selection must prove
-- itself: that the chosen shelf really was dry, and that the pin really was read on it.
--
-- NOTE ON THE FINAL GUARD: it refuses if the literal shelf code survives ANYWHERE in the rewritten
-- scenario, comments included. That is deliberate and it already caught one real mistake during
-- authoring - the first draft of the replacement comment quoted the old code back, which would
-- have left a name-bound string in a fixture whose whole point is that it is no longer name-bound.

DO $mig$
DECLARE
  v_src   text;
  v_new   text;

  -- ---- substitution 1: the declarations the predicate + plant need
  c_decl_old CONSTANT text := E'  sh_z      uuid;   -- A07, zero availability\n';
  c_decl_new CONSTANT text := E'  sh_z      uuid;   -- the DRY shelf: selected by PREDICATE (S-253), never by shelf_code\n'
    || E'  v_z_code    text    := ''none'';\n'
    || E'  v_z_avail   integer := -1;\n'
    || E'  v_z_stock   integer := -1;\n'
    || E'  v_z_max     integer := -1;\n'
    || E'  v_z_plant   integer := -1;\n'
    || E'  v_z_planted integer := 0;\n'
    || E'  v_pinfloor_z integer := -1;\n';

  -- ---- substitution 2: predicate selection + headroom self-supply
  c_sel_old CONSTANT text :=
E'    SELECT s.shelf_id, s.pod_product_id INTO sh_z, pod_z\n'
|| E'      FROM public.v_shelf_state s WHERE s.machine_id = m AND s.shelf_code = ''A07'';\n';

  c_sel_new CONSTANT text :=
E'    -- THE DRY SHELF IS CHOSEN BY THE PROPERTY IT MUST HAVE, NOT BY ITS NAME (S-253).\n'
|| E'    --    A fixed shelf_code was hardcoded here until production restocked that shelf and this\n'
|| E'    --    fixture went red with zero code change (S-249). The predicate below is the engine''s\n'
|| E'    --    own avail_units arithmetic: is_constrained AND available_units = 0 is exactly what\n'
|| E'    --    makes blocked_no_wh reachable. max_stock >= 2 leaves room for stock >= 1 AND\n'
|| E'    --    headroom >= 1 at the same time.\n'
|| E'    SELECT s.shelf_id, s.pod_product_id, s.shelf_code,\n'
|| E'           COALESCE(a.available_units, 0), COALESCE(s.current_stock, 0), COALESCE(s.max_stock, 0)\n'
|| E'      INTO sh_z, pod_z, v_z_code, v_z_avail, v_z_stock, v_z_max\n'
|| E'      FROM public.v_shelf_availability_v3 a\n'
|| E'      JOIN public.v_shelf_state s ON s.shelf_id = a.shelf_id\n'
|| E'     WHERE a.machine_id = m\n'
|| E'       AND a.shelf_id <> sh_t AND a.shelf_id <> sh_c\n'
|| E'       AND a.sourcing = ''boonz_wh''\n'
|| E'       AND a.is_constrained\n'
|| E'       AND COALESCE(a.available_units, 0) = 0\n'
|| E'       AND COALESCE(s.max_stock, 0) >= 2\n'
|| E'       AND EXISTS (SELECT 1 FROM public.product_mapping pm\n'
|| E'                    WHERE pm.pod_product_id = a.pod_product_id AND pm.status = ''Active''\n'
|| E'                      AND (pm.machine_id IS NULL OR pm.machine_id = m))\n'
|| E'     ORDER BY GREATEST(COALESCE(s.max_stock,0) - COALESCE(s.current_stock,0), 0) DESC, s.shelf_code\n'
|| E'     LIMIT 1;\n'
|| E'\n'
|| E'    IF sh_z IS NULL THEN\n'
|| E'      RAISE EXCEPTION ''FX16 setup: no shelf on this machine has ZERO warehouse availability - '' ||\n'
|| E'        ''the "a pin never conjures stock" premise cannot be staged, and re-baselining seq 15/16 '' ||\n'
|| E'        ''would delete that proof rather than fix it'';\n'
|| E'    END IF;\n'
|| E'\n'
|| E'    -- SELF-SUPPLY THE HEADROOM (fixture 17 idiom, leg 136''s planter). always_stock sets\n'
|| E'    -- pin_floor_raw = 1, and pin_floor_units = LEAST(1, fill_to_cap): with a full shelf the pin\n'
|| E'    -- is arithmetically incapable of biting and seq 14 would fail for a reason that is not the\n'
|| E'    -- engine''s. Stock stays >= 1: floor_units fires only at stock_clamped = 0, and an empty\n'
|| E'    -- shelf would lift need_raw through the min-facing floor with no pin involved at all.\n'
|| E'    v_z_plant := LEAST(GREATEST(v_z_stock, 1), v_z_max - 1);\n'
|| E'    IF v_z_plant <> v_z_stock THEN\n'
|| E'      PERFORM golden.plant_shelf_stock(sh_z, v_z_plant);\n'
|| E'      v_z_planted := 1;\n'
|| E'      v_z_stock   := v_z_plant;\n'
|| E'    END IF;\n';

  -- ---- substitution 3: measure the pin floor the dry shelf actually received
  c_pf_old CONSTANT text :=
E'    v_need_z := COALESCE(NULLIF(v_b->sh_z::text->>''nr'',''ABSENT'')::int, -1);\n';
  c_pf_new CONSTANT text :=
E'    v_need_z := COALESCE(NULLIF(v_b->sh_z::text->>''nr'',''ABSENT'')::int, -1);\n'
|| E'    v_pinfloor_z := COALESCE(NULLIF(v_b->sh_z::text->>''pf'',''ABSENT'')::int, -1);\n';

  -- ---- substitution 4: publish the new measurements
  c_obs_old CONSTANT text := E'    ''need_z'',       v_need_z,\n';
  c_obs_new CONSTANT text := E'    ''need_z'',       v_need_z,\n'
|| E'    ''z_code'',       v_z_code,\n'
|| E'    ''z_avail'',      v_z_avail,\n'
|| E'    ''z_planted'',    v_z_planted,\n'
|| E'    ''pinfloor_z'',   v_pinfloor_z,\n';
BEGIN
  SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = 16;
  IF v_src IS NULL THEN RAISE EXCEPTION 'fixture 16 not found'; END IF;
  v_new := v_src;

  -- Every substitution is VERIFIED, one at a time. A silent no-op replace() would leave the
  -- fixture unchanged while the migration reported success - the exact class of failure the
  -- build's "migration file presence is not proof of apply" rule exists to catch.
  IF position(c_decl_old IN v_new) = 0 THEN RAISE EXCEPTION 'sub 1 (declarations) did not match'; END IF;
  v_new := replace(v_new, c_decl_old, c_decl_new);

  IF position(c_sel_old IN v_new) = 0 THEN RAISE EXCEPTION 'sub 2 (sh_z selection) did not match'; END IF;
  v_new := replace(v_new, c_sel_old, c_sel_new);

  IF position(c_pf_old IN v_new) = 0 THEN RAISE EXCEPTION 'sub 3 (pin floor measure) did not match'; END IF;
  v_new := replace(v_new, c_pf_old, c_pf_new);

  IF position(c_obs_old IN v_new) = 0 THEN RAISE EXCEPTION 'sub 4 (scratch keys) did not match'; END IF;
  v_new := replace(v_new, c_obs_old, c_obs_new);

  -- The old hardcode must be GONE, not merely supplemented. Both occurrences - the declaration
  -- comment and the SELECT - are covered by the substitutions above, so ANY surviving occurrence
  -- means one of them silently missed.
  IF position('A07' IN v_new) <> 0 THEN
    RAISE EXCEPTION 'a hardcoded shelf code survived the rewrite - the fixture is still name-bound';
  END IF;

  UPDATE golden.fixtures
     SET scenario_sql = v_new,
         notes = notes || ' | S-253 (leg 137): sh_z is now selected BY PREDICATE (sourcing boonz_wh, '
              || 'is_constrained, available_units = 0, max_stock >= 2, Active mapping), not by shelf_code. '
              || 'The old code was hardcoded and production restocked it (S-249), which reddened seq 13/15/16 '
              || 'with a byte-identical engine. Headroom is self-supplied via golden.plant_shelf_stock; ZERO WH '
              || 'AVAILABILITY is never planted (that would mean writing warehouse_inventory to manufacture '
              || 'a shortage). Stock is held >= 1 so the min-facing floor cannot lift need_raw in the pin''s '
              || 'place. seq 32/33 prove the selection instead of assuming it.'
   WHERE fixture_id = 16;

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES
   (16, 32,
    'PREMISE, MEASURED NOT ASSUMED (S-253): the shelf this fixture calls dry really did read zero available warehouse units. When this goes red the fixture has lost its subject - re-select, never re-baseline seq 15/16',
    'SELECT value->>''z_avail'' FROM golden.scratch WHERE fixture_id=16 AND key=''obs''',
    'eq', '0', true, 'P4'),
   (16, 33,
    'NON-VACUITY OF THE PIN ITSELF: the always_stock pin reached the dry shelf with a floor of at least one unit. A full shelf would floor pin_floor_units at 0 and seq 14 would then pass on demand the pin never created',
    'SELECT value->>''pinfloor_z'' FROM golden.scratch WHERE fixture_id=16 AND key=''obs''',
    'gte', '1', true, 'P4');

  RAISE NOTICE 'fixture 16 rewritten: % -> % chars, 2 assertions added', length(v_src), length(v_new);
END $mig$;