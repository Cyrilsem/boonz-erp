-- Commission IRIS-1070-0000-O1 (d5628a72-807a-4a64-9976-5d76139ae354) as a SINGLE-DOOR cabinet.
-- CS confirmed 2026-08-24: new machine, new location, physically 16 lanes, not 32.
-- Cody reviewed: Articles 1, 3, 4, 5, 8, 12, Appendix A. Verdict: approve with revisions.
--   Article 5 gap: no canonical writer exists for machines.status on an existing row.
--   Migration path taken per precedent (CHANGELOG 1880, IRIS-1010 flip). Follow-up filed:
--   create set_machine_status as the canonical writer so the next commissioning needs no migration.
-- ORDERING IS LOAD BEARING: phantom the B lanes BEFORE the machine goes Active, otherwise
--   seed_missing_slot_lifecycle (scope: status='Active' AND include_in_refill AND is_phantom=false)
--   mints slot_lifecycle rows for 16 lanes that do not physically exist.

SELECT set_config('app.via_rpc','true', true);
SELECT set_config('app.rpc_name','migration:commission_iris_1070_single_door', true);

-- 1. Retire the 16 B-lane rows. is_phantom, never DELETE (no canonical deleter; FK risk).
UPDATE public.shelf_configurations
   SET is_phantom = true
 WHERE machine_id = 'd5628a72-807a-4a64-9976-5d76139ae354'
   AND shelf_code LIKE 'B%'
   AND is_phantom = false;

-- 2. Backfill max_capacity on the 16 real lanes.
--    ⛔ PROVENANCE: A06/A07/A08/A10 are CS-VERIFIED real depths. The other 12 are
--    product_slot_capacity registry values and are PROVISIONAL. The registry has
--    over-stated every lane CS has physically checked (Zigi 25->8, Plaay 30->8,
--    Loacker 25->15, Barebells 30->20). Driver to count depths on the install visit.
UPDATE public.shelf_configurations sc
   SET max_capacity = v.cap
  FROM (VALUES
    ('A01', 8),('A02',17),('A03',15),('A04',15),
    ('A05',30),('A06', 8),('A07',15),('A08', 8),
    ('A09',30),('A10',20),('A11',30),
    ('A12',21),('A13',30),('A14',14),
    ('A15',30),('A16',20)
  ) AS v(shelf_code, cap)
 WHERE sc.machine_id = 'd5628a72-807a-4a64-9976-5d76139ae354'
   AND sc.shelf_code = v.shelf_code;

-- 3. Commission the machine. include_in_refill is NOT set here: toggle_machine_refill
--    is its canonical writer (Article 1) and is called immediately after this migration.
--    pod_address deliberately NOT touched: it reads 'Dubai Harbor' but CS says this is a
--    new location and has not supplied the address. Guessing it would be worse than leaving it.
UPDATE public.machines
   SET status = 'Active',
       installation_date = DATE '2026-08-25'
 WHERE machine_id = 'd5628a72-807a-4a64-9976-5d76139ae354'
   AND status = 'Pending';