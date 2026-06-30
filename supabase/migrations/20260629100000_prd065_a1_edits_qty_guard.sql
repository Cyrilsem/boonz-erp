-- PRD-065 A1 (guard part) — pod_inventory_edits no-NULL/<=0 quantity guard.
-- Dara: pod_inventory_edits ALREADY CHECK-enforces quantity_update IS NOT NULL AND > 0 for
-- add_stock + add_new_product (conditional CHECK). The gap exposed 29 Jun (JET Pepsi partial_sold
-- edit 5d5ab4a7 created with quantity_update NULL -> approve threw "invalid quantity_update") is
-- sold / partial_sold / return_to_warehouse. This adds the missing guard for those three.
-- 'expired' is exempt (it ignores qty); 'in_stock'/'transfer' are not approver-supported and left alone.
-- NOT VALID: forward-only — enforces on new INSERT/UPDATE, does NOT retro-validate historical rows
-- (Hard Rule 6: no history rewrite; the one bad legacy row was already hand-fixed).
-- This is a GUARD (constraint), not a writer — safe to apply on Cody green.

ALTER TABLE public.pod_inventory_edits
  ADD CONSTRAINT pod_inventory_edits_qty_required_chk
  CHECK (
    edit_type NOT IN ('sold','partial_sold','return_to_warehouse')
    OR (quantity_update IS NOT NULL AND quantity_update > 0)
  ) NOT VALID;

COMMENT ON CONSTRAINT pod_inventory_edits_qty_required_chk ON public.pod_inventory_edits IS
  'PRD-065 A1: sold/partial_sold/return_to_warehouse require quantity_update > 0 (expired exempt; add_* covered by their own conditional CHECK). NOT VALID = new rows only.';

-- DOWN:
-- ALTER TABLE public.pod_inventory_edits DROP CONSTRAINT IF EXISTS pod_inventory_edits_qty_required_chk;
