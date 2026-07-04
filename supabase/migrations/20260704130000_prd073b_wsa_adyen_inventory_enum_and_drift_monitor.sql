-- PRD-073 WS-A: eligibility hardening (Cody-reviewed; machines protected, RLS untouched).
-- Root cause: the machines-page FE rendered TEXT column adyen_inventory_in_store as a
-- boolean toggle -> literal 'true' -> 12 Active machines failed is_eligible_machine
-- ('Live' required) and were invisible to v_shelf_sales_identity grading (urgency blind).
-- Data fix (12 rows -> 'Live') applied from chat 2026-07-03. FE writer fixed same commit
-- as this file (EditableSelect over the constrained set; boolean type corrected).
-- Constraint proven in a rolled-back dry run: validates existing rows, rejects 'true'.
ALTER TABLE public.machines ADD CONSTRAINT machines_adyen_inventory_in_store_enum
  CHECK (adyen_inventory_in_store IS NULL OR adyen_inventory_in_store IN
   ('Live','Pending Setup','false','Warehouse Ready','Offline - WH Missing Shelves','Live - WH Storage')) NOT VALID;
ALTER TABLE public.machines VALIDATE CONSTRAINT machines_adyen_inventory_in_store_enum;

-- Monitor: Active + Online-today machines contributing ZERO rows to v_shelf_sales_identity
-- (any cause). The urgency model is blind on every row here.
CREATE OR REPLACE VIEW public.v_machine_eligibility_drift AS
SELECT m.machine_id, m.official_name, m.status, m.adyen_status,
       m.adyen_inventory_in_store, m.repurposed_at
FROM machines m
WHERE m.status = 'Active' AND m.adyen_status = 'Online today'
  AND NOT EXISTS (SELECT 1 FROM v_shelf_sales_identity s WHERE s.machine_id = m.machine_id);

COMMENT ON VIEW public.v_machine_eligibility_drift IS
  'PRD-073 WS-A: Active+Online machines invisible to shelf grading (any cause). Should be empty; known residue 2026-07-04: 3 repurposed-but-Active rows (repurposed_at set) + Pending Setup machines.';
