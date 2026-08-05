-- PRD-110 P4 - forward fix to golden fixture 9 assertion 4 (Article 12: a new
-- migration to correct an old one, never an edit-in-place).
--
-- WHAT WENT WRONG AND WHY IT IS WORTH RECORDING. Assertion 4 was written by
-- analogy with fixture 26 seq 6/7, which pin the P4.4b RPCs at
-- 'search_path=public, pg_temp'. I ASSUMED the legacy tier matched. It does not:
-- repack_machine, log_manual_refill and push_plan_to_dispatch all pin
-- 'search_path=public' with NO pg_temp. The fixture went red on its first run and
-- that red was correct - LAW 13, and the fixture caught me, which is the point of
-- writing the assertion before believing the answer.
--
-- ⛔ AND THE GAP IS NOT COSMETIC. Listing pg_temp LAST is what stops it being
--    searched FIRST. A SECURITY DEFINER function pinned to 'public' alone still
--    resolves unqualified names against the caller's temp schema before public,
--    which is the classic search_path shadowing surface for a definer function.
--    Measured fleet-wide this leg, across 332 SECURITY DEFINER functions in public:
--      105  pin pg_temp explicitly (hardened)
--      196  pin 'search_path=public' only  <- repack_machine, log_manual_refill,
--                                             push_plan_to_dispatch are in here
--       22  pin NOTHING at all (worst case)
--    ⛔ That is a pre-PRD-110, fleet-scale class. It is NOT fixed here (LAW 10) and
--       NOT papered over. It is recorded as S-198 in the PARKING-LOT and the
--       assertion below now states the true value and names the gap, so the next
--       reader cannot mistake 'search_path=public' for the standard.

UPDATE golden.assertions
   SET description = '⚠️ repack_machine is SECURITY DEFINER, and its search_path is pinned - but to ''public'' ALONE, with NO pg_temp. ⛔ That is NOT the hardened shape: listing pg_temp last is what stops it being searched FIRST, so a definer function pinned to public alone still resolves unqualified names against the caller''s temp schema first. Contrast fixture 26 seq 6/7, where the P4.4b tier pins ''public, pg_temp''. ⛔ S-198: this is fleet-scale and pre-PRD-110 - 196 of 332 public DEFINER functions look like this and 22 pin nothing at all - so it is recorded, not fixed here. This assertion states what IS. When S-198 is executed, this is the assertion that must move.',
       expect      = 'true|search_path=public'
 WHERE fixture_id = 9 AND seq = 4;
