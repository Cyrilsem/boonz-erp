-- PRD-110 S-53 - fixture 30 seq 8 / seq 9 constants corrected. Forward-only (Article 12): the
-- previous migration is applied and is NOT edited; this supersedes the two expect values.
--
-- The LAW-1 baseline run exposed that BOTH guard constants were derived from a differently-scoped
-- query than the assertion body executes. The assertions count product_sourcing edges directly by
-- product name; the numbers 75 and 12 came from queries that additionally required a matching
-- machine-scoped product_mapping row. Neither gap is a data defect - measured live:
--
--   seq 8, VOX-supplied venue edges on co_managed = 77, not 75:
--     Aquafina 11 + Fade Fit 44 + VOX Cotton Candy 4 + VOX Lollies 6 + VOX Popcorn 12.
--     VOX Lollies carries 6 edges, of which 4 have a machine-scoped 'boonz' mapping and 2 have a
--     'venue_team' one - so the boonz-intent query that produced 75 saw only 4 of the 6. All 6 are
--     correctly venue.
--
--   seq 9, Coke-family boonz_wh edges on the Soft Drinks Mix pod = 20, not 12:
--     Coca Cola Regular 7 + Zero 7 + Diet 3 + Mountain Dew 3. The 12 came from restricting to the
--     3 machines whose Soft Drinks Mix pod also carries a venue_team row; the pod exists on 7.
--
-- All 77 and all 20 carry an Active machine-scoped mapping row, and NONE of them is touched by the
-- S-53 correction (which flips only Pepsi - Black and the two Red Bull SKUs). So both remain
-- standing guards; only the constants move to the measured truth.

UPDATE golden.assertions
   SET expect = '77',
       description = 'S-10 TRIPWIRE, the guard against over-correction: the 77 VOX-supplied venue edges on co_managed machines (Aquafina 11, Fade Fit 44, VOX Cotton Candy 4, VOX Lollies 6, VOX Popcorn 12) stay venue. Each carries a GLOBAL-DEFAULT venue_team row, so they are correct under ANY-scope and wrong under most-specific-wins. A backfill that reverts to most-specific-wins re-sources VOX goods to Boonz WH and undoes P0.4. S-53 does not touch any of them. Never fix this by weakening the assertion'
 WHERE fixture_id = 30 AND seq = 8;

UPDATE golden.assertions
   SET expect = '20',
       description = 'MIXED-POD GUARD: the 20 Coca-Cola and Mountain Dew edges on the Soft Drinks Mix pod (Regular 7, Zero 7, Diet 3, Mountain Dew 3) stay boonz_wh. That pod is genuinely mixed - Pepsi from the venue, Coke from Boonz WH - and only per-SKU edges can express it. A pod-grain flip reds this'
 WHERE fixture_id = 30 AND seq = 9;
