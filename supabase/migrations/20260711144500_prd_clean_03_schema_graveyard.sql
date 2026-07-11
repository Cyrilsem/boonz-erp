-- PRD-CLEAN-03: move dead tables/views/functions to graveyard schema. NO DROPs, fully reversible.
-- Kept in public (live refs): refill_plan_lock (FE), refill_dispatch_plan + daily_pipeline_runs
-- (write_dispatch_plan = chat-side deployment writer), engine_recommendation_snapshot (active
-- trigger tg_capture_refill_edit_signal), refill_plan_deviations (stitch_pod_to_boonz),
-- refill_commit_log (commit_refill_plan called from FE), refill_instructions (2 FE-called fns),
-- slot_capacity_max (engine_swap_pod).
CREATE SCHEMA IF NOT EXISTS graveyard;

-- Phase A: zero references (0 views, 0 functions, 0 FE hits)
ALTER TABLE public.pod_inventory_backup_20260416 SET SCHEMA graveyard;
ALTER TABLE public.pod_inventory_backup_20260421 SET SCHEMA graveyard;
ALTER TABLE public.weimi_daily_staging SET SCHEMA graveyard;
ALTER TABLE public.weimi_recon_staging SET SCHEMA graveyard;
ALTER TABLE public._debug_log SET SCHEMA graveyard;

-- Phase B: dead tables + their dead-only referencing functions (verified: no live pipeline
-- function, cron job, trigger, or src/ file references any of these; the apparent
-- engine_finalize callers were substring artifacts of engine_finalize_pod)
ALTER TABLE public.daily_plan_drafts SET SCHEMA graveyard;
ALTER TABLE public.rotation_proposals SET SCHEMA graveyard;
ALTER TABLE public.refill_action_proposals SET SCHEMA graveyard;
ALTER TABLE public.pod_inventory_seed_staging SET SCHEMA graveyard;
ALTER TABLE public.machine_summary SET SCHEMA graveyard;
ALTER VIEW public.v_machine_summary SET SCHEMA graveyard;

ALTER FUNCTION public.orchestrate_refill_plan(date) SET SCHEMA graveyard;
ALTER FUNCTION public.engine_finalize(date, boolean) SET SCHEMA graveyard;
ALTER FUNCTION public.engine_publish_to_refill_plan(date) SET SCHEMA graveyard;
ALTER FUNCTION public.propose_add_plan(date, integer, integer) SET SCHEMA graveyard;
ALTER FUNCTION public.propose_swap_plan(date, integer, integer, numeric) SET SCHEMA graveyard;
ALTER FUNCTION public.reconcile_intent_progress(date) SET SCHEMA graveyard;
ALTER FUNCTION public.apply_rotation_proposal(uuid, date, text) SET SCHEMA graveyard;
ALTER FUNCTION public.mark_proposals_expired(integer) SET SCHEMA graveyard;
ALTER FUNCTION public.propose_rotation_plan(integer, numeric, integer, boolean) SET SCHEMA graveyard;
ALTER FUNCTION public.reject_rotation_proposal(uuid, text) SET SCHEMA graveyard;
ALTER FUNCTION public.compute_nowh_proposals(date) SET SCHEMA graveyard;
ALTER FUNCTION public.load_pod_staging_chunk(jsonb) SET SCHEMA graveyard;
ALTER FUNCTION public.backfill_sales_history_qty_v47_window(boolean, timestamptz, timestamptz, integer) SET SCHEMA graveyard;
