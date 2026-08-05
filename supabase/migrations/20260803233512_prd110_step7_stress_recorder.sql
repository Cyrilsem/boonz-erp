-- PRD-110 STEP 7 — stress-suite recorder.
-- One durable home for all seven stress suites' verdicts + headline metrics.
-- Matches the golden-schema posture exactly: RLS ON, ZERO policies, NO grants
-- beyond postgres. The harness is reachable only by the management API / postgres,
-- which is what keeps it off the anon/authenticated surface (cf. D-42).

CREATE TABLE IF NOT EXISTS golden.stress_runs (
  -- D1: uuid PK.
  stress_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Which STEP 7 suite. Explicit CHECK, not a lookup table: the set is fixed by
  -- the goal command, and adding S8 SHOULD cost a forward migration.
  suite         text        NOT NULL CHECK (suite IN ('S1','S2','S3','S4','S5','S6','S7')),
  -- Wall-clock of the measured work, not of the INSERT.
  started_at    timestamptz NOT NULL,
  finished_at   timestamptz NOT NULL DEFAULT now(),
  duration_ms   integer     NOT NULL CHECK (duration_ms >= 0),
  -- D2: the verdict is never unknown. Rows are appended AFTER the suite completes.
  passed        boolean     NOT NULL,
  n_pass        integer     NOT NULL DEFAULT 0 CHECK (n_pass >= 0),
  n_fail        integer     NOT NULL DEFAULT 0 CHECK (n_fail >= 0),
  -- Headline numbers the DONE report cites (runtime_ms, dup_lines, lost_edits...).
  -- Small and queryable, deliberately separate from the verbose breakdown.
  metric        jsonb       NOT NULL DEFAULT '{}'::jsonb,
  -- Per-check breakdown, mirrors golden.runs.detail. Verbose, not queried by the report.
  detail        jsonb,
  -- How the suite was executed. 'external' = parallel connections driven from bash
  -- (S3/S5), which cannot be reproduced from inside a single SQL transaction.
  driver        text        NOT NULL DEFAULT 'sql' CHECK (driver IN ('sql','external')),
  note          text
);

COMMENT ON TABLE golden.stress_runs IS
  'PRD-110 STEP 7 stress-suite results. Append-only by convention; a re-run appends '
  'a new row rather than updating (S7 requires three comparable rows to exist).';

-- D5: the only read pattern is "latest row per suite" (DONE report + S7 comparator).
CREATE INDEX IF NOT EXISTS idx_stress_runs_suite_started
  ON golden.stress_runs (suite, started_at DESC);

ALTER TABLE golden.stress_runs ENABLE ROW LEVEL SECURITY;
-- Intentionally NO policies and NO grants: identical to golden.runs/fixtures/assertions.
-- RLS-on + zero-policies + zero-grants = deny-all for anon/authenticated.

-- Append function. SECURITY INVOKER on purpose: this must NOT become a way to reach
-- the harness with someone else's privileges. Callers are postgres via the mgmt API.
CREATE OR REPLACE FUNCTION golden.record_stress(
  p_suite      text,
  p_passed     boolean,
  p_started_at timestamptz,
  p_metric     jsonb   DEFAULT '{}'::jsonb,
  p_detail     jsonb   DEFAULT NULL,
  p_note       text    DEFAULT NULL,
  p_driver     text    DEFAULT 'sql',
  p_n_pass     integer DEFAULT 0,
  p_n_fail     integer DEFAULT 0
) RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = golden, public, pg_temp
AS $fn$
DECLARE
  v_id  uuid;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_started_at IS NULL THEN
    RAISE EXCEPTION 'golden.record_stress: p_started_at is required - a stress result '
                    'without a measured window is not evidence';
  END IF;
  IF p_started_at > v_now THEN
    RAISE EXCEPTION 'golden.record_stress: p_started_at (%) is in the future', p_started_at;
  END IF;

  INSERT INTO golden.stress_runs (
    suite, started_at, finished_at, duration_ms, passed,
    n_pass, n_fail, metric, detail, driver, note)
  VALUES (
    p_suite, p_started_at, v_now,
    (EXTRACT(EPOCH FROM (v_now - p_started_at)) * 1000)::int,
    p_passed,
    COALESCE(p_n_pass, 0), COALESCE(p_n_fail, 0),
    COALESCE(p_metric, '{}'::jsonb), p_detail, p_driver, p_note)
  RETURNING stress_run_id INTO v_id;

  RETURN v_id;
END
$fn$;

COMMENT ON FUNCTION golden.record_stress IS
  'Appends one PRD-110 STEP 7 stress result. Duration is measured server-side from '
  'p_started_at to clock_timestamp(); the caller cannot fake a runtime.';

-- Cody-required revision (S-140): a new function is granted EXECUTE to PUBLIC by
-- default. Reachability is already blocked by the schema-USAGE gate (golden is
-- {postgres=UC/postgres}, proven by golden._acl_canary_public_64/66), but a single
-- gate is not a posture. Revoke explicitly and match the tightest sibling ACL.
REVOKE ALL ON FUNCTION golden.record_stress(
  text, boolean, timestamptz, jsonb, jsonb, text, text, integer, integer) FROM PUBLIC;
