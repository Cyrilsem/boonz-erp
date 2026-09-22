-- PRD-131 F7: 22 Sep repair verification.
--
-- Read-only. Does not change any approval. Deferred to tonight's 22:00 Dubai batch per CS's
-- ordering, run after A5 + prd131_01/02 (or standalone if 02 is held -- nothing here depends on
-- movement_kind existing).
--
-- Part 1: verify the six WAVEMAKER/MINDSHARE rows (Red Bull 5+4 on WAVEMAKER A04, Krambals
-- 2+3+3+1 on MINDSHARE A16) are already relabelled to action='Remove' and approved. Checked live
-- 2026-09-22: all six already carry action='Remove' and a non-null wh_approved_at (approved
-- between 10:38 and 11:47 that morning, as part of Part 1 of this session's work). This part of
-- F7 is DONE -- nothing left to reclassify via reclassify_dispatch_movement for these six.
SELECT rd.dispatch_id, m.official_name, sc.shelf_code, bp.boonz_product_name, rd.quantity,
       rd.action, rd.wh_approved_at,
       (rd.action = 'Remove' AND rd.wh_approved_at IS NOT NULL) AS already_fixed
FROM refill_dispatching rd
JOIN machines m ON m.machine_id = rd.machine_id
LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
LEFT JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
WHERE rd.dispatch_id IN (
  'cfa5cf35-bbd3-47b9-bec7-1d87546c87e5', -- WAVEMAKER A04 Red Bull x4
  'ae334d4a-a32e-4cbd-bdca-621eaeccb3f0', -- WAVEMAKER A04 Red Bull x5
  'b2e98f08-3fd0-41bb-8685-8574271aa6c3', -- MINDSHARE A16 Krambals Forest Mushroom x3
  '65742d51-2320-4616-adf2-d4b40b4e1e01', -- MINDSHARE A16 Krambals Creamy Cheese x3
  '4e5da056-8c1b-4fcf-a546-41fbe3c1816c', -- MINDSHARE A16 Krambals Creamy Cheese x2
  '63fdc62c-7f6c-4b8b-818b-ff1264bef297'  -- MINDSHARE A16 Krambals Tomato & Mozzarella x1
)
ORDER BY m.official_name, sc.shelf_code;

-- Part 2: WAVEMAKER A01 Sunbites variance for the recount list. Does not touch wh_approved_at.
-- IMPORTANT: checked live 2026-09-22 while drafting this script -- both WAVEMAKER A01 Sunbites
-- Remove rows (Sunbites - Cheese x4, Sunbites - Olive And Oregano x2, approved total 6) show
-- driver_confirmed_qty EQUAL to quantity on both rows (4=4, 2=2). There is NO live variance
-- today between approved and driver-confirmed count for these two rows -- the PRD's originally
-- cited "approved as 6, driver reported 2" does not match current data. Not fabricating a "2"
-- to match the PRD text. Printing the real numbers below; if this still doesn't match what CS
-- expects, the "driver reported 2" figure may refer to a different signal (an earlier field-app
-- submission later corrected, or a different Sunbites flavor/shelf) that this query does not
-- capture -- worth a quick sanity check with CS rather than silently resolving the discrepancy
-- either way.
SELECT rd.dispatch_id, bp.boonz_product_name, rd.quantity AS approved_qty,
       rd.driver_confirmed_qty, rd.driver_confirmed_at,
       (rd.quantity - COALESCE(rd.driver_confirmed_qty, rd.quantity)) AS variance,
       rd.wh_approved_at
FROM refill_dispatching rd
JOIN machines m ON m.machine_id = rd.machine_id
JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
WHERE rd.dispatch_date = '2026-09-22'
  AND m.official_name = 'WAVEMAKER-1006-4100-O1'
  AND sc.shelf_code = 'A01'
  AND rd.action = 'Remove'
  AND bp.boonz_product_name ILIKE 'Sunbites%'
ORDER BY bp.boonz_product_name;
