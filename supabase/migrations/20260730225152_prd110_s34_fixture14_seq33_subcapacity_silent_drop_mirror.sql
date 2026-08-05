-- PRD-110 · S-34 / S-05 · relay leg 28
--
-- WHY THIS EXISTS. Pinning fixture 3's machine empty (previous migration) made fixture 3
-- seq 1 -- "every sub-capacity shelf has a plan line" -- pass, because at stock 0 every
-- shelf is sub-capacity AND every one receives a line. That is a TRUE result on a real
-- 16-shelf evaluation, not a vacuous one, but it is no longer DISCRIMINATING for S-05:
-- v19's silent drop only fires at partial stock, where the computed qty rounds to 0.
-- Measured at leg 28 on MPMCC-1058 unpinned: 11 sub-capacity shelves, 8 lines, 3 dropped
-- (A05 Krambals 5/6, A08 Skittles Bag 8/10, A11 Be-kind Bar 18/20).
--
-- So S-05's SUB-capacity mirror moves here, beside its OVER-capacity mirror (seq 30/31/32),
-- on the fixture that deliberately runs on unpinned live state. Same machine, same gate,
-- same "count of bad things = 0" shape. Net effect: no assertion power was lost by S-34's
-- fix -- it changed hands, and this migration is the receipt.

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
VALUES (
  14, 33,
  'v3 TARGET (S-05 sub-capacity mirror, moved from fixture 3 seq 1 at leg 28): no SUB-capacity shelf is silently dropped -- each one receives a plan line (0 uncovered). v19 drops any sub-capacity shelf whose computed qty rounds to 0; P2.5''s unconditional floor is what closes this.',
  $q$
SELECT count(*)::text FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock < s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills pr
                      WHERE pr.plan_date = {{plan_date}} AND pr.shelf_id = s.shelf_id)
$q$,
  'eq', '0', true, 'P2',
  $g$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod_v3')$g$)
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description = EXCLUDED.description, check_sql = EXCLUDED.check_sql,
      expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
      enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required,
      acceptance_gate_sql = EXCLUDED.acceptance_gate_sql;

-- Record on fixture 3 seq 1 that its S-05 duty moved, so a future leg does not read its
-- pass as evidence that the silent-drop class is closed.
UPDATE golden.assertions SET description = description ||
  ' [leg 28] NOTE: under S-34''s empty pin this passes and is no longer discriminating for '
  'S-05 (at stock 0 the engine covers every shelf). S-05''s sub-capacity detector now lives '
  'at fixture 14 seq 33, which runs unpinned. This assertion still binds v3 coverage.'
WHERE fixture_id = 3 AND seq = 1;

UPDATE golden.fixtures SET notes = coalesce(notes,'') || E'\n\n'
  || '[leg 28 / S-05] seq 33 added: the SUB-capacity mirror of the silent-drop class, moved '
  || 'here from fixture 3 seq 1 when S-34''s empty pin stopped that assertion discriminating. '
  || 'Measured unpinned at leg 28: 11 sub-capacity shelves on MPMCC-1058, 8 lines, 3 dropped '
  || '(A05 Krambals 5/6, A08 Skittles Bag 8/10, A11 Be-kind Bar 18/20). Gated on '
  || 'engine_add_pod_v3, so it is expected-red until P2.5 lands.'
WHERE fixture_id = 14;
