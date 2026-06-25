-- PRD-059 WS5: Inactive cleanup -> status='Removed/Expired', removal_reason='inactive_cleanup'.
--
-- Scope: ALL Inactive pod_inventory rows that still carry stock (current_stock > 0). CS decision
-- 2026-06-24: "all inactive should be removed" -> sweep the full set (1,901 rows / ~7,755 units /
-- 293 already expired / 34 null-expiry), INCLUDING the 23 NO-MAPPING rows WS3 just set to Inactive.
-- End state: zero Inactive-with-stock rows remain, so none can resurface as live inventory.
-- (Zero-stock Inactive rows are out of scope: nothing to preserve, they inflate no count.)
--
-- SAFETY (Hard Rule 6 / no-destructive / Article 18):
--   * Status transition + reason tag ONLY. current_stock is PRESERVED (NOT zeroed), along with
--     expiration_date / batch_id / shelf_id, for audit. No DELETE, no DROP, no stock change.
--   * Fully reversible: UPDATE ... SET status='Inactive', removal_reason=NULL for the ids logged
--     in write_audit_log under rpc_name='prd059_ws5_inactive_cleanup'.
--   * Idempotent: matches status='Inactive' only.
--   * Forward-only; self-aborts above a sane cap.
--   * Audited by tg_audit_pod_inventory; app.rpc_name labels provenance.

DO $$
DECLARE
  v_count int;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd059_ws5_inactive_cleanup', true);

  UPDATE public.pod_inventory pi
  SET status = 'Removed/Expired',
      removal_reason = 'inactive_cleanup'
  WHERE pi.status = 'Inactive'
    AND pi.current_stock > 0;   -- preserve stock; only stock-bearing Inactive rows in scope

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'PRD-059 WS5: cleaned up % Inactive pod_inventory rows (expected ~1901).', v_count;

  IF v_count > 2300 THEN
    RAISE EXCEPTION 'PRD-059 WS5 safety abort: % rows exceeds the expected ~1901 ceiling', v_count;
  END IF;
END $$;
