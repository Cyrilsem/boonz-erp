-- PRD-110 P0.2 (second half) — "else the gap regrows".
-- Applied via Supabase MCP 2026-07-30; created cron jobid 42.
-- Article 11 OK: the cron calls an RPC, never a raw table write.
--
-- WHY THIS EXISTS: seed_missing_slot_lifecycle already existed but NOTHING scheduled it and
-- no trigger auto-provisioned on shelf insert. That is why 47 shelves across 4 Active
-- refillable machines had silently regrown an invisible-to-engine lifecycle gap by 2026-07-30.
-- Scheduled 15:30 UTC = 19:30 Dubai, i.e. 30 minutes BEFORE cron 13
-- (phaseF_stage1_prep_8pm_dubai, 16:00 UTC) so coverage is repaired before the plan is built.
-- Safe to run unscoped ONLY because 20260730120005 added the Active + include_in_refill guard.

SELECT cron.schedule(
  'prd110_p02_slot_lifecycle_coverage_1930_dubai',
  '30 15 * * *',
  $$SELECT public.seed_missing_slot_lifecycle(false, NULL);$$
);
