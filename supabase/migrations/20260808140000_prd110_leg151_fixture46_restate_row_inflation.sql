-- PRD-110 leg 151 - fixture 46 seq 26 RESTATED (S-272), plus two sensors.
--
-- THE RED: seq 26 read `rows_out = lines_in` and went false at rows_out 2 / lines_in 1.
-- THE CAUSE IS NOT A DEFECT. stitch_v3's ladder now resolves 11 of the fixture's 12 planted
-- units (live WH stock for pod abc20f95 decayed), so stitch emitted ONE placed row plus ONE
-- Blocked row - LAW 5 working exactly as specified: every blocked unit lands in blocked_demand
-- rather than vanishing. `sku_legs` is still 0, so the thing seq 26's DESCRIPTION claims to
-- guard - P3.1d SKU-leg row inflation - never happened.
--
-- ⛔ THE ASSERTION WAS MEASURING TOTAL ROWS AND CALLING IT INFLATION. A LAW-5 blocked row is
-- not inflation. Any partial ladder resolution reds it, forever, for a correct engine.
--
-- THE RESTATEMENT (S-272 - move expect_op/expect WITH the shape of check_sql):
--   seq 26  eq 'true'  over a stitch-contract boolean
--        -> eq '0'     over a COUNT re-derived from refill_plan_output_shadow
-- It now states the property it always meant: no source line yields more than one NON-BLOCKED
-- output row. Re-derived from the shadow table (an object independent of stitch_v3's own return
-- contract, per S-267) using the same source-line grouping seq 27 already uses.
--
-- ⛔ A count-eq-0 assertion passes vacuously on an empty set, so it does not travel alone:
--   seq 28 (NEW) pins `sku_legs = 0` - the P3.1d split mechanism reading zero directly, which is
--          the premise the inflation claim rests on. Non-vacuous by construction: stitch_v3
--          always reports the field.
--   seq 29 (NEW) is the premise sensor (S-274): the fixture plants EXACTLY ONE source line and
--          stitch must return at least one row for it. ⭐ Stated over lines_in/rows_out rather
--          than over placed rows, so it stays true when the ladder resolves nothing and the only
--          output is a Blocked row - it senses the fixture's own plant, not live WH stock.
--
-- Nothing is deleted and nothing is loosened: the old claim's true content survives in seq 26 and
-- is now strictly harder to satisfy vacuously than it was.

DO $guard$
DECLARE v_n int; v_op text; v_exp text; v_maxseq int;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 46;
  IF v_n <> 27 THEN
    RAISE EXCEPTION 'fixture 46 has % assertions, expected 27 - another leg moved it', v_n;
  END IF;

  SELECT expect_op, expect INTO v_op, v_exp
    FROM golden.assertions WHERE fixture_id = 46 AND seq = 26;
  IF v_op IS DISTINCT FROM 'eq' OR v_exp IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'fixture 46 seq 26 is already (%, %), expected (eq, true) - refusing to restate twice', v_op, v_exp;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM golden.assertions
                  WHERE fixture_id = 46 AND seq = 26
                    AND check_sql LIKE '%rows_out%' AND check_sql LIKE '%lines_in%') THEN
    RAISE EXCEPTION 'fixture 46 seq 26 no longer reads rows_out/lines_in - the pre-image is not what this migration was written against';
  END IF;

  SELECT max(seq) INTO v_maxseq FROM golden.assertions WHERE fixture_id = 46;
  IF v_maxseq <> 27 THEN
    RAISE EXCEPTION 'fixture 46 max seq is %, expected 27 - seq 28/29 are not free', v_maxseq;
  END IF;
END
$guard$;

UPDATE golden.assertions
   SET description = 'Regression (P3.1d): NO SKU-LEG ROW INFLATION. No source line yields more than one non-Blocked output row. Re-derived from refill_plan_output_shadow, not from stitch_v3''s own return contract (S-267), using seq 27''s source-line grouping. RESTATED at leg 151 (S-272): the pre-image read rows_out = lines_in, which counted the LAW-5 Blocked row as inflation and therefore reds forever once the ladder resolves a source line only partially. Paired with seq 28 (the mechanism reads zero) and seq 29 (the plant reached stitch), because a count-eq-0 passes vacuously alone.',
       check_sql = 'SELECT count(*)::text FROM (
     SELECT o.machine_id, o.shelf_id, o.anchor_pod_product_id, count(*) AS n
       FROM public.refill_plan_output_shadow o
      WHERE o.run_id = ((SELECT value FROM golden.scratch
                          WHERE fixture_id = {{fixture_id}} AND key = ''stitch'')->>''run_id'')::uuid
        AND o.action <> ''Blocked''
      GROUP BY 1,2,3) z
   WHERE z.n > 1',
       expect_op = 'eq',
       expect    = '0'
 WHERE fixture_id = 46 AND seq = 26;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (46, 28,
  'THE MECHANISM READS ZERO: on the 2030 horizon LAW 7 expires every real batch, so the FEFO seam creates no SKU legs at all and the P3.1d split that seq 26 guards is provably idle rather than merely unobserved. Non-vacuous by construction - stitch_v3 always reports sku_legs.',
  'SELECT (value->>''sku_legs'') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''stitch''',
  'eq', '0', true, 'P3'),
 (46, 29,
  'PREMISE SENSOR (S-274) for seq 26: the fixture plants EXACTLY ONE source line into pod_refills_shadow and stitch_v3 must return at least one row for it, so seq 26''s count-eq-0 is never scored over an empty run. Stated over the fixture''s OWN plant (lines_in) and total rows (rows_out), never over placed rows - a run whose ladder resolves nothing still emits a Blocked row, and that is a pass, not a red.',
  'SELECT (((value->>''lines_in'')::int = 1) AND ((value->>''rows_out'')::int >= 1))::text
    FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''stitch''',
  'eq', 'true', true, 'P3');

DO $post$
DECLARE v_n int; v_op text; v_exp text;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 46;
  IF v_n <> 29 THEN RAISE EXCEPTION 'post: fixture 46 has % assertions, expected 29', v_n; END IF;

  SELECT expect_op, expect INTO v_op, v_exp FROM golden.assertions WHERE fixture_id = 46 AND seq = 26;
  IF v_op <> 'eq' OR v_exp <> '0' THEN
    RAISE EXCEPTION 'post: seq 26 did not move to (eq, 0); it is (%, %)', v_op, v_exp;
  END IF;

  -- S-272: the SHAPE moved too, not just the numbers.
  IF EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id = 46 AND seq = 26
              AND (check_sql LIKE '%rows_out%' OR check_sql LIKE '%lines_in%')) THEN
    RAISE EXCEPTION 'post: seq 26 still reads the stitch return contract - the restatement did not change the shape';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id = 46 AND seq = 26
                  AND check_sql LIKE '%refill_plan_output_shadow%') THEN
    RAISE EXCEPTION 'post: seq 26 does not re-derive from refill_plan_output_shadow';
  END IF;

  IF (SELECT count(*) FROM golden.assertions WHERE fixture_id = 46 AND seq IN (28,29) AND enabled) <> 2 THEN
    RAISE EXCEPTION 'post: seq 28/29 are not both present and enabled';
  END IF;
END
$post$;

SELECT 46 AS fixture_id,
       (SELECT count(*) FROM golden.assertions WHERE fixture_id = 46) AS n_assertions,
       (SELECT expect_op||'/'||expect FROM golden.assertions WHERE fixture_id = 46 AND seq = 26) AS seq26;
