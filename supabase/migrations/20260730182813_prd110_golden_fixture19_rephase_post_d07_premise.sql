-- PRD-110 leg 21 · fixture 19 "Co-managed venue fill" - RE-PHASE two stale-premise assertions.
-- ⚠️ RE-PHASED, NEVER DELETED (the house rule the pointer states for fixture 3 seq 15).
--
-- WHAT HAPPENED. P1 was 101/0 at leg 14 and was NOT re-run by legs 15-20. Leg 21 ran it and got
-- fixture 19 = 13 pass / 2 fail. Bisected: this is NOT a regression. Both failures assert the
-- PREMISE THAT D-07 IS PARKED, and leg 20 APPLIED D-07 (CS-approved, "APPLY NOW"):
--   seq 1 "premise: operating_model is NULL on the target machine (D-07 parked)"  true -> false
--   seq 4 "D-07 dormancy: unclassified machine gives the fail-safe anomaly"    anomaly -> venue_fill
-- MPMCC-1058-0000-R0 is now co_managed, so `_estimator_rise_disposition_v3` correctly returns
-- venue_fill for a venue-sourced product. The SUBSTANTIVE assertions all still pass unchanged:
-- seq 5 (co_managed+venue -> venue_fill), seq 6 (boonz-sourced -> anomaly), seq 7 (venue on
-- fully_managed -> anomaly), seq 8 (unknown edge -> boonz_wh), seq 9 (guard REFUSES the bad
-- reclassification). The engine behaviour is correct; the fixture's world moved.
--
-- seq 1 - minimal: the scratch key `model_live_null` is captured BEFORE the fixture's own
--   set_machine_operating_model_v3 call, so it still means "was the machine already classified when
--   this run started". Post-D-07 the correct answer is false. Expect flips true -> false. Reading it
--   live instead would be tautological, because the fixture classifies the machine itself.
--
-- seq 4 - the invariant is REAL and is KEPT, but it lost its subject. `_estimator_rise_disposition_v3`
--   is `co_managed AND sourcing='venue' -> venue_fill ELSE anomaly`, so the NULL case matters
--   precisely because `NULL = 'co_managed'` is NULL and falls to ELSE. A rewrite using
--   `<> 'fully_managed'` or a careless COALESCE would silently flip NULL to venue_fill.
--   Measured this leg: there is NO live subject left - the canonical writer REFUSES NULL
--   ("model <NULL> must be fully_managed|co_managed|partner_managed", so the fixture cannot
--   un-classify inside its envelope), and zero unclassified machines hold a venue edge, because
--   venue edges exist only on the now-classified Active fleet.
--   So seq 4 becomes SUBJECT-FREE and FLEET-WIDE (the S-04 house pattern): no unclassified machine
--   may produce venue_fill, for any sourcing edge. This is STRICTLY STRONGER than the old
--   single-subject check, and it is the live tripwire for S-25: `add_new_machine` and
--   `repurpose_machine` both mint Active machines WITHOUT operating_model, so unclassified machines
--   WILL reappear - and when they do, this assertion is what proves they fail safe.

UPDATE golden.assertions
   SET description = 'premise: the target machine is ALREADY CLASSIFIED when the run starts (D-07 applied, leg 20)',
       expect      = 'false'
 WHERE fixture_id = 19 AND seq = 1;

UPDATE golden.assertions
   SET description = 'D-07 fail-safe, fleet-wide: no UNCLASSIFIED machine may ever auto-attribute a count rise to venue_fill (S-25 tripwire)',
       expect_op   = 'eq',
       expect      = 'true',
       check_sql   = 'SELECT (NOT EXISTS (SELECT 1 FROM public.machines m JOIN public.v_product_sourcing_current ps ON ps.machine_id = m.machine_id WHERE m.operating_model IS NULL AND public._estimator_rise_disposition_v3(m.machine_id, ps.pod_product_id, ps.boonz_product_id) = ''venue_fill''))::text'
 WHERE fixture_id = 19 AND seq = 4;
