-- PRD-110 P3.3 — fixture 43 seq 42 was a DUPLICATE OF SEQ 41, not an idempotency test.
--
-- Both read the same two scratch keys and compared the same two numbers. Caught while the
-- fixture was still RED, which is the only cheap time to catch it: two assertions that agree
-- by construction look like two pieces of evidence and are one.
--
-- Re-expressed against the TABLE ITSELF: after two identical heartbeats, no (source, target)
-- pair may appear twice for this plan_date. That is the property the rp_v3_unique_heartbeat
-- constraint exists to guarantee, tested through the writer rather than by reading pg_constraint.

UPDATE golden.assertions SET
  description = 'S4 STRESS PRECONDITION, TESTED THROUGH THE WRITER: after two identical heartbeats no (source_shelf, target_shelf) pair appears twice for this plan_date. Seq 17 proves the UNIQUE constraint EXISTS; this proves the writer actually routes through it instead of erroring or duplicating',
  check_sql = $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM (
       SELECT source_shelf_id, target_shelf_id
       FROM public.rotation_proposals_v3 WHERE plan_date = DATE '2030-02-13'
       GROUP BY 1,2 HAVING count(*) > 1) z) END$a$,
  expect_op = 'eq',
  expect = '0'
WHERE fixture_id = 43 AND seq = 42;

-- And a genuinely independent idempotency witness: the second call must RETURN the same
-- number of proposals it returned the first time. A writer that swallowed its own conflicts
-- and returned an empty set would pass seq 42 and fail this.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(43, 53, 'IDEMPOTENCY, RETURN SIDE: the second identical heartbeat returns the SAME proposal count as the first -- a writer that silently returned nothing on re-run would pass the row-count test and fail this one',
 $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out_again')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT ((SELECT value::int FROM golden.scratch WHERE fixture_id=43 AND key='out_again')
             = (SELECT jsonb_array_length(value) FROM golden.scratch WHERE fixture_id=43 AND key='out'))::text) END$a$,
 'eq', 'true', true, 'P3');
