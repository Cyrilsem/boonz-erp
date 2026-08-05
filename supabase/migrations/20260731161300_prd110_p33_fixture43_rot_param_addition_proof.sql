-- PRD-110 P3.3 / D-26 — fixture 43 seq 3 and seq 6 re-expressed ADDITION-PROOF.
--
-- ⛔ S-79: both assertions counted the rot_* column family and compared to the literal 5.
--    Adding rot_keep_floor -- a CS decision, not a defect -- turned both RED (actual 6).
--    An ABSOLUTE COUNT over a family that is designed to grow is a tripwire on your own
--    roadmap: it fires on correct work and says nothing about correctness.
--
-- seq 3 becomes a REQUIRED-SET check: the six columns the fixture depends on must each exist.
--   A seventh rot_* param will not red it; a DROPPED one still will.
-- seq 6 becomes a 0-VIOLATIONS check: no rot_* column may lack the POLICY comment.
--   This is strictly STRONGER than the old form -- an uncommented future param now reds it,
--   where the old count would have gone GREEN as soon as any five carried comments.

UPDATE golden.assertions
SET description = 'Every rot_* param the fixture depends on exists as a column on refill_policy_params (REQUIRED-SET form, not a count -- S-79: a count over a growing family reds on correct additions)',
    check_sql = $q$SELECT count(*)::text FROM information_schema.columns
   WHERE table_name='refill_policy_params'
     AND column_name = ANY (ARRAY['rot_slow_velocity_per_day','rot_min_source_qty',
                                  'rot_min_speedup','rot_min_fit_score',
                                  'rot_max_proposals','rot_keep_floor'])$q$,
    expect_op = 'eq',
    expect    = '6'
WHERE fixture_id = 43 AND seq = 3;

UPDATE golden.assertions
SET description = 'EVERY rot_* param declares itself POLICY, not measured (S-69 habit) -- 0 columns missing the declaration. 0-violations form so a future uncommented param reds it (S-79)',
    check_sql = $q$SELECT count(*)::text FROM information_schema.columns c
   JOIN pg_class cl ON cl.relname='refill_policy_params'
   WHERE c.table_name='refill_policy_params' AND c.column_name LIKE 'rot\_%'
     AND COALESCE(col_description(cl.oid, c.ordinal_position), '') NOT LIKE '%POLICY, not measured%'$q$,
    expect_op = 'eq',
    expect    = '0'
WHERE fixture_id = 43 AND seq = 6;

DO $do$
BEGIN
  IF (SELECT count(*) FROM golden.assertions
        WHERE fixture_id=43 AND seq IN (3,6) AND check_sql LIKE '%rot\_keep\_floor%' ESCAPE '\')
     < 1 THEN
    RAISE EXCEPTION 'S-79: seq 3 did not pick up rot_keep_floor';
  END IF;
  IF (SELECT expect FROM golden.assertions WHERE fixture_id=43 AND seq=6) <> '0' THEN
    RAISE EXCEPTION 'S-79: seq 6 was not inverted to the 0-violations form';
  END IF;
END
$do$;
