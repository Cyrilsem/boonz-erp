-- PRD-059 WS3: NO ACTIVE MAPPING -> status='Inactive'.
--
-- Scope: NULL-shelf Active batches (card-counted via v_machine_expiry_batches) whose
-- boonz_product has NO Active product_mapping at all (neither machine-specific nor global).
-- These boonz products cannot be placed on any slot or sold -> they are orphaned at the
-- boonz grain (mostly MANUAL-LOG specific variants). CS decision 2026-06-24: transition to
-- Inactive so they stop inflating the live expiry card. Reviewed row set = 23 batches.
--
-- SAFETY (Hard Rule 6 / no-destructive):
--   * Status transition ONLY (Active -> Inactive). No DELETE, no DROP, no stock change:
--     current_stock / expiration_date / batch_id / shelf_id all untouched (preserved for audit).
--   * Fully reversible: UPDATE ... SET status='Active' for the ids logged in write_audit_log
--     under rpc_name='prd059_ws3_no_mapping_inactive'.
--   * Idempotent: matches status='Active' only, so re-running is a no-op.
--   * Re-resolved inline at apply time (not a frozen id list); self-aborts above a sane cap.
--   * Audited by tg_audit_pod_inventory; app.rpc_name labels provenance.

DO $$
DECLARE
  v_count int;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd059_ws3_no_mapping_inactive', true);

  WITH am AS (
    SELECT boonz_product_id, machine_id, is_global_default
    FROM public.product_mapping WHERE status = 'Active'
  ),
  no_mapping AS (
    SELECT b.pod_inventory_id
    FROM public.v_machine_expiry_batches b
    WHERE b.shelf_id IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM am
        WHERE am.boonz_product_id = b.boonz_product_id
          AND (am.machine_id = b.machine_id OR am.is_global_default)
      )
  )
  UPDATE public.pod_inventory pi
  SET status = 'Inactive'
  FROM no_mapping nm
  WHERE pi.pod_inventory_id = nm.pod_inventory_id
    AND pi.status = 'Active';   -- idempotency guard

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'PRD-059 WS3: transitioned % pod_inventory rows to Inactive (expected ~23).', v_count;

  IF v_count > 50 THEN
    RAISE EXCEPTION 'PRD-059 WS3 safety abort: % rows exceeds the expected ~23 ceiling', v_count;
  END IF;
END $$;
