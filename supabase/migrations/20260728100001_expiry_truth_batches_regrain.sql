-- PRD-105 Expiry Truth at Shelf Grain — Change 1 (RC-3)
-- Re-grain v_machine_expiry_batches dedupe from (machine, shelf) to
-- (machine, shelf-or-noshelf, boonz_product_id). A newer snapshot on one
-- product carries no information about a sibling product on the same shelf,
-- so shelf-grain dedupe silently dropped valid siblings before the MIN.
-- Precondition verified: 0 collisions at the finer grain (nothing legit dropped).
-- Replaced-body md5 (byte-identical rollback): f2f6397dc4a4fb0e90fbad7ba85f02ab
CREATE OR REPLACE VIEW public.v_machine_expiry_batches AS
WITH ranked AS (
  SELECT pi.pod_inventory_id, pi.machine_id, pi.shelf_id, pi.boonz_product_id,
         pi.batch_id, pi.expiration_date, pi.current_stock, pi.snapshot_date,
         ROW_NUMBER() OVER (
           PARTITION BY pi.machine_id,
                        COALESCE(pi.shelf_id::text, 'noshelf'),
                        pi.boonz_product_id
           ORDER BY pi.snapshot_date DESC, pi.pod_inventory_id
         ) AS rn
  FROM public.pod_inventory pi
  WHERE pi.status = 'Active' AND pi.current_stock > 0
)
SELECT pod_inventory_id, machine_id, shelf_id, boonz_product_id,
       batch_id, expiration_date, current_stock, snapshot_date
FROM ranked WHERE rn = 1;
