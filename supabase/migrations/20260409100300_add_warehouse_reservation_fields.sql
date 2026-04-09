-- CC-06: Add Engine B FIFO reservation columns to warehouse_inventory
-- Pre-check: warehouse_inventory exists (1646 rows as of 2026-04-09)
ALTER TABLE public.warehouse_inventory
  ADD COLUMN IF NOT EXISTS reserved_for_machine_id uuid REFERENCES public.machines(machine_id),
  ADD COLUMN IF NOT EXISTS reservation_priority int,
  ADD COLUMN IF NOT EXISTS reserved_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_warehouse_inventory_reservation
  ON public.warehouse_inventory(reserved_for_machine_id, reservation_priority)
  WHERE reserved_for_machine_id IS NOT NULL;

COMMENT ON COLUMN public.warehouse_inventory.reserved_for_machine_id IS
'If set, this batch is held for a specific machine and Engine B will pull it FIFO by expiration before fresh stock.';
COMMENT ON COLUMN public.warehouse_inventory.reservation_priority IS
'Lower number = higher priority. Used by Engine B for FIFO reserved-stock ordering.';
COMMENT ON COLUMN public.warehouse_inventory.reserved_at IS
'Timestamp when this batch was reserved for the machine.';
