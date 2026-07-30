-- PRD-110 P0.6(d) prep, two Cody revisions before the INV-06 v2 fix.
--
-- (1) ROLLBACK ARTIFACT (Cody: Article 12). preflight_refill_plan was shipped by PRD-109
--     via MCP and mirrored into NO migration file, so a CREATE OR REPLACE would leave the
--     prior body unrecoverable. Freeze it into golden.snapshots, which exists precisely to
--     hold frozen input state. Rebuild command is recorded in capture_sql.
--     TWO golden.snapshots traps: row_count is GENERATED (never insert it) and it is
--     generated as jsonb_array_length(rows), so `rows` MUST be a jsonb ARRAY, not an object.
--
-- (2) FIXTURE 10 HARDENING. Live lifecycle: a parent that was stitched and then superseded
--     by a re-run KEEPS its stitched_at (1 of 155 superseded + 2 of 5 voided + 2 of 82
--     approved carry a stray stitched_at, while status='stitched' <=> stitched_at IS NOT
--     NULL holds 196/196). The first cut of the fixture left superseded parents at
--     stitched_at NULL, so a fix keyed on `stitched_at IS NOT NULL` would have passed
--     seq 10/16 while still false-positiving in production. Give the superseded parents a
--     stitched_at so the fixture can only go green on a status-keyed predicate.

INSERT INTO golden.snapshots (fixture_id, table_name, rows, capture_sql)
SELECT 10,
       'pg_proc:public.preflight_refill_plan@pre_p06d_inv06_v2',
       jsonb_build_array(jsonb_build_object(
         'proname',      p.proname,
         'identity_args',pg_get_function_identity_arguments(p.oid),
         'returns',      pg_get_function_result(p.oid),
         'language',     l.lanname,
         'volatile',     p.provolatile,
         'secdef',       p.prosecdef,
         'proconfig',    to_jsonb(p.proconfig),
         'proacl',       p.proacl::text,
         'owner',        pg_get_userbyid(p.proowner),
         'prosrc',       p.prosrc)),
       $cap$Rollback = re-create the function from this snapshot:
  CREATE OR REPLACE FUNCTION public.preflight_refill_plan(p_plan_date date)
    RETURNS TABLE(verdict text, violations jsonb, warnings jsonb,
                  checked_at timestamptz, invariant_versions jsonb)
    LANGUAGE plpgsql STABLE SET search_path = public
  AS $B$ <rows->0->>'prosrc'> $B$;
Retrieve with:
  SELECT rows->0->>'prosrc' FROM golden.snapshots
   WHERE fixture_id = 10
     AND table_name = 'pg_proc:public.preflight_refill_plan@pre_p06d_inv06_v2';$cap$
FROM pg_proc p
JOIN pg_language l  ON l.oid = p.prolang
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'preflight_refill_plan'
  AND NOT EXISTS (SELECT 1 FROM golden.snapshots s
                   WHERE s.fixture_id = 10
                     AND s.table_name = 'pg_proc:public.preflight_refill_plan@pre_p06d_inv06_v2');

-- Fixture 10: superseded parents now carry stitched_at, mirroring the real lifecycle.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
'UPDATE public.pod_refill_plan SET stitched_at = now()
 WHERE plan_date = {{plan_date}} AND status = ''stitched'';',
'-- Every parent that was ever stitched keeps stitched_at, INCLUDING the superseded ones.
-- This is what makes seq 10/16 reject a fix keyed on stitched_at instead of status.
UPDATE public.pod_refill_plan SET stitched_at = now()
 WHERE plan_date = {{plan_date}} AND status IN (''stitched'',''superseded'');')
 WHERE fixture_id = 10;

UPDATE golden.assertions
   SET description = 'S1 superseded parent (WITH stitched_at set, as in production) with no children is NOT an INV-06 violation (fixture 10 headline)'
 WHERE fixture_id = 10 AND seq = 10;

-- Guard: both revisions must actually have landed.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM golden.fixtures
                  WHERE fixture_id = 10
                    AND scenario_sql LIKE '%IN (''stitched'',''superseded'')%') THEN
    RAISE EXCEPTION 'fixture 10 stitched_at hardening did not apply - scenario_sql anchor missed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM golden.snapshots
                  WHERE fixture_id = 10
                    AND table_name = 'pg_proc:public.preflight_refill_plan@pre_p06d_inv06_v2'
                    AND length(rows->0->>'prosrc') > 20000) THEN
    RAISE EXCEPTION 'preflight rollback snapshot missing or truncated';
  END IF;
END $$;
