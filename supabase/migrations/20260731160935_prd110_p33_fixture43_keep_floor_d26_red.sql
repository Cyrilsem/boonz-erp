-- PRD-110 P3.3 / D-26 — fixture 43 adopts the CS keep-floor BEFORE the function does (LAW 1).
--
-- This migration is deliberately RED-making: the independent recomputation now subtracts
-- rot_keep_floor, propose_rotations_v3 does not yet. seq 22 (THE SPINE: proposed_qty equals
-- the independent recomputation) MUST go RED here, and the seq-46 D-26 contract below with it.
-- If either stays GREEN after this migration, the recomputation is not actually independent
-- and the whole fixture is decorative.
--
-- ⭐ S-75 HABIT KEPT: seq 47 is a SENSOR FOR THE SENSOR on the floor itself. A keep-floor that
--    never reduces any pair's qty is a policy that reads as applied and changes nothing.

-- ── 1. the recomputation reads the new param ──────────────────────────────────────────────
UPDATE golden.fixtures
SET scenario_sql = replace(scenario_sql,
      'rot_max_proposals AS maxprop',
      'rot_max_proposals AS maxprop, rot_keep_floor AS keep')
WHERE fixture_id = 43;

-- ── 2. every movable-qty expression subtracts the floor ───────────────────────────────────
-- ⛔ Cody revision 2: GREATEST(..., 0) is load-bearing. Without it a shelf below the floor
--    yields a NEGATIVE qty, hence a NEGATIVE pdays, which passes the expiry guard
--    (s_exp - CURRENT_DATE) >= pdays vacuously -- S-75's disease in a new costume.
-- The substring occurs three times (qty, pdays, and the >0 admission guard). All three must
-- move together; the assertion at the foot of this migration proves none was missed.
UPDATE golden.fixtures
SET scenario_sql = replace(scenario_sql,
      'LEAST(src.stock, tgt.headroom)',
      'LEAST(GREATEST(src.stock - (SELECT keep FROM f43_p), 0), tgt.headroom)')
WHERE fixture_id = 43;

-- ── 3. population counters: expose the floor and whether it BINDS ─────────────────────────
UPDATE golden.fixtures
SET scenario_sql = replace(scenario_sql,
      E'  ''expected_rows'',',
      E'  ''keep_floor'',        (SELECT keep FROM f43_p),\n'
      || E'  -- ⭐ SENSOR FOR THE SENSOR (D-26). Pairs where the keep-floor actually REDUCED the\n'
      || E'  --    movable qty. If this is 0, rot_keep_floor is decorative and seq 46 proves nothing.\n'
      || E'  ''floor_bound_pairs'', (SELECT count(*) FROM f43_all\n'
      || E'                          WHERE GREATEST(s_stock - (SELECT keep FROM f43_p), 0)\n'
      || E'                                < LEAST(s_stock, t_head)),\n'
      || E'  ''expected_rows'',')
WHERE fixture_id = 43;

-- ── 4. the D-26 contract, and the sensor that keeps it honest ─────────────────────────────
-- ⛔ S-78: fixture 43 already occupies seq 1..53 CONTIGUOUSLY. The obvious next seqs (46, 47)
--    are TAKEN, and an `ON CONFLICT (fixture_id, seq) DO UPDATE` -- the shape used elsewhere in
--    this build -- would have silently OVERWRITTEN two live assertions and still reported a
--    clean apply. This INSERT is deliberately bare: a seq collision must ERROR, never merge.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(43, 54,
 'D-26 CONTRACT (CS, 2026-07-31): every rotation LEAVES BEHIND at least rot_keep_floor units on the source shelf -- 0 proposals strip a shelf below the floor',
 $q$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text
     FROM golden.scratch s, jsonb_array_elements(s.value) e
     WHERE s.fixture_id=43 AND s.key='out'
       AND (e->>'source_qty_on_shelf')::int - (e->>'proposed_qty')::int
           < (SELECT rot_keep_floor FROM public.refill_policy_params LIMIT 1)) END$q$,
 'eq', '0', true, 'P3'),
(43, 55,
 'S-75 SENSOR FOR THE SENSOR (D-26): the keep-floor MEASURABLY binds -- there exist candidate pairs whose movable qty it reduced. If this reads 0 the floor is decorative and seq 46 passes vacuously; it does NOT mean the fleet stopped having small shelves',
 $q$SELECT COALESCE((SELECT (value->>'floor_bound_pairs') FROM golden.scratch
                    WHERE fixture_id=43 AND key='pop'), '-1')$q$,
 'gt', '0', true, 'P3');

-- ── 5. prove the rewrite is COMPLETE, not partial ─────────────────────────────────────────
DO $do$
DECLARE v text;
BEGIN
  SELECT scenario_sql INTO v FROM golden.fixtures WHERE fixture_id = 43;
  IF position('LEAST(src.stock, tgt.headroom)' in v) > 0 THEN
    RAISE EXCEPTION 'D-26: an unfloored LEAST(src.stock, tgt.headroom) survived the rewrite';
  END IF;
  IF position('rot_keep_floor AS keep' in v) = 0 THEN
    RAISE EXCEPTION 'D-26: f43_p never picked up rot_keep_floor';
  END IF;
  IF position('floor_bound_pairs' in v) = 0 THEN
    RAISE EXCEPTION 'D-26: the sensor-for-the-sensor counter was not installed';
  END IF;
  IF (SELECT count(*) FROM golden.assertions WHERE fixture_id=43 AND seq IN (54,55)) <> 2 THEN
    RAISE EXCEPTION 'D-26: contract assertions 54/55 missing';
  END IF;
  IF (SELECT count(*) FROM golden.assertions WHERE fixture_id=43) <> 55 THEN
    RAISE EXCEPTION 'D-26: fixture 43 should hold 55 assertions, holds %',
      (SELECT count(*) FROM golden.assertions WHERE fixture_id=43);
  END IF;
END
$do$;
