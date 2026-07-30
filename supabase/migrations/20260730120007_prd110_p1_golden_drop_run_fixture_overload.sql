-- PRD-110 STEP 1 fix. Applied via MCP as `prd110_p1_golden_drop_run_fixture_overload` 2026-07-30.
-- Adding p_max_phase in 20260730120004 created an OVERLOAD rather than a replacement:
-- golden.run_fixture(int,text) [old] and golden.run_fixture(int,text,text) [new, 3rd arg
-- defaulted] both matched a 2-arg call, so golden.run_all() failed with
--   42725: function golden.run_fixture(integer, text) is not unique
--
-- SAME defect class this loop flagged when hardening seed_missing_slot_lifecycle (Wave-2
-- closeout lesson: "check pronargdefaults on overload changes") — walked into on the harness's
-- own function. Recorded rather than quietly patched.
--
-- Safe to DROP outright (no Article 13 window): the 2-arg form was created hours earlier in the
-- same session, is harness-internal, and had no caller outside golden.run_all.

DROP FUNCTION IF EXISTS golden.run_fixture(int, text);

DO $$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'golden' AND p.proname = 'run_fixture';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'golden.run_fixture must have exactly 1 signature, found %', v_n;
  END IF;
END $$;
