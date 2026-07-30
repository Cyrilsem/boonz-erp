-- PRD-105 Expiry Truth at Shelf Grain — partial index
-- Serves the v_machine_expiry_batches base scan and the per-shelf MIN grouping
-- in get_machine_slots_with_expiry and v_machine_expiry_summary.
CREATE INDEX IF NOT EXISTS idx_pod_inventory_active_shelf_expiry
  ON public.pod_inventory (machine_id, shelf_id, expiration_date)
  WHERE status = 'Active' AND current_stock > 0;
