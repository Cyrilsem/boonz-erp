-- Rollback for DRAFT_warehouse_damage_writeoff.sql

DROP VIEW IF EXISTS public.v_damage_log;

-- Backfill rows: delete only the 3 exact sibling rows this migration inserted (matched by
-- disposal_reason + damage_source + the 3 known batch_ids + qty 1, created today), never a
-- broader delete.
DELETE FROM public.warehouse_inventory
WHERE disposal_reason = 'Damaged'
  AND damage_source = 'handling'
  AND warehouse_stock = 1
  AND batch_id IN (
    (SELECT batch_id FROM public.warehouse_inventory WHERE wh_inventory_id = '093b104f-a4a4-4e9b-bbfb-978ed8a26a27'),
    (SELECT batch_id FROM public.warehouse_inventory WHERE wh_inventory_id = 'f250682e-7cf4-4919-8d64-5100ae1a1206'),
    (SELECT batch_id FROM public.warehouse_inventory WHERE wh_inventory_id = 'af6eee21-eb2c-46d3-b4e7-164d8d009c73')
  )
  AND created_at::date = CURRENT_DATE
  AND wh_inventory_id NOT IN (
    '093b104f-a4a4-4e9b-bbfb-978ed8a26a27',
    'f250682e-7cf4-4919-8d64-5100ae1a1206',
    'af6eee21-eb2c-46d3-b4e7-164d8d009c73'
  );

DROP FUNCTION IF EXISTS public.warehouse_damage_writeoff(uuid, numeric, text, text, uuid, boolean);

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT IF EXISTS warehouse_inventory_damage_source_check;
ALTER TABLE public.warehouse_inventory DROP COLUMN IF EXISTS damage_source;

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT warehouse_inventory_disposal_reason_check;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT warehouse_inventory_disposal_reason_check
  CHECK (
    disposal_reason IS NULL
    OR disposal_reason = 'Waste'
    OR disposal_reason = 'Returning to supplier'
    OR disposal_reason = 'Returned to supplier'
    OR disposal_reason = 'audit_zero'
    OR disposal_reason ~ '^ghost_purge_\d{4}-\d{2}-\d{2}$'
  );
