-- PRD-110 leg 110 - forward fix to golden fixture 14 assertion 6.
-- Article 12: a NEW migration to correct an old one, never an edit in place.
--
-- WHAT SEQ 6 MEANT TO PROVE, AND WHY IT STOPPED BEING ABLE TO PROVE IT.
-- Fixture 14 is the "sensor lie" fixture: MPMCC-1058-0000-R0 reports WEIMI counts
-- ABOVE shelf capacity. seq 6 asserted "composition total = capacity" on every such
-- shelf, to prove the P1.4 estimator clamps to CAPACITY rather than swallowing the
-- inflated WEIMI count. Its sibling seq 7 proves the other half (composition must NOT
-- equal current_stock) and seq 8 proves the fleet-wide ceiling (total <= capacity).
--
-- MEASURED LIVE 2026-08-03 during the STEP 7 / S7 sweep, shelf A10
-- (8adc06ae-b1a6-4e64-a5cc-af5fd271fbca):
--   max_stock 12 · WEIMI current_stock 16 · shelf_composition total 9
--   inventory_events for that shelf, in full:
--     2026-07-30 18:40  correction         +12   "P1.4 estimator cold-start seed"
--     2026-08-01 20:40  derived_decrement   -3   "P1.4 estimator: WEIMI drop allocated"
-- ⭐ The clamp DID fire: the seed is exactly 12, the CAPACITY, not the 16 the sensor
--    was reporting. The 9 is that 12 minus three units the estimator believes were
--    consumed. That is the estimator working correctly, not failing.
-- ⛔ seq 6 conflated two different claims - "the clamp fired at seed" and "nothing has
--    been consumed since" - and only the first was ever its job. Ordinary correct
--    consumption on a clamped shelf was therefore guaranteed to turn it red, and on
--    2026-08-01 it did. A12 and A14 stayed green only because they have sold nothing.
--
-- ⛔ NOT WEAKENED TO 'tot <= mx'. That is precisely seq 8, fleet-wide, so collapsing
--    seq 6 into it would delete the clamp proof outright. That is the S-48 / S-52 /
--    S-55 vacuity failure mode, already burned three times in this build.
-- ⭐ RESTATED IN CONSERVATION FORM, which proves strictly MORE than the original did:
--      (a) the SEED event on every over-capacity shelf equals CAPACITY   <- the clamp
--      (b) composition total equals the sum of ALL its inventory_events  <- conservation
--    Both are checked per shelf and both must hold. A10, A12 and A14 all satisfy both
--    (verified read-only before this migration was written). The OLD form could only
--    ever be satisfied by a clamped shelf that had never sold a single unit, so it was
--    a tripwire with a shelf life, not an invariant.
--
-- ⭐ THE CLASS MATTERS MORE THAN THIS ONE ASSERTION. seq 6 joins fixture 2 seq 27/64,
--    fixture 8 seq 29 (S-129), fixture 24 seq 29 (S-55) and fixture 40 seq 8 as
--    assertions anchored to a TRANSIENT production state that correct downstream
--    behaviour has legitimately moved. Recorded as S-200 in the PARKING-LOT.

-- ⛔ CODY REQUIRED REVISION (Article 12, the "and idempotent" half). A bare UPDATE
--    reports success with UPDATE 0 if the target row is ever absent or renumbered -
--    the S-193 failure class (a statement reporting ok while changing nothing). The
--    DO block below raises unless it hits EXACTLY one row.
DO $mig$
DECLARE v_n int;
BEGIN

UPDATE golden.assertions
   SET description = 'CLAMP + CONSERVATION: on every over-capacity ("sensor lie") shelf, the estimator''s SEED event equals CAPACITY (proving it clamped to max_stock instead of swallowing the inflated WEIMI count), AND the shelf''s composition total equals the sum of ALL its inventory_events (proving nothing was invented or lost since). 0 violations. ⛔ Do NOT weaken this to "total <= capacity" - that is seq 8, fleet-wide, and it would delete the clamp proof. ⛔ The ORIGINAL form of this assertion was "composition total = capacity", which silently also required that the shelf had never sold anything; shelf A10 went red on 2026-08-01 for a derived_decrement of -3 that was entirely correct. See S-200.',
       check_sql   = 'SELECT count(*)::text FROM (
  SELECT s.max_stock AS mx,
         (SELECT sum(c.est_qty) FROM public.shelf_composition c
           WHERE c.shelf_id = s.shelf_id) AS tot,
         (SELECT sum(e.qty_delta) FROM public.inventory_events e
           WHERE e.shelf_id = s.shelf_id) AS evt_sum,
         (SELECT e.qty_delta FROM public.inventory_events e
           WHERE e.shelf_id = s.shelf_id
           ORDER BY e.ts, e.created_at LIMIT 1) AS seed
    FROM public.v_shelf_state s
   WHERE s.machine_name = ''MPMCC-1058-0000-R0''
     AND s.pod_product_id IS NOT NULL
     AND s.current_stock > s.max_stock
) t
WHERE t.tot IS NOT NULL
  AND (t.seed IS DISTINCT FROM t.mx::numeric OR t.tot IS DISTINCT FROM t.evt_sum)'
 WHERE fixture_id = 14 AND seq = 6;

GET DIAGNOSTICS v_n = ROW_COUNT;
IF v_n <> 1 THEN
  RAISE EXCEPTION 'prd110 leg110: expected exactly 1 row for golden.assertions (14,6), updated %', v_n;
END IF;

END
$mig$;
