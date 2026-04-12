-- Migration: create v_slot_capacity view
-- CC-20-CC2 step 2 of 2
-- Engine B reads this view: returns override_max_stock if a row exists in
-- slot_capacity_max, otherwise falls back to v_live_shelf_stock.max_stock.

CREATE OR REPLACE VIEW v_slot_capacity AS
SELECT
  lss.machine_id,
  lss.machine_name,
  lss.aisle_code,
  lss.slot_name,
  lss.max_stock                          AS live_max_stock,
  scm.override_max_stock,
  COALESCE(scm.override_max_stock, lss.max_stock) AS effective_max_stock,
  CASE WHEN scm.override_max_stock IS NOT NULL
    THEN 'override' ELSE 'live' END      AS capacity_source,
  scm.reason                             AS override_reason
FROM v_live_shelf_stock lss
LEFT JOIN slot_capacity_max scm
  ON scm.machine_id = lss.machine_id
  AND scm.aisle_code = lss.aisle_code;
