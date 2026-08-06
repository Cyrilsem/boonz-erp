-- PRD-110 S-257 — fixture 24 seq 5 stops pinning a live WEIMI-derived population to a literal.
--
-- ⛔ WHAT MOVED, AND WHAT DID NOT. seq 5 read 61 at leg 134 (2026-08-06 05:02:14Z) and 62 at
--    leg 138 (2026-08-06 21:57:26Z), both read out of golden.runs, not remembered. The fixture's
--    ACTUAL claim is untouched: seq 21 (would_block_on_retirement = 0 AFTER retirement) and
--    seq 6/7/8 (SOA identical across retirement, to the cent) all stayed green. 41 of 42 passed
--    and `scenario_error` was NULL, so per S-254 the assertion list is trustworthy.
--
-- ⛔ S-251 IS EXONERATED, AND THIS IS THE TRANSFERABLE PART. The natural reading - "leg 136
--    changed PRODUCTION sourcing on ten co_managed machines, so of course an availability count
--    moved" - IS WRONG. `v_shelf_availability_v3` computes
--        sentinel_backed := wh_units_sentinel > 0
--    from product_mapping x v_wh_pickable x the machine's primary/secondary warehouse, and
--    ⛔ NEVER READS product_sourcing AT ALL. The ten sourcing rows cannot move this number.
--    (They move `is_constrained` / `available_units`, which are different columns.)
--
-- ⭐ RULED OUT BY MEASUREMENT, not by argument: sentinel rows 40 (seq 1 green) · pickable
--    sentinels 40 (seq 4 green) · product_mapping untouched since 2026-08-05 22:33Z, which is
--    BEFORE the 61 reading · machines untouched for 24h · shelf population 544, unchanged.
--    ⇒ The mover is a per-shelf POD RE-RESOLUTION in v_shelf_state, i.e. WEIMI identity drift -
--    the one input that is expected to move on its own and that the DATA-SOURCE LAW says WEIMI owns.
--
-- ⭐ THE REMEDY IS A STRENGTHENING, NOT A LOOSENING. seq 5's only job was NON-VACUITY: stopping
--    the retirement assertions from passing on an empty set. It never proved anything about
--    safety - a count of 61 says nothing about whether retiring a sentinel breaks a shelf. It
--    keeps that job (gt 0) and hands the real work to two NEW assertions that are rot-proof
--    because they assert PROPERTIES of the population rather than its size.

UPDATE golden.assertions SET
  expect_op = 'gt',
  expect    = '0',
  description = 'NON-VACUITY ONLY: at least one shelf is sentinel-backed before retirement, so the retirement assertions below cannot pass on an empty set. '
             || '⛔ DELIBERATELY NOT A LITERAL COUNT (S-257). It was pinned at 61 and read 62 on 2026-08-06 once a shelf re-resolved its pod in WEIMI. '
             || 'sentinel_backed is derived from product_mapping x v_wh_pickable x v_shelf_state, all of which move under production on their own, so any literal here rots. '
             || 'The claims that MATTER are seq 36 (structural) and seq 37 (readiness), which cannot rot, plus seq 21 which proves the retirement itself is safe. '
             || '⛔ S-251 is NOT the cause: v_shelf_availability_v3 never reads product_sourcing.'
WHERE fixture_id = 24 AND seq = 5;

-- seq 36 — STRUCTURAL, and it is a real defect detector, not bookkeeping. Sentinels exist to stop
-- venue-supplied shelves on co_managed machines from blocking. A sentinel propping up a
-- fully_managed or partner_managed machine would mean phantom stock standing in for warehouse
-- stock Boonz actually owes - the exact failure the sentinel retirement is meant to end.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (24, 36,
 'STRUCTURAL (S-257): every sentinel-backed shelf sits on a co_managed machine. A sentinel backing a fully_managed or partner_managed machine is phantom stock standing in for stock Boonz actually owes — a real defect, and one a literal population count could never have caught. Rot-proof: it scales with the fleet.',
 'SELECT count(*)::text FROM public.v_shelf_availability_v3 a JOIN public.machines m ON m.machine_id = a.machine_id WHERE a.sentinel_backed AND m.operating_model IS DISTINCT FROM ''co_managed''',
 'eq', '0', true, 'P1')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description=EXCLUDED.description, check_sql=EXCLUDED.check_sql, expect_op=EXCLUDED.expect_op, expect=EXCLUDED.expect, enabled=EXCLUDED.enabled, phase_required=EXCLUDED.phase_required;

-- seq 37 — READINESS, measured on the LIVE population at fixture start. seq 21 proves the
-- retirement is safe INSIDE the rolled-back probe; this proves the fleet is still in a state
-- where that retirement would be safe, which is the claim DR-2 actually needs on the night.
-- A newly-added shelf carrying ONLY sentinel stock would trip this and nothing else.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (24, 37,
 'READINESS (S-257): no sentinel-backed shelf would block on retirement, measured on the live population at fixture start (seq 21 proves the same property AFTER the simulated retirement, inside the probe). This is the DR-2 go/no-go property and it is quantity-independent — a shelf carrying ONLY sentinel stock trips this and nothing else in the fixture.',
 'SELECT (value->>''would_block'') FROM golden.scratch WHERE fixture_id = 24 AND key = ''before''',
 'eq', '0', true, 'P1')
ON CONFLICT (fixture_id, seq) DO UPDATE SET description=EXCLUDED.description, check_sql=EXCLUDED.check_sql, expect_op=EXCLUDED.expect_op, expect=EXCLUDED.expect, enabled=EXCLUDED.enabled, phase_required=EXCLUDED.phase_required;
