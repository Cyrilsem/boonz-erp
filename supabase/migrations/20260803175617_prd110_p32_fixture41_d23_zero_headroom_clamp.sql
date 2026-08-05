-- PRD-110 · leg 93 · D-23 EXECUTION — "KEEP THE CLAMP" pinned at the boundary that matters.
--
-- CS answered D-23 on 2026-08-01: "KEEP THE CLAMP. dest_capacity_clamp stands; overflow
-- visibly to return_to_wh." Keeping behaviour is only a decision if something PINS it, so
-- this leg executes D-23 as a fixture-only unit. NO engine edit: resolve_m2m_sku_legs_v3 is
-- byte-untouched, which seq 46 (provolatile/prosecdef) and the md5 pins already guard.
--
-- WHAT WAS ACTUALLY MISSING (measured, not assumed, before a line was written):
--   * Fixture 41 anchor A has headroom 9 (no clamp) and anchor B headroom 1 (partial clamp).
--     NOTHING in the suite reaches headroom = 0 — the boundary where "keep the clamp" is most
--     consequential, because it is the case in which the resolver must transfer NOTHING.
--   * `dest_capacity_clamp` appeared as a literal string in ZERO of the 46 assertions. It is
--     pinned INDIRECTLY (totals.clamped_units is a SUM FILTERed on that exact reason, so a
--     rename turns seq 36 red) but never stated at leg grain. Seq 38 only counts DISTINCT
--     return reasons, so on its own it would survive a rename of both.
--
-- ANCHOR C — the OVER-FULL destination, verified by a rolled-back smoke probe first (S-149):
--   golden.pin_machine_stock puts every aisle of MPMCC-1058 at 99 units, so A05 (max_stock 6)
--   reads current_stock 99 through v_shelf_state — the resolver's own view. Raw headroom is
--   -93 and GREATEST(...,0) floors it to 0, so this exercises the OVER-full case, not merely
--   the exactly-full one. Probe result, reproduced here as the expected values below:
--     status=ok · input=14 · transfer=0 · return=14 · clamped=8 · conserved=true · dest_hr=0
--     · transfer legs in the array = 0 · reasons = {dest_capacity_clamp,
--       not_assortable_at_destination}
--
-- WHY THE PIN IS SAFE ON A LIVE WEIMI OBSERVATION (the reason this is not LAW 12 drift):
--   golden.run_fixture executes scenario_sql inside a plpgsql BEGIN...EXCEPTION block. That is
--   a subtransaction: if ANY statement between the pin and the restore raises, the whole
--   scenario — pin included — is rolled back and never commits. So the fixture-3 idiom
--   (pin -> work -> restore, ONE DO block, NO inner handler) is exactly right, and adding an
--   inner handler would make it WORSE by letting execution continue past a failed restore.
--   Verified empirically: the smoke probe raised at the end and left 0 rows in
--   golden.weimi_pin_backup, 0 unfinished golden.runs, and A05 back at current_stock 5.
--   Anchors A and B are captured into scratch BEFORE this block, so the pin cannot move them.

-- ---------------------------------------------------------------------------------------
-- (1) SCENARIO: append anchor C. Appended, never rewritten, so the existing anchors and
--     every number the 46 live assertions read stay byte-identical.
-- ---------------------------------------------------------------------------------------
UPDATE golden.fixtures
   SET scenario_sql = scenario_sql || $ANCHORC$

-- ---------------------------------------------------------------------------
-- (3) ANCHOR C -- D-23: THE ZERO-HEADROOM BOUNDARY. Pin -> call -> restore in ONE
--     DO block with NO inner exception handler (fixture 3 / S-34 idiom): if anything
--     raises, run_fixture's own EXCEPTION block rolls the pin back with the scenario.
--     Guarded by to_regprocedure so a RED baseline still completes, matching (2) above.
-- ---------------------------------------------------------------------------
DO $do2$
DECLARE v_m uuid := '9acce2bf-0e65-48f4-bf44-cefa0326f2c5';
BEGIN
  IF to_regprocedure('public.resolve_m2m_sku_legs_v3(uuid,uuid,jsonb)') IS NOT NULL THEN

    -- Cody R2: the PRE-PIN live value, captured before anything is touched. The residue
    -- proofs below compare against THIS rather than against a hardcoded stock level, so
    -- they stay red only for actual residue and never for an ordinary sale or refill.
    INSERT INTO golden.scratch (fixture_id, key, value)
    SELECT 41, 'pre_pin', jsonb_build_object(
             'dstB_current',  s.current_stock,
             'dstB_headroom', GREATEST(s.max_stock - s.current_stock, 0))
      FROM public.v_shelf_state s
     WHERE s.shelf_id = '81820a63-8272-485e-bab8-5793d212b297';

    PERFORM golden.pin_machine_stock(v_m, 99);

    -- The pinned precondition, read through the SAME view the resolver reads. If the pin
    -- ever stops landing, seq 48/49/50 say so instead of anchor C quietly becoming anchor B.
    INSERT INTO golden.scratch (fixture_id, key, value)
    SELECT 41, 'pop_C', jsonb_build_object(
             'dstC_current',          s.current_stock,
             'dstC_max',              s.max_stock,
             'dstC_headroom_raw',     (s.max_stock - s.current_stock),
             'dstC_headroom_floored', GREATEST(s.max_stock - s.current_stock, 0))
      FROM public.v_shelf_state s
     WHERE s.shelf_id = '81820a63-8272-485e-bab8-5793d212b297';

    -- Same 7-SKU / 14-unit input as anchors A and B, so anchor C differs in ONE variable.
    INSERT INTO golden.scratch (fixture_id, key, value)
    SELECT 41, 'legs_C',
           public.resolve_m2m_sku_legs_v3(
             '31894963-0ef0-44f2-9970-773a2836b9bf'::uuid,
             '81820a63-8272-485e-bab8-5793d212b297'::uuid,
             $lines2$[
               {"boonz_product_id":"4678bf8c-e3d3-47e0-87ac-84f654508944","qty":2},
               {"boonz_product_id":"60b527c9-05db-45f7-a130-b01b3bf6abbd","qty":2},
               {"boonz_product_id":"167b0d57-4c24-4502-bb81-ee852a4d5d5f","qty":2},
               {"boonz_product_id":"1bc836b3-c881-4da5-898b-2d4e152776fe","qty":2},
               {"boonz_product_id":"9f47ace5-0577-44b9-b058-438dbb8e306b","qty":2},
               {"boonz_product_id":"51c132ff-7d8e-463a-9324-03903105da4c","qty":2},
               {"boonz_product_id":"9f098f7d-2ec6-4c0a-b858-595030d544df","qty":2}
             ]$lines2$::jsonb);

    PERFORM golden.restore_machine_stock(v_m);

    -- Restore proof, through the same view again. golden.restore_machine_stock already
    -- self-verifies its total, but that is the harness checking itself; seq 61/62 make the
    -- FIXTURE state the live value it handed back, so residue cannot pass silently.
    INSERT INTO golden.scratch (fixture_id, key, value)
    SELECT 41, 'post_restore', jsonb_build_object(
             'dstB_current',  s.current_stock,
             'dstB_headroom', GREATEST(s.max_stock - s.current_stock, 0))
      FROM public.v_shelf_state s
     WHERE s.shelf_id = '81820a63-8272-485e-bab8-5793d212b297';

  END IF;
END
$do2$;
$ANCHORC$,
       notes = notes || ' D-23 (CS 2026-08-01: KEEP THE CLAMP): anchor C adds the zero-headroom boundary via golden.pin_machine_stock(MPMCC-1058, 99) -> A05 reads 99/6 so headroom floors to 0. Pin and restore live inside run_fixture''s scenario subtransaction, so a mid-scenario raise rolls the pin back rather than leaving a live WEIMI observation modified.'
 WHERE fixture_id = 41
   -- Cody R1: guard the append. Forward-only does not imply re-application-safe: a second
   -- append would run pin/restore twice and the second restore would raise "no pin backup".
   AND position('legs_C' in scenario_sql) = 0;

-- ---------------------------------------------------------------------------------------
-- (2) ASSERTIONS 47-63.
-- ---------------------------------------------------------------------------------------
INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES

(41, 47, 'Anchor C produced a result at all (RED tripwire: this is what fails if the pin, the restore or the resolver is absent)',
 $q$SELECT count(*)::text FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', '1', true, 'P3'),

(41, 48, 'PIN LANDED in the resolver''s OWN view: the destination reads 99 units. Without this, anchor C would silently degrade into a second copy of anchor B and still look green',
 $q$SELECT value->>'dstC_current' FROM golden.scratch WHERE fixture_id=41 AND key='pop_C'$q$,
 'eq', '99', true, 'P3'),

(41, 49, 'THE BOUNDARY IS GENUINELY OVER-FULL, not merely exactly full: raw max-current is NEGATIVE, so the GREATEST(...,0) floor is load-bearing rather than cosmetic. Asserted as < 0 rather than = -93 because -93 encodes max_stock 6, which is ordinary configuration and may legitimately change (Cody R3)',
 $q$SELECT value->>'dstC_headroom_raw' FROM golden.scratch WHERE fixture_id=41 AND key='pop_C'$q$,
 'lt', '0', true, 'P3'),

(41, 50, 'Anchor C precondition: floored headroom is exactly 0',
 $q$SELECT value->>'dstC_headroom_floored' FROM golden.scratch WHERE fixture_id=41 AND key='pop_C'$q$,
 'eq', '0', true, 'P3'),

(41, 51, 'A completely full destination is a legitimate ANSWER, not an error: anchor C still reports status ok',
 $q$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', 'ok', true, 'P3'),

(41, 52, 'Anchor C still accounts for all 14 input units at the boundary',
 $q$SELECT value#>>'{totals,input_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', '14', true, 'P3'),

(41, 53, 'D-23 CORE (CS: KEEP THE CLAMP): with zero headroom NOTHING crosses - transfer_units is 0. Deleting the LEAST(...,headroom) term makes this 8 and turns this assertion red',
 $q$SELECT value#>>'{totals,transfer_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', '0', true, 'P3'),

(41, 54, 'LAW 5 AT THE BOUNDARY: the legs array contains ZERO transfer legs. The resolver OMITS the leg entirely rather than emitting a transfer carrying qty 0 - silent qty-0 is a build failure, and a 0-unit transfer leg is exactly that',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_C' AND l->>'leg'='transfer'$q$,
 'eq', '0', true, 'P3'),

(41, 55, 'D-23 SECOND HALF (CS: overflow VISIBLY to return_to_wh): all 14 units take a return leg, none are dropped',
 $q$SELECT value#>>'{totals,return_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', '14', true, 'P3'),

(41, 56, 'Anchor C clamps the WHOLE eligible Krambals set: 8 units, versus 7 at anchor B where 1 unit of headroom existed',
 $q$SELECT value#>>'{totals,clamped_units}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', '8', true, 'P3'),

(41, 57, 'Anchor C conserves exactly even when the transfer set is empty',
 $q$SELECT value#>>'{totals,conserved}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', 'true', true, 'P3'),

(41, 58, 'D-23 LITERAL PIN at anchor C: the 8 clamped units sit on return_to_wh legs whose reason is EXACTLY the string dest_capacity_clamp',
 $q$SELECT COALESCE(sum((l->>'qty')::int),0)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_C'
      AND l->>'leg'='return_to_wh' AND l->>'reason'='dest_capacity_clamp'$q$,
 'eq', '8', true, 'P3'),

(41, 59, 'THE TWO REASONS STAY UNCONFLATED AT THE BOUNDARY: the 6 non-assortable Zigi units keep their own reason even when every eligible unit also clamped',
 $q$SELECT COALESCE(sum((l->>'qty')::int),0)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_C'
      AND l->>'leg'='return_to_wh' AND l->>'reason'='not_assortable_at_destination'$q$,
 'eq', '6', true, 'P3'),

(41, 60, 'Anchor C reports the zero headroom it clamped to, so the reason for an all-return plan is legible without re-deriving it',
 $q$SELECT value#>>'{dest,headroom}' FROM golden.scratch WHERE fixture_id=41 AND key='legs_C'$q$,
 'eq', '0', true, 'P3'),

(41, 61, 'RESIDUE PROOF: after restore the destination reads back the EXACT stock it held before the pin - the fixture hands the live WEIMI observation back as it found it. Compared against the pre-pin capture, not a hardcoded level, so an ordinary sale or refill can never redden a residue proof (Cody R2)',
 $q$SELECT ((SELECT value->>'dstB_current' FROM golden.scratch WHERE fixture_id=41 AND key='post_restore')
         = (SELECT value->>'dstB_current' FROM golden.scratch WHERE fixture_id=41 AND key='pre_pin'))::text$q$,
 'eq', 'true', true, 'P3'),

(41, 62, 'RESIDUE PROOF: anchor B''s headroom is restored to its pre-pin value - the same quantity seq 19 and seq 39 depend on, so a leaked pin would redden them too rather than silently rebaselining them',
 $q$SELECT ((SELECT value->>'dstB_headroom' FROM golden.scratch WHERE fixture_id=41 AND key='post_restore')
         = (SELECT value->>'dstB_headroom' FROM golden.scratch WHERE fixture_id=41 AND key='pre_pin'))::text$q$,
 'eq', 'true', true, 'P3'),

(41, 63, 'D-23 LITERAL PIN at anchor B: the 7 clamped units are labelled EXACTLY dest_capacity_clamp at LEG grain. Seq 36 pins the same string only indirectly (totals.clamped_units is a SUM FILTERed on it) and seq 38 merely counts DISTINCT reasons, so neither states it at leg grain',
 $q$SELECT COALESCE(sum((l->>'qty')::int),0)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') l
    WHERE s.fixture_id=41 AND s.key='legs_B'
      AND l->>'leg'='return_to_wh' AND l->>'reason'='dest_capacity_clamp'$q$,
 'eq', '7', true, 'P3');
