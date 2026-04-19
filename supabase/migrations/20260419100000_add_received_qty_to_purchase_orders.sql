-- BUG-4: Add received_qty to purchase_orders so partial receives
-- preserve the original ordered_qty instead of overwriting it.
-- received_qty = NULL means not yet received (pending).
-- received_qty < ordered_qty means partial delivery.

ALTER TABLE purchase_orders
  ADD COLUMN IF NOT EXISTS received_qty numeric NULL;

COMMENT ON COLUMN purchase_orders.received_qty IS
  'Actual quantity received. NULL = not yet received. May differ from ordered_qty on partial deliveries.';
