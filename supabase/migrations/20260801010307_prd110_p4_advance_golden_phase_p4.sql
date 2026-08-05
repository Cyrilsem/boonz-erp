SET LOCAL statement_timeout = '30s';
-- PRD-110 leg 79: the Phase 3 gate is DECLARED (fixtures 1·41·11·12·40·50,
-- 275 assertions, 0 reds, all re-measured at one DB state). Advance the harness.
-- ⭐ Verified INERT before flipping: the only enabled P4/P5 assertions in the
-- suite are fixture 55's own 26, so this activates nothing that was sleeping.
-- (Leg 55's P3 flip was inert for the same reason and for the same checked cause.)
UPDATE golden.config
   SET current_phase = 'P4',
       updated_at = now(),
       note = 'PRD-110 leg 79: Phase 3 CLOSED and checkpointed - gate 1/41/11/12/40/50 re-measured green at one DB state (275 assertions, 0 reds). Advancing to P4 (P4.1 feedback ledger + P4.2 planning pins, fixture 55).'
 WHERE id = 1;

DO $guard$
DECLARE v text;
BEGIN
  SELECT current_phase INTO v FROM golden.config WHERE id = 1;
  IF v <> 'P4' THEN RAISE EXCEPTION 'phase flip did not land: %', v; END IF;
  IF golden.phase_rank('P4') IS NULL THEN RAISE EXCEPTION 'phase_rank does not know P4'; END IF;
  RAISE NOTICE 'golden.config now %', v;
END
$guard$;
