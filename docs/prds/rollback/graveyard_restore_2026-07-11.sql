-- PRD-CLEAN-03 rollback: restore every graveyarded object to public.
ALTER TABLE graveyard.pod_inventory_backup_20260416 SET SCHEMA public;
ALTER TABLE graveyard.pod_inventory_backup_20260421 SET SCHEMA public;
ALTER TABLE graveyard.weimi_daily_staging SET SCHEMA public;
ALTER TABLE graveyard.weimi_recon_staging SET SCHEMA public;
ALTER TABLE graveyard._debug_log SET SCHEMA public;
ALTER TABLE graveyard.daily_plan_drafts SET SCHEMA public;
ALTER TABLE graveyard.rotation_proposals SET SCHEMA public;
ALTER TABLE graveyard.refill_action_proposals SET SCHEMA public;
ALTER TABLE graveyard.pod_inventory_seed_staging SET SCHEMA public;
ALTER TABLE graveyard.machine_summary SET SCHEMA public;
ALTER VIEW graveyard.v_machine_summary SET SCHEMA public;
ALTER FUNCTION graveyard.orchestrate_refill_plan(date) SET SCHEMA public;
ALTER FUNCTION graveyard.engine_finalize(date, boolean) SET SCHEMA public;
ALTER FUNCTION graveyard.engine_publish_to_refill_plan(date) SET SCHEMA public;
ALTER FUNCTION graveyard.propose_add_plan(date, integer, integer) SET SCHEMA public;
ALTER FUNCTION graveyard.propose_swap_plan(date, integer, integer, numeric) SET SCHEMA public;
ALTER FUNCTION graveyard.reconcile_intent_progress(date) SET SCHEMA public;
ALTER FUNCTION graveyard.apply_rotation_proposal(uuid, date, text) SET SCHEMA public;
ALTER FUNCTION graveyard.mark_proposals_expired(integer) SET SCHEMA public;
ALTER FUNCTION graveyard.propose_rotation_plan(integer, numeric, integer, boolean) SET SCHEMA public;
ALTER FUNCTION graveyard.reject_rotation_proposal(uuid, text) SET SCHEMA public;
ALTER FUNCTION graveyard.compute_nowh_proposals(date) SET SCHEMA public;
ALTER FUNCTION graveyard.load_pod_staging_chunk(jsonb) SET SCHEMA public;
ALTER FUNCTION graveyard.backfill_sales_history_qty_v47_window(boolean, timestamptz, timestamptz, integer) SET SCHEMA public;

-- PRD-CLEAN-07 additions:
ALTER TABLE graveyard.refill_priority_params SET SCHEMA public;
ALTER TABLE graveyard.service_priority_params SET SCHEMA public;
ALTER VIEW graveyard.v_machine_service_priority SET SCHEMA public;
-- DROP VIEW public.v_refill_config;
