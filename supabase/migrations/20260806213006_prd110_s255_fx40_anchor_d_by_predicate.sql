-- PRD-110 leg 137 / S-255 - fixture 40's anchor D is selected BY PREDICATE, so "rung 1 is
-- satisfiable at all" is a condition of selection instead of a hope about live warehouse stock.
--
-- WHY: five assertions (44, 48, 50, 51, 55) were red from ONE cause. Anchor D was the hardcoded
-- triple AMZ-1046 / A11 / Hunter Ridge. Its pod still HAS primary-WH stock - 4 units - but the
-- 2026-07-30 plan has already claimed 7 for other shelves of the same pod, so
-- net_primary = GREATEST(4 - 7, 0) = 0. D_need is defined as net + 1, so the call asked for 1 and
-- rung 1 could serve 0: D stopped being a rung-1 PARTIAL and became a rung-1 MISS, the ladder fell
-- through to substitute#2, and every downstream assertion cascaded. The engine is untouched.
--
-- WHY NOT PLANT IT: the two levers that would restore net_primary are warehouse_inventory (a
-- protected entity - planting a shortage or a surplus there is out of bounds) and pod_refills on
-- 2026-07-30 (a LIVE plan table on a real past date - LAW 12 forbids it outright). Neither is
-- available, and neither should be. The anchor is what has to move.
--
-- THE SELECTION RULE, and every clause earns its place:
--   * net_primary >= 1        - the ONLY property anchor D actually needs. D_need = net + 1 then
--                               makes the partial structural: it cannot rot into a vacuous pass
--                               however live stock moves, which was already the original intent.
--   * shelf NOT IN (A, B, C)  - a D that collided with C would make seq 47/48 agree trivially.
--   * AMZ-1046 preferred      - a PREFERENCE in ORDER BY, never a filter, so it cannot rot. It
--                               keeps continuity with the machine BUILD-SPEC line 89 names while
--                               falling back to the whole fleet the moment that machine cannot
--                               serve. This is the one thing a bare predicate would have lost.
--   * n_variants DESC         - prefer an anchor that actually exercises the product_mapping
--                               fan-out dedup, rather than a single-variant pod that would pass
--                               the dedup guard by having nothing to dedup.
--
-- DRY-PROVEN BEFORE SHIPPING (LAW 1): resolve_supply_ladder_v3 is STABLE and read-only, so the two
-- leading candidates were called directly first. AMZ-1046 A02 McVities Digestive Nibbles returned
-- resolved_rung=variant, rung_no=1, qty_resolved=2, qty_shortfall=1, qty_needed=3, rung 2
-- attempted=false, 6 rungs logged, sentinel_units_excluded present - every assertion 44..56 satisfied,
-- and the ladder's OWN net_primary (2) agrees with the fixture's independently-derived model, which
-- is what seq 50's equality rests on.

DO $mig40$
DECLARE
  v_src text;
  v_new text;

  c_del CONSTANT text := $q$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
$q$;

  c_block CONSTANT text := $q$
-- ---------------------------------------------------------------------------
-- (0) ANCHOR D IS RESOLVED BY PREDICATE (S-255), never by uuid.
--     It is written to scratch FIRST so that the population read below and the
--     ladder call further down consume ONE identical anchor - two independent
--     lookups could silently drift apart and the fixture would still look green.
-- ---------------------------------------------------------------------------
DO $fx40d$
DECLARE
  v_mid uuid; v_sid uuid; v_pid uuid;
  v_name text; v_code text; v_pod text;
  v_net int; v_var int;
BEGIN
  WITH cand AS (
    SELECT s.machine_id, s.shelf_id, s.pod_product_id, s.shelf_code, s.pod_name,
           m.official_name, m.primary_warehouse_id
      FROM public.v_shelf_state s
      JOIN public.machines m ON m.machine_id = s.machine_id
     WHERE s.pod_product_id IS NOT NULL
       AND s.shelf_id NOT IN ('48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,
                              'cfed8e4f-7cba-4129-90ac-56ab0af0cfa8'::uuid,
                              '65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid)
  ),
  variants AS (
    SELECT c.shelf_id, v.boonz_product_id
      FROM cand c
      CROSS JOIN LATERAL (
        SELECT DISTINCT pm.boonz_product_id
          FROM public.product_mapping pm
         WHERE pm.pod_product_id = c.pod_product_id
           AND pm.status = 'Active'
           AND (pm.machine_id = c.machine_id OR pm.machine_id IS NULL)
      ) v
  ),
  claims AS (
    SELECT c.shelf_id, COALESCE(SUM(pr.qty), 0)::int AS claimed
      FROM cand c
      LEFT JOIN public.pod_refills pr
             ON pr.plan_date      = DATE '2026-07-30'
            AND pr.pod_product_id = c.pod_product_id
            AND pr.shelf_id IS DISTINCT FROM c.shelf_id
     GROUP BY c.shelf_id
  ),
  sup AS (
    SELECT c.shelf_id,
           COALESCE(SUM(w.warehouse_stock) FILTER (
              WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
                AND w.warehouse_id = c.primary_warehouse_id), 0)::int AS real_primary,
           count(DISTINCT vr.boonz_product_id)::int                   AS n_variants
      FROM cand c
      JOIN variants vr ON vr.shelf_id = c.shelf_id
      LEFT JOIN public.v_wh_pickable w
             ON w.boonz_product_id = vr.boonz_product_id
            AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = c.machine_id)
     GROUP BY c.shelf_id
  )
  SELECT c.machine_id, c.shelf_id, c.pod_product_id,
         c.official_name, c.shelf_code, c.pod_name,
         GREATEST(sup.real_primary - cl.claimed, 0), sup.n_variants
    INTO v_mid, v_sid, v_pid, v_name, v_code, v_pod, v_net, v_var
    FROM cand c
    JOIN sup    ON sup.shelf_id = c.shelf_id
    JOIN claims cl ON cl.shelf_id = c.shelf_id
   WHERE GREATEST(sup.real_primary - cl.claimed, 0) >= 1
   ORDER BY (c.machine_id = '981a155e-8bfc-4d6e-b168-0770ef082dc9'::uuid) DESC,
            sup.n_variants DESC,
            GREATEST(sup.real_primary - cl.claimed, 0) ASC,
            c.official_name, c.shelf_code
   LIMIT 1;

  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'FX40 setup: no pod-bound shelf in the fleet has net_primary >= 1 on 2026-07-30, so a rung-1 PARTIAL cannot be staged at all. Do NOT weaken seq 44/48/50/51/55 - they are the S-85/S-86 proof that the terminal rung is the first SATISFIABLE one and that a partial fill does not cascade.';
  END IF;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (40, 'anchor_D', jsonb_build_object(
    'machine_id',     v_mid,
    'shelf_id',       v_sid,
    'pod_product_id', v_pid,
    'machine_name',   v_name,
    'shelf_code',     v_code,
    'pod_name',       v_pod,
    'net_primary',    v_net,
    'n_variants',     v_var));
END
$fx40d$;
$q$;

  c_vals_old CONSTANT text := $q$         ('D', '981a155e-8bfc-4d6e-b168-0770ef082dc9'::uuid,
               '68511c6d-ebd1-4b9a-908d-fe5490a493c6'::uuid,
               '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid, 2)$q$;

  c_vals_new CONSTANT text := $q$         ('D', (SELECT (value->>'machine_id')::uuid     FROM golden.scratch WHERE fixture_id = 40 AND key = 'anchor_D'),
               (SELECT (value->>'shelf_id')::uuid       FROM golden.scratch WHERE fixture_id = 40 AND key = 'anchor_D'),
               (SELECT (value->>'pod_product_id')::uuid FROM golden.scratch WHERE fixture_id = 40 AND key = 'anchor_D'), 2)$q$;

  c_call_old CONSTANT text := $q$        '981a155e-8bfc-4d6e-b168-0770ef082dc9'::uuid,
        '68511c6d-ebd1-4b9a-908d-fe5490a493c6'::uuid,
        '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid,$q$;

  c_call_new CONSTANT text := $q$        (SELECT (value->>'machine_id')::uuid     FROM golden.scratch WHERE fixture_id = 40 AND key = 'anchor_D'),
        (SELECT (value->>'shelf_id')::uuid       FROM golden.scratch WHERE fixture_id = 40 AND key = 'anchor_D'),
        (SELECT (value->>'pod_product_id')::uuid FROM golden.scratch WHERE fixture_id = 40 AND key = 'anchor_D'),$q$;
BEGIN
  SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = 40;
  IF v_src IS NULL THEN RAISE EXCEPTION 'fixture 40 not found'; END IF;
  v_new := v_src;

  IF position(c_del IN v_new) = 0 THEN RAISE EXCEPTION 'sub 0 (delete anchor) did not match'; END IF;
  v_new := replace(v_new, c_del, c_del || c_block);

  IF position(c_vals_old IN v_new) = 0 THEN RAISE EXCEPTION 'sub 1 (anchors VALUES row) did not match'; END IF;
  v_new := replace(v_new, c_vals_old, c_vals_new);

  IF position(c_call_old IN v_new) = 0 THEN RAISE EXCEPTION 'sub 2 (ladder_D call) did not match'; END IF;
  v_new := replace(v_new, c_call_old, c_call_new);

  -- The old shelf and pod ids must be GONE. The old MACHINE id deliberately survives, once, as the
  -- ORDER BY preference - so it is checked for separately rather than lumped in.
  IF v_new LIKE '%68511c6d-ebd1-4b9a-908d-fe5490a493c6%'
     OR v_new LIKE '%51e4600f-2c15-428b-92ef-85fdc783c3af%' THEN
    RAISE EXCEPTION 'S-255: a hardcoded anchor-D shelf/pod id survived - the anchor is still uuid-bound';
  END IF;
  IF (length(v_new) - length(replace(v_new, '981a155e-8bfc-4d6e-b168-0770ef082dc9', ''))) / 36 <> 1 THEN
    RAISE EXCEPTION 'S-255: the AMZ-1046 machine id must appear EXACTLY once (the ORDER BY preference), found %',
      (length(v_new) - length(replace(v_new, '981a155e-8bfc-4d6e-b168-0770ef082dc9', ''))) / 36;
  END IF;

  UPDATE golden.fixtures
     SET scenario_sql = v_new,
         notes = notes || ' | S-255 (leg 137): anchor D is now SELECTED BY PREDICATE (net_primary >= 1 '
              || 'on 2026-07-30, shelf not A/B/C), resolved once into golden.scratch key anchor_D and read '
              || 'from there by BOTH the population CTE and the ladder call. The old hardcoded AMZ-1046 A11 '
              || 'Hunter Ridge triple went net_primary = 0 (4 units of stock, 7 already claimed), which turned '
              || 'D from a rung-1 PARTIAL into a rung-1 MISS and cascaded seq 44/48/50/51/55. Neither lever '
              || 'that would restore it is touchable: warehouse_inventory is protected and pod_refills on a '
              || 'real past date is LAW 12. AMZ-1046 survives only as an ORDER BY preference, so continuity '
              || 'with BUILD-SPEC line 89 is kept without being able to rot. seq 58/59/60 record and prove '
              || 'the anchor rather than trusting it.'
   WHERE fixture_id = 40;

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES
   (40, 58,
    'S-255 ANCHOR HYGIENE: the predicate-selected D is a DIFFERENT shelf from anchors A, B and C. A D that collided with C would make seq 47 and 48 agree for a reason that has nothing to do with the ladder',
    'SELECT ((value->>''shelf_id'') NOT IN (''48907909-7b0c-438b-8183-95ceaf1b4b81'',''cfed8e4f-7cba-4129-90ac-56ab0af0cfa8'',''65d699ab-441c-43e7-9a5d-bbd90d0da08e''))::text FROM golden.scratch WHERE fixture_id = 40 AND key = ''anchor_D''',
    'eq', 'true', true, 'P3'),
   (40, 59,
    'S-255 ATTRIBUTABILITY (METRICS_REGISTRY line 46 - a fixture must record the anchor it ran against): a dynamically selected anchor is unattributable unless it names itself, so a future red can be traced to the machine and shelf it actually measured',
    'SELECT CASE WHEN COALESCE(value->>''machine_name'','''') = '''' OR COALESCE(value->>''shelf_code'','''') = '''' THEN ''UNRECORDED'' ELSE ''RECORDED'' END FROM golden.scratch WHERE fixture_id = 40 AND key = ''anchor_D''',
    'eq', 'RECORDED', true, 'P3'),
   (40, 60,
    'S-255 NON-VACUITY of the fan-out guard on D: the chosen pod resolves to at least one deduped variant, so seq 53s conservation arithmetic is measured over a real product_mapping resolution and not an empty one',
    'SELECT (value->>''n_variants'')::int FROM golden.scratch WHERE fixture_id = 40 AND key = ''anchor_D''',
    'gte', '1', true, 'P3');
END $mig40$;