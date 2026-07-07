-- PRD-078: golden regression baseline (Wave 0a.3). Additive QA data + immutable fixture.
-- input_fixture (immutable once frozen) + diff_vs_golden. golden_v1 is a frozen snapshot
-- of the real committed pod_refill_plan for the 5 representative machines (no engine re-run
-- on prod; capture_run stays branch-only). Engines untouched.
CREATE TABLE IF NOT EXISTS refill_qa.input_fixture (
  fixture_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label text NOT NULL, plan_date date NOT NULL, machine_ids uuid[] NOT NULL,
  frozen_at timestamptz, input_hash text, schema_version text NOT NULL DEFAULT 'v1',
  payload jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE refill_qa.input_fixture ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS qa_if_read ON refill_qa.input_fixture;
CREATE POLICY qa_if_read ON refill_qa.input_fixture FOR SELECT TO authenticated USING (true);
GRANT SELECT ON refill_qa.input_fixture TO authenticated, service_role;

CREATE OR REPLACE FUNCTION refill_qa.tg_fixture_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.frozen_at IS NOT NULL THEN
    RAISE EXCEPTION 'refill_qa.input_fixture %: frozen (%), immutable per PRD-078', OLD.fixture_id, OLD.frozen_at;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_fixture_immutable ON refill_qa.input_fixture;
CREATE TRIGGER trg_fixture_immutable BEFORE UPDATE ON refill_qa.input_fixture
  FOR EACH ROW EXECUTE FUNCTION refill_qa.tg_fixture_immutable();

CREATE OR REPLACE FUNCTION refill_qa.diff_vs_golden(p_candidate uuid, p_golden_label text DEFAULT 'golden_v1')
RETURNS jsonb LANGUAGE sql STABLE
SET search_path TO 'refill_qa','public','pg_temp'
AS $$
  SELECT refill_qa.diff_runs(g.run_id, p_candidate,
           (SELECT machine_ids FROM refill_qa.input_fixture WHERE label=p_golden_label ORDER BY frozen_at DESC NULLS LAST LIMIT 1))
  FROM refill_qa.plan_run g
  WHERE g.label = p_golden_label
  ORDER BY g.created_at DESC LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION refill_qa.diff_vs_golden(uuid,text) TO authenticated, service_role;

-- golden_v1 data (fixture + frozen plan snapshot + conservation verdict) is seeded by the
-- one-shot DO block recorded in PRD-078-EXECUTION-LOG.md (additive; idempotent guard on
-- label='golden_v1'). Not repeated here to keep the migration DDL-only + re-runnable.
