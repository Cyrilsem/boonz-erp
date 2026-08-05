-- ═══════════════════════════════════════════════════════════════════════════
-- PRD-110 · P2.6 · GOLDEN FIXTURE 33 — "Preflight blocks at commit"
-- LAW 1: FIXTURE FIRST. This migration ships the failing baseline BEFORE the
-- commit gate exists. It must run RED on the block-mode / override assertions
-- and GREEN on the non-vacuity + anti-over-block ones.
--
-- Baseline measured live on 2030-02-03 before writing this file:
--   leak present  -> verdict FAIL, exactly 1 violation, all of it INV-06
--   leak repaired -> verdict PASS, 0 violations, 0 warnings
-- Both directions are therefore real behaviour, not a to_regclass absence.
--
-- HARNESS NOTE (golden.probe_commit_under_mode): golden.run_fixture is
-- TRANSACTIONAL, so the helper's flip of refill_policy_params.preflight_enforcement
-- is invisible to every other session and is restored inside the same statement
-- sequence. A hard abort rolls the flip back with the rest of the fixture.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── harness helper ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION golden.probe_commit_under_mode(
  p_plan_date       date,
  p_mode            text,
  p_comment         text,
  p_use_override    boolean DEFAULT false,
  p_override_reason text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, golden, pg_temp
AS $fn$
DECLARE
  v_prev            text;
  v_row_id          bigint;
  v_res             jsonb;
  v_ov              jsonb;
  v_err             jsonb;
  v_log_before      int;
  v_log_after       int;
  v_ovlog_before    int;
  v_ovlog_after     int;
BEGIN
  IF p_mode NOT IN ('warn','block') THEN
    RAISE EXCEPTION 'golden.probe_commit_under_mode: p_mode must be warn or block, got %', p_mode;
  END IF;

  SELECT rpp.id, COALESCE(rpp.preflight_enforcement,'warn')
    INTO v_row_id, v_prev
    FROM public.refill_policy_params rpp ORDER BY rpp.id LIMIT 1;

  SELECT count(*) INTO v_log_before
    FROM public.refill_commit_log WHERE plan_date = p_plan_date;
  SELECT count(*) INTO v_ovlog_before
    FROM public.preflight_override_log WHERE plan_date = p_plan_date;

  UPDATE public.refill_policy_params SET preflight_enforcement = p_mode WHERE id = v_row_id;

  BEGIN
    IF p_use_override THEN
      IF to_regprocedure('public.preflight_override_v3(date,text)') IS NULL THEN
        v_ov := jsonb_build_object('error','preflight_override_v3 NOT BUILT');
      ELSE
        EXECUTE 'SELECT public.preflight_override_v3($1,$2)'
           INTO v_ov USING p_plan_date, p_override_reason;
      END IF;
    END IF;
    v_res := public.commit_refill_plan(p_plan_date, p_comment, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM);
  END;

  SELECT count(*) INTO v_log_after
    FROM public.refill_commit_log WHERE plan_date = p_plan_date;
  SELECT count(*) INTO v_ovlog_after
    FROM public.preflight_override_log WHERE plan_date = p_plan_date;

  -- restore ALWAYS, on both the happy and the caught-exception path
  UPDATE public.refill_policy_params SET preflight_enforcement = v_prev WHERE id = v_row_id;

  RETURN jsonb_build_object(
    'mode',               p_mode,
    'prev_mode',          v_prev,
    'override',           COALESCE(v_ov,  'null'::jsonb),
    'result',             COALESCE(v_res, 'null'::jsonb),
    'error',              COALESCE(v_err, 'null'::jsonb),
    'commit_log_delta',   v_log_after   - v_log_before,
    'override_log_delta', v_ovlog_after - v_ovlog_before);
END
$fn$;

COMMENT ON FUNCTION golden.probe_commit_under_mode(date,text,text,boolean,text) IS
  'PRD-110 P2.6 golden harness: run commit_refill_plan under a temporary preflight_enforcement mode, capture result or error, always restore the previous mode. Test-only; never called by production.';

-- ── fixture 33 ─────────────────────────────────────────────────────────────
DELETE FROM golden.assertions WHERE fixture_id = 33;
DELETE FROM golden.fixtures   WHERE fixture_id = 33;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes, scenario_sql)
VALUES (
  33,
  'Preflight blocks at commit (P2.6 enforcement + audited override)',
  'PRD-110 BUILD SPEC P2.6 / WS-B2 - preflight invariants were advisory at the stitch gate only; commit_refill_plan performed ZERO invariant checking, so a plan with a known conservation leak could be committed without anything refusing or recording it.',
  'P2',
  DATE '2030-02-03',
  'failing_expected',
  true,
  'plan_date 2030-02-03 = golden.render''s computed DATE 2030-01-01 + fixture_id. Seeds ONE conserving REMOVE parent (5 = 3+2) and ONE genuine leak (8 vs 3+2+2=7) on GRIT-1022-0100-W0, exactly the fixture-10 shapes. Measured baseline before this file was written: FAIL / 1 violation / all INV-06, flipping to PASS / 0 / 0 once the leak is repaired. All side effects run in scenario_sql and land in golden.scratch; every assertion is a pure read.',
$scn$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);

DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'baselines', jsonb_build_object(
  'df_open',        (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'ovlog_all',      (SELECT count(*) FROM public.preflight_override_log),
  'ovlog_other',    (SELECT count(*) FROM public.preflight_override_log WHERE plan_date <> {{plan_date}}),
  'commitlog_other',(SELECT count(*) FROM public.refill_commit_log WHERE plan_date <> {{plan_date}}),
  'enforcement',    (SELECT COALESCE(preflight_enforcement,'warn') FROM public.refill_policy_params ORDER BY id LIMIT 1));

-- synthetic 2030 plan_date only (LAW 12): no live plan row is ever touched
DELETE FROM public.refill_plan_output WHERE plan_date = {{plan_date}};
DELETE FROM public.pod_refill_plan    WHERE plan_date = {{plan_date}};

INSERT INTO public.pod_refill_plan
  (plan_date, machine_id, shelf_id, pod_product_id, action, qty, status, reasoning, source_origin)
SELECT {{plan_date}}, m.machine_id, sc.shelf_id, sl.pod_product_id, s.action, s.qty, s.status,
       jsonb_build_object('source','golden_fixture_33','scenario',s.tag), 'warehouse'::source_origin_enum
FROM (VALUES
    ('A06','REMOVE', 5, 'stitched', 'C1_conserving'),
    ('A07','REMOVE', 8, 'stitched', 'C2_genuine_leak')
  ) AS s(shelf_code, action, qty, status, tag)
JOIN public.machines m ON m.official_name = 'GRIT-1022-0100-W0'
JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id AND sc.shelf_code = s.shelf_code
JOIN public.slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.archived = false AND sl.is_current = true;

UPDATE public.pod_refill_plan SET stitched_at = now() WHERE plan_date = {{plan_date}};

INSERT INTO public.refill_plan_output
  (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name, action, quantity,
   operator_status, machine_id, shelf_id, pod_product_id, source_origin, comment)
SELECT {{plan_date}}, 'GRIT-1022-0100-W0', s.shelf_code, pp.pod_product_name,
       pp.pod_product_name || ' - ' || s.variant, 'Remove', s.qty, 'approved',
       m.machine_id, sc.shelf_id, sl.pod_product_id, 'warehouse'::source_origin_enum,
       'golden_fixture_33 ' || s.tag
FROM (VALUES
    ('A06', 3, 'Variant A', 'C1_conserving'),
    ('A06', 2, 'Variant B', 'C1_conserving'),
    ('A07', 3, 'Variant A', 'C2_genuine_leak'),
    ('A07', 2, 'Variant B', 'C2_genuine_leak'),
    ('A07', 2, 'Variant C', 'C2_genuine_leak')
  ) AS s(shelf_code, qty, variant, tag)
JOIN public.machines m ON m.official_name = 'GRIT-1022-0100-W0'
JOIN public.shelf_configurations sc ON sc.machine_id = m.machine_id AND sc.shelf_code = s.shelf_code
JOIN public.slot_lifecycle sl ON sl.shelf_id = sc.shelf_id AND sl.archived = false AND sl.is_current = true
JOIN public.pod_products pp ON pp.pod_product_id = sl.pod_product_id;

-- the dirty-plan verdict, before any commit is attempted
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'pf_dirty', jsonb_build_object(
  'verdict', pf.verdict,
  'n_viol',  jsonb_array_length(pf.violations),
  'n_warn',  jsonb_array_length(pf.warnings),
  'n_inv06', (SELECT count(*) FROM jsonb_array_elements(pf.violations) v WHERE v->>'invariant_id' = 'INV-06'))
FROM public.preflight_refill_plan({{plan_date}}) pf;

-- P1 warn mode: commit still succeeds, but must now REPORT the verdict
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'warn',
       golden.probe_commit_under_mode({{plan_date}}, 'warn', 'golden fixture 33 - warn probe');

-- P2 block mode: commit must REFUSE and write nothing
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block',
       golden.probe_commit_under_mode({{plan_date}}, 'block', 'golden fixture 33 - block probe');

-- P3 block mode + a too-short override reason: must raise, commit nothing, log nothing
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_short',
       golden.probe_commit_under_mode({{plan_date}}, 'block', 'golden fixture 33 - short reason probe',
                                      true, 'short');

-- P4 block mode + a valid audited override: commit proceeds, override is logged
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_override',
       golden.probe_commit_under_mode({{plan_date}}, 'block', 'golden fixture 33 - audited override probe',
                                      true, 'CS override for golden fixture 33 conservation leak');

-- P5 the override is SINGLE-USE: the very next block-mode commit must refuse again
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_again',
       golden.probe_commit_under_mode({{plan_date}}, 'block', 'golden fixture 33 - override reuse probe');

-- capture the override row as jsonb so the assertions parse even before the
-- source / consumed_at columns exist (RED baseline must not ERROR)
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'ov_row',
       COALESCE((SELECT to_jsonb(pol) FROM public.preflight_override_log pol
                  WHERE pol.plan_date = {{plan_date}}
                  ORDER BY pol.overridden_at DESC LIMIT 1), '{}'::jsonb);

-- ANTI-OVER-BLOCK: repair the leak, and the very same gate must let it through
UPDATE public.pod_refill_plan SET qty = 7
 WHERE plan_date = {{plan_date}} AND reasoning->>'scenario' = 'C2_genuine_leak';

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'pf_clean', jsonb_build_object(
  'verdict', pf.verdict, 'n_viol', jsonb_array_length(pf.violations))
FROM public.preflight_refill_plan({{plan_date}}) pf;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'block_clean',
       golden.probe_commit_under_mode({{plan_date}}, 'block', 'golden fixture 33 - clean plan under block');

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'final', jsonb_build_object(
  'enforcement',    (SELECT COALESCE(preflight_enforcement,'warn') FROM public.refill_policy_params ORDER BY id LIMIT 1),
  'df_open',        (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'ovlog_other',    (SELECT count(*) FROM public.preflight_override_log WHERE plan_date <> {{plan_date}}),
  'commitlog_other',(SELECT count(*) FROM public.refill_commit_log WHERE plan_date <> {{plan_date}}));
$scn$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- ── non-vacuity (RISK 98 / S-48 / S-52 discipline) ────────────────────────
(33, 1, 'NON-VACUITY: 2 REMOVE parents seeded on the fixture plan_date',
 'SELECT count(*)::text FROM public.pod_refill_plan WHERE plan_date = {{plan_date}}',
 'eq', '2', true, 'P2'),
(33, 2, 'NON-VACUITY: 5 child legs seeded on the fixture plan_date',
 'SELECT count(*)::text FROM public.refill_plan_output WHERE plan_date = {{plan_date}}',
 'eq', '5', true, 'P2'),
(33, 3, 'NON-VACUITY: the dirty plan really is dirty - preflight verdict FAIL',
 'SELECT value->>''verdict'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''pf_dirty''',
 'eq', 'FAIL', true, 'P2'),
(33, 4, 'NON-VACUITY: the dirty verdict is exactly ONE violation, and it is the INV-06 leak',
 'SELECT value->>''n_inv06'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''pf_dirty''',
 'eq', '1', true, 'P2'),
(33, 5, 'NON-VACUITY: every probe actually ran (7 scratch rows written by the scenario)',
 'SELECT count(*)::text FROM golden.scratch WHERE fixture_id = {{fixture_id}}',
 'gte', '9', true, 'P2'),

-- ── WARN mode: behaviour unchanged, but the verdict must be REPORTED ──────
(33, 10, 'WARN: commit still succeeds (the flag is warn; nothing may start refusing without CS burn-in)',
 'SELECT value->''result''->>''status'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''warn''',
 'eq', 'ok', true, 'P2'),
(33, 11, 'WARN: the commit response now CARRIES the preflight verdict instead of hiding it',
 'SELECT value->''result''->''preflight''->>''verdict'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''warn''',
 'eq', 'FAIL', true, 'P2'),
(33, 12, 'WARN: the commit response names the enforcement mode it ran under',
 'SELECT value->''result''->''preflight''->>''enforcement'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''warn''',
 'eq', 'warn', true, 'P2'),
(33, 13, 'WARN: exactly one commit_log row was written',
 'SELECT value->>''commit_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''warn''',
 'eq', '1', true, 'P2'),

-- ── BLOCK mode: the headline ─────────────────────────────────────────────
(33, 20, 'BLOCK: commit REFUSES a plan that violates an invariant (fixture 33 headline)',
 'SELECT value->''result''->>''status'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block''',
 'eq', 'preflight_failed', true, 'P2'),
(33, 21, 'BLOCK: a refused commit writes ZERO commit_log rows - the refusal is real, not cosmetic',
 'SELECT value->>''commit_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block''',
 'eq', '0', true, 'P2'),
(33, 22, 'BLOCK: the refusal reports the violation count',
 'SELECT value->''result''->>''violation_count'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block''',
 'eq', '1', true, 'P2'),
(33, 23, 'BLOCK: the refusal hands back the violation itself, naming INV-06 (a fix path, not just a NO)',
 'SELECT value->''result''->>''violations'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block''',
 'contains', 'INV-06', true, 'P2'),

-- ── the audited override ─────────────────────────────────────────────────
(33, 30, 'OVERRIDE: preflight_override_v3(date,text) exists as the single audited escape hatch',
 'SELECT (to_regprocedure(''public.preflight_override_v3(date,text)'') IS NOT NULL)::text',
 'eq', 'true', true, 'P2'),
(33, 31, 'OVERRIDE: a reason shorter than 10 characters is REFUSED',
 'SELECT value->''error''->>''message'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_short''',
 'contains', '10 characters', true, 'P2'),
(33, 32, 'OVERRIDE: the short-reason attempt committed NOTHING',
 'SELECT value->>''commit_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_short''',
 'eq', '0', true, 'P2'),
(33, 33, 'OVERRIDE: a valid audited override lets the commit through under block mode',
 'SELECT value->''result''->>''status'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_override''',
 'eq', 'ok', true, 'P2'),
(33, 34, 'OVERRIDE: exactly one preflight_override_log row was written for the plan_date',
 'SELECT value->>''override_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_override''',
 'eq', '1', true, 'P2'),
(33, 35, 'OVERRIDE: the audit row records WHICH gate was overridden',
 'SELECT value->>''source'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''ov_row''',
 'eq', 'commit', true, 'P2'),
(33, 36, 'OVERRIDE: the audit row records the operator reason verbatim',
 'SELECT value->>''reason'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''ov_row''',
 'contains', 'golden fixture 33', true, 'P2'),
(33, 37, 'OVERRIDE IS SINGLE USE: consuming it stamps consumed_at',
 'SELECT (value->>''consumed_at'' IS NOT NULL)::text FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''ov_row''',
 'eq', 'true', true, 'P2'),
(33, 38, 'OVERRIDE IS SINGLE USE: the NEXT block-mode commit refuses again - one override, one commit',
 'SELECT value->''result''->>''status'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_again''',
 'eq', 'preflight_failed', true, 'P2'),
(33, 39, 'OVERRIDE IS SINGLE USE: the reuse attempt wrote no commit_log row',
 'SELECT value->>''commit_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_again''',
 'eq', '0', true, 'P2'),

-- ── ANTI-OVER-BLOCK: the gate must not become a wall ─────────────────────
(33, 40, 'ANTI-OVER-BLOCK: repairing the leak flips the verdict to PASS (the gate reads the plan, not the calendar)',
 'SELECT value->>''verdict'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''pf_clean''',
 'eq', 'PASS', true, 'P2'),
(33, 41, 'ANTI-OVER-BLOCK: a clean plan commits under BLOCK mode with no override at all',
 'SELECT value->''result''->>''status'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_clean''',
 'eq', 'ok', true, 'P2'),
(33, 42, 'ANTI-OVER-BLOCK: the clean block-mode commit really did write its commit_log row',
 'SELECT value->>''commit_log_delta'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_clean''',
 'eq', '1', true, 'P2'),
(33, 43, 'ANTI-OVER-BLOCK: the clean commit reports verdict PASS in its response',
 'SELECT value->''result''->''preflight''->>''verdict'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''block_clean''',
 'eq', 'PASS', true, 'P2'),

-- ── harness safety ───────────────────────────────────────────────────────
(33, 90, 'HARNESS SAFETY: preflight_enforcement is restored to exactly what it was before the fixture ran',
 'SELECT (SELECT value->>''enforcement'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
       = (SELECT value->>''enforcement'' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines'')',
 'eq', 'true', true, 'P2'),
(33, 91, 'HARNESS SAFETY: the live flag is back to warn (CS burn-in is not over)',
 'SELECT COALESCE(preflight_enforcement,''warn'') FROM public.refill_policy_params ORDER BY id LIMIT 1',
 'eq', 'warn', true, 'P2'),
(33, 92, 'HARNESS SAFETY: the fixture resolved no live driver_feedback',
 'SELECT ((SELECT (value->>''df_open'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
        - (SELECT (value->>''df_open'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines''))::text',
 'eq', '0', true, 'P2'),
(33, 93, 'HARNESS SAFETY: zero override_log rows were written for any OTHER plan_date',
 'SELECT ((SELECT (value->>''ovlog_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
        - (SELECT (value->>''ovlog_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines''))::text',
 'eq', '0', true, 'P2'),
(33, 94, 'HARNESS SAFETY: zero commit_log rows were written for any OTHER plan_date',
 'SELECT ((SELECT (value->>''commitlog_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''final'')
        - (SELECT (value->>''commitlog_other'')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = ''baselines''))::text',
 'eq', '0', true, 'P2');
