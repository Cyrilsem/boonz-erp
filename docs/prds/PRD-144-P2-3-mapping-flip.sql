-- PRD-144 P2-3, second half: FOR CS APPROVAL. NOT APPLIED. Not a migration (lives in docs/prds on purpose).
-- Moves the six products' Active venue_team mappings to Boonz supply (105 rows when audited on 19 Oct:
-- 7Up Regular 30, 7Up Diet 31, Pepsi Black 9, Red Bull Diet 12, Red Bull Regular 12, Snickers 11).
--
-- Run ONLY after both of these are true:
--   1. Migration prd144_p2_3_source_kind_moves_stock is applied (pack/receive decide by source_kind).
--   2. Remove legs of venue-supplied products are written with source_kind 'venue'. Today they carry 'wh', and
--      receive_dispatch_line skips the warehouse credit for them only because the mapping says venue_team. After
--      this flip, a venue Remove of these six products would credit Boonz warehouse stock that was never there.
--
-- The count guard aborts if the row count differs from what was reviewed.
DO $flip$
DECLARE n int;
BEGIN
  UPDATE public.product_mapping
     SET source_of_supply = 'boonz'
   WHERE source_of_supply = 'venue_team'
     AND status = 'Active'
     AND boonz_product_id IN (
       SELECT product_id FROM public.boonz_products
        WHERE boonz_product_name IN ('7Up - Regular', '7Up - Diet', 'Pepsi - Black',
                                     'Red Bull - Regular', 'Red Bull - Diet', 'Snickers - Regular'));
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 105 THEN
    RAISE EXCEPTION 'PRD-144 P2-3 flip: expected 105 mappings, found %; nothing changed, re-audit first', n;
  END IF;
END
$flip$;
