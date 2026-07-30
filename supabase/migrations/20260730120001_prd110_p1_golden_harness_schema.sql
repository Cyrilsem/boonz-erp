-- PRD-110 STEP 1 — golden fixture harness (proof harness; LAW 1 "FIXTURE FIRST")
-- Applied via Supabase MCP as migration `prd110_p1_golden_harness_schema` on 2026-07-30.
-- Cody class (c)/(f): new non-public schema holding TEST FIXTURES, not business data.
-- No protected entity touched. Runner is SECURITY INVOKER (it executes fixture-authored
-- dynamic SQL; DEFINER would be a privilege-escalation hole).

CREATE SCHEMA IF NOT EXISTS golden;

COMMENT ON SCHEMA golden IS
  'PRD-110 golden fixture harness. Frozen input snapshots + assertions + runner. '
  'Fixtures execute on synthetic plan_dates in year 2030 so they never collide with live '
  '(goal command LAW 12). Not business data: no Article 2 protected-entity scope.';

CREATE TABLE IF NOT EXISTS golden.fixtures (
  fixture_id       int  PRIMARY KEY,
  name             text NOT NULL UNIQUE,
  source_incident  text,
  phase_required   text NOT NULL CHECK (phase_required IN ('P0','P1','P2','P3','P4','P5')),
  plan_date        date NOT NULL UNIQUE
                     CHECK (plan_date >= DATE '2030-01-01' AND plan_date < DATE '2031-01-01'),
  scenario_sql     text,
  notes            text,
  enabled          boolean NOT NULL DEFAULT true,
  baseline_status  text CHECK (baseline_status IN ('failing_expected','passing','unknown')),
  created_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN golden.fixtures.plan_date IS
  'Synthetic 2030 plan_date owned exclusively by this fixture. Convention: 2030-01-01 + fixture_id days.';
COMMENT ON COLUMN golden.fixtures.scenario_sql IS
  'SQL executed after snapshot load, before assertions (the scenario RPC calls). {{plan_date}} substituted.';
COMMENT ON COLUMN golden.fixtures.baseline_status IS
  'failing_expected = captured pre-fix as a red baseline (STEP 1: "failing baselines are the point").';

CREATE TABLE IF NOT EXISTS golden.snapshots (
  fixture_id   int  NOT NULL REFERENCES golden.fixtures(fixture_id) ON DELETE CASCADE,
  table_name   text NOT NULL,
  rows         jsonb NOT NULL,
  row_count    int GENERATED ALWAYS AS (jsonb_array_length(rows)) STORED,
  captured_at  timestamptz NOT NULL DEFAULT now(),
  capture_sql  text,
  PRIMARY KEY (fixture_id, table_name)
);
COMMENT ON TABLE golden.snapshots IS
  'Frozen real rows per fixture. rows = jsonb array of row objects. capture_sql records provenance '
  'so a snapshot can be re-taken and diffed rather than trusted blindly.';

CREATE TABLE IF NOT EXISTS golden.assertions (
  fixture_id   int  NOT NULL REFERENCES golden.fixtures(fixture_id) ON DELETE CASCADE,
  seq          int  NOT NULL,
  description  text NOT NULL,
  check_sql    text NOT NULL,
  expect_op    text NOT NULL DEFAULT 'eq'
                 CHECK (expect_op IN ('eq','ne','gte','lte','gt','lt','is_null','not_null','contains')),
  expect       text,
  enabled      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (fixture_id, seq)
);
COMMENT ON COLUMN golden.assertions.check_sql IS
  'MUST return exactly one row, one column. Cast to text by the runner. '
  'Placeholders {{plan_date}} and {{fixture_id}} are substituted before EXECUTE.';

CREATE TABLE IF NOT EXISTS golden.runs (
  run_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fixture_id   int  NOT NULL REFERENCES golden.fixtures(fixture_id) ON DELETE CASCADE,
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  passed       boolean,
  n_pass       int NOT NULL DEFAULT 0,
  n_fail       int NOT NULL DEFAULT 0,
  detail       jsonb,
  note         text
);
CREATE INDEX IF NOT EXISTS golden_runs_fixture_started_idx ON golden.runs (fixture_id, started_at DESC);

REVOKE ALL ON SCHEMA golden FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA golden FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA golden FROM PUBLIC;

ALTER TABLE golden.fixtures   ENABLE ROW LEVEL SECURITY;
ALTER TABLE golden.snapshots  ENABLE ROW LEVEL SECURITY;
ALTER TABLE golden.assertions ENABLE ROW LEVEL SECURITY;
ALTER TABLE golden.runs       ENABLE ROW LEVEL SECURITY;
-- Deliberately NO policies: RLS-on + zero policies = deny-all for anon/authenticated, while
-- the owner / service_role (BYPASSRLS) retains access. Article 2 satisfied without inventing
-- roles that have no business reading a test harness.
