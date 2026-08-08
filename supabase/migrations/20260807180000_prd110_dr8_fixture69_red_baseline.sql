-- PRD-110 DR-8 — FIXTURE 69, authored BEFORE the RPC it proves (LAW 1).
-- ⛔ It is EXPECTED to run RED on its first fire: public.approve_facing_proposal_v3 does not
--    exist yet, so every executed probe returns 42883 and the scenario itself completes (the
--    probes are individually trapped) — i.e. this is an HONEST red baseline, not a scenario_error.
--
-- ⭐ THE DESIGN POINT (D-47 / S-173 doctrine): the RPC is EXECUTED at every refusal it owns and
--    on both happy paths, never inspected from its own source text.
--
-- ⛔ THE FIXTURE OWNS ITS PREMISES (leg-114/115 idiom, S-274): it PLANTS the two proposals it
--    decides. It never reads, never decides and never counts the live CS queue — every one of the
--    20 rows sitting in facing_proposals_v3 today is fixture-48 residue at plan_date 2030-02-18
--    (S-276) and the fixture must not become the 21st.
--
-- ⛔ SENTINEL IS NOT `plan_date >= '2030-01-01'` (leg 145): that band is occupied. This fixture
--    keys on the two proposal_ids it minted, and secondarily on its own two plan_dates
--    2030-06-09 / 2030-06-10, which no other fixture uses.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (69,
 'DR-8 facing approve/reject RPC: the anonymous caller is refused BY NAME rather than by a bare CHECK violation, both decisions are EXECUTED end to end on planted proposals, ''applied'' is never written, and the return payload DISCLOSES that approval moves no plan',
 'PRD-110 DR-8 (CS ruling 2026-08-04) + leg 145 S-276 (the queue it serves holds zero real proposals)',
 'P4', DATE '2030-06-09',
$scn$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ── STATIC HALF: structure + the disclosure evidence, nothing written ─────────
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'static', jsonb_build_object(
  'rpc_count',      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = 'approve_facing_proposal_v3'),
  'rpc_secdef',     (SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = 'approve_facing_proposal_v3'),
  'rpc_owner',      (SELECT pg_get_userbyid(p.proowner) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = 'approve_facing_proposal_v3'),
  'rpc_cfg',        (SELECT array_to_string(p.proconfig, ' ') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = 'approve_facing_proposal_v3'),
  'rpc_acl',        (SELECT COALESCE(p.proacl::text,'<default>') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = 'approve_facing_proposal_v3'),
  'rpc_names_itself',(SELECT (p.prosrc LIKE '%app.rpc_name%') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.proname = 'approve_facing_proposal_v3'),
  'rls_on',         (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.facing_proposals_v3'::regclass),
  'n_policies',     (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.facing_proposals_v3'::regclass),
  'auth_insert',    has_table_privilege('authenticated','public.facing_proposals_v3','INSERT'),
  'auth_update',    has_table_privilege('authenticated','public.facing_proposals_v3','UPDATE'),
  'auth_select',    has_table_privilege('authenticated','public.facing_proposals_v3','SELECT'),
  'anon_select',    has_table_privilege('anon','public.facing_proposals_v3','SELECT'),
  'review_named_chk',(SELECT pg_get_constraintdef(oid) FROM pg_constraint
                       WHERE conname = 'fp_v3_review_named'),
  -- ── S-276 DISCLOSURE EVIDENCE, derived from the SOURCE side (S-267), never from
  --    facing_proposals_v3 itself ───────────────────────────────────────────────
  'proc_readers',   (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.prosrc ILIKE '%facing_proposals_v3%'
                        AND p.proname <> 'approve_facing_proposal_v3'),
  'proc_consumers_of_approved',
                    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname = 'public' AND p.prosrc ILIKE '%facing_proposals_v3%'
                        AND p.prosrc ILIKE '%approved%'
                        AND p.proname <> 'approve_facing_proposal_v3'),
  'view_consumers_of_approved',
                    (SELECT string_agg(c.relname, ',' ORDER BY c.relname) FROM pg_class c
                       JOIN pg_namespace n ON n.oid = c.relnamespace
                      WHERE c.relkind = 'v' AND n.nspname = 'public'
                        AND pg_get_viewdef(c.oid) ILIKE '%facing_proposals_v3%'
                        AND pg_get_viewdef(c.oid) ILIKE '%approved%'),
  -- ⛔ CODY R2: NO OTHER FIXTURE IN THE SUITE READS cron.job, AND golden.run_fixture IS SECURITY
  --    INVOKER. The sweep only reads that table because it happens to run as postgres. An
  --    unprivileged run would raise INSIDE this single INSERT, killing the whole scenario — and
  --    per S-266 a raising scenario re-evaluates the PREVIOUS run's snapshot and can report GREEN.
  --    The privilege is therefore CHECKED, and its absence becomes a red actual that explains
  --    itself, never a scenario_error that lies.
  'crons_minting_facings',
                    (CASE WHEN to_regclass('cron.job') IS NOT NULL
                            AND has_table_privilege(current_user, 'cron.job', 'SELECT')
                          THEN (SELECT count(*)::text FROM cron.job WHERE command ILIKE '%facing%')
                          ELSE 'NO_ACCESS' END),
  'queue_real_pending',
                    (SELECT count(*) FROM public.facing_proposals_v3
                      WHERE status = 'pending' AND plan_date < DATE '2027-01-01'),
  'queue_pending_before',
                    (SELECT count(*) FROM public.facing_proposals_v3 WHERE status = 'pending')
);

-- ── EXECUTED HALF: every refusal and both decisions actually driven, inside a
--    rolled-back probe. NOTHING below this line survives the fixture. ──────────
DO $fx69$
DECLARE
  c_admin   constant text := '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}';
  c_field   constant text := '{"sub":"34b19df6-d6c7-4008-9a51-63e5c09fa134","role":"authenticated"}';
  c_noone   constant text := '{"role":"authenticated"}';
  v_admin   constant uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  v_m       uuid;
  v_pod     uuid;
  v_p1      uuid;
  v_p2      uuid;
  v_ret_a   jsonb := '{}'::jsonb;
  v_ret_r   jsonb := '{}'::jsonb;
  v_payload jsonb;
  s_anon    text := 'NOT_ATTEMPTED';  e_anon    text := 'NOT_ATTEMPTED';
  s_field   text := 'NOT_ATTEMPTED';  e_field   text := 'NOT_ATTEMPTED';
  s_baddec  text := 'NOT_ATTEMPTED';
  s_shortnt text := 'NOT_ATTEMPTED';
  s_absent  text := 'NOT_ATTEMPTED';  e_absent  text := 'NOT_ATTEMPTED';
  s_approve text := 'NOT_ATTEMPTED';
  s_redo    text := 'NOT_ATTEMPTED';  e_redo    text := 'NOT_ATTEMPTED';
  s_reject  text := 'NOT_ATTEMPTED';
  v_row1    public.facing_proposals_v3%ROWTYPE;
  v_row2    public.facing_proposals_v3%ROWTYPE;
BEGIN
  SELECT machine_id     INTO v_m   FROM public.machines      ORDER BY machine_id::text     LIMIT 1;
  SELECT pod_product_id INTO v_pod FROM public.pod_products  ORDER BY pod_product_id::text LIMIT 1;
  IF v_m IS NULL OR v_pod IS NULL THEN
    RAISE EXCEPTION 'fixture 69 setup: no machine/pod exists to anchor the planted proposals, so every probe below would be vacuous';
  END IF;

  BEGIN
    -- ⛔ EVERYTHING INSIDE THIS BLOCK IS DISCARDED. The two planted proposals, the decisions
    --    taken on them and every GUC change roll back when the RAISE at the end fires. Only
    --    v_payload escapes, smuggled out through the error message (the fixture-24/67 idiom).

    -- (0) PLANT the two proposals this fixture owns. ⛔ It decides ONLY these.
    INSERT INTO public.facing_proposals_v3
      (plan_date, machine_id, pod_product_id, direction, facings_current, facings_proposed,
       rev_per_facing_day_potential, machine_peer_median, peer_families, ratio_to_median,
       unit_price, price_basis, velocity_basis, score, scoring_breakdown)
    VALUES
      (DATE '2030-06-09', v_m, v_pod, 'expand', 1, 2, 3.50, 2.00, 4, 1.75, 5.00,
       'golden_fixture_69', 'golden_fixture_69', 1.25, jsonb_build_object('planted_by', 69))
    RETURNING proposal_id INTO v_p1;

    INSERT INTO public.facing_proposals_v3
      (plan_date, machine_id, pod_product_id, direction, facings_current, facings_proposed,
       rev_per_facing_day_potential, machine_peer_median, peer_families, ratio_to_median,
       unit_price, price_basis, velocity_basis, score, scoring_breakdown)
    VALUES
      (DATE '2030-06-10', v_m, v_pod, 'shrink', 3, 2, 0.40, 2.00, 4, 0.20, 5.00,
       'golden_fixture_69', 'golden_fixture_69', 0.90, jsonb_build_object('planted_by', 69))
    RETURNING proposal_id INTO v_p2;

    -- (1) ⛔⛔ THE ANONYMOUS CALLER. This is the sharp bit DR-8 exists to get right:
    --     fp_v3_review_named CHECKs (status in approved/rejected/applied) => reviewed_by NOT NULL.
    --     A copy of approve_feedback_proposal_v3 (which tolerates auth.uid() IS NULL) would reach
    --     that CHECK and surface to CS as a bare 23514 naming a constraint instead of the missing
    --     identity. The RPC must refuse FIRST, by name.
    --     ⛔ BOTH GUCs must be neutralised: auth.uid() coalesces request.jwt.claim.sub BEFORE
    --        request.jwt.claims, so clearing only the latter would leave the caller identified.
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims',    c_noone, true);
    BEGIN
      PERFORM public.approve_facing_proposal_v3(v_p1, 'approve', 'fixture 69 anonymous-caller probe');
      s_anon := 'NONE'; e_anon := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_anon := SQLSTATE; e_anon := SQLERRM; END;

    -- (2) A REAL BUT UNPRIVILEGED CALLER (field_staff). Article 5: deciding proposals is an
    --     operator_admin/superadmin act.
    PERFORM set_config('request.jwt.claims', c_field, true);
    BEGIN
      PERFORM public.approve_facing_proposal_v3(v_p1, 'approve', 'fixture 69 field-staff probe');
      s_field := 'NONE'; e_field := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_field := SQLSTATE; e_field := SQLERRM; END;

    -- (3) BACK TO THE ADMIN for the argument guards and both decisions.
    PERFORM set_config('request.jwt.claims', c_admin, true);

    BEGIN
      PERFORM public.approve_facing_proposal_v3(v_p1, 'apply', 'fixture 69 bad-decision probe');
      s_baddec := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_baddec := SQLSTATE; END;

    BEGIN
      PERFORM public.approve_facing_proposal_v3(v_p1, 'approve', 'too short');
      s_shortnt := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_shortnt := SQLSTATE; END;

    BEGIN
      PERFORM public.approve_facing_proposal_v3
        ('00000000-0000-0000-0000-000000000069'::uuid, 'approve', 'fixture 69 absent-proposal probe');
      s_absent := 'NONE'; e_absent := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_absent := SQLSTATE; e_absent := SQLERRM; END;

    -- (4) APPROVE — the happy path, end to end.
    BEGIN
      v_ret_a := public.approve_facing_proposal_v3(v_p1, 'approve',
        'fixture 69: approved for the golden suite, expand A -> B');
      s_approve := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_approve := SQLSTATE; v_ret_a := jsonb_build_object('err', SQLERRM); END;

    -- (5) RE-DECIDE the same proposal — a decided proposal is closed.
    BEGIN
      PERFORM public.approve_facing_proposal_v3(v_p1, 'reject', 'fixture 69 re-decision probe');
      s_redo := 'NONE'; e_redo := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_redo := SQLSTATE; e_redo := SQLERRM; END;

    -- (6) REJECT — the other half. ⛔ CS must be able to CLEAR the queue, not only fill it.
    BEGIN
      v_ret_r := public.approve_facing_proposal_v3(v_p2, 'reject',
        'fixture 69: rejected for the golden suite, shrink not warranted');
      s_reject := 'NONE';
    EXCEPTION WHEN OTHERS THEN s_reject := SQLSTATE; v_ret_r := jsonb_build_object('err', SQLERRM); END;

    SELECT * INTO v_row1 FROM public.facing_proposals_v3 WHERE proposal_id = v_p1;
    SELECT * INTO v_row2 FROM public.facing_proposals_v3 WHERE proposal_id = v_p2;

    v_payload := jsonb_build_object(
      'planted',        (SELECT count(*) FROM public.facing_proposals_v3
                          WHERE plan_date IN (DATE '2030-06-09', DATE '2030-06-10')),
      's_anon',         s_anon,    'e_anon',    e_anon,
      's_field',        s_field,   'e_field',   e_field,
      's_baddec',       s_baddec,
      's_shortnt',      s_shortnt,
      's_absent',       s_absent,  'e_absent',  e_absent,
      's_approve',      s_approve,
      's_redo',         s_redo,    'e_redo',    e_redo,
      's_reject',       s_reject,
      'ret_a_status',   COALESCE(v_ret_a->>'status','<absent>'),
      'ret_a_effect',   COALESCE(v_ret_a->>'plan_effect','<absent>'),
      'ret_a_detail',   COALESCE(v_ret_a->>'plan_effect_detail','<absent>'),
      'ret_r_status',   COALESCE(v_ret_r->>'status','<absent>'),
      'row1_status',    COALESCE(v_row1.status,'<absent>'),
      'row1_reviewer',  COALESCE(v_row1.reviewed_by::text,'<null>'),
      'row1_reviewed',  (v_row1.reviewed_at IS NOT NULL),
      'row1_applied_pd',COALESCE(v_row1.applied_to_plan_date::text,'<null>'),
      'row1_note',      COALESCE(v_row1.review_note,'<null>'),
      'row2_status',    COALESCE(v_row2.status,'<absent>'),
      'row2_reviewer',  COALESCE(v_row2.reviewed_by::text,'<null>'),
      'admin_is',       v_admin::text);
    RAISE EXCEPTION 'GP69:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP69:%' THEN v_payload := substring(SQLERRM from 'GP69:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx69$;

-- ── RESIDUE: the probe planted two rows, decided them, and must have left nothing ──
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'planted_after',  (SELECT count(*) FROM public.facing_proposals_v3
                      WHERE plan_date IN (DATE '2030-06-09', DATE '2030-06-10')),
  'pending_after',  (SELECT count(*) FROM public.facing_proposals_v3 WHERE status = 'pending'),
  'via_rpc_after',  COALESCE(NULLIF(current_setting('app.via_rpc', true), ''), 'UNSET'),
  'caller_after',   COALESCE(auth.uid()::text, '<null>')
);
$scn$,
 'DR-8. seq 20-39 are the executed core; seq 40-44 are the S-276 disclosure (the queue this RPC serves holds zero REAL proposals and no cron fills it); seq 50-53 the residue. ⛔ Do not soften seq 20 to not_null — "P0001 and not 23514" IS the claim, and 23514 here would mean the RPC let the CHECK do its refusing for it.',
 true, 'failing_expected');

-- PRD-110 DR-8 — fixture 69 assertions.
-- Grouping: 1-12 STRUCTURE · 20-39 the EXECUTED RPC (the core) · 40-44 the S-276 DISCLOSURE ·
--           50-53 the RESIDUE.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ── STRUCTURE ────────────────────────────────────────────────────────────────
(69, 1, 'DR-8: the approve RPC exists, exactly once. ⛔ Two overloads on a decision writer is the repurpose_machine foot-gun (CLAUDE.md) applied to CS review — always check pg_proc before adding one.',
 'SELECT (value->>''rpc_count'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P4'),
(69, 2, 'Article 5: it is SECURITY DEFINER — the caller holds no write privilege on facing_proposals_v3 (seq 8/9), so the RPC is the only way a decision can be recorded.',
 'SELECT (value->>''rpc_secdef'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P4'),
(69, 3, 'It is owned by postgres. A definer owned by anyone else would run with the wrong authority.',
 'SELECT (value->>''rpc_owner'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'postgres', true, 'P4'),
(69, 4, 'search_path is pinned on the definer — the standing Supabase hardening rule for every SECURITY DEFINER in this build.',
 'SELECT (value->>''rpc_cfg'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'search_path=public', true, 'P4'),
(69, 5, '⛔ S-268: `anon` holds no EXECUTE. REVOKE ALL FROM PUBLIC does NOT remove Supabase''s default grants, so the revoke has to name anon explicitly — this assertion is what proves it was named.',
 'SELECT (value->>''rpc_acl'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'ne', '<default>', true, 'P4'),
(69, 6, 'S-268, the positive half: `anon=X` appears nowhere in the ACL.',
 'SELECT ((value->>''rpc_acl'') NOT LIKE ''%anon=X%'')::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P4'),
(69, 7, '`authenticated` CAN execute it — this is the CS review path, and revoking it would leave the queue unclearable.',
 'SELECT (value->>''rpc_acl'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'authenticated=X', true, 'P4'),
(69, 8, 'Article 3: `authenticated` cannot INSERT into facing_proposals_v3 directly.',
 'SELECT (value->>''auth_insert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P4'),
(69, 9, 'Article 3: `authenticated` cannot UPDATE facing_proposals_v3 directly — so the status column has exactly one writer, which is the point of DR-8.',
 'SELECT (value->>''auth_update'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P4'),
(69, 10, 'The read path survives: `authenticated` keeps SELECT, so a CS review screen can still list the queue.',
 'SELECT (value->>''auth_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P4'),
(69, 11, 'RLS stays on and the single fp_v3_select policy is untouched. DR-8 adds a writer; it does not reshape the table''s access model.',
 'SELECT (value->>''n_policies'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P4'),
(69, 12, '⛔ THE CONSTRAINT THAT MAKES seq 20 NECESSARY still exists, worded as measured: any approved/rejected/applied row must name its reviewer. If this is ever relaxed, seq 20''s refusal stops being load-bearing and this fixture must be restated, not quietly kept.',
 'SELECT (value->>''review_named_chk'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'reviewed_by IS NOT NULL', true, 'P4'),

-- ── THE EXECUTED RPC — the core ──────────────────────────────────────────────
(69, 20, '⭐⭐ EXECUTED, and this is THE assertion of DR-8: an ANONYMOUS caller is refused with P0001 — the RPC''s own RAISE — and NOT with 23514. ⛔ 23514 here would mean the RPC copied approve_feedback_proposal_v3 (which tolerates auth.uid() IS NULL), reached fp_v3_review_named and let a CHECK do its refusing, surfacing to CS as a constraint name instead of "you are not identified". ⛔ Do not soften to not_null.',
 'SELECT (value->>''s_anon'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'P0001', true, 'P4'),
(69, 21, '⭐ The anonymous refusal NAMES the missing identity in words a reviewer can act on.',
 'SELECT (value->>''e_anon'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'contains', 'identified caller', true, 'P4'),
(69, 22, 'The anonymous refusal also names the constraint it is pre-empting, so the next engineer knows WHY the guard is first rather than deleting it as redundant.',
 'SELECT (value->>''e_anon'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'contains', 'fp_v3_review_named', true, 'P4'),
(69, 23, '⭐ EXECUTED: an identified but UNPRIVILEGED caller (field_staff) is refused. Article 5 — deciding a proposal is an operator_admin/superadmin act.',
 'SELECT (value->>''s_field'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'P0001', true, 'P4'),
(69, 24, 'The unprivileged refusal is about PERMISSION, not identity — the two refusals must not collapse into one message.',
 'SELECT (value->>''e_field'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'contains', 'not permitted', true, 'P4'),
(69, 25, 'EXECUTED: a decision outside approve/reject is refused. ⛔ ''apply'' is the probe value on purpose: ''applied'' is a real status of this table and DR-8 must not offer it as a decision (seq 33).',
 'SELECT (value->>''s_baddec'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'P0001', true, 'P4'),
(69, 26, 'EXECUTED: a review note under 10 characters is refused — same bar as every other decision RPC in this build.',
 'SELECT (value->>''s_shortnt'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'P0001', true, 'P4'),
(69, 27, 'EXECUTED: an unknown proposal_id is refused rather than silently doing nothing (the silent-no-op class this build treats as a build failure).',
 'SELECT (value->>''s_absent'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'P0001', true, 'P4'),
(69, 28, 'The absent-proposal refusal says so in words.',
 'SELECT (value->>''e_absent'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'contains', 'not found', true, 'P4'),
(69, 29, '⭐⭐ EXECUTED HAPPY PATH: the approve call SUCCEEDS on a planted pending proposal.',
 'SELECT (value->>''s_approve'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'NONE', true, 'P4'),
(69, 30, 'The approve call returns status=approved.',
 'SELECT (value->>''ret_a_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'approved', true, 'P4'),
(69, 31, '⭐⭐ THE DISCLOSURE, IN THE RETURN VALUE: plan_effect reads ''none_yet''. ⛔ S-128''s lesson applied as DISCLOSURE, not refusal — approve_feedback_proposal_v3 REFUSES never_stock because approving it would mint a pin the engine ignores, i.e. a live rule that lies. Approving a FACING proposal mints nothing, so refusing would leave CS unable to clear the queue at all. The RPC records the decision and SAYS what it does not do.',
 'SELECT (value->>''ret_a_effect'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'none_yet', true, 'P4'),
(69, 32, 'The disclosure is legible, not a bare enum: the payload names the fact that no planner consumes the approved status today.',
 'SELECT (value->>''ret_a_detail'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'contains', 'no plan object', true, 'P4'),
(69, 33, '⭐⭐ THE ROW AFTER APPROVAL IS ''approved'', NEVER ''applied''. ⛔ ''applied'' and applied_to_plan_date belong to a FUTURE applier that will change a plan; writing them here would claim a facing change had reached a machine when nothing did.',
 'SELECT (value->>''row1_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'approved', true, 'P4'),
(69, 34, '⭐⭐ applied_to_plan_date stays NULL. This is the other half of seq 33 and the one a careless future applier will trip.',
 'SELECT (value->>''row1_applied_pd'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '<null>', true, 'P4'),
(69, 35, 'The decision is ATTRIBUTED: reviewed_by is the admin who called it — which is what satisfies fp_v3_review_named honestly rather than by luck.',
 'SELECT (((SELECT value->>''row1_reviewer'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs'') = (SELECT value->>''admin_is'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''))::text)', 'eq', 'true', true, 'P4'),
(69, 36, 'The decision is TIMED: reviewed_at is set.',
 'SELECT (value->>''row1_reviewed'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'true', true, 'P4'),
(69, 37, 'The review note is stored (trimmed), so the audit answers "why" and not merely "who".',
 'SELECT (value->>''row1_note'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'contains', 'approved for the golden suite', true, 'P4'),
(69, 38, 'EXECUTED: re-deciding a decided proposal is REFUSED — a decision is closed, and a second reviewer must not be able to silently overwrite the first.',
 'SELECT (value->>''s_redo'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'P0001', true, 'P4'),
(69, 39, '⭐ EXECUTED: the REJECT half works and lands as ''rejected''. ⛔ CS must be able to CLEAR this queue, not only fill it — an RPC that could approve but not reject would leave every unwanted proposal pending forever.',
 'SELECT (value->>''row2_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'rejected', true, 'P4'),

-- ── THE S-276 DISCLOSURE — measured, not narrated ─────────────────────────────
(69, 40, 'NON-VACUITY: both planted proposals existed when the probes ran. Without this, every refusal above could be passing because there was nothing to decide.',
 'SELECT (value->>''planted'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '2', true, 'P4'),
(69, 41, '⛔ S-276, MEASURED FROM THE SOURCE SIDE (S-267): exactly ONE other function in public reads facing_proposals_v3 — propose_facing_changes_v3, the proposer. There is no applier and no second writer.',
 'SELECT (value->>''proc_readers'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P4'),
(69, 42, '⭐⭐ THIS IS WHY plan_effect IS ''none_yet'': ZERO functions consume the approved status. Approving changes no plan, no pin, no dispatch. ⚠️ When an applier legitimately ships, this goes to 1 — re-baseline it THEN, in the same unit, and restate seq 31/32 with it.',
 'SELECT (value->>''proc_consumers_of_approved'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P4'),
(69, 43, '⭐ THE ONE THING THAT DOES READ IT IS A SCOREBOARD, NOT A PLANNER: v_proposal_acceptance_v3 maps approved -> the ''accepted'' bucket for the G12 acceptance metric. Naming it here is what keeps seq 42''s claim honest — "nothing consumes it" would have been false, and "nothing PLANS on it" is true.',
 'SELECT (value->>''view_consumers_of_approved'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'v_proposal_acceptance_v3', true, 'P4'),
(69, 44, '⛔⛔ S-276 / S-244, THE HONEST HEADLINE: the REVIEWABLE queue this RPC serves is EMPTY. Every pending row is fixture-48 residue at plan_date 2030-02-18, and a CS-facing read filters plan_date < 2027-01-01. Contrast DR-7, which shipped a real weekly cron. ⚠️ When a facing filler legitimately ships this becomes non-zero — re-baseline it THEN, naming the filler, never before.',
 'SELECT (value->>''queue_real_pending'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P4'),
(69, 45, '⛔ S-276, the cause rather than the symptom: NO cron job mints facing proposals. propose_facing_changes_v3 is unwired, which is exactly why seq 44 reads zero. ⛔ Cody R2: an actual of NO_ACCESS means the suite was run without SELECT on cron.job — the claim is then UNMEASURED, not satisfied, and it reads red rather than taking the scenario down.',
 'SELECT (value->>''crons_minting_facings'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P4'),

-- ── THE RESIDUE ──────────────────────────────────────────────────────────────
(69, 50, 'RESIDUE: both planted proposals are gone. The probe INSERTed two rows into a live CS review table — this proves they were discarded rather than committed. ⛔ S-265 is the standing example of a fixture that minted into a real queue and left it there; fixture 69 must never join it.',
 'SELECT (value->>''planted_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', '0', true, 'P4'),
(69, 51, 'RESIDUE: the pending count is exactly what it was before the probe. Nothing this fixture did changed what CS sees in the queue.',
 'SELECT (((SELECT value->>''pending_after'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after'') = (SELECT value->>''queue_pending_before'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''))::text)', 'eq', 'true', true, 'P4'),
(69, 52, 'RESIDUE (S-197): app.via_rpc does not leak out of the probe. The RPC sets it; a leak would silently satisfy write-guards for every later statement in the session.',
 'SELECT (value->>''via_rpc_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', 'UNSET', true, 'P4'),
(69, 53, '⛔ RESIDUE, IDENTITY: the probe impersonated nobody and then field_staff. This proves the session came back to the fixture''s own admin — an identity leak would silently change who every later fixture in a sweep runs as.',
 'SELECT (value->>''caller_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d', true, 'P4');
