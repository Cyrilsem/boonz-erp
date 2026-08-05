-- ═══════════════════════════════════════════════════════════════════════════
-- PRD-110 · P2.6 · FIXTURE 33 CORRECTION (recorded, not silent)
-- Fixture 33 seq 37 originally asserted that consuming an override stamps
-- preflight_override_log.consumed_at. Cody blocked that design under Article 7:
-- the table carries pol_no_update / pol_no_delete, and a postgres-owned
-- SECURITY DEFINER would have bypassed RLS to UPDATE it - defeating the very
-- policy the article exists to enforce. Consumption is now recorded by an
-- INSERT on the consuming side (refill_commit_log.preflight_override_id).
-- The fixture is re-expressed against that, and the assertion gets STRONGER:
-- it now pins the audit CHAIN (which commit spent which grant), not a flag.
-- ═══════════════════════════════════════════════════════════════════════════

DO $mig$
DECLARE
  v_scn    text;
  v_anchor text := 'ORDER BY pol.overridden_at DESC LIMIT 1), ''{}''::jsonb);';
  v_add    text;
  v_hits   int;
BEGIN
  SELECT scenario_sql INTO v_scn FROM golden.fixtures WHERE fixture_id = 33;
  IF v_scn IS NULL THEN RAISE EXCEPTION 'fixture 33 not found'; END IF;

  -- leg-26 method: the anchor must match EXACTLY ONCE
  v_hits := (length(v_scn) - length(replace(v_scn, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'fixture 33 scenario anchor matched % times, expected exactly 1', v_hits;
  END IF;

  v_add := v_anchor || E'\n\n'
    || E'-- the consumption record itself: the commit row that SPENT the grant\n'
    || E'INSERT INTO golden.scratch (fixture_id, key, value)\n'
    || E'SELECT {{fixture_id}}, ''commit_link'',\n'
    || E'       COALESCE((SELECT to_jsonb(rcl) FROM public.refill_commit_log rcl\n'
    || E'                  WHERE rcl.plan_date = {{plan_date}}\n'
    || E'                    AND rcl.preflight_override_id IS NOT NULL\n'
    || E'                  ORDER BY rcl.committed_at DESC LIMIT 1), ''{}''::jsonb);';

  UPDATE golden.fixtures
     SET scenario_sql = replace(v_scn, v_anchor, v_add),
         notes = notes || ' | seq 37 CORRECTED (Cody, Article 7): consumption is read from refill_commit_log.preflight_override_id, never from a stamped consumed_at on the append-only audit log.'
   WHERE fixture_id = 33;
END
$mig$;

UPDATE golden.assertions SET
  description = 'OVERRIDE IS SINGLE USE: the commit that spent the grant NAMES it - consumption is an INSERT on the commit log, never an UPDATE of the append-only audit log (Article 7)',
  check_sql = 'SELECT ((SELECT value->>''preflight_override_id'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''commit_link'')
        IS NOT DISTINCT FROM
        (SELECT value->>''override_id'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''ov_row''))::text',
  expect_op = 'eq', expect = 'true'
WHERE fixture_id = 33 AND seq = 37;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(33, 44, 'AUDIT CHAIN: the override grant and the commit that spent it are both non-empty (non-vacuity guard on seq 37 - two NULLs must never read as a match)',
 'SELECT ((SELECT value->>''override_id'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''ov_row'') IS NOT NULL)::text',
 'eq', 'true', true, 'P2'),
(33, 45, 'AUDIT CHAIN: the commit row records the preflight verdict it was committed under',
 'SELECT value->>''preflight_verdict'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''commit_link''',
 'eq', 'FAIL', true, 'P2'),
(33, 46, 'AUDIT CHAIN: the commit row records how many violations it was let through with',
 'SELECT value->>''preflight_violation_count'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''commit_link''',
 'eq', '1', true, 'P2')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description = EXCLUDED.description, check_sql = EXCLUDED.check_sql,
      expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
      enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;
