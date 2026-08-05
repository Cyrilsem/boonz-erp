-- PRD-110 leg 33 · S-37 follow-up · REPAIR, applied within the same atomic unit.
--
-- DEFECT I INTRODUCED, and the lesson. The preceding migration rebuilt fixture 2's
-- scenario_sql from the on-disk migration FILE that originally created it
-- (20260730185730). That file is NOT the current text: leg 24 later extended the
-- 'before' block with two more ADR-8.3 tripwire keys --
--     'pr' -> public.pod_refills      (seq 92)
--     'bd' -> public.blocked_demand   (seq 93)
-- -- via a migration that never touched the fixture-2 creation file. Rebuilding from the
-- file silently reverted leg 24's extension, so seq 92/93 read a missing key, got NULL,
-- and failed. Caught immediately by the fixture's own run (n_fail=2), not by luck.
--
-- THIS IS LAW 13 IN MINIATURE: trust the LIVE object over the file that once created it.
-- A migration file is a record of one change, never the current state of a mutable row.
-- The general guard, which is now the house rule for any scenario_sql edit:
--     WITH refs AS (SELECT DISTINCT (regexp_matches(check_sql,'value->>''([a-z0-9_]+)''','g'))[1] k
--                   FROM golden.assertions WHERE fixture_id = N),
--          have AS (SELECT DISTINCT jsonb_object_keys(value) k FROM golden.scratch WHERE fixture_id = N)
--     SELECT refs.k FROM refs LEFT JOIN have USING (k) WHERE have.k IS NULL;   -- must be empty
-- Run against the LIVE fixture before and after every scenario_sql rewrite.
--
-- Restores both keys. Everything else in scenario_sql is left exactly as the previous
-- migration set it. golden schema only.

UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
$old$  'anom',    (SELECT count(*) FROM public.inventory_anomalies));$old$,
$new$  'anom',    (SELECT count(*) FROM public.inventory_anomalies),
  'pr',      (SELECT count(*) FROM public.pod_refills),
  'bd',      (SELECT count(*) FROM public.blocked_demand));$new$)
 WHERE fixture_id = 2
   AND position($old$  'anom',    (SELECT count(*) FROM public.inventory_anomalies));$old$ in scenario_sql) > 0;

-- Fail loudly rather than silently no-op if the anchor text ever moves.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM golden.fixtures
                  WHERE fixture_id = 2
                    AND scenario_sql LIKE '%''pr'',      (SELECT count(*) FROM public.pod_refills)%'
                    AND scenario_sql LIKE '%''bd'',      (SELECT count(*) FROM public.blocked_demand)%')
  THEN
    RAISE EXCEPTION 'fixture 2 scenario_sql repair did not apply: anchor text not found';
  END IF;
END $$;
