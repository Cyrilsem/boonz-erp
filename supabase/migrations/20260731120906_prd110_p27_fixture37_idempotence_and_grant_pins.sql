-- PRD-110 leg 54 · L54-U1 · fixture 37 hardening
--
-- TWO defects, both surfaced by the committed run_all('P2') that leg 53 left
-- running and could not read before it closed. Leg 53 saw fixture 37 green on its
-- VIRGIN run and recorded 27/27; the atomic run_all disagreed at 26/27.
--
-- (1) NON-IDEMPOTENCE (seq 13). shadow_runner_log_v3 is append-only and DURABLE
--     by design. Every fixture-37 run therefore appends one more row per
--     (note, step), so seq 13's ABSOLUTE count drifts 1 -> 2 -> 3. Proven, not
--     assumed: all 9 (note,step,status) groups sat at exactly n=2 after exactly
--     two runs. This would also have failed STRESS S7 ("golden.run_all() x3
--     consecutive - identical results").
--
--     ⛔ The obvious fix - have the fixture DELETE its own rows first - was
--     REFUSED on Cody review. The table carries tg_srl_v3_no_update plus an audit
--     trigger and is an Article 7 append-only log; a fixture that deletes from it
--     would also directly contradict its OWN seq 19, which exists to prove "the
--     absence probe was non-destructive and the log survived intact".
--
--     ✅ Instead the assertion is re-expressed as a DELTA measured across the
--     gate0 call. This mutates nothing, is idempotent by construction, and is
--     STRICTLY STRONGER than the original: it proves THIS run wrote exactly one
--     row, where an absolute count could be satisfied by someone else's row.
--     It is NOT weakened to gte 1 - that would stop catching a double-write,
--     which is the regression the assertion exists for.
--
-- (2) S-57 IS WIDER THAN RECORDED. Leg 53 recorded that shadow_runner_log_v3
--     "deliberately follows the pod_refills_shadow standard, not this one". Live
--     grants say otherwise: it carries the SAME loose INSERT/UPDATE/DELETE/
--     TRUNCATE for `authenticated` as engine_forecast_error_v3. Cause: Supabase's
--     default privileges already GRANT ALL on a new public table, and a
--     `GRANT SELECT` is ADDITIVE - only an explicit REVOKE narrows it. Seq 26/27
--     missed it because they check `anon` only, repeating fixture 36 seq 31's
--     exact blind spot. Seq 28-30 close it for BOTH tables and are deliberately
--     RED until the companion migration 20260731121820 lands (LAW 1).

-- ---------------------------------------------------------------------------
-- (1) Scenario: bracket the gate0 call with a before/after count. No new
--     PL/pgSQL declarations are needed - the counts land in golden.scratch,
--     which the scenario already clears for this fixture at start.
-- ---------------------------------------------------------------------------
UPDATE golden.fixtures
SET scenario_sql = replace(
  scenario_sql,
$anchor$  -- If this propagates instead of returning, the fixture fails on seq 11 by absence.
  EXECUTE format('SELECT public.run_nightly_shadow_v3(%L::date, 7, 3, %L)',
                 DATE '2030-02-08', 'golden_fixture_37_gate0') INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (37, 'runner_gate0', v);$anchor$,
$patch$  -- If this propagates instead of returning, the fixture fails on seq 11 by absence.
  -- leg 54: measure the log DELTA around this call, never the absolute count.
  -- The log is append-only and durable, so an absolute count drifts across
  -- reruns; the delta isolates THIS run and cannot be satisfied by another
  -- writer's row.
  INSERT INTO golden.scratch (fixture_id, key, value)
  SELECT 37, 'gate0_before', to_jsonb(count(*)) FROM public.shadow_runner_log_v3
   WHERE note = 'golden_fixture_37_gate0' AND step = 'engine' AND status = 'blocked_gate0';

  EXECUTE format('SELECT public.run_nightly_shadow_v3(%L::date, 7, 3, %L)',
                 DATE '2030-02-08', 'golden_fixture_37_gate0') INTO v;

  INSERT INTO golden.scratch (fixture_id, key, value)
  SELECT 37, 'gate0_after', to_jsonb(count(*)) FROM public.shadow_runner_log_v3
   WHERE note = 'golden_fixture_37_gate0' AND step = 'engine' AND status = 'blocked_gate0';

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (37, 'runner_gate0', v);$patch$)
WHERE fixture_id = 37;

-- A replace() whose anchor does not match is a SILENT no-op. Refuse to be silent.
DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM golden.fixtures
    WHERE fixture_id = 37 AND scenario_sql LIKE '%gate0_before%'
  ) THEN
    RAISE EXCEPTION 'fixture 37 delta patch did NOT apply - the replace anchor did not match';
  END IF;
  -- And it must have patched the gate0 block only, not the happy/rerun blocks.
  IF (SELECT (length(scenario_sql) - length(replace(scenario_sql, 'gate0_before', '')))
             / length('gate0_before') FROM golden.fixtures WHERE fixture_id = 37) <> 1 THEN
    RAISE EXCEPTION 'fixture 37 delta patch applied more than once';
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- (1b) seq 13 re-expressed as the delta.
-- ---------------------------------------------------------------------------
UPDATE golden.assertions
SET description = 'FAILURE VISIBILITY: the blocked night wrote exactly ONE new durable log row (DELTA across the call - the log is append-only, so an absolute count drifts on rerun)',
    check_sql = 'SELECT (((SELECT (value#>>''{}'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''gate0_after'')'
              || ' - (SELECT (value#>>''{}'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''gate0_before''))::text)',
    expect_op = 'eq',
    expect = '1'
WHERE fixture_id = 37 AND seq = 13;

DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM golden.assertions
                  WHERE fixture_id = 37 AND seq = 13 AND check_sql LIKE '%gate0_after%') THEN
    RAISE EXCEPTION 'fixture 37 seq 13 was not re-expressed';
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- (2) Grant pins. Phrased as "count of non-SELECT privileges" so the assertion
--     needs no comma literal at the third quoting level.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(37, 28, 'S-57: authenticated holds NO write privilege on the run log (a GRANT SELECT is additive - only a REVOKE narrows Supabase default GRANT ALL)',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM information_schema.role_table_grants WHERE grantee=''''authenticated'''' AND table_schema=''''public'''' AND table_name=''''shadow_runner_log_v3'''' AND privilege_type <> ''''SELECT'''''')',
 'eq', '0', true, 'P2'),

(37, 29, 'S-57: authenticated holds NO write privilege on engine_forecast_error_v3 either (the table that raised S-57)',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM information_schema.role_table_grants WHERE grantee=''''authenticated'''' AND table_schema=''''public'''' AND table_name=''''engine_forecast_error_v3'''' AND privilege_type <> ''''SELECT'''''')',
 'eq', '0', true, 'P2'),

(37, 30, 'NON-VACUITY: the REVOKE did not go too far - authenticated retains SELECT on BOTH objects, so the readers still read',
 'SELECT golden.probe_scalar(''SELECT count(*)::text FROM information_schema.role_table_grants WHERE grantee=''''authenticated'''' AND table_schema=''''public'''' AND privilege_type = ''''SELECT'''' AND table_name IN (''''shadow_runner_log_v3'''',''''engine_forecast_error_v3'''')'')',
 'eq', '2', true, 'P2');
