-- Rollback for PRD-137 F10 (v_machine_expiry_batches excludes confirmed-pending-approval Remove
-- lots, 2026-09-29). Restores the pre-F10 view: no exclusion, dedupes pod_inventory only.
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
