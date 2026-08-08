-- PRD-110 · leg 162 · fixture 76 date fix — S-317
--
-- ⛔⛔ S-317. `golden.fixtures.plan_date` IS NOT THE DATE THE SCENARIO RUNS ON.
--    `golden.render` substitutes `{{plan_date}}` with
--        quote_literal((DATE '2030-01-01' + p_fixture_id)::text) || '::date'
--    i.e. the date is ALLOCATED FROM THE FIXTURE ID, and the `plan_date` COLUMN is
--    never read by the harness at all. 22 of the enabled fixtures already carry a
--    `plan_date` column that disagrees with the date their scenario actually uses.
--
-- HOW IT BIT: fixture 76 (20260809020000) declared `plan_date = 2030-03-11` and then
--    mixed `{{plan_date}}` (which rendered 2030-03-18) with hand-written
--    `DATE '2030-03-11'` literals inside its DO blocks. The base run and probe B's
--    late base landed on 2030-03-18; `compose_plan_with_edits_v3` and every stitch
--    probe looked at 2030-03-11 and found nothing. The RED fire came back
--    15 pass / 14 fail with FIVE of the failures being PREMISE assertions
--    (seq 11, 12, 60, 61, 62) — which, per the standing rule that every premise must
--    pass in the red run, makes the red meaningless rather than merely noisy.
--
-- ⭐ THE FIX IS TO STOP HAND-WRITING THE PRIMARY DATE AT ALL. Every occurrence of the
--    primary date becomes `{{plan_date}}`, so the harness's allocator is the single
--    source of that date and the two can never diverge again. The `plan_date` COLUMN
--    is corrected to 2030-03-18 so a human reading the row is not misled.
--
-- ⛔ The three AUXILIARY dates cannot use the allocator (a fixture gets exactly one
--    allocated date), so they are moved OFF the allocator's range entirely —
--    2030-01-01 + 112 = 2030-04-23 is the furthest any fixture id can reach today, and
--    2030-03-12/13/14 sit inside it, one slot away from a future fixture 77/78/79.
--    They become 2030-07-02 / 07-03 / 07-04, verified free of every
--    pod_refills_shadow, refill_plan_output_shadow, plan_edits_v3 and fixture-scenario
--    reference at authoring time.
--
-- Article 12: forward-only. 20260809020000 is not edited; this migration corrects it.

BEGIN;

DO $guard$
DECLARE v_sql text; v_pd date;
BEGIN
  SELECT scenario_sql, plan_date INTO v_sql, v_pd FROM golden.fixtures WHERE fixture_id = 76;
  IF v_sql IS NULL THEN
    RAISE EXCEPTION 'S-317: fixture 76 does not exist - 20260809020000 was not applied';
  END IF;
  IF v_pd <> DATE '2030-03-11' THEN
    RAISE EXCEPTION 'S-317: fixture 76 plan_date is %, not the 2030-03-11 this file corrects', v_pd;
  END IF;
  IF position('2030-03-11' in v_sql) = 0 THEN
    RAISE EXCEPTION 'S-317: fixture 76 carries no 2030-03-11 literal - already fixed, or not the reviewed body';
  END IF;

  -- The allocator's answer for THIS fixture id, re-derived rather than trusted.
  IF (DATE '2030-01-01' + 76) <> DATE '2030-03-18' THEN
    RAISE EXCEPTION 'S-317: the allocator no longer yields 2030-03-18 for fixture 76';
  END IF;

  -- The auxiliary dates must still be free. A fixture that plants on a date another
  -- fixture already uses is the S-311 class of failure, self-inflicted.
  IF EXISTS (SELECT 1 FROM public.pod_refills_shadow
              WHERE plan_date IN (DATE '2030-07-02', DATE '2030-07-03', DATE '2030-07-04'))
     OR EXISTS (SELECT 1 FROM public.plan_edits_v3
                 WHERE plan_date IN (DATE '2030-07-02', DATE '2030-07-03', DATE '2030-07-04'))
     OR EXISTS (SELECT 1 FROM golden.fixtures
                 WHERE fixture_id <> 76
                   AND (scenario_sql LIKE '%2030-07-02%' OR scenario_sql LIKE '%2030-07-03%'
                     OR scenario_sql LIKE '%2030-07-04%')) THEN
    RAISE EXCEPTION 'S-317: one of 2030-07-02/03/04 is no longer free';
  END IF;
END
$guard$;

UPDATE golden.fixtures
   SET scenario_sql =
         replace(
           replace(
             replace(
               replace(scenario_sql, 'DATE ''2030-03-11''', '{{plan_date}}'),
               'DATE ''2030-03-12''', 'DATE ''2030-07-02'''),
             'DATE ''2030-03-13''', 'DATE ''2030-07-03'''),
           'DATE ''2030-03-14''', 'DATE ''2030-07-04'''),
       plan_date = DATE '2030-03-18',
       source_incident = source_incident ||
         ' | S-317: golden.render allocates the scenario date as (2030-01-01 + fixture_id) = 2030-03-18;'
         ' the plan_date column is NOT read by the harness. Primary date is {{plan_date}} only.'
 WHERE fixture_id = 76;

DO $post$
DECLARE v_sql text; v_pd date;
BEGIN
  SELECT scenario_sql, plan_date INTO v_sql, v_pd FROM golden.fixtures WHERE fixture_id = 76;

  IF position('2030-03-11' in v_sql) > 0 THEN
    RAISE EXCEPTION 'S-317: a 2030-03-11 literal survived the replacement';
  END IF;
  IF position('2030-03-12' in v_sql) > 0 OR position('2030-03-13' in v_sql) > 0
     OR position('2030-03-14' in v_sql) > 0 THEN
    RAISE EXCEPTION 'S-317: an in-allocator-range auxiliary date survived the replacement';
  END IF;
  IF v_pd <> DATE '2030-03-18' THEN
    RAISE EXCEPTION 'S-317: plan_date column not corrected, reads %', v_pd;
  END IF;

  -- the replacements actually landed somewhere, rather than matching nothing
  IF position('2030-07-02' in v_sql) = 0 THEN RAISE EXCEPTION 'S-317: uncomposed_edits date missing'; END IF;
  IF position('2030-07-03' in v_sql) = 0 THEN RAISE EXCEPTION 'S-317: uncomposed_fallback date missing'; END IF;
  IF position('2030-07-04' in v_sql) = 0 THEN RAISE EXCEPTION 'S-317: empty-date probe date missing'; END IF;

  -- ⭐ the primary date must now appear ONLY through the allocator token. Six sites:
  --    section 3's record_plan_edit_v3 + compose, probe A's stitch, probe B's insert
  --    (already a token), probe E's explicit stitch, plus the two tripwire captures
  --    and section 2's base insert.
  IF (length(v_sql) - length(replace(v_sql, '{{plan_date}}', ''))) / length('{{plan_date}}') < 8 THEN
    RAISE EXCEPTION 'S-317: fewer {{plan_date}} tokens than the eight sites the primary date occupies';
  END IF;

  -- and the rendered form must be the allocator's date, proven by rendering it
  IF position('''2030-03-18''::date' in golden.render(v_sql, 76)) = 0 THEN
    RAISE EXCEPTION 'S-317: the rendered scenario does not carry 2030-03-18';
  END IF;
END
$post$;

COMMIT;
