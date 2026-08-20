-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Part 4/4 of the 2026-08-15 pricing_status rollout, filed after the security advisor flagged
-- procurement_price_sync_and_flag() as anon-executable via /rest/v1/rpc/. Trigger functions fire
-- as table owner regardless of REVOKE, so this is safe; verified via a full receive afterwards.

revoke all on function public.procurement_price_sync_and_flag() from public, anon, authenticated;
grant execute on function public.procurement_price_sync_and_flag() to postgres, service_role;
