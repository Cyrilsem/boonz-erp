-- PRD-110 leg 111 · UNIT B · S-200 fixture 40 seq 8 — WITH A CORRECTION TO S-200's OWN CLASSIFY
--
-- S-200 filed 40/8 as class (A) "ambient non-vacuity gone vacuous", remedy = fixture 31's
-- rollback-probe idiom. Measured live, that classification is WRONG and the probe would have been
-- the wrong tool:
--
--   anchor A (Fade Fit)      real_primary 0 · real_other  0 · sentinel 7992
--   anchor B (Vitamin Well)  real_primary 0 · real_other 88 · sentinel    0
--
-- B's real stock did NOT evaporate. It MOVED OUT of the machine's primary warehouse (WH_MCC)
-- into another warehouse. seq 8 was pinned to ONE warehouse, so an ordinary inter-warehouse
-- transfer turned it red while the fact it exists to prove stayed true the whole time.
--
-- What seq 8 actually guards is the A-vs-B CONTRAST that the whole fixture is built on:
--   A is blocked because NO real stock exists anywhere - only phantom sentinel units (the trap).
--   B is blocked while real stock DOES exist in the network - so B's shortfall is not an
--   absence artifact, and rungs 2..6 are exercised on a genuinely supplied pod.
-- Expressed network-wide, that contrast is immune to stock moving between warehouses, which is
-- routine operational traffic and says NOTHING about the ladder.
--
-- ⛔ The description is corrected, not just the SQL. The original said "blocked by contention";
--    with 88 units sitting at an alternate WH the honest word is no longer contention, and a
--    fixture that keeps a stale narrative is how S-200 happened in the first place.
-- ⛔ NOT relaxed to gte 0. The threshold stays >= 1; only the SCOPE of "where the stock may be"
--    widens from one warehouse to the network. seq 43 below proves A still fails that same test,
--    so the contrast is preserved rather than dissolved.

DO $a8$
DECLARE v_n integer;
BEGIN
  UPDATE golden.assertions
     SET check_sql   = 'SELECT (((value->>''B_real_primary'')::numeric + (value->>''B_real_other'')::numeric))::text FROM golden.scratch WHERE fixture_id = 40 AND key = ''supply''',
         description = 'NON-VACUITY (B), S-200 restated network-wide: Vitamin Well HAS real (non-sentinel) stock somewhere in the warehouse network, so anchor B is blocked while genuinely supplied - NOT by absence. Originally pinned to the machine''s PRIMARY warehouse and went red on 2026-08-01 when the stock simply moved warehouse (real_primary 0, real_other 88) - an ordinary transfer that says nothing about the ladder. Paired with seq 43, which proves anchor A fails this same test at 0.'
   WHERE fixture_id = 40 AND seq = 8;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'leg111 UNIT B: assertion (40,8) hit % rows, expected 1', v_n; END IF;
END $a8$;

-- seq 57 NEW: the OTHER half of the contrast, which was only ever half-covered.
-- Seq 57, not 43: fixture 40 occupies 1..56 contiguously. ⛔ BOTH failed seq picks this leg came
-- from reading a FILTERED assertion list and inferring the gap. Always take max(seq)+1 from an
-- UNFILTERED query - the bare INSERT is what caught it, twice, exactly as intended.
-- seq 7 pins A_real_primary = 0, but that alone no longer distinguishes A from B (both are 0
-- in the primary WH now). Without this, seq 8 could go vacuous in the opposite direction - if A
-- ever acquired real stock the sentinel trap would silently stop being a trap and nothing would say so.
INSERT INTO golden.assertions (fixture_id, seq, check_sql, expect_op, expect, description)
VALUES (40, 57,
  'SELECT (((value->>''A_real_primary'')::numeric + (value->>''A_real_other'')::numeric))::text FROM golden.scratch WHERE fixture_id = 40 AND key = ''supply''',
  'eq', '0',
  'SENTINEL TRAP, non-vacuity completed (S-200, leg 111): Fade Fit has ZERO real non-sentinel stock ANYWHERE in the network - not merely zero in the primary WH (seq 7). This is what makes anchor A a genuine trap: the ONLY thing that could rescue it is the 7992 phantom units, so the ladder refusing it is a real refusal. Pairs with seq 8 (B >= 1 network-wide) to state the A-vs-B contrast the whole fixture rests on.');
