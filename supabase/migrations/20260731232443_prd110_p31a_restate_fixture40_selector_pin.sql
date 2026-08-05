-- PRD-110 leg 76 · RESTATE fixture 40 seq 34 (md5 pin on the P3.1a selector)
--
-- WHY. Fixture 40 seq 34 pins md5(find_substitutes_for_shelf_v3.prosrc) to assert that the
-- P3.1b ladder unit did not edit the P3.1a selector (LAW 3). That purpose is CORRECT and is
-- KEPT. The baseline moved because a DIFFERENT, fixture-proven unit changed the selector:
-- migration 20260731232246 (prd110_p31a_assortment_guardrails_registry) added the standing
-- CS assortment guardrail demanded by fixture 12 (migration 20260731231836), which was RED
-- at 19 pass / 7 fail before the change and is 26/26 after it.
--
-- ⛔ RESTATED, NOT DELETED, NOT WEAKENED. The check_sql is untouched, the operator stays
-- `eq` on a full md5, and the assertion still fails the moment any unit edits the selector
-- without its own fixture. Only the expected baseline moves, and the description now carries
-- the provenance of the move so a later leg does not read this as a silently loosened pin.
--
--   ca7c52f99df518a1933e88db44864e03  (leg 73 baseline)
--   6aa6885ee84688b03fac3a73ed8e8db9  (leg 76, guardrail registry)

DO $restate$
DECLARE v_live text; v_rows int;
BEGIN
  SELECT md5(p.prosrc) INTO v_live
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'find_substitutes_for_shelf_v3';

  -- Refuse to pin a hash that is not what is actually deployed right now.
  IF v_live IS DISTINCT FROM '6aa6885ee84688b03fac3a73ed8e8db9' THEN
    RAISE EXCEPTION 'restate ABORTED: live selector md5 is %, expected 6aa6885ee84688b03fac3a73ed8e8db9', v_live;
  END IF;

  -- Refuse to move a pin that is not the one this file was written for.
  IF NOT EXISTS (SELECT 1 FROM golden.assertions
                  WHERE fixture_id = 40 AND seq = 34
                    AND expect = 'ca7c52f99df518a1933e88db44864e03') THEN
    RAISE EXCEPTION 'restate ABORTED: fixture 40 seq 34 does not hold the expected old baseline';
  END IF;

  UPDATE golden.assertions
     SET expect = '6aa6885ee84688b03fac3a73ed8e8db9',
         description = 'LAW 3: the P3.1a selector find_substitutes_for_shelf_v3 is byte-untouched by THIS unit '
                    || '(the P3.1b ladder). RESTATED at leg 76: the baseline moved '
                    || 'ca7c52f9 -> 6aa6885e by migration 20260731232246, the assortment-guardrail registry '
                    || 'demanded by fixture 12 - a different unit, with its own fixture and its own RED. '
                    || 'The pin is unchanged in purpose and strength: any unit that edits the selector '
                    || 'without its own fixture still fails here.'
   WHERE fixture_id = 40 AND seq = 34;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'restate ABORTED: updated % rows, expected 1', v_rows; END IF;
END $restate$;
