-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- RC-11: revokes anon's direct write privileges on weimi_device_status, the table carrying
-- door hardware state (door_statuses jsonb column, populated from cabinet/layer/aisle door
-- reports). Writes go through upsert_device_status(jsonb) instead, which is not
-- SECURITY DEFINER, so anon's remaining EXECUTE on that RPC is inert without direct table
-- INSERT/UPDATE privilege. Confirmed live 2026-08-20: anon holds only SELECT/REFERENCES/
-- TRIGGER on weimi_device_status (no INSERT/UPDATE/DELETE), consistent with this revoke
-- having been applied and never reverted.

REVOKE INSERT, UPDATE, DELETE ON public.weimi_device_status FROM anon;
