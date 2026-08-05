-- PRD-110 P3.6 / CS DECISION D-36 — FIXTURE FIRST (LAW 1), no engine edit in this migration.
--
-- CS answered D-36 → RE-ASSERT `app.rpc_name` after each inner call in swap_v3; no
-- signature change. This migration writes the proof that reddens on today's body and
-- greens on the fixed one. The engine edit lands in the NEXT migration.
--
-- ⛔ THE D-36 TEXT'S PREMISE WAS WRONG AND IS CORRECTED HERE. It claimed write_audit_log
--    "records two ordinary edits and no swap". It records NOTHING: plan_edits_v3 carries
--    no audit trigger at all (only tg_plan_edits_v3_append_only / _no_truncate), and
--    write_audit_log holds zero rows for swap_v3, record_plan_edit_v3 or plan_edits_v3.
--    The REAL defect is narrower and worse:
--
--      set_config('app.rpc_name', ..., true) is TRANSACTION-scoped, not statement-scoped.
--      record_plan_edit_v3 overwrites the name with its own and swap_v3 never re-asserts,
--      so swap_v3 RETURNS leaving 'record_plan_edit_v3' behind, and the NEXT write to any
--      of the 42 audited tables in that same transaction is stamped with the inner writer
--      instead of the act the human actually performed.
--
--    Measured live before this file was written: after a successful swap_v3,
--    current_setting('app.rpc_name') = 'record_plan_edit_v3'.
--
-- ⭐ swap_v3 is the LONE outlier, not a new convention. Every other PRD-110 v3 writer that
--    calls an inner rpc_name-setter already re-asserts — create_spot_purchase_v3 (3),
--    mine_edit_history_v3 (3), run_weekly_miners_v3 (2), submit_feedback_v3 (2) — and
--    fixtures 56/57/58 already pin exactly this property for three of them. swap_v3 sets
--    the name once and is the only v3 writer with no such assertion.
--
-- ⛔ STEP 6 IS HERMETIC ON PURPOSE. golden.run_all() runs every fixture in ONE transaction
--    and a subtransaction that COMMITS does not roll set_config back, so a value left
--    behind here would travel to later fixtures. Fixture 60 seq 54 reads the AMBIENT
--    app.rpc_name without setting it first, so an unrestored sentinel would redden fixture
--    60 for a reason that has nothing to do with fixture 60. Step 6 captures the incoming
--    value and puts it back.

UPDATE golden.fixtures
   SET scenario_sql = scenario_sql || $d36$

-- (6) D-36 — PROVENANCE SURVIVING THE INNER CALLS. Hermetic: captures the ambient
--     app.rpc_name on entry and restores it on exit (see header).
DO $do$
DECLARE
  r        jsonb;
  v        jsonb := '{}'::jsonb;
  v_pre    text;
  v_src    text;
  v_parts  text[];
  v_tail   text;
  v_inner  int;
  v_re     int;
BEGIN
  v_pre := current_setting('app.rpc_name', true);

  IF to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id,key,value)
    VALUES (54,'d36_guc', jsonb_build_object('status','absent'));
    RETURN;
  END IF;

  -- 6a ANCHOR A — a SUCCESSFUL swap runs BOTH inner legs (drop then add). This is the
  --    anchor that carries the defect: today it reads 'record_plan_edit_v3'.
  PERFORM set_config('app.rpc_name', 'golden.f54_sentinel', true);
  BEGIN
    EXECUTE 'SELECT public.swap_v3($1,$2,$3,$4,$5,$6,$7)'
      INTO r USING DATE '2030-02-24',
        '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
        'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,
        'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid,
        'golden fixture 54 D-36 provenance after a two-leg swap', 11, NULL::uuid;
    v := v || jsonb_build_object(
      'ok_status', COALESCE(r->>'status','<null>'),
      'ok_legs',   jsonb_array_length(COALESCE(r->'legs','[]'::jsonb)),
      'after_ok',  COALESCE(current_setting('app.rpc_name', true), '<null>'),
      'via_ok',    COALESCE(current_setting('app.via_rpc',  true), '<null>'));
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object('ok_status', 'threw: ' || SQLERRM);
  END;

  -- 6b ANCHOR B — a REFUSED swap raises BEFORE any inner call, and the caught raise rolls
  --    that subtransaction back, so the CALLER's own value survives untouched. GREEN both
  --    before and after the fix: this anchor is what proves 6a's red is caused by the
  --    inner calls rather than by the probe. (S-157: anchors at different settings.)
  PERFORM set_config('app.rpc_name', 'golden.f54_sentinel', true);
  BEGIN
    EXECUTE 'SELECT public.swap_v3($1,$2,$3,$4,$5,$6,$7)'
      INTO r USING DATE '2030-02-24',
        '9db7a821-d312-43b0-8e83-9642abfbfb0b'::uuid,
        'b6454a65-f4da-4c07-8570-b8791f687ee2'::uuid,
        '31186e1c-b61b-4d13-b520-052fb86725a3'::uuid,
        'golden fixture 54 D-36 refused swap leaves no provenance residue', 5, NULL::uuid;
    v := v || jsonb_build_object('after_refused', 'not_refused');
  EXCEPTION WHEN OTHERS THEN
    v := v || jsonb_build_object(
      'after_refused', COALESCE(current_setting('app.rpc_name', true), '<null>'));
  END;

  -- 6c STRUCTURAL — CS said "after EACH inner call", which is a stronger property than
  --     "correct on the way out". Split the body on the inner-call literal: the LAST
  --     element is everything after the final inner call, so a re-assert found there is
  --     literally a re-assert after the last inner call. The coverage check scales with
  --     the number of legs instead of pinning a brittle literal count (S-156), so a third
  --     leg added later cannot silently re-open D-36.
  SELECT p.prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'swap_v3';

  v_parts := regexp_split_to_array(v_src, 'record_plan_edit_v3\(');
  v_tail  := v_parts[array_length(v_parts,1)];
  v_inner := array_length(v_parts,1) - 1;
  SELECT count(*) INTO v_re
    FROM regexp_matches(v_src, 'set_config\(''app\.rpc_name'', ''swap_v3''', 'g');

  v := v || jsonb_build_object(
    'inner_calls', v_inner,
    'reasserts',   v_re,
    'reassert_after_last_inner',
      CASE WHEN v_tail LIKE '%set_config(''app.rpc_name'', ''swap_v3''%' THEN 'yes' ELSE 'no' END,
    'reassert_covers_every_inner',
      CASE WHEN v_re - 1 >= v_inner THEN 'yes' ELSE 'no' END);

  INSERT INTO golden.scratch (fixture_id,key,value) VALUES (54,'d36_guc', v);

  -- ⛔ HERMETIC EXIT. Put the ambient value back so fixture 60 (which reads app.rpc_name
  --    without setting it) sees exactly what it would have seen without this step.
  PERFORM set_config('app.rpc_name', COALESCE(v_pre, ''), true);
END $do$;
$d36$
 WHERE fixture_id = 54
   AND position('d36_guc' in scenario_sql) = 0;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
VALUES
 (54, 60,
  'D-36 premise: the provenance probe measured a swap that actually SUCCEEDED',
  $q$SELECT COALESCE((SELECT value->>'ok_status' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'eq', 'ok', 'P3'),

 (54, 61,
  'D-36 premise: that swap ran BOTH inner legs - the anchor is not measuring a one-leg path with nothing to overwrite it',
  $q$SELECT COALESCE((SELECT value->>'ok_legs' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'eq', '2', 'P3'),

 (54, 62,
  'D-36: after a successful swap app.rpc_name reads swap_v3, NOT the inner writer - it is transaction-scoped, so whatever swap_v3 leaves behind stamps the next audited write in the same transaction',
  $q$SELECT COALESCE((SELECT value->>'after_ok' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'eq', 'swap_v3', 'P3'),

 (54, 63,
  'D-36: re-asserting the name does not clobber app.via_rpc - the write-guards that trust it keep working',
  $q$SELECT COALESCE((SELECT value->>'via_ok' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'eq', 'true', 'P3'),

 (54, 64,
  'D-36 discriminator: a REFUSED swap raises before any inner call and the caught raise rolls the GUC back, so the caller keeps its own value - green before AND after the fix, which is what proves seq 62 measures the inner calls',
  $q$SELECT COALESCE((SELECT value->>'after_refused' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'eq', 'golden.f54_sentinel', 'P3'),

 (54, 65,
  'D-36 structural: the re-assert sits AFTER the last inner call, so a leg appended later inherits the convention instead of silently re-opening D-36',
  $q$SELECT COALESCE((SELECT value->>'reassert_after_last_inner' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'eq', 'yes', 'P3'),

 (54, 66,
  'D-36 structural: CS said after EACH inner call - re-asserts cover every inner call, and the check scales with the leg count rather than pinning a literal',
  $q$SELECT COALESCE((SELECT value->>'reassert_covers_every_inner' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'eq', 'yes', 'P3'),

 (54, 67,
  'D-36 residue: step 6 is hermetic - it restores the ambient app.rpc_name, so fixture 60 (which reads it WITHOUT setting it) is unaffected when run_all runs every fixture in one transaction',
  $q$SELECT CASE WHEN COALESCE(current_setting('app.rpc_name', true),'') = 'golden.f54_sentinel'
                 THEN 'leaked' ELSE 'clean' END$q$,
  'eq', 'clean', 'P3'),

 (54, 68,
  'D-36 anti-vacuity (CODY R1): swap_v3 still routes BOTH legs through the canonical writer - with zero inner calls the body splits into one element, so seq 65 finds the OPENING assert in the tail and seq 66 evaluates n-1 >= 0, and both would read yes exactly when the writer had been bypassed',
  $q$SELECT COALESCE((SELECT value->>'inner_calls' FROM golden.scratch
                       WHERE fixture_id=54 AND key='d36_guc'),'absent')$q$,
  'gte', '2', 'P3')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description    = EXCLUDED.description,
      check_sql      = EXCLUDED.check_sql,
      expect_op      = EXCLUDED.expect_op,
      expect         = EXCLUDED.expect,
      phase_required = EXCLUDED.phase_required;
