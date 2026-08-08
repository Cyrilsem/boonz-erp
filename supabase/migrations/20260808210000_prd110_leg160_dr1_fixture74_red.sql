-- PRD-110 DR-1 — FIXTURE 74, authored BEFORE the unit it proves (LAW 1).
-- ⛔ EXPECTED RED on first fire: engine_cutover_authority_v3, engine_cutover_audit_v3,
--    v_cutover_readiness_v3, flip_cluster_to_v3_v3, revert_cluster_to_v19_v3,
--    is_cluster_authoritative_v3 and cutover_block_reason_v3 do not exist yet, so the scenario
--    raises and `scenario_error` is non-null. Per S-254 the whole assertion list is untrustworthy
--    on that run — that IS the honest red baseline, and both run ids get logged.
--
-- ⭐ DESIGN POINT (D-47 / S-173): the gate is EXECUTED at every branch of its refusal taxonomy,
--    including the `ready` branch, which live data cannot currently reach. A gate proven only by
--    the refusals it happens to emit today is a gate whose accept path has never run.
--
-- ⭐ S-301: the `ready` path is EXERCISED inside a forced-rollback subtransaction by planting a
--    settled v3+v19 series, never by reading live state — a live-state assertion would flip the
--    moment 2026-08-11 settles.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (74,
 'DR-1 per-cluster cutover authority: the registry ships FLAG-OFF at v19 for all 10 live clusters and never offers WH, the gate refuses every cluster today and refuses for TWO DIFFERENT reasons, the accept path is exercised rather than assumed, a REFUSED flip is audited as loudly as an applied one, the revert is never evidence-gated, and the live builder''s guard FAILS OPEN. ⛔ The readiness view must discount synthetic fixture dates (S-307): engine_forecast_error_v3 carries 529 rows on 2030 dates spanning all 10 clusters, so an unfiltered gate reports v3 evidence for six clusters that have never once been planned by v3.',
 'PRD-110 DR-1 (CS ruling 2026-08-04, per-cluster) + goal-command-2 Tier 4',
 'P1', DATE '2030-05-19',
$scn$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ── STATIC HALF: structure, seed, grants, and the readiness verdict as it stands ──
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'static', jsonb_build_object(
  'auth_tbl_exists',  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                        WHERE n.nspname='public' AND c.relname='engine_cutover_authority_v3'),
  'audit_tbl_exists', (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                        WHERE n.nspname='public' AND c.relname='engine_cutover_audit_v3'),
  'auth_rls',         (SELECT relrowsecurity FROM pg_class WHERE oid='public.engine_cutover_authority_v3'::regclass),
  'audit_rls',        (SELECT relrowsecurity FROM pg_class WHERE oid='public.engine_cutover_audit_v3'::regclass),
  'anon_select',      has_table_privilege('anon','public.engine_cutover_authority_v3','SELECT'),
  'anon_insert',      has_table_privilege('anon','public.engine_cutover_authority_v3','INSERT'),
  'authd_select',     has_table_privilege('authenticated','public.engine_cutover_authority_v3','SELECT'),
  'authd_update',     has_table_privilege('authenticated','public.engine_cutover_authority_v3','UPDATE'),
  'authd_delete',     has_table_privilege('authenticated','public.engine_cutover_authority_v3','DELETE'),
  'audit_no_update',  (SELECT count(*) FROM pg_policy WHERE polrelid='public.engine_cutover_audit_v3'::regclass
                        AND polcmd='w' AND pg_get_expr(polqual, polrelid)='false'),
  'audit_no_delete',  (SELECT count(*) FROM pg_policy WHERE polrelid='public.engine_cutover_audit_v3'::regclass
                        AND polcmd='d' AND pg_get_expr(polqual, polrelid)='false'),
  'seed_n',           (SELECT count(*) FROM public.engine_cutover_authority_v3),
  'seed_all_v19',     (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v19'),
  'seed_any_v3',      (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3'),
  'wh_present',       (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE cluster_key='WH'),
  'registry_vs_live', (SELECT count(*) FROM (
                          SELECT a.cluster_key, l.venue_group
                            FROM public.engine_cutover_authority_v3 a
                            FULL JOIN (SELECT DISTINCT venue_group FROM public.machines WHERE status='Active') l
                              ON l.venue_group = a.cluster_key
                           WHERE a.cluster_key IS NULL OR l.venue_group IS NULL) d),
  'engine_check',     (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                        WHERE conrelid='public.engine_cutover_authority_v3'::regclass
                          AND conname='eca_v3_flip_fields_together'),
  'readiness_rows',   (SELECT count(*) FROM public.v_cutover_readiness_v3),
  'n_ready',          (SELECT count(*) FROM public.v_cutover_readiness_v3 WHERE refusal_code='ready'),
  'n_no_v3',          (SELECT count(*) FROM public.v_cutover_readiness_v3 WHERE refusal_code='no_v3_measurement'),
  'n_horizon',        (SELECT count(*) FROM public.v_cutover_readiness_v3 WHERE refusal_code='v3_horizon_not_elapsed'),
  'vox_code',         (SELECT refusal_code FROM public.v_cutover_readiness_v3 WHERE cluster_key='VOX'),
  'vox_n_series_v3',  (SELECT n_series_v3 FROM public.v_cutover_readiness_v3 WHERE cluster_key='VOX'),
  'amazon_code',      (SELECT refusal_code FROM public.v_cutover_readiness_v3 WHERE cluster_key='AMAZON'),
  'wmape_never_zero', (SELECT count(*) FROM public.v_cutover_readiness_v3
                        WHERE is_vacuous AND wmape_v3 IS NOT NULL),
  'authoritative_any',(SELECT count(*) FROM public.machines m
                        WHERE m.status='Active' AND public.is_cluster_authoritative_v3(m.machine_id)),
  'block_reason_off', (SELECT (public.cutover_block_reason_v3()->>'blocked')),
  'builder_calls_gate',(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                        WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                          AND p.prosrc LIKE '%cutover_block_reason_v3%'),
  'builder_law12_kept',(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                        WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                          AND p.prosrc LIKE '%refused_live_plan%'),
  'audit_rows_before',(SELECT count(*) FROM public.engine_cutover_audit_v3)
);

-- ── EXECUTED HALF: every branch of the taxonomy actually driven, inside a rolled-back probe ──
DO $fx74$
DECLARE
  v_payload      jsonb;
  v_novo         uuid := '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04';  -- the single Active NOVO machine
  v_pod          uuid;
  v_r_vox        jsonb := '{"na":true}'::jsonb;
  v_r_amazon     jsonb := '{"na":true}'::jsonb;
  v_r_short      text  := 'NOT_ATTEMPTED';
  v_novo_ready   text  := 'NOT_ATTEMPTED';
  v_r_flip       jsonb := '{"na":true}'::jsonb;
  v_r_revert     jsonb := '{"na":true}'::jsonb;
  v_after_flip   text  := 'NOT_ATTEMPTED';
  v_after_revert text  := 'NOT_ATTEMPTED';
  v_flipped_at   text  := 'NOT_ATTEMPTED';
  v_evid_null    text  := 'NOT_ATTEMPTED';
  v_auth_novo    text  := 'NOT_ATTEMPTED';
  v_block_on     jsonb := '{"na":true}'::jsonb;
  v_block_off    jsonb := '{"na":true}'::jsonb;
  v_failopen     jsonb := '{"na":true}'::jsonb;
  v_audit_refuse int   := -1;
  v_audit_apply  int   := -1;
BEGIN
  SELECT pod_product_id INTO v_pod FROM public.engine_forecast_error_v3 LIMIT 1;
  IF v_pod IS NULL THEN
    RAISE EXCEPTION 'fixture 74 setup: engine_forecast_error_v3 is empty, so the planted ready path below would be vacuous';
  END IF;

  BEGIN
    -- ⛔ EVERYTHING IN THIS BLOCK IS DISCARDED by the RAISE at the end. Only v_payload escapes,
    --    smuggled out through the error message (the fixture-24 / fixture-67 idiom).

    -- (1) REFUSED, reason A: a cluster v3 has never planned. VOX is the biggest cluster (11
    --     machines) and carries 119 SYNTHETIC 2030 v3 rows — S-307. If the view fails to discount
    --     them this returns v3_horizon_not_elapsed and the refusal lies about WHY.
    v_r_vox := public.flip_cluster_to_v3_v3('VOX', 'fixture 74 executes the refusal taxonomy');

    -- (2) REFUSED, reason B: a cluster with real v3 series that have not settled.
    v_r_amazon := public.flip_cluster_to_v3_v3('AMAZON', 'fixture 74 executes the refusal taxonomy');

    -- (3) the reason floor is enforced (the pod_inventory_edit 10-char idiom).
    BEGIN
      PERFORM public.flip_cluster_to_v3_v3('NOVO', 'too short');
      v_r_short := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_r_short := SQLSTATE; END;

    -- (4) ⭐ THE ACCEPT PATH, EXERCISED. Live data cannot reach `ready` today, so it is PLANTED:
    --     a settled v3 series strictly better than its v19 counterpart, on a REAL-window date
    --     (2026-07-01, which holds no rows) so the view's S-244 filter still admits it.
    INSERT INTO public.engine_forecast_error_v3
      (plan_date, engine_tag, machine_id, pod_product_id, horizon_days, horizon_end, n_shelves,
       dc_variants, forecast_units, actual_units, abs_error, signed_error, actuals_settled,
       velocity_basis, measured_at)
    VALUES
      (DATE '2026-07-01','v3',  v_novo, v_pod, 7, DATE '2026-07-08', 1, 1, 100, 100, 10, 10, true, 'fixture74', now()),
      (DATE '2026-07-01','v19', v_novo, v_pod, 7, DATE '2026-07-08', 1, 1, 100, 100, 40, 40, true, 'fixture74', now());

    v_novo_ready := (SELECT refusal_code FROM public.v_cutover_readiness_v3 WHERE cluster_key='NOVO');

    -- (5) APPLIED. This is the only branch that mutates the registry.
    v_r_flip := public.flip_cluster_to_v3_v3('NOVO', 'fixture 74 exercises the accept path');
    v_after_flip := (SELECT authoritative_engine FROM public.engine_cutover_authority_v3 WHERE cluster_key='NOVO');
    v_flipped_at := (SELECT (flipped_at IS NOT NULL)::text FROM public.engine_cutover_authority_v3 WHERE cluster_key='NOVO');
    v_evid_null  := (SELECT (flip_evidence IS NOT NULL)::text FROM public.engine_cutover_authority_v3 WHERE cluster_key='NOVO');
    v_auth_novo  := public.is_cluster_authoritative_v3(v_novo)::text;

    -- (6) ⭐ THE LIVE BUILDER'S GUARD, with a cluster genuinely authoritative.
    v_block_on := public.cutover_block_reason_v3();

    -- (7) ⭐ THE REVERT IS NOT EVIDENCE-GATED. NOVO's evidence is now planted-good, so reverting it
    --     would not prove the point. Flip is impossible on VOX, so instead the registry is driven
    --     to v3 for NOVO above and reverted here while the GATE for it would still refuse a
    --     re-flip after the planted rows are gone. The claim under test is narrow and real: revert
    --     consults no evidence at all and cannot be jammed by the gate that blocks the forward path.
    v_r_revert := public.revert_cluster_to_v19_v3('NOVO', 'fixture 74 proves rollback is ungated');
    v_after_revert := (SELECT authoritative_engine FROM public.engine_cutover_authority_v3 WHERE cluster_key='NOVO');
    v_block_off := public.cutover_block_reason_v3();

    -- (8) ⚠️⚠️ FAIL-OPEN (Cody's blocking revision) IS THE ONE CLAIM IN THIS FIXTURE PROVEN BY
    --     INSPECTION RATHER THAN EXECUTION, and the reason is stated rather than hidden.
    --     To execute it the probe would have to make the authority read genuinely fail, which means
    --     DDL against the table — RENAME preserves the OID so cached plans still resolve and the
    --     probe would silently pass without testing anything, and DROP ... CASCADE inside a
    --     production fixture that fires 65 times a sweep is a blast radius the Constitution forbids
    --     on a protected entity. The handler is asserted structurally at seq 44/45 instead.
    v_failopen := jsonb_build_object('blocked', 'STRUCTURAL_ONLY');

    SELECT count(*) FILTER (WHERE outcome='refused'), count(*) FILTER (WHERE outcome='applied')
      INTO v_audit_refuse, v_audit_apply
      FROM public.engine_cutover_audit_v3;

    v_payload := jsonb_build_object(
      'vox_outcome',    v_r_vox->>'outcome',      'vox_code',    v_r_vox->>'refusal_code',
      'amazon_outcome', v_r_amazon->>'outcome',   'amazon_code', v_r_amazon->>'refusal_code',
      'short_reason',   v_r_short,
      'novo_ready',     v_novo_ready,
      'flip_outcome',   v_r_flip->>'outcome',
      'after_flip',     v_after_flip,   'flipped_at_set', v_flipped_at, 'evidence_set', v_evid_null,
      'auth_novo',      v_auth_novo,
      'block_on',       v_block_on->>'blocked',   'block_on_clusters', (v_block_on->>'clusters'),
      'revert_outcome', v_r_revert->>'outcome',
      'after_revert',   v_after_revert,
      'block_off',      v_block_off->>'blocked',
      'failopen',       v_failopen->>'blocked',   'failopen_degraded', (v_failopen->>'degraded'),
      'audit_refused',  v_audit_refuse,           'audit_applied', v_audit_apply);
    RAISE EXCEPTION 'GP74:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP74:%' THEN v_payload := substring(SQLERRM from 'GP74:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx74$;

-- ── RESIDUE: the probe must have left nothing behind ──────────────────────────
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'all_v19_after',   (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine<>'v19'),
  'audit_rows_after',(SELECT count(*) FROM public.engine_cutover_audit_v3),
  'planted_gone',    (SELECT count(*) FROM public.engine_forecast_error_v3 WHERE velocity_basis='fixture74'),
  'tbl_named_right', (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                       WHERE n.nspname='public' AND c.relname='engine_cutover_authority_v3'),
  'via_rpc_after',   COALESCE(NULLIF(current_setting('app.via_rpc', true), ''), 'UNSET')
);
$scn$,
 'DR-1. Ships with the registry at v19 for all 10 clusters (LAW 4). seq 30-45 are the executed core; seq 60-65 the residue. ⛔ Do NOT re-baseline seq 15 (n_ready=0) to make a flip possible — reaching ready is a CS decision backed by settled WMAPE, not a fixture edit. ⛔ Do NOT soften seq 18: VOX reading no_v3_measurement despite 119 synthetic 2030 rows is the S-307 claim.',
 true, 'failing_expected');

-- ── ASSERTIONS ────────────────────────────────────────────────────────────────
-- Grouping: 1-13 STRUCTURE + GRANTS · 14-20 THE SEED (LAW 4 flag-off) ·
--           21-29 THE READINESS VERDICT (incl. S-307) · 30-45 THE EXECUTED GATE ·
--           60-65 THE RESIDUE.

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ── STRUCTURE + GRANTS ───────────────────────────────────────────────────────
(74, 1, 'DR-1: the authority registry exists. Before this unit, Phase 5 had NO cutover object of any kind — probed live at leg 158 and again at leg 160.',
 'SELECT (value->>''auth_tbl_exists'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P1'),
(74, 2, 'DR-1: the append-only audit table exists. A flip that leaves no record is not auditable, and CS flips this on ~Aug 17 with real money behind it.',
 'SELECT (value->>''audit_tbl_exists'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P1'),
(74, 3, 'Article 2: RLS enabled on the authority registry.',
 'SELECT (value->>''auth_rls'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(74, 4, 'Article 2: RLS enabled on the audit table.',
 'SELECT (value->>''audit_rls'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(74, 5, 'S-268: `anon` is named EXPLICITLY and holds no SELECT on the registry. anon + PUBLIC EXECUTE leaks are a standing open finding on two other v3 objects; this one ships without one.',
 'SELECT (value->>''anon_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(74, 6, 'S-268: `anon` holds no INSERT on the registry either.',
 'SELECT (value->>''anon_insert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(74, 7, 'The read path works: `authenticated` keeps SELECT so the board can render which cluster is on which engine.',
 'SELECT (value->>''authd_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(74, 8, 'Article 3/5: `authenticated` cannot UPDATE the registry directly. The engine a cluster is planned by transitions through an RPC or not at all.',
 'SELECT (value->>''authd_update'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(74, 9, 'Article 3: `authenticated` cannot DELETE from the registry.',
 'SELECT (value->>''authd_delete'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(74, 10, 'Article 7: the audit table blocks UPDATE at the policy layer.',
 'SELECT (value->>''audit_no_update'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gte', '1', true, 'P1'),
(74, 11, 'Article 7: the audit table blocks DELETE at the policy layer.',
 'SELECT (value->>''audit_no_delete'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gte', '1', true, 'P1'),
(74, 12, '⛔ THE ANTI-THEATRE CHECK EXISTS: a row cannot sit at ''v3'' without carrying flipped_at, a human reason and the evidence snapshot that justified it. This constraint is what makes a quiet flip impossible.',
 'SELECT (value->>''engine_check'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'flipped_at', true, 'P1'),
(74, 13, '⛔ THE SEAM: _build_draft_core_v3 actually CALLS cutover_block_reason_v3. Without this the registry is a table nothing reads — precisely the theatre S-138 forbids.',
 'SELECT (value->>''builder_calls_gate'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P1'),

-- ── THE SEED — LAW 4, flag-off ───────────────────────────────────────────────
(74, 14, 'The registry covers all 10 LIVE clusters. Not 9 (the parking lot''s stale figure) and not 11 (which counts Inactive machines).',
 'SELECT (value->>''seed_n'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '10', true, 'P1'),
(74, 15, '⛔⛔ LAW 4: DR-1 SHIPS FLAG-OFF. Every cluster reads ''v19''. ⛔ Do NOT re-baseline this to flip a cluster — the flip is CS''s decision at ~Aug 17 backed by settled WMAPE, and this loop NEVER performs it.',
 'SELECT (value->>''seed_all_v19'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '10', true, 'P1'),
(74, 16, 'LAW 4, stated from the other side so a partial flip cannot hide: ZERO clusters are authoritative for v3.',
 'SELECT (value->>''seed_any_v3'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P1'),
(74, 17, '⛔ ''WH'' IS NOT A CLUSTER. It is the warehouse, it appears only on Inactive machines, and a registry seeded from all machines rather than Active ones would have offered CS the warehouse as a flippable cluster.',
 'SELECT (value->>''wh_present'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P1'),
(74, 18, 'DRIFT GUARD: the registry and the live Active fleet name exactly the same set of clusters, in both directions. A new venue group that never reaches the registry would be silently un-flippable; a stale registry row would offer a cluster that no longer exists.',
 'SELECT (value->>''registry_vs_live'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P1'),
(74, 19, 'FLAG-OFF, measured through the read predicate the write path will actually consult: no Active machine is authoritative for v3.',
 'SELECT (value->>''authoritative_any'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P1'),
(74, 20, 'FLAG-OFF at the builder''s guard: cutover_block_reason_v3 reports not-blocked, so tonight''s live plan is built exactly as it was before this unit existed.',
 'SELECT (value->>''block_reason_off'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(74, 21, '⛔ LAW 12: _build_draft_core_v3 keeps its live-plan guard verbatim. This unit added a refusal to the nightly producer and must not have disturbed the one that was already there.',
 'SELECT (value->>''builder_law12_kept'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P1'),

-- ── THE READINESS VERDICT ────────────────────────────────────────────────────
(74, 22, 'The readiness view answers for every live cluster — a cluster missing from the gate is a cluster with no answer, which reads as "not ready" for the wrong reason.',
 'SELECT (value->>''readiness_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '10', true, 'P1'),
(74, 23, '⛔⛔ NOT ONE CLUSTER IS READY TODAY, and that is the honest state of the evidence: v3 has zero settled series anywhere. ⚠️ When this legitimately becomes > 0 (2026-08-11 at the earliest) that is the signal CS asked for, NOT a fixture failure — re-baseline it THEN, with the settled WMAPE in hand, never before.',
 'SELECT (value->>''n_ready'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P1'),
(74, 24, '⭐ THE REFUSALS SPLIT TWO WAYS AND THE SPLIT IS THE POINT: SIX clusters (ADDMIND, GRIT, LVLUP, VML, VOX, WPP) have never had a single real v3 series. "Wait a week" and "v3 has never planned this cluster" are completely different answers for CS.',
 'SELECT (value->>''n_no_v3'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '6', true, 'P1'),
(74, 25, 'The other FOUR clusters (AMAZON, INDEPENDENT, NOVO, OHMYDESK) have real v3 series from 2026-08-04 that have not settled. These are the only cutover candidates that time alone can ripen.',
 'SELECT (value->>''n_horizon'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '4', true, 'P1'),
(74, 26, '⛔⛔ S-307, THE LANDMINE THIS FIXTURE EXISTS TO DISARM: VOX reads no_v3_measurement even though engine_forecast_error_v3 holds 119 v3 rows for VOX machines on synthetic 2030 dates. Without the S-244 window filter the gate would tell CS that the largest cluster in the fleet has v3 evidence, sourced entirely from golden fixture residue. ⛔ Do NOT soften this to not_null.',
 'SELECT (value->>''vox_code'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'no_v3_measurement', true, 'P1'),
(74, 27, 'S-307, measured directly: VOX''s REAL v3 series count is zero. seq 26 proves the verdict; this proves the number the verdict rests on.',
 'SELECT (value->>''vox_n_series_v3'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P1'),
(74, 28, 'AMAZON is on the other branch: real series, not yet settled.',
 'SELECT (value->>''amazon_code'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'v3_horizon_not_elapsed', true, 'P1'),
(74, 29, '⛔ S-176: WMAPE IS NEVER COERCED TO ZERO. Where the gate is vacuous, wmape_v3 is NULL. A fabricated zero would read as a perfect forecast and sign off a cutover on no evidence at all.',
 'SELECT (value->>''wmape_never_zero'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '0', true, 'P1'),

-- ── THE EXECUTED GATE (D-47 / S-173: a gate passed by inspection is not passed) ──
(74, 30, '⭐⭐ EXECUTED: flipping VOX is REFUSED. The gate is not a comment in a design doc — it was called and it said no.',
 'SELECT (value->>''vox_outcome'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'refused', true, 'P1'),
(74, 31, '⭐⭐ EXECUTED: and it refused for the RIGHT reason. A gate that refuses everything with one generic code would pass seq 30 while telling CS nothing.',
 'SELECT (value->>''vox_code'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'no_v3_measurement', true, 'P1'),
(74, 32, '⭐⭐ EXECUTED: flipping AMAZON is REFUSED — this is the CS ruling "do not flip on vacuous WMAPE" enforced in the database rather than remembered by the operator.',
 'SELECT (value->>''amazon_outcome'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'refused', true, 'P1'),
(74, 33, '⭐⭐ EXECUTED: AMAZON''s refusal names the horizon, distinguishing "come back after 2026-08-11" from "this cluster was never planned by v3".',
 'SELECT (value->>''amazon_code'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'v3_horizon_not_elapsed', true, 'P1'),
(74, 34, 'EXECUTED: a flip with a throwaway reason is refused. The 10-character floor is the pod_inventory_edit idiom, and it exists so the audit row is worth reading a year from now.',
 'SELECT (value->>''short_reason'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'ne', 'NONE', true, 'P1'),
(74, 35, '⭐⭐ THE ACCEPT PATH IS REACHABLE. With a settled v3 series strictly better than v19 planted for NOVO, the gate says ready. ⛔ Without this assertion the whole unit could be a gate that refuses unconditionally, and every refusal above would pass anyway.',
 'SELECT (value->>''novo_ready'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'ready', true, 'P1'),
(74, 36, '⭐⭐ EXECUTED: the flip is then APPLIED. The gate accepts on evidence and only on evidence.',
 'SELECT (value->>''flip_outcome'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'applied', true, 'P1'),
(74, 37, 'EXECUTED: and the registry actually moved to v3 for that cluster. An RPC returning "applied" without moving the row is the failure mode this catches.',
 'SELECT (value->>''after_flip'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'v3', true, 'P1'),
(74, 38, 'EXECUTED: flipped_at is stamped, so the anti-theatre CHECK at seq 12 is satisfied by the writer rather than worked around by it.',
 'SELECT (value->>''flipped_at_set'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'true', true, 'P1'),
(74, 39, '⭐ EXECUTED: the evidence snapshot is stored ON the row. The justification is frozen at flip time — if the gate view is later redefined, what CS relied on is still readable.',
 'SELECT (value->>''evidence_set'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'true', true, 'P1'),
(74, 40, '⭐ EXECUTED: the read predicate agrees with the registry — a NOVO machine is now authoritative for v3. This is the function the Phase 5 write path will consult, so registry and predicate must never disagree.',
 'SELECT (value->>''auth_novo'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'true', true, 'P1'),
(74, 41, '⭐⭐ EXECUTED: with a cluster genuinely authoritative, the LIVE BUILDER''S GUARD reports blocked. ⛔ This is the S-304a lesson applied before the fact: the builder cannot honour a partial cutover (both ADD engines are whole-plan-date scoped), so it stops loudly instead of planning those machines with v19 while CS believes they are on v3.',
 'SELECT (value->>''block_on'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'true', true, 'P1'),
(74, 42, 'EXECUTED: and the block NAMES the cluster responsible, so the 16:00 operator is not left guessing why the plan stopped.',
 'SELECT (value->>''block_on_clusters'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'contains', 'NOVO', true, 'P1'),
(74, 43, '⭐⭐ EXECUTED: THE REVERT IS APPLIED AND CONSULTS NO EVIDENCE. A rollback blocked by the same gate that blocks the forward path is not a rollback — it is a trap. This is the assertion CS depends on if a cutover goes wrong at 02:00.',
 'SELECT (value->>''revert_outcome'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'applied', true, 'P1'),
(74, 44, 'EXECUTED: after the revert the cluster is back on v19 and the builder''s guard clears, so the nightly plan resumes with no further action.',
 'SELECT (value->>''block_off'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'false', true, 'P1'),
(74, 45, 'EXECUTED: a REFUSED flip is written to the audit table, not just returned to the caller. "CS tried to flip VOX on Aug 17 and the gate said no" is the single most interesting row this table will ever hold, and an audit that logged only successes would drop it.',
 'SELECT (value->>''audit_refused'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gte', '2', true, 'P1'),
(74, 46, 'EXECUTED: the applied flip and the applied revert are both audited too.',
 'SELECT (value->>''audit_applied'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gte', '2', true, 'P1'),

-- ── THE RESIDUE ──────────────────────────────────────────────────────────────
(74, 60, '⛔⛔ RESIDUE, AND THE MOST IMPORTANT ONE IN THIS FILE: the probe drove a real cluster to v3 and back. If any of that survived, this fixture would have performed the cutover LAW 4 forbids, as a side effect, on every sweep.',
 'SELECT (value->>''all_v19_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', '0', true, 'P1'),
(74, 61, 'RESIDUE: the audit table is byte-unchanged. The probe wrote four audit rows inside the rolled-back subtransaction; this proves they were discarded rather than committed.',
 'SELECT (((SELECT value->>''audit_rows_after'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after'') = (SELECT value->>''audit_rows_before'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''))::text)', 'eq', 'true', true, 'P1'),
(74, 62, '⛔ RESIDUE: the planted forecast series are GONE. They were engineered to make a cluster look ready — leaving them behind would poison the real gate for every future leg, which is exactly the S-307 disease this fixture was built to catch.',
 'SELECT (value->>''planted_gone'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', '0', true, 'P1'),
(74, 63, 'RESIDUE: the authority table still has its real name after the probe.',
 'SELECT (value->>''tbl_named_right'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', '1', true, 'P1'),
(74, 64, 'RESIDUE (S-197): app.via_rpc does not leak out of the probe.',
 'SELECT (value->>''via_rpc_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', 'UNSET', true, 'P1'),
(74, 65, '⚠️ STRUCTURAL, DELIBERATELY: the builder''s guard carries an exception handler so a failure of its OWN read can never stop the nightly plan. ⛔ Executing this would require DDL against a protected entity inside a fixture that fires 65 times a sweep — RENAME preserves the OID so cached plans still resolve and would pass vacuously, and DROP CASCADE is a blast radius the Constitution forbids. The trade-off is recorded rather than hidden.',
 'SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=''public'' AND p.proname=''cutover_block_reason_v3''', 'contains', 'WHEN OTHERS', true, 'P1'),
(74, 66, '⚠️ STRUCTURAL companion to seq 65: the handler resolves to NOT-blocked. A handler that swallowed the error and then blocked anyway would be worse than no handler — it would stop the live plan for a reason nobody could see.',
 'SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=''public'' AND p.proname=''cutover_block_reason_v3''', 'contains', 'degraded', true, 'P1');
