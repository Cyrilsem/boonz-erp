-- PRD-110 P0.3 / CS DECISION D-35 — FIXTURE FIRST (LAW 1). No engine edit in this migration.
--
-- CS answered D-35 → COLLAPSE the inline Saturday rule in `_build_draft_core_v3` into the
-- canonical helper; agreement fixture required. This migration writes the proof that
-- reddens on today's body and greens on the collapsed one. The engine edit is the NEXT
-- migration.
--
-- ⭐ PREMISE RE-DERIVED LIVE BEFORE A LINE WAS WRITTEN (S-158 — D-36's parked wording was
--    factually wrong and only a live probe caught it). D-35's wording holds exactly:
--      · is_refill_planning_day_v3(date) = `p IS NOT NULL AND EXTRACT(DOW FROM p) <> 6`,
--        IMMUTABLE, SECURITY INVOKER, search_path=public, pg_catalog, one overload.
--      · run_nightly_shadow_v3 asks the helper by name.
--      · _build_draft_core_v3 does NOT call it and still carries the rule inline as a bare
--        `IF EXTRACT(DOW FROM p_plan_date) = 6 THEN ... 'skipped_saturday'`.
--    Two copies of one calendar, exactly as Cody flagged under Article 16.
--
-- ⛔ WHY THE COLLAPSE IS SEMANTICS-PRESERVING, AND WHY THAT NEEDED CHECKING. The helper
--    also encodes `p IS NOT NULL`, which the inline rule does not. It is safe here ONLY
--    because `_build_draft_core_v3` RAISEs on a NULL p_plan_date three lines earlier, so at
--    the point of the branch `NOT is_refill_planning_day_v3(p_plan_date)` is provably
--    identical to `EXTRACT(DOW FROM p_plan_date) = 6`. Collapse a rule onto a helper whose
--    guard set is LARGER than the site's and you silently change behaviour; here the extra
--    guard is already discharged upstream.
--
-- ⛔ NEW LANDMINE, FOUND BY PROBING RATHER THAN BY ASSUMING — A 2030 DATE IS NOT
--    AUTOMATICALLY A SAFE ONE TO CALL STAGE 1 ON. `_build_draft_core_v3` returns early on
--    a Saturday, on a live plan, and on zero included machines — but on a date that HAS
--    confirmed+included machines_to_visit rows it proceeds to engine_add_pod /
--    engine_swap_pod / engine_finalize_pod, under a pinned statement_timeout of 20 minutes.
--    2030-03-05..2030-03-14 carry EIGHT machines_to_visit rows each (fixture 58's cast), so
--    "any 2030 date" would have fired the real engines inside the golden harness.
--    ⭐ This fixture therefore VERIFIES ITS WINDOW IS VIRGIN FIRST and refuses to call
--    Stage 1 at all otherwise — seq 3 turns that refusal into a red instead of a runtime.
--    2030-06-03..2030-06-09 was probed virgin on all three tables before this file existed.
--
-- ⭐ NO SUBTRANSACTION-UNWIND NEEDED (contrast S-153). With p_repick=false and
--    p_auto_confirm=false, and on a virgin week, all seven calls are provably write-free —
--    smoke-probed live at 14 ms for three calls, zero rows on all three tables afterwards.
--    Seq 10 re-proves that as a correctness property on every run rather than trusting it.
--
-- ⭐ THE SPREAD IS THE POINT (S-157). Agreement alone is fakeable: a helper stuck at TRUE
--    and a Stage 1 that never skips agree on all seven days. Seq 8/9 pin that EXACTLY ONE
--    of the seven days is skipped and that it is the Saturday, so the agreement in seq 7
--    is agreement about something.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, notes, scenario_sql)
VALUES (
  61,
  'One calendar, one copy (D-35): Stage 1 and the nightly runner cannot disagree about which day is a refill-planning day, because Stage 1 no longer owns a second copy of the rule',
  'PRD-110 Cody Article 16 review — is_refill_planning_day_v3 names the PRD-035 WS-E rule and run_nightly_shadow_v3 asks it by name, but _build_draft_core_v3 kept the same rule inline as a bare EXTRACT(DOW FROM p_plan_date) = 6. Two copies of one calendar can drift apart silently.',
  'P0',
  DATE '2030-06-03',
  'Window 2030-06-03..2030-06-09 probed virgin on machines_to_visit / pod_refill_plan / refill_dispatching before adoption. The fixture re-verifies virginity every run and refuses to call Stage 1 if the window has since been colonised.',
$fx61$
DO $do$
DECLARE
  d0            date := DATE '2030-06-03';   -- Monday
  dN            date := DATE '2030-06-09';   -- Sunday
  v_d           date;
  v_r           jsonb;
  v_status      text;
  v_core_skip   boolean;
  v_helper_ok   boolean;
  v_virgin      boolean;
  v_disagree    int  := 0;
  v_skip_days   int  := 0;
  v_skip_day    date;
  v_h_false     int  := 0;
  v_h_false_dow int;
  v_days        int  := 0;
  v_statuses    jsonb := '{}'::jsonb;
  v_src         text;
  v_rows_after  int;
  v_v           jsonb;
BEGIN
  DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

  -- (1) THE WINDOW MUST BE VIRGIN BEFORE STAGE 1 IS CALLED AT ALL. See the header: a date
  --     carrying confirmed+included machines_to_visit rows sends _build_draft_core_v3 into
  --     the real engines. Refusing here is what keeps this fixture cheap and safe.
  -- ⛔ CODY R2: refill_plan_output is included deliberately. It is the one protected table
  --    LAW 12 names by name ("never touch live plan tables for dates with non-pending
  --    refill_plan_output rows"), and fixture 53 seq 22 already carries this tripwire.
  --    Omitting it would let a date carrying live plan rows read as virgin.
  v_virgin := NOT (
       EXISTS (SELECT 1 FROM public.machines_to_visit   WHERE plan_date     BETWEEN d0 AND dN)
    OR EXISTS (SELECT 1 FROM public.pod_refill_plan     WHERE plan_date     BETWEEN d0 AND dN)
    OR EXISTS (SELECT 1 FROM public.refill_dispatching  WHERE dispatch_date BETWEEN d0 AND dN)
    OR EXISTS (SELECT 1 FROM public.refill_plan_output  WHERE plan_date     BETWEEN d0 AND dN));

  -- (2) STRUCTURAL — who owns the calendar rule, measured on the live bodies.
  SELECT p.prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3';

  v_v := jsonb_build_object(
    'week_virgin',   CASE WHEN v_virgin THEN 'yes' ELSE 'no' END,
    'helper_overloads',
      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'is_refill_planning_day_v3'),
    'core_helper_calls',
      (SELECT count(*) FROM regexp_matches(v_src, 'is_refill_planning_day_v3\(', 'g')),
    'core_inline_dow',
      (SELECT count(*) FROM regexp_matches(v_src, 'EXTRACT\(DOW FROM p_plan_date\)', 'g')),
    'core_saturday_branch',
      (SELECT count(*) FROM regexp_matches(v_src, 'skipped_saturday', 'g')),
    'runner_helper_calls',
      (SELECT count(*) FROM regexp_matches(
         (SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'run_nightly_shadow_v3'),
         'is_refill_planning_day_v3\(', 'g')),
    'core_shape',
      (SELECT CASE WHEN count(*) = 1
                    AND bool_and(p.prosecdef)
                    AND bool_and(p.pronargdefaults = 0)
                    AND bool_and(pg_get_function_identity_arguments(p.oid)
                                 = 'p_plan_date date, p_repick boolean, p_auto_confirm boolean')
                   THEN 'ok' ELSE 'changed' END
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3'));

  -- (3) BEHAVIOURAL AGREEMENT over a whole week. One call per day; the comparison is
  --     "did Stage 1 take its Saturday exit?" against "does the helper call this a
  --     planning day?". They must be exact complements on all seven days.
  IF v_virgin THEN
    FOR v_d IN SELECT generate_series(d0, dN, INTERVAL '1 day')::date LOOP
      v_days := v_days + 1;
      BEGIN
        v_r := public._build_draft_core_v3(v_d, false, false);
        v_status := COALESCE(v_r->>'status', '<null>');
      EXCEPTION WHEN OTHERS THEN
        v_status := 'threw: ' || SQLERRM;
      END;

      v_core_skip := (v_status = 'skipped_saturday');
      v_helper_ok := public.is_refill_planning_day_v3(v_d);

      IF v_core_skip <> (NOT v_helper_ok) THEN
        v_disagree := v_disagree + 1;
      END IF;
      IF v_core_skip THEN
        v_skip_days := v_skip_days + 1;
        v_skip_day  := v_d;
      END IF;
      IF NOT v_helper_ok THEN
        v_h_false     := v_h_false + 1;
        v_h_false_dow := EXTRACT(DOW FROM v_d);
      END IF;

      v_statuses := v_statuses || jsonb_build_object(v_d::text, v_status);
    END LOOP;
  END IF;

  -- (4) RESIDUE — the seven calls must have written nothing anywhere.
  SELECT (SELECT count(*) FROM public.machines_to_visit   WHERE plan_date     BETWEEN d0 AND dN)
       + (SELECT count(*) FROM public.pod_refill_plan     WHERE plan_date     BETWEEN d0 AND dN)
       + (SELECT count(*) FROM public.refill_dispatching  WHERE dispatch_date BETWEEN d0 AND dN)
       + (SELECT count(*) FROM public.refill_plan_output  WHERE plan_date     BETWEEN d0 AND dN)
    INTO v_rows_after;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'd35_calendar', v_v || jsonb_build_object(
    'days_probed',    v_days,
    'disagreements',  v_disagree,
    'core_skip_days', v_skip_days,
    'core_skip_day',  COALESCE(v_skip_day::text, '<none>'),
    'helper_false_days', v_h_false,
    'helper_false_dow',  COALESCE(v_h_false_dow::text, '<none>'),
    'rows_after',     v_rows_after,
    'statuses',       v_statuses));
END $do$;
$fx61$
)
ON CONFLICT (fixture_id) DO UPDATE
  SET name            = EXCLUDED.name,
      source_incident = EXCLUDED.source_incident,
      phase_required  = EXCLUDED.phase_required,
      plan_date       = EXCLUDED.plan_date,
      notes           = EXCLUDED.notes,
      scenario_sql    = EXCLUDED.scenario_sql;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
VALUES
 (61, 1,
  'D-35 premise: the canonical helper exists and is a single overload - the collapse has exactly one target',
  $q$SELECT COALESCE((SELECT value->>'helper_overloads' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '1', 'P0'),

 (61, 2,
  'D-35 premise: run_nightly_shadow_v3 already asks the helper by name - it is the consumer Stage 1 has to agree WITH, so if it ever stopped asking, this fixture would be comparing Stage 1 against nothing',
  $q$SELECT COALESCE((SELECT value->>'runner_helper_calls' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'gte', '1', 'P0'),

 (61, 3,
  'D-35 safety: the 2030-06-03..09 window is still virgin, so calling Stage 1 seven times cannot reach the engines. 2030-03-05..14 carries eight machines_to_visit rows per day, which is exactly the trap this refuses - a red here means pick a new window, never widen the fixture',
  $q$SELECT COALESCE((SELECT value->>'week_virgin' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', 'yes', 'P0'),

 (61, 4,
  'D-35 CORE: _build_draft_core_v3 gets its calendar from is_refill_planning_day_v3 instead of owning a second copy of the rule (RED until the collapse lands)',
  $q$SELECT COALESCE((SELECT value->>'core_helper_calls' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '1', 'P0'),

 (61, 5,
  'D-35 CORE: no bare EXTRACT(DOW FROM p_plan_date) survives in Stage 1 - the Article 16 illegal copy is retired, not merely shadowed by a call (RED until the collapse lands)',
  $q$SELECT COALESCE((SELECT value->>'core_inline_dow' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '0', 'P0'),

 (61, 6,
  'D-35 anti-vacuity (S-162): the Saturday exit still EXISTS in Stage 1. Deleting the branch outright would satisfy seq 5 and leave seq 4 the only thing standing between the fleet and Saturday plans',
  $q$SELECT COALESCE((SELECT value->>'core_saturday_branch' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'gte', '1', 'P0'),

 (61, 7,
  'D-35 AGREEMENT: across seven consecutive days Stage 1 takes its Saturday exit on exactly the days the helper calls non-planning - zero disagreements. This is the property CS asked for and it must hold BEFORE and AFTER the collapse, because a refactor that changes behaviour is not a refactor',
  $q$SELECT COALESCE((SELECT value->>'disagreements' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '0', 'P0'),

 (61, 8,
  'D-35 spread (S-157): exactly ONE of the seven days is skipped by Stage 1. Without this, a helper stuck at TRUE and a Stage 1 that never skips would agree perfectly on all seven days and seq 7 would be theatre',
  $q$SELECT COALESCE((SELECT value->>'core_skip_days' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '1', 'P0'),

 (61, 9,
  'D-35 spread: the one skipped day is the Saturday - PRD-035 WS-E names Saturday as a delivery day, so this pins WHICH day the shared calendar means, not merely that both sides mean the same one',
  $q$SELECT COALESCE((SELECT value->>'core_skip_day' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '2030-06-08', 'P0'),

 (61, 10,
  'D-35 spread: the helper independently rejects exactly one day and its DOW is 6 - measured from the helper side so a Stage 1 that skipped the wrong day could not drag the assertion along with it',
  $q$SELECT COALESCE((SELECT (value->>'helper_false_days') || '/' || (value->>'helper_false_dow')
                       FROM golden.scratch WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '1/6', 'P0'),

 (61, 11,
  'D-35 residue (LAW 12, CODY R2): seven Stage 1 calls at p_repick=false / p_auto_confirm=false wrote nothing to machines_to_visit, pod_refill_plan, refill_dispatching OR refill_plan_output - the last is the table LAW 12 names by name and the one fixture 53 seq 22 already tripwires. The fixture is read-only by construction and re-proves it rather than trusting the smoke probe',
  $q$SELECT COALESCE((SELECT value->>'rows_after' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '0', 'P0'),

 (61, 12,
  'D-35 signature (S-163): the collapse is a body edit only - _build_draft_core_v3 stays a single SECURITY DEFINER overload with zero defaulted arguments and the same identity arguments. A CREATE OR REPLACE that silently dropped defaults is the 13-day driver-confirm outage precedent',
  $q$SELECT COALESCE((SELECT value->>'core_shape' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', 'ok', 'P0'),

 (61, 13,
  'D-35 premise: all seven days were actually probed - a window loop that ran zero times would leave every count at its initial value and read green across seq 7/8/10',
  $q$SELECT COALESCE((SELECT value->>'days_probed' FROM golden.scratch
                       WHERE fixture_id=61 AND key='d35_calendar'),'absent')$q$,
  'eq', '7', 'P0')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description    = EXCLUDED.description,
      check_sql      = EXCLUDED.check_sql,
      expect_op      = EXCLUDED.expect_op,
      expect         = EXCLUDED.expect,
      phase_required = EXCLUDED.phase_required;
