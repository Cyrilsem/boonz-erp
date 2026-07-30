-- PRD-110 STEP 1 — golden runner. Applied via MCP as `prd110_p1_golden_runner` 2026-07-30.
-- SECURITY INVOKER by design (executes fixture-authored dynamic SQL; DEFINER would be a
-- privilege-escalation hole). Read-only w.r.t. all business tables: the only writes are into
-- golden.runs (harness bookkeeping).
-- NOTE: golden.compare is superseded by 20260730120003; golden.run_fixture / run_all are
-- superseded by 20260730120004 (per-assertion phase gating). Both kept here for lineage.

CREATE OR REPLACE FUNCTION golden.render(p_sql text, p_fixture_id int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(
           replace(p_sql, '{{fixture_id}}', p_fixture_id::text),
           '{{plan_date}}',
           quote_literal((DATE '2030-01-01' + p_fixture_id)::text) || '::date')
$$;
COMMENT ON FUNCTION golden.render(text,int) IS
  'Substitutes {{plan_date}} (as a quoted ::date literal) and {{fixture_id}} in fixture SQL.';

-- (original golden.compare body — see 20260730120003 for the case_not_found fix)
-- (original golden.run_fixture / golden.run_all — see 20260730120004 for phase gating)
