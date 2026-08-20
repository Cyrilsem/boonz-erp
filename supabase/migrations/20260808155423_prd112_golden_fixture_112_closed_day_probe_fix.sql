-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Fixture 112's closed-day tripwire probe used DATE '2029-01-01' (future of the real Dubai clock, so the probe proved nothing); corrected to '2020-01-01'. Verified live: golden.fixtures.scenario_sql for fixture_id=112 carries DATE '2020-01-01' today.

UPDATE golden.fixtures
SET scenario_sql = replace(scenario_sql, 'DATE ''2029-01-01''', 'DATE ''2020-01-01''')
WHERE fixture_id = 112
  AND scenario_sql LIKE '%DATE ''2029-01-01''%';
