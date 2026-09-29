-- PRD-137 F10, 2026-09-29 (CS mid-run addition): Picker P1 "expired stock on shelf" (via
-- v_machine_health_signals.expired_skus_now, sourced from v_machine_expiry_batches through
-- v_machine_expiry_summary) double-counts a pod lot that a driver has already pulled and
-- confirmed, but that is still sitting in pod_inventory as Active with stock > 0 because the
-- physical removal is only reflected in the system once WH approves the confirmation. Evidence:
-- ALJLT-1015-0200-O1 A11 McVities Digestive Mini Dark, expired 2026-09-28, dispatch 98e97a7f,
-- driver_confirmed_at set 2026-09-29 19:00 UTC, wh_approved_at still null -- yet the lot still
-- shows up as an expired SKU driving P1.
--
-- Fix at the root: v_machine_expiry_batches (consumed by v_shelf_state, v_machine_expiry_summary
-- and, via that, v_machine_health_signals/v_machine_priority P1, and by v_expiry_pull_candidates)
-- excludes any batch that already has a live, driver-confirmed, WH-pending Remove or Machine To
-- Warehouse line for that exact (machine, shelf, product, expiry).
--
-- Rollback: supabase/rollback/20260929195500_prd137_f10_v_machine_expiry_batches_exclude_confirmed_pending_rollback.sql
-- (byte-verified against pg_get_viewdef, whitespace-stripped, before this change).
CREATE OR REPLACE VIEW public.v_machine_expiry_batches AS
 WITH ranked AS (
         SELECT pi.pod_inventory_id,
            pi.machine_id,
            pi.shelf_id,
            pi.boonz_product_id,
            pi.batch_id,
            pi.expiration_date,
            pi.current_stock,
            pi.snapshot_date,
            row_number() OVER (PARTITION BY pi.machine_id, (COALESCE(pi.shelf_id::text, 'noshelf'::text)), pi.boonz_product_id, pi.expiration_date ORDER BY pi.snapshot_date DESC, pi.pod_inventory_id) AS rn
           FROM pod_inventory pi
          WHERE pi.status = 'Active'::text AND pi.current_stock > 0::numeric
            AND NOT EXISTS (
              SELECT 1 FROM refill_dispatching rd
               WHERE rd.machine_id = pi.machine_id
                 AND rd.shelf_id IS NOT DISTINCT FROM pi.shelf_id
                 AND rd.boonz_product_id = pi.boonz_product_id
                 AND rd.expiry_date IS NOT DISTINCT FROM pi.expiration_date
                 AND rd.action IN ('Remove','Machine To Warehouse')
                 AND rd.driver_confirmed_at IS NOT NULL
                 AND rd.wh_approved_at IS NULL
                 AND COALESCE(rd.cancelled,false) = false
                 AND COALESCE(rd.skipped,false) = false
            )
        )
 SELECT pod_inventory_id,
    machine_id,
    shelf_id,
    boonz_product_id,
    batch_id,
    expiration_date,
    current_stock,
    snapshot_date
   FROM ranked
  WHERE rn = 1;
