-- PRD-114 - the gate tick becomes SECURITY INVOKER, and its deployed body is
-- reconciled with its file.
--
-- TWO things land here. The second is cosmetic; the first is a real harness bug
-- that produced a real red, and it is the reason this file exists at all.
--
-- ============================================================================
-- 1. SECURITY DEFINER was the wrong context to run the suite from
-- ============================================================================
--
-- Fixture 71 (`D-27(a): one canonical definition of an m2m donor surplus`) came
-- back RED in the `PRD-114 gate` sweep, 31 pass / 1 fail, with no failing
-- assertion. The whole scenario had refused:
--
--   scenario_error: cannot set parameter "role" within security-definer function
--
-- That is PostgreSQL's own rule, not a Boonz one: `SET ROLE` is forbidden
-- anywhere inside a SECURITY DEFINER call stack, because it would let the
-- definer's borrowed privileges be laundered into a third role. Fixture 71's
-- `scenario_sql` switches role to plant its donor surplus, so wrapping the
-- runner in a DEFINER function made that fixture unrunnable.
--
-- The bug is entirely mine. `golden.run_all` and `golden.run_fixture` are BOTH
-- `prosecdef = false` - the suite has always executed as its INVOKER, and pg_cron
-- job 52 runs as `postgres`. Marking the tick DEFINER did not add a capability;
-- it REMOVED one, and it removed exactly the one a privilege fixture needs. The
-- tick is now INVOKER, which restores byte-for-byte the context `run_all` gives a
-- fixture and the context every historical green baseline was measured in.
--
-- Blast radius, measured rather than assumed: a regex over `scenario_sql` and
-- over every enabled fixture's assertion `check_sql` for
-- `set (local )?role | set_config('role')` returns fixture 71 and NOTHING else.
-- Fixture 114 impersonates its driver and its operator_admin through
-- `request.jwt.claims`, not through `SET ROLE`, so it was never in this class.
-- One fixture was affected and it is the one that went red - there is no silent
-- second victim.
--
-- Worth naming what did NOT happen. A `SET ROLE` refusal is a hard ERROR, so
-- `run_fixture` recorded it as a scenario_error and reported the run false. Had
-- the DEFINER restriction instead caused a role switch to silently no-op, every
-- privilege assertion in the suite would have run as `postgres` and PASSED - a
-- false green in exactly the class of test that exists to catch privilege bugs.
-- The gate has now produced three harness bugs across three PRDs (PRD-003's
-- shared-transaction GUC leak, this PRD's P0 phase gate, and this), and all three
-- were caught because some guard distrusted the harness rather than the code.
--
-- The affected run row is NOT deleted. It is retagged
-- `PRD-114 gate VOID (definer blocked SET ROLE)` so the mistake stays in
-- `golden.runs` where the next reader finds it, and so the sweep re-claims
-- fixture 71 and runs it for real.
--
-- ============================================================================
-- 2. The body is reconciled with the file
-- ============================================================================
--
-- The gate was applied in TWO steps against the database - the first cut, then
-- the phase-gate fix (`GREATEST(P0, config.current_phase, fixture.phase_required)`)
-- after the first sweep tick came back 0 pass / 0 fail. The repo carries ONE
-- consolidated file for those two applies,
-- `20260812232000_prd114_golden_gate_one_fixture_per_tick.sql`, written with the
-- full five-line explanation of the phase bug, whereas the body actually deployed
-- by the fix carried a one-line version of the same comment. So `md5(prosrc)` of
-- the live function did NOT equal the body in that file:
--
--   live 1539 chars / b2b9264295ff289271d892a101a255bf
--   file 1843 chars / e681ed4bb7792f9a7844619fbddcfcac
--
-- The LOGIC was byte-identical - the divergence is entirely inside a comment, and
-- every fixture in the sweep ran on the correct phase expression. But "the file
-- matches the database" is a property that is either checkable or it is not, and a
-- comment-sized exception to it is how the next reader learns to skip the check.
-- The applied file is NOT edited (Article 12 / the PRD-003 rule: editing an
-- applied migration is how a file stops describing what actually ran). This is a
-- forward-only replace that moves the DATABASE to the file's text instead.
--
-- One correction to the header of `20260812232000`, recorded here because that
-- file must not be edited: it says the job was scheduled at `'* * * * *'`. The job
-- as actually scheduled (pg_cron job 52, `prd114_golden_gate`) used `'20 seconds'`,
-- so 73 fixtures sweep in well under an hour instead of well over one. The
-- advisory-lock overlap guard is what makes a sub-minute interval safe: the six
-- fixtures that run longer than the interval simply hold the lock and the
-- intervening ticks return immediately.
--
-- No signature change. No logic change beyond the security context.

CREATE OR REPLACE FUNCTION public.prd114_golden_gate_tick(p_tag text DEFAULT 'PRD-114 gate')
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'golden', 'pg_temp'
AS $function$
DECLARE
  v_fx    int;
  v_cfg   text := COALESCE((SELECT current_phase FROM golden.config WHERE id = 1), 'P0');
  v_req   text;
  v_gate  text;
BEGIN
  -- Overlap guard: a fixture that runs longer than the tick interval must not be
  -- joined by the next tick. Session-scoped, so a crashed tick releases it.
  IF NOT pg_try_advisory_lock(114114) THEN
    RETURN;
  END IF;

  -- cron 44 (prd110_p14_composition_estimator_hourly) rewrites shelf_composition
  -- at :40 every hour. Fixtures 2, 19, 20, 21, 22 and 27 compare a snapshot taken
  -- at fixture start against live values at fixture end, so a straddle is a red
  -- that means nothing. Stand down across the window.
  IF EXTRACT(minute FROM (now() AT TIME ZONE 'UTC')) BETWEEN 39 AND 42 THEN
    PERFORM pg_advisory_unlock(114114);
    RETURN;
  END IF;

  -- Next enabled fixture this sweep has not claimed. run_fixture INSERTs its run
  -- row before executing, so a fixture is claimed the moment it starts.
  SELECT f.fixture_id, f.phase_required INTO v_fx, v_req
  FROM golden.fixtures f
  WHERE f.enabled
    AND NOT EXISTS (
      SELECT 1 FROM golden.runs r
      WHERE r.fixture_id = f.fixture_id AND r.note = p_tag)
  ORDER BY f.fixture_id
  LIMIT 1;

  IF v_fx IS NULL THEN
    PERFORM pg_advisory_unlock(114114);
    RETURN;
  END IF;

  -- Byte-for-byte the gate golden.run_all computes. Do not simplify to 'P0':
  -- config.current_phase is 'P4' live and fixture 1 is a P3 fixture whose 59
  -- assertions are all at that phase, so a 'P0' run SKIPS every one of them and
  -- run_fixture's Guard 3 (a run that evaluated NOTHING is not a pass) reports
  -- 0/0/false. The first cut of this function did exactly that.
  v_gate := GREATEST('P0', v_cfg, COALESCE(v_req, 'P0'));

  PERFORM golden.run_fixture(v_fx, p_tag, v_gate);
  PERFORM pg_advisory_unlock(114114);
END
$function$;

COMMENT ON FUNCTION public.prd114_golden_gate_tick(text) IS
  'PRD-114 acceptance 5. Runs ONE golden fixture per invocation, so pg_cron gives each fixture its own transaction and no GUC leaks across the fixture boundary (PRD-003 G-3). MUST stay SECURITY INVOKER: golden.run_all and golden.run_fixture are both invoker, and PostgreSQL forbids SET ROLE anywhere inside a SECURITY DEFINER call stack, so a DEFINER tick makes fixture 71 (and any future privilege fixture that switches role) unrunnable. Phase gate is GREATEST(P0, golden.config.current_phase, fixture.phase_required) - the same expression run_all uses; hard-coding P0 skips every assertion in a P3/P4 fixture and produces a vacuous run. Carries the advisory-lock overlap guard and the cron-44 straddle guard. UNSCHEDULE the job when the sweep completes - with every fixture claimed it returns immediately forever.';

REVOKE ALL ON FUNCTION public.prd114_golden_gate_tick(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prd114_golden_gate_tick(text) FROM anon;
REVOKE ALL ON FUNCTION public.prd114_golden_gate_tick(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.prd114_golden_gate_tick(text) TO service_role;

-- Void the DEFINER-blocked fixture-71 run so the sweep re-claims it. Retag, never
-- delete: golden.runs is the record of what the harness actually did, mistakes
-- included.
UPDATE golden.runs
SET note = 'PRD-114 gate VOID (definer blocked SET ROLE)'
WHERE note = 'PRD-114 gate'
  AND fixture_id = 71
  AND passed = false;
