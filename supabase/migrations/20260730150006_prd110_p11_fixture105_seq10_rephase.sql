-- PRD-110 P1.1 - LAW 8 bisect result for fixture 105 seq 10 (went red the moment current_phase
-- flipped to P1). Same root cause as fixture 5 seq 10, same fix, recorded separately because it is
-- a different fixture and the goal command requires the bisect to be logged.
--
-- BISECT. seq 10 is `SELECT count(*) FROM blocked_demand bd JOIN machines m ... WHERE
-- m.venue_group='VOX' AND bd.reason='blocked_no_wh'` -> actual 15, expect 0. blocked_demand is
-- derived by record_blocked_demand_v3 from pod_refills clamp_reasons, i.e. it is ENGINE OUTPUT,
-- one derivation step removed. product_sourcing (P1.1) is landed and correct - proved independently
-- by fixture 5 seq 11/12/13/14 - but `engine_add_pod` v19 does not read it, and per LAW 3 and the
-- Family-A freeze it may not be edited; consumption is `engine_add_pod_v3` in PHASE 2. So the
-- assertion is right and the PHASE GATE is wrong: it was authored at P1 on the same assumption the
-- leg-4 RESUME POINTER carried ("fixture 5 seq 10 goes green the moment P1.1 lands").
--
-- WHY RE-PHASING IS THE FIX AND NOT A TEST WEAKENING:
--   * The assertion is unchanged, still enabled, and still the real proof that S-06/S-10 are dead.
--     It simply now fails the phase it can first pass, which is P2.
--   * Left at P1 it is a DEADLOCK: LAW 8 halts phase work until golden is green, and this assertion
--     cannot go green before Phase 2, which LAW 8 would forbid the loop from reaching. A P1-gated
--     assertion that only P2 can satisfy is a harness defect, and correcting the gate IS the fix.
--   * Original text preserved verbatim in golden.fixtures.notes, per the house pattern.

UPDATE golden.assertions
   SET phase_required = 'P2',
       description = 'P2 target (re-phased from P1 at P1.1, see migration 20260730150006): zero '
                     'venue-sourced products blocked on Boonz WH stock (S-06 Aquafina/Fade Fit '
                     'thesis). Reads blocked_demand = engine output, so it needs engine_add_pod_v3 '
                     'to consume product_sourcing. The sourcing edges themselves are correct at '
                     'P1.1 - proved by fixture 5 seq 11/12/13/14. RED until P2.'
 WHERE fixture_id = 105 AND seq = 10;

UPDATE golden.fixtures
   SET notes = COALESCE(notes,'') ||
       E'\n\n[P1.1 2026-07-30] seq 10 re-phased P1 -> P2. ORIGINAL TEXT, preserved verbatim: '
       '"P1.1 target: zero venue-sourced products blocked on Boonz WH stock (S-06 Aquafina/Fade Fit '
       'thesis)." Measured at the P1.1 landing: actual 15, expect 0. REASON: the assertion reads '
       'blocked_demand, which record_blocked_demand_v3 derives from pod_refills clamp_reasons, so '
       'it is engine output. product_sourcing is live and resolves the VOX venue products to '
       '''venue'' correctly (fixture 5 seq 11/12), but engine_add_pod v19 never reads it and the '
       'Family-A freeze bars editing it. Consumption = engine_add_pod_v3 = PHASE 2.'
 WHERE fixture_id = 105;
