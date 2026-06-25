-- PRD-059 WS4: HIGHLIGHT orphans -> status='Removed/Expired', removal_reason='orphan_not_on_machine'.
--
-- Scope: NULL-shelf Active batches (card-counted via v_machine_expiry_batches) that DO have an
-- Active product_mapping but whose pod-product is NOT live on the machine per v_live_shelf_stock
-- (is_enabled). The product is genuinely off the machine (removed from planogram / machine
-- repurposed or decommissioned, e.g. *_OLD and WH2-* staging units) yet a stock record lingers
-- and inflates the live expiry card. CS signed off the row list (110 batches / ~517 units,
-- 2 expired / 11 exp<=30d). No driver pull required (stock not physically on a live shelf).
--
-- SAFETY (Hard Rule 6 / no-destructive):
--   * Status transition + reason tag ONLY. No DELETE, no DROP, no stock change: current_stock /
--     expiration_date / batch_id / shelf_id all preserved for audit.
--   * Fully reversible: UPDATE ... SET status='Active', removal_reason=NULL for the ids logged
--     in write_audit_log under rpc_name='prd059_ws4_highlight_orphan_writeoff'.
--   * Idempotent: matches status='Active' only.
--   * Re-resolved inline at apply time (not a frozen id list); self-aborts above a sane cap.
--   * Audited by tg_audit_pod_inventory; app.rpc_name labels provenance.

DO $$
DECLARE
  v_count int;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd059_ws4_highlight_orphan_writeoff', true);

  WITH am AS (
    SELECT boonz_product_id, machine_id, pod_product_id, is_global_default
    FROM public.product_mapping WHERE status = 'Active'
  ),
  highlight AS (
    SELECT b.pod_inventory_id
    FROM public.v_machine_expiry_batches b
    WHERE b.shelf_id IS NULL
      -- has an Active mapping (else it is WS3, not WS4)
      AND EXISTS (
        SELECT 1 FROM am
        WHERE am.boonz_product_id = b.boonz_product_id
          AND (am.machine_id = b.machine_id OR am.is_global_default)
      )
      -- but the pod-product is NOT live on the machine
      AND NOT EXISTS (
        SELECT 1 FROM public.v_live_shelf_stock vls
        WHERE vls.machine_id = b.machine_id AND vls.is_enabled
          AND vls.pod_product_id IN (
            SELECT pod_product_id FROM am ms
              WHERE ms.boonz_product_id = b.boonz_product_id AND ms.machine_id = b.machine_id
            UNION
            SELECT pod_product_id FROM am g
              WHERE g.boonz_product_id = b.boonz_product_id AND g.is_global_default
                AND NOT EXISTS (SELECT 1 FROM am ms2
                  WHERE ms2.boonz_product_id = b.boonz_product_id AND ms2.machine_id = b.machine_id)
          )
      )
  )
  UPDATE public.pod_inventory pi
  SET status = 'Removed/Expired',
      removal_reason = 'orphan_not_on_machine'
  FROM highlight h
  WHERE pi.pod_inventory_id = h.pod_inventory_id
    AND pi.status = 'Active';   -- idempotency guard

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'PRD-059 WS4: wrote off % orphan pod_inventory rows (expected ~110).', v_count;

  IF v_count > 160 THEN
    RAISE EXCEPTION 'PRD-059 WS4 safety abort: % rows exceeds the expected ~110 ceiling', v_count;
  END IF;
END $$;
