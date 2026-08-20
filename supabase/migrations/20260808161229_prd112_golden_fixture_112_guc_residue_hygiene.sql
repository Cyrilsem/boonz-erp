-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- golden.run_all runs every fixture in ONE transaction and app.via_rpc/app.rpc_name are transaction-local; fixture 112 left them set, arming the S-197 leak class for whatever ran next. Resets both GUCs and pins the reset with assertion seq 21.

UPDATE golden.fixtures
SET scenario_sql = regexp_replace(
  scenario_sql,
  E'\nEND\n\\$do\\$;\\s*$',
  E'\n  PERFORM set_config(''app.via_rpc'',  '''', true);\n  PERFORM set_config(''app.rpc_name'', '''', true);\nEND\n$do$;'
)
WHERE fixture_id = 112
  AND scenario_sql NOT LIKE E'%set_config(''app.via_rpc'',  '''', true)%';

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (
  112, 21,
  'RESIDUE: this fixture leaves app.via_rpc unset. run_all is one transaction and these GUCs are transaction-local, so a fixture that walks away with via_rpc set disarms the canonical-writer guard for whatever runs next (the S-197 class fixtures 18/26/67/71/74 each assert against).',
  E'SELECT COALESCE(NULLIF(current_setting(''app.via_rpc'', true), ''''), ''UNSET'')',
  'eq', 'UNSET', true, 'P0'
)
ON CONFLICT (fixture_id, seq) DO NOTHING;
