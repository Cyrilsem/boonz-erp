-- PRD-110 · P2.0c · authored relay leg 26 · CORRECTED AND APPLIED relay leg 31
-- Re-express the EIGHT gated Phase-2 acceptance assertions against the SHADOW objects.
--
-- ⚠️ LEG-31 CORRECTIONS. This file sat unapplied for five legs and AGED against a live
--    baseline (S-30's own lesson, and S-36's twin). Five defects were found by reading it
--    in full against live state; any one of them breaks the apply or reds a correct engine:
--      1. Guard 7h hardcoded 233 = 224 + 9. Live is 229 (leg 28 added five). The file would
--         have rolled ITSELF back. Corrected to 238 = 229 + 9.
--      2. It predates fixture 14 seq 33 (leg 28's S-05 sub-capacity mirror). That is the
--         EIGHTH gated criterion; it is now re-expressed here and guards 7d/7e/7f are 8, not 7.
--      3. It predates leg 28's S-34 pin and appended the v3 call AFTER the pin envelope on
--         fixtures 3 and 5 - v19 would plan a pinned machine and v3 a restored one. Section 3
--         is now split 3a/3b and guard 7b2 proves the v3 call precedes the restore.
--      4. S-30's own prescribed anchor for correction 3 ('PERFORM golden.restore_machine_stock(v_m);')
--         does not exist in fixture 5, which restores three machines in a FOR loop. That
--         replace() would have silently no-op'd and guard 7b would have rolled the migration
--         back. The v19 call is the anchor instead - measured present exactly once in both.
--      5. Fixture 105 seq 10 filtered on the MACHINE's venue_group as a proxy for
--         "venue-sourced". P1.1 retired that proxy and a LAW-5-compliant engine would have
--         been red for obeying the law (S-36). Re-scoped to the sourcing edge.
--    Applied in ONE atomic unit with public.engine_add_pod_v3 (leg 31), because the eight
--    criteria arm the instant the engine exists.
--    A sixth item came out of the leg-31 Cody pass, and it is an ADDITION rather than a
--    correction: ADR-shadow-plan-tables §8 obligation 3 requires the "pod_refill_plan row
--    count unchanged across any v3 shadow run" tripwire on EVERY Phase-2 fixture. It rode on
--    fixture 14 only. Fixtures 3, 5 and 105 become v3-running fixtures the moment this file
--    lands, so seq 86 now carries that proof on all four. Coverage therefore moves +13, not +9.
--
-- WHY (leg-25 pointer item 2, and S-19's leg-24 lesson):
--   The eight assertions that arm on EXISTS(pg_proc WHERE proname='engine_add_pod_v3')
--   read the LIVE public.pod_refills / public.blocked_demand. But v3 writes
--   public.pod_refills_shadow (LAW 4 - shadow, don't switch). Creating the engine without
--   re-expressing them first makes the suite genuinely red for a reason the engine is not
--   at fault for, and LAW 8 would send the next leg bisecting a blameless engine.
--   This migration is the "option (a)" atomic unit the pointer recommended: re-express
--   FIRST, engine SECOND.
--
-- WHAT THIS IS NOT: it does not create engine_add_pod_v3 and it does not change any
--   engine behaviour. Every one of the eight stays gated on the same pg_proc predicate and
--   stays expected-red until the engine exists.
--
-- THREE THINGS BEYOND THE MECHANICAL SWAP, each of which is required and none optional:
--
--   1. VACUOUS-GREEN GUARD (S-29 / RISK 75). Five of the eight are "count of violations = 0".
--      Pointed at an empty shadow table they would report a PASS - the harness would record
--      "P2's Fade Fit target already met" while nothing had run. Every re-expressed assertion
--      therefore returns the sentinel '-1' when this fixture has no v3 run of its own, which
--      fails eq-0 and gt-0 alike. This is the same defect class leg 25 closed with seq 89;
--      shipping the swap without it would re-open it one migration later.
--
--   2. seq 88 - RUN-TIME PREMISE (RISK 75's standing rule: "any fixture that calls a live
--      writer must assert that its OWN call did work, before asserting anything about what
--      the call produced"). seq 89 is reserved for the estimator's version of this premise;
--      seq 88 is now the reserved sequence for the v3 engine's. It is deliberately
--      self-diagnosing: it reports 'helper_never_ran' / 'engine_error: <SQLERRM>' /
--      'no_run_id_returned' rather than a bare number, so a bisecting leg reads the cause
--      on line one.
--
--   3. seq 87 - LAW 4 TRIPWIRE. ADR 8.3 already rides as seq 91 (pod_refill_plan) and seq 97
--      (blocked_demand). public.pod_refills is the live table the v3 engine is most likely to
--      write by mistake, because it is the one v19 writes and the one the eight used to read.
--      seq 87 pins the live row count at this plan_date across the v3 call. v19 legitimately
--      writes that date, so the count is captured INSIDE the helper after v19 and before v3 -
--      an absolute count would have been meaningless here.
--
-- SCOPE DISCIPLINE: seq 4 on fixture 3 is currently a genuine green (it "arrived early" -
--   v19 already fills the empty A07). Re-pointing it at the shadow would silently delete a
--   true, currently-proven fact about the live engine. The v19 claim is therefore PRESERVED
--   verbatim as new non-gated fixture-3 seq 7, so coverage never drops (the rule the leg-22
--   run_all phase-gate migration exists to enforce).
--
-- CONTRACT THIS PLACES ON engine_add_pod_v3 (binding on the leg that builds it):
--   * signature  engine_add_pod_v3(p_plan_date date, p_days_cover integer) RETURNS jsonb
--   * the returned jsonb MUST carry 'run_id' - it is how every acceptance assertion scopes
--     itself to its own run. pod_refills_shadow is append-only (tg_pod_refills_shadow_append_only
--     refuses UPDATE and DELETE), so a fixture cannot clear the table between runs and MUST
--     scope by run_id. "Latest row at this plan_date" is not an acceptable substitute.
--   * it MUST write reasoning->>'need_raw' on every line, or v_blocked_demand_shadow_v3
--     derives nothing and fixture 105 seq 10 can never go green.
--   * it MUST NOT write public.pod_refills (seq 87).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. golden.v3_run_id - the run this fixture produced, or NULL if it produced none.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION golden.v3_run_id(p_fixture_id integer)
RETURNS uuid
LANGUAGE sql
STABLE
AS $fn$
  SELECT NULLIF(value ->> 'run_id', '')::uuid
  FROM golden.scratch
  WHERE fixture_id = p_fixture_id AND key = 'engine_v3'
$fn$;

COMMENT ON FUNCTION golden.v3_run_id(integer) IS
  'PRD-110 P2.0c: the engine_add_pod_v3 run_id this fixture produced, NULL if engine_add_pod_v3 '
  'does not exist yet or the call failed. Every gated P2 acceptance assertion scopes itself by '
  'this value; pod_refills_shadow is append-only so run_id is the only honest scope.';

-- ---------------------------------------------------------------------------
-- 2. golden.run_engine_v3_if_built - invoke v3 only once it has been built.
--    Lets the re-expression ship BEFORE the engine without breaking any fixture.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION golden.run_engine_v3_if_built(
  p_fixture_id  integer,
  p_plan_date   date,
  p_days_cover  integer DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_res         jsonb;
  v_live_before integer;
  v_prp_before  integer;
BEGIN
  -- Captured AFTER the fixture's v19 call and BEFORE v3, so seq 87 measures v3 alone.
  SELECT count(*) INTO v_live_before
  FROM public.pod_refills WHERE plan_date = p_plan_date;

  -- ADR-shadow-plan-tables §8 obligation 3 (added leg 31 at Cody review): "a golden assertion
  -- that pod_refill_plan row count is unchanged across any v3 shadow run ... belongs on every
  -- Phase-2 fixture". It rode on fixture 14 only (seq 91, off fixture 14's own 'before' scratch
  -- key, which fixtures 3/5/105 do not have). Capturing it here gives all four the same proof
  -- off one mechanism. ABSOLUTE, not scoped to plan_date: no fixture in this suite calls stitch
  -- or commit, so nothing may write this table at all.
  SELECT count(*) INTO v_prp_before FROM public.pod_refill_plan;

  IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'engine_add_pod_v3')
  THEN
    v_res := jsonb_build_object('built', false);
  ELSE
    -- The error is captured rather than propagated ON PURPOSE. Letting it escape would
    -- abort the whole rendered scenario in run_fixture's subtransaction, rolling back the
    -- v19 call too, and every unrelated assertion would go red with no usable cause.
    -- Captured, the fixture stays diagnostic: seq 88 fails and names the SQLERRM.
    BEGIN
      EXECUTE format('SELECT public.engine_add_pod_v3(%L::date, %s)', p_plan_date, p_days_cover)
        INTO v_res;
      v_res := COALESCE(v_res, '{}'::jsonb) || jsonb_build_object('built', true);
    EXCEPTION WHEN OTHERS THEN
      v_res := jsonb_build_object('built', true, 'error', SQLERRM);
    END;
  END IF;

  v_res := v_res || jsonb_build_object('pr_live_before',  v_live_before,
                                       'prp_live_before', v_prp_before);

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (p_fixture_id, 'engine_v3', v_res)
  ON CONFLICT (fixture_id, key) DO UPDATE
    SET value = EXCLUDED.value, written_at = now();

  RETURN v_res;
END
$fn$;

COMMENT ON FUNCTION golden.run_engine_v3_if_built(integer, date, integer) IS
  'PRD-110 P2.0c: calls public.engine_add_pod_v3 if it exists, records the result (and the '
  'pre-call live pod_refills count for this plan_date) in golden.scratch key ''engine_v3''. '
  'A no-op that writes {"built": false} while the engine does not exist, so the eight gated '
  'P2 acceptance assertions can be re-expressed on the shadow objects BEFORE the engine lands.';

-- ---------------------------------------------------------------------------
-- 3. Wire the helper into the four engine-running fixtures (3, 5, 14, 105).
--    The v19 call and every existing assertion are untouched - the helper is ADDED,
--    never substituted. But WHERE it is added is not uniform, and that is S-30
--    correction 3 (leg 31):
--
--    * Fixtures 3 and 5 PIN their machines to stock 0 (S-34, leg 28) and restore them
--      before the transaction ends. Appending the v3 call to the END of scenario_sql
--      would run v19 against a PINNED machine and v3 against a RESTORED one. Every
--      shadow-vs-live diff would then be noise, which defeats LAW 4's entire purpose,
--      and fixture 3 seq 4's "empty A07" premise (A07 is really 3/6) would hold only
--      for v19. The v3 call must sit INSIDE the pin envelope, beside the v19 call.
--    * Fixtures 14 and 105 do not pin. Appending is correct for them, and only them.
--
--    ANCHOR NOTE (leg 31, measured - the PARKING-LOT's own prescription was wrong here):
--    S-30's recommended fix anchored on 'PERFORM golden.restore_machine_stock(v_m);'.
--    Fixture 3 has exactly that string; FIXTURE 5 DOES NOT - it restores three machines
--    in a FOR loop ('PERFORM golden.restore_machine_stock(r.machine_id); END LOOP;').
--    That replace() would have been a silent no-op on fixture 5 and guard 7b would have
--    rolled the whole migration back. Both pinning fixtures DO carry exactly one
--    'PERFORM public.engine_add_pod({{plan_date}}, 7);', so the v19 call is the anchor.
-- ---------------------------------------------------------------------------

-- 3a. Pinning fixtures (3, 5): v3 runs on the SAME pinned state as v19.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
         'PERFORM public.engine_add_pod({{plan_date}}, 7);',
         'PERFORM public.engine_add_pod({{plan_date}}, 7);'
         || E'\n  -- PRD-110 P2.0c: v3 runs INSIDE the pin envelope, on the state v19 just planned.\n'
         || '  PERFORM golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 7);')
 WHERE fixture_id IN (3, 5)
   AND scenario_sql NOT LIKE '%run_engine_v3_if_built%';

-- 3b. Non-pinning fixtures (14, 105): appended at the end, after the v19 call.
UPDATE golden.fixtures
   SET scenario_sql = scenario_sql ||
E'\n-- PRD-110 P2.0c: run the v3 engine into the shadow tables once it exists (no-op until then).\nSELECT golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 7);\n'
 WHERE fixture_id IN (14, 105)
   AND scenario_sql NOT LIKE '%run_engine_v3_if_built%';

-- ---------------------------------------------------------------------------
-- 4. Re-express the eight. Same seq, same gate, same intent - new subject.
-- ---------------------------------------------------------------------------

-- fixture 3 seq 1 · G3 coverage on the shadow plan
UPDATE golden.assertions SET
  description = 'G3 coverage (v3, SHADOW): every sub-capacity shelf with a live WEIMI slot has a plan line in this fixture''s own engine_add_pod_v3 run (0 uncovered)',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT count(*) FROM public.shelf_configurations sc
    JOIN public.machines m ON m.machine_id = sc.machine_id
    JOIN public.v_shelf_slot_identity si ON si.shelf_id = sc.shelf_id
    WHERE m.official_name = 'MPMCC-1058-0000-R0' AND sc.is_phantom = false
      AND si.current_stock < si.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills_shadow prs
                      WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
                        AND prs.plan_date = {{plan_date}} AND prs.shelf_id = sc.shelf_id)
  )::text END$sql$
WHERE fixture_id = 3 AND seq = 1;

-- fixture 3 seq 4 · P2.5 unconditional floor on the shadow plan
UPDATE golden.assertions SET
  description = 'P2.5 unconditional floor (v3, SHADOW): empty A07 (stock 0) receives a qty>0 line in this fixture''s own engine_add_pod_v3 run',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT COALESCE(max(prs.qty), 0) FROM public.pod_refills_shadow prs
    JOIN public.shelf_configurations sc ON sc.shelf_id = prs.shelf_id
    WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
      AND prs.plan_date = {{plan_date}} AND sc.shelf_code = 'A07'
  )::text END$sql$
WHERE fixture_id = 3 AND seq = 4;

-- fixture 5 seq 10 · venue-sourced never blocks, on the shadow plan
UPDATE golden.assertions SET
  description = 'P2 TARGET (v3, SHADOW): zero Fade Fit lines clamped blocked_no_wh in this fixture''s own engine_add_pod_v3 run, incl. ACTIVATEMCC-1037 (S-10). v3 must consume product_sourcing / v_shelf_availability_v3; the frozen v19 engine reads warehouse scope only.',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT count(*) FROM public.pod_refills_shadow prs
    WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
      AND prs.plan_date = {{plan_date}}
      AND prs.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
      AND prs.clamp_reason = 'blocked_no_wh'
  )::text END$sql$
WHERE fixture_id = 5 AND seq = 10;

-- fixture 105 seq 10 · no NON-BOONZ-SOURCED shelf blocked on Boonz WH, on the shadow ledger
--
-- S-36 (leg 29, measured): the pre-shadow form filtered on the MACHINE's venue_group = 'VOX'
-- as a proxy for "venue-sourced". P1.1 retired that proxy. All three of this fixture's
-- machines are VOX-group AND three of their shelves are genuinely boonz_wh-sourced with real
-- need and available_units = 0 (MPMCC-1054 A12 Haribo 7/8, A13 Leibniz 3/16, MPMCC-1058 A05
-- Krambals 5/6). A LAW-5-compliant engine MUST emit qty=0 + clamp_reason='blocked_no_wh' for
-- each, v_blocked_demand_shadow_v3 derives three rows, and the old predicate would read 3 -
-- a genuine red for an engine that obeyed the law. Those rows are CORRECT output and the
-- weekly-procurement consumer needs them; the defect was in the measurement.
-- Scope by the SOURCING EDGE instead: the shelves that must never block on Boonz WH are the
-- ones that are not Boonz-sourced.
UPDATE golden.assertions SET
  description = 'P2 target (v3, SHADOW, re-scoped at S-36): zero NON-boonz_wh-sourced shelves blocked on Boonz WH stock in this fixture''s own engine_add_pod_v3 run (S-06 Aquafina / Fade Fit thesis). Scoped by v_shelf_availability_v3.sourcing, NOT by the machine''s venue_group - P1.1 retired that proxy and a VOX-group machine legitimately carries boonz_wh shelves, which may block correctly. Reads v_blocked_demand_shadow_v3, which derives from pod_refills_shadow.reasoning->>''need_raw''. The sourcing edges themselves are already correct at P1.1 - fixture 5 seq 11/12/13/14.',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT count(*) FROM public.v_blocked_demand_shadow_v3 bd
    JOIN public.v_shelf_availability_v3 a ON a.shelf_id = bd.shelf_id
    WHERE bd.run_id = golden.v3_run_id({{fixture_id}})
      AND bd.plan_date = {{plan_date}}
      AND a.sourcing <> 'boonz_wh' AND bd.reason = 'blocked_no_wh'
  )::text END$sql$
WHERE fixture_id = 105 AND seq = 10;

-- fixture 14 seq 30 · no over-capacity shelf silently dropped, on the shadow plan
UPDATE golden.assertions SET
  description = 'v3 TARGET (SHADOW): no over-capacity shelf is silently dropped - each one receives a plan line in this fixture''s own engine_add_pod_v3 run (0 uncovered)',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT count(*) FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock > s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills_shadow prs
                      WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
                        AND prs.plan_date = {{plan_date}} AND prs.shelf_id = s.shelf_id)
  )::text END$sql$
WHERE fixture_id = 14 AND seq = 30;

-- fixture 14 seq 31 · the plan records the CLAMPED value, on the shadow plan
UPDATE golden.assertions SET
  description = 'v3 TARGET (SHADOW): THE PLAN USES THE CLAMPED VALUE - the shadow line records current_stock <= max_stock, never the raw sensor lie (0 violations; a missing line counts as one)',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT count(*) FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock > s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills_shadow prs
                      WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
                        AND prs.plan_date = {{plan_date}} AND prs.shelf_id = s.shelf_id
                        AND prs.current_stock <= prs.max_stock)
  )::text END$sql$
WHERE fixture_id = 14 AND seq = 31;

-- fixture 14 seq 32 · qty=0 WITH a clamp_reason, never silent (LAW 5), on the shadow plan
UPDATE golden.assertions SET
  description = 'v3 TARGET (SHADOW): an over-full shelf says qty=0 WITH a clamp_reason - explicit, never silent (LAW 5) (0 violations; a missing line counts as one)',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT count(*) FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock > s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills_shadow prs
                      WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
                        AND prs.plan_date = {{plan_date}} AND prs.shelf_id = s.shelf_id
                        AND prs.qty = 0 AND prs.clamp_reason IS NOT NULL)
  )::text END$sql$
WHERE fixture_id = 14 AND seq = 32;

-- fixture 14 seq 33 · no SUB-capacity shelf silently dropped, on the shadow plan
-- S-30 correction 2 (leg 31): this file was written at leg 26 and predates leg 28's S-05
-- sub-capacity mirror. seq 33 is the EIGHTH gated P2 acceptance criterion, not the seventh,
-- and it must be re-expressed on the shadow with the same -1 vacuous-green sentinel or it
-- would stay pointed at public.pod_refills - which v3 never writes - and red a correct engine.
UPDATE golden.assertions SET
  description = 'v3 TARGET (SHADOW, S-05 sub-capacity mirror, moved from fixture 3 seq 1 at leg 28): no SUB-capacity shelf is silently dropped -- each one receives a plan line in this fixture''s own engine_add_pod_v3 run (0 uncovered). v19 drops any sub-capacity shelf whose computed qty rounds to 0 (its insert predicate is literally "need_raw > 0"); P2.5''s unconditional floor plus v3''s no-silent-drop contract is what closes this.',
  check_sql = $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN '-1' ELSE (
    SELECT count(*) FROM public.v_shelf_state s
    WHERE s.machine_name = 'MPMCC-1058-0000-R0' AND s.pod_product_id IS NOT NULL
      AND s.current_stock < s.max_stock
      AND NOT EXISTS (SELECT 1 FROM public.pod_refills_shadow prs
                      WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
                        AND prs.plan_date = {{plan_date}} AND prs.shelf_id = s.shelf_id)
  )::text END$sql$
WHERE fixture_id = 14 AND seq = 33;

-- ---------------------------------------------------------------------------
-- 5. Preserve the v19 fact that fixture 3 seq 4 used to carry (coverage must never drop).
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
VALUES (3, 7,
  'v19 REGRESSION GUARD (preserved verbatim from the pre-shadow seq 4): the LIVE engine still fills the empty A07 with qty>0. Ungated on purpose - seq 4 now measures v3 on the shadow plan, and this fact must not be lost with it.',
  $sql$SELECT COALESCE(max(pr.qty),0)::text FROM public.pod_refills pr
    JOIN public.shelf_configurations sc ON sc.shelf_id = pr.shelf_id
    JOIN public.machines m ON m.machine_id = pr.machine_id
    WHERE pr.plan_date = {{plan_date}} AND m.official_name='MPMCC-1058-0000-R0' AND sc.shelf_code='A07'$sql$,
  'gt', '0', true, 'P0', NULL)
ON CONFLICT (fixture_id, seq) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6. seq 87 (LAW 4 tripwire) and seq 88 (RISK 75 run-time premise) on all four fixtures.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
SELECT f.fixture_id, 87,
  'LAW 4 tripwire: engine_add_pod_v3 wrote NOTHING to the LIVE public.pod_refills at this plan_date. Measured as a delta captured inside golden.run_engine_v3_if_built after the v19 call and before the v3 call - v19 legitimately writes this date, so an absolute count would be meaningless.',
  $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run'
    ELSE ((SELECT count(*) FROM public.pod_refills WHERE plan_date = {{plan_date}})
          = (SELECT (value->>'pr_live_before')::int FROM golden.scratch
               WHERE fixture_id = {{fixture_id}} AND key = 'engine_v3'))::text END$sql$,
  'eq', 'true', true, 'P2',
  $sql$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod_v3')$sql$
FROM (VALUES (3),(5),(14),(105)) AS f(fixture_id)
ON CONFLICT (fixture_id, seq) DO NOTHING;

-- seq 86 · ADR-shadow-plan-tables §8 obligation 3, extended from fixture 14 to all four
-- (leg 31, Cody). The obligation is explicit that this tripwire "belongs on every Phase-2
-- fixture the way the S-08 tripwire (seq 90) rides on every engine-calling fixture", and
-- fixtures 3, 5 and 105 become v3-running fixtures the moment this migration lands.
-- Absolute, not delta-scoped by plan_date: no fixture in this suite calls stitch or commit,
-- so the correct expectation is that public.pod_refill_plan does not move AT ALL.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
SELECT f.fixture_id, 86,
  'ADR 8.3 / LAW 4 tripwire: engine_add_pod_v3 wrote NOTHING to the LIVE public.pod_refill_plan. Measured as a delta captured inside golden.run_engine_v3_if_built immediately before the v3 call. Rides on all four engine fixtures (ADR-shadow-plan-tables §8 obligation 3); fixture 14 seq 91 proves the same fact off its own scenario scratch key and is deliberately left in place.',
  $sql$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run'
    ELSE ((SELECT count(*) FROM public.pod_refill_plan)
          = (SELECT (value->>'prp_live_before')::int FROM golden.scratch
               WHERE fixture_id = {{fixture_id}} AND key = 'engine_v3'))::text END$sql$,
  'eq', 'true', true, 'P2',
  $sql$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod_v3')$sql$
FROM (VALUES (3),(5),(14),(105)) AS f(fixture_id)
ON CONFLICT (fixture_id, seq) DO NOTHING;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
SELECT f.fixture_id, 88,
  'RISK 75 run-time premise: MY OWN engine_add_pod_v3 call ran and produced shadow lines. Reserved sequence for the v3-engine premise, beside seq 89 (estimator). Self-diagnosing: reports helper_never_ran / engine_error:<SQLERRM> / no_run_id_returned rather than a bare number, so a bisecting leg reads the cause on line one.',
  $sql$SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'engine_v3')
      THEN 'helper_never_ran'
    WHEN (SELECT value->>'error' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'engine_v3') IS NOT NULL
      THEN 'engine_error: ' || (SELECT value->>'error' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'engine_v3')
    WHEN golden.v3_run_id({{fixture_id}}) IS NULL
      THEN 'no_run_id_returned'
    ELSE (SELECT count(*) FROM public.pod_refills_shadow WHERE run_id = golden.v3_run_id({{fixture_id}}))::text
  END$sql$,
  'gt', '0', true, 'P2',
  $sql$SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod_v3')$sql$
FROM (VALUES (3),(5),(14),(105)) AS f(fixture_id)
ON CONFLICT (fixture_id, seq) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7. END-STATE GUARD. Cody's leg-25 revision, and it earned its keep on first apply then:
--    assert what the migration MEANT, not that a statement fired. Anything short of the
--    full end state rolls the whole migration back with no schema_migrations row.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
  v_n int;
BEGIN
  -- 7a. both helpers exist
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='golden' AND p.proname='v3_run_id') THEN
    RAISE EXCEPTION 'END-STATE: golden.v3_run_id missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='golden' AND p.proname='run_engine_v3_if_built') THEN
    RAISE EXCEPTION 'END-STATE: golden.run_engine_v3_if_built missing';
  END IF;

  -- 7b. all four engine fixtures invoke the helper, exactly once each
  SELECT count(*) INTO v_n FROM golden.fixtures
   WHERE fixture_id IN (3,5,14,105) AND scenario_sql LIKE '%run_engine_v3_if_built%';
  IF v_n <> 4 THEN RAISE EXCEPTION 'END-STATE: helper wired into % of 4 fixtures', v_n; END IF;
  SELECT count(*) INTO v_n FROM golden.fixtures
   WHERE fixture_id IN (3,5,14,105)
     AND (length(scenario_sql) - length(replace(scenario_sql,'run_engine_v3_if_built',''))) / length('run_engine_v3_if_built') <> 1;
  IF v_n <> 0 THEN RAISE EXCEPTION 'END-STATE: % fixture(s) call the helper more than once', v_n; END IF;

  -- 7b2 (S-30 correction 3, leg 31). On the two PINNING fixtures the v3 call must sit INSIDE
  --      the pin envelope - i.e. strictly BEFORE the first restore_machine_stock. Appending it
  --      would have v19 plan a pinned machine and v3 plan a restored one, and every
  --      shadow-vs-live diff would be noise. This guard is what proves the correction landed.
  SELECT count(*) INTO v_n FROM golden.fixtures
   WHERE fixture_id IN (3,5)
     AND (strpos(scenario_sql, 'run_engine_v3_if_built') = 0
       OR strpos(scenario_sql, 'restore_machine_stock')  = 0
       OR strpos(scenario_sql, 'run_engine_v3_if_built')
          > strpos(scenario_sql, 'restore_machine_stock'));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'END-STATE: % pinning fixture(s) call v3 OUTSIDE the pin envelope', v_n;
  END IF;

  -- 7c. all four still call the v19 engine (the re-expression must not have displaced it)
  SELECT count(*) INTO v_n FROM golden.fixtures
   WHERE fixture_id IN (3,5,14,105) AND scenario_sql LIKE '%public.engine_add_pod(%';
  IF v_n <> 4 THEN RAISE EXCEPTION 'END-STATE: v19 engine call lost on % of 4 fixtures', 4 - v_n; END IF;

  -- 7d. all EIGHT re-expressed assertions read a shadow object, scope by run_id, carry the guard.
  --     EIGHT, not seven: leg 28 added fixture 14 seq 33 (S-05 sub-capacity mirror) after this
  --     file was written. S-30 correction 2, leg 31.
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE (fixture_id, seq) IN ((3,1),(3,4),(5,10),(105,10),(14,30),(14,31),(14,32),(14,33))
     AND check_sql LIKE '%golden.v3_run_id(%'
     AND (check_sql LIKE '%pod_refills_shadow%' OR check_sql LIKE '%v_blocked_demand_shadow_v3%')
     AND check_sql LIKE '%IS NULL THEN ''-1''%';
  IF v_n <> 8 THEN RAISE EXCEPTION 'END-STATE: only % of 8 acceptance assertions re-expressed on the shadow', v_n; END IF;

  -- 7e. and none of them still reads the live plan/ledger tables
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE (fixture_id, seq) IN ((3,1),(3,4),(5,10),(105,10),(14,30),(14,31),(14,32),(14,33))
     AND (check_sql LIKE '%public.pod_refills %' OR check_sql LIKE '%public.pod_refills'||E'\n'||'%'
          OR check_sql LIKE '%public.blocked_demand%');
  IF v_n <> 0 THEN RAISE EXCEPTION 'END-STATE: % acceptance assertion(s) still read a LIVE table', v_n; END IF;

  -- 7f. all eight still gated on the same predicate (they must stay expected-red until the engine exists)
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE (fixture_id, seq) IN ((3,1),(3,4),(5,10),(105,10),(14,30),(14,31),(14,32),(14,33))
     AND acceptance_gate_sql LIKE '%engine_add_pod_v3%' AND phase_required = 'P2';
  IF v_n <> 8 THEN RAISE EXCEPTION 'END-STATE: gate/phase lost on % of 8', 8 - v_n; END IF;

  -- 7g. the thirteen new assertions exist (seq 86/87/88 on four fixtures, plus fixture 3 seq 7)
  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id IN (3,5,14,105) AND seq IN (86,87,88);
  IF v_n <> 12 THEN RAISE EXCEPTION 'END-STATE: % of 12 tripwire/premise assertions present', v_n; END IF;
  -- and every one of them is gated, so none can go red before the engine exists
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id IN (3,5,14,105) AND seq IN (86,87,88)
     AND (acceptance_gate_sql NOT LIKE '%engine_add_pod_v3%' OR phase_required <> 'P2');
  IF v_n <> 0 THEN RAISE EXCEPTION 'END-STATE: % tripwire/premise assertion(s) ungated', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id=3 AND seq=7
                 AND check_sql LIKE '%public.pod_refills pr%' AND acceptance_gate_sql IS NULL) THEN
    RAISE EXCEPTION 'END-STATE: fixture 3 seq 7 v19 regression guard missing or gated';
  END IF;

  -- 7h. total coverage moved by exactly +13
  --     S-30 correction 1 (leg 31): this constant was 233 = 224 + 9, written at leg 26. Leg 28
  --     added five assertions; the live baseline has been 229 since 22:42 that evening, so the
  --     file as written would have ROLLED ITSELF BACK on apply. Re-measured live at leg-31
  --     STEP R: 229 assertions across 11 fixtures.
  --     +13 = fixture 3 seq 7 (the preserved v19 fact)
  --         + seq 86 / 87 / 88 on each of the four engine fixtures (3 x 4 = 12).
  --     seq 33 is RE-EXPRESSED, not added, so it moves no count.
  SELECT count(*) INTO v_n FROM golden.assertions;
  IF v_n <> 242 THEN RAISE EXCEPTION 'END-STATE: assertion count is % (expected 242 = 229 + 13)', v_n; END IF;
END
$guard$;

COMMIT;
