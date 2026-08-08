-- PRD-110 DR-1b · leg 161 · golden fixture 75
-- The red-then-green proof for DR-1b. Authored and fired RED before the four DR-1b migrations
-- were applied; the transition to green IS the evidence (the D-46 idiom).
--
-- What it proves, in order of how much it matters:
--   1. ⭐⭐ THE PARTITION, EXECUTED. With NOVO genuinely authoritative, a promotion rewrites the
--      NOVO machine's live pod_refills rows with v3's and leaves the control machine's v19 rows
--      BYTE-UNTOUCHED. This is the whole point of DR-1b and it is driven, not inspected.
--   2. ⭐⭐ THE UNSCOPED WIPE IS GONE from engine_add_pod. That single statement is what made a
--      partial cutover impossible.
--   3. The promotion REFUSES rather than publishing an empty plan.
--   4. It is idempotent, and it is a NO-OP while 0 clusters are authoritative (the flag-off state
--      this unit actually ships in).
--   5. The halt is gone from the builder, but the gate is still CALLED and still fails open
--      (fixture 74 seq 13 / 65 / 66 parity — DR-1b must not silently undo DR-1).
--
-- ⛔ EVERY mutation lives inside the rolled-back probe (the fixture-24 / 67 / 74 idiom): the
--    payload is smuggled out through a RAISE and nothing survives. The `after` half asserts that.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  75,
  'PRD-110 DR-1b: the per-cluster cutover HALT becomes a BRANCH. engine_add_pod no longer wipes the whole plan_date and no longer plans clusters it does not own; promote_v3_shadow_to_live_v3 publishes v3''s plan for authoritative clusters ONLY, pinning one shadow run, refusing rather than publishing empty, and leaving every other cluster''s v19 rows byte-untouched. Ships FLAG-OFF: with 0 of 10 clusters authoritative the promotion is a no-op and v19 behaviour is identical.',
  'PRD-110 leg 160 DR-1 shipped a cutover guard whose only move was to HALT the entire nightly plan while any cluster was authoritative for v3. DR-1b is the branch that makes a flip actually plan that cluster.',
  'P1',
  DATE '2030-05-21',
  true,
  'failing_expected',
  'Leg 161. Fired RED before the DR-1b migrations, GREEN after. The control machine is OHMYDESK (OMDBB-1020-0P00-O1); the flipped cluster is NOVO (NOVO-1023-0000-W0), reusing fixture 74''s planted-evidence recipe because live data cannot reach refusal_code=ready today.',
$FX75$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ── STATIC HALF: the shape of the change ────────────────────────────────────────
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'static', jsonb_build_object(
  -- the scope view
  'scope_view_exists', (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                         WHERE n.nspname='public' AND c.relname='v_add_engine_scope_v3'),
  -- ⭐ the LEFT JOIN is load-bearing: an inner join would DROP a machine whose venue_group has no
  --    authority row from BOTH engines, and it would go silently unplanned (LAW 5 at machine grain).
  'scope_left_join',   (SELECT count(*) FROM pg_views WHERE schemaname='public'
                         AND viewname='v_add_engine_scope_v3' AND definition ILIKE '%LEFT JOIN%'),
  'scope_authd_select',has_table_privilege('authenticated','public.v_add_engine_scope_v3','SELECT'),
  'scope_authd_insert',has_table_privilege('authenticated','public.v_add_engine_scope_v3','INSERT'),
  'scope_anon_select', has_table_privilege('anon','public.v_add_engine_scope_v3','SELECT'),

  -- the promotion RPC
  'promo_n_sigs',      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='promote_v3_shadow_to_live_v3'),
  'promo_secdef',      (SELECT prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='promote_v3_shadow_to_live_v3'),
  'promo_via_rpc',     (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='promote_v3_shadow_to_live_v3'
                           AND p.prosrc LIKE '%app.via_rpc%' AND p.prosrc LIKE '%app.rpc_name%'),
  'promo_role_gate',   (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='promote_v3_shadow_to_live_v3'
                           AND p.prosrc LIKE '%user_profiles%' AND p.prosrc LIKE '%operator_admin%'),
  'promo_law12',       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='promote_v3_shadow_to_live_v3'
                           AND p.prosrc LIKE '%_assert_refill_plan_writable%'),
  -- ⛔ it must pin ONE run: pod_refills_shadow PK carries run_id, pod_refills PK does not.
  'promo_pins_run',    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='promote_v3_shadow_to_live_v3'
                           AND p.prosrc LIKE '%ORDER BY s.produced_at DESC%'),

  -- ⭐⭐ engine_add_pod: the unscoped whole-date wipe must be GONE.
  'v19_unscoped_wipe', (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='engine_add_pod'
                           AND p.prosrc LIKE '%DELETE FROM public.pod_refills WHERE plan_date = p_plan_date%'),
  'v19_scoped_wipe',   (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='engine_add_pod'
                           AND p.prosrc LIKE '%is_cluster_authoritative_v3(pr.machine_id)%'),
  'v19_scoped_pick',   (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='engine_add_pod'
                           AND p.prosrc LIKE '%is_cluster_authoritative_v3(mtv.machine_id)%'),
  -- the defaults and the single signature are load-bearing: cron 13 calls this by name.
  'v19_n_sigs',        (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='engine_add_pod'),
  'v19_nargdefaults',  (SELECT pronargdefaults FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='engine_add_pod'),
  'v19_varconflict',   (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='engine_add_pod'
                           AND p.prosrc LIKE '%#variable_conflict use_column%'),

  -- ⭐⭐ the builder: the halt is gone, the branch landed, and DR-1 is NOT undone.
  'builder_halt_gone', (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                           AND p.prosrc LIKE '%refused_cutover_not_implemented%'),
  'builder_promotes',  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                           AND p.prosrc LIKE '%promote_v3_shadow_to_live_v3%'),
  'builder_runs_v3',   (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                           AND p.prosrc LIKE '%engine_add_pod_v3(p_plan_date, 14)%'),
  -- fixture 74 seq 13 parity: the builder must STILL call the gate.
  'builder_calls_gate',(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                           AND p.prosrc LIKE '%cutover_block_reason_v3%'),
  -- LAW 12 and LAW 11 must be undisturbed by this edit.
  'builder_law12',     (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                           AND p.prosrc LIKE '%refused_live_plan%'),
  'builder_law11',     (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                           AND p.prosrc LIKE '%skipped_manual_gate%'),
  -- fixture 74 seq 65/66 parity: the gate itself must be byte-untouched and still fail OPEN.
  'gate_failopen',     (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                         WHERE n.nspname='public' AND p.proname='cutover_block_reason_v3'
                           AND p.prosrc LIKE '%WHEN OTHERS%' AND p.prosrc LIKE '%degraded%'),

  -- FLAG-OFF, as shipped.
  'clusters_on_v3',    (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3'),
  'block_off',         (SELECT (public.cutover_block_reason_v3()->>'blocked'))
);

-- ── EXECUTED HALF: the partition, actually driven ───────────────────────────────
DO $fx75$
DECLARE
  v_payload   jsonb;
  v_novo      uuid := '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04';  -- the single Active NOVO machine
  v_ctl       uuid := '822d386f-e0db-4a51-b201-0731df90f393';  -- OHMYDESK control, never flipped
  v_novo_shelf uuid := 'bb99e47a-0954-4ca4-9239-51ca7d2c1e8e';
  v_ctl_shelf uuid := '761f9c42-c9c6-4750-b8af-7f3564ac7496';
  v_pod       uuid;
  v_run       uuid := gen_random_uuid();
  v_d         date := DATE '2030-05-21';
  v_noop      jsonb := '{"na":true}'::jsonb;
  v_flip      jsonb := '{"na":true}'::jsonb;
  v_promo     jsonb := '{"na":true}'::jsonb;
  v_promo2    jsonb := '{"na":true}'::jsonb;
  v_scope_novo text := 'NOT_ATTEMPTED';
  v_scope_ctl  text := 'NOT_ATTEMPTED';
  v_scope_n    int  := -1;
  v_mtv_n      int  := -1;
  v_novo_author text := 'NOT_ATTEMPTED';
  v_ctl_author  text := 'NOT_ATTEMPTED';
  v_novo_qty   int  := -1;
  v_ctl_qty    int  := -1;
  v_refuse     text := 'NOT_ATTEMPTED';
  v_after_rev  jsonb := '{"na":true}'::jsonb;
BEGIN
  SELECT pod_product_id INTO v_pod FROM public.engine_forecast_error_v3 LIMIT 1;
  IF v_pod IS NULL THEN
    RAISE EXCEPTION 'fixture 75 setup: engine_forecast_error_v3 is empty; the planted flip below would be vacuous';
  END IF;

  BEGIN
    -- ⛔ EVERYTHING BELOW IS DISCARDED by the RAISE at the end. Only v_payload escapes.

    -- (0) FLAG-OFF FIRST, before anything is flipped: the promotion must be a no-op.
    --     This is the state DR-1b actually ships in, so it is asserted before the interesting part.
    v_noop := public.promote_v3_shadow_to_live_v3(v_d);

    -- (1) Plant the settled v3 evidence for NOVO (fixture 74's recipe) so the gate says ready.
    --     abs_error / signed_error are GENERATED ALWAYS — the miss is engineered through the
    --     forecast: v3 off by 10 on 100 (wmape 0.10), v19 off by 40 (0.40).
    INSERT INTO public.engine_forecast_error_v3
      (plan_date, engine_tag, machine_id, pod_product_id, horizon_days, horizon_end, n_shelves,
       dc_variants, forecast_units, actual_units, actuals_settled, velocity_basis, measured_at)
    VALUES
      (DATE '2026-07-02','v3',  v_novo, v_pod, 7, DATE '2026-07-09', 1, 1, 110, 100, true, 'velocity_instock', now()),
      (DATE '2026-07-02','v19', v_novo, v_pod, 7, DATE '2026-07-09', 1, 1, 140, 100, true, 'velocity_instock', now());

    v_flip := public.flip_cluster_to_v3_v3('NOVO', 'fixture 75 drives the DR-1b partition');

    -- (2) Both machines are picked for the synthetic date.
    INSERT INTO public.machines_to_visit (plan_date, machine_id, official_name, status, confirmed_at)
    VALUES (v_d, v_novo, 'NOVO-1023-0000-W0',  'picked', now()),
           (v_d, v_ctl,  'OMDBB-1020-0P00-O1', 'picked', now());

    -- (3) ⭐ THE SCOPE VIEW, EXECUTED. One machine to each engine, and NEITHER dropped.
    v_scope_novo := (SELECT assigned_engine FROM public.v_add_engine_scope_v3
                      WHERE plan_date=v_d AND machine_id=v_novo);
    v_scope_ctl  := (SELECT assigned_engine FROM public.v_add_engine_scope_v3
                      WHERE plan_date=v_d AND machine_id=v_ctl);
    v_scope_n    := (SELECT count(*) FROM public.v_add_engine_scope_v3 WHERE plan_date=v_d);
    v_mtv_n      := (SELECT count(*) FROM public.machines_to_visit
                      WHERE plan_date=v_d AND status IN ('picked','cs_added'));

    -- (4) v19's output for BOTH machines, as it would stand before the promotion.
    INSERT INTO public.pod_refills
      (plan_date, machine_id, shelf_id, pod_product_id, qty, current_stock, max_stock, reasoning)
    VALUES (v_d, v_novo, v_novo_shelf, v_pod, 7, 1, 8, '{"tagged_by":"v19_fixture75"}'::jsonb),
           (v_d, v_ctl,  v_ctl_shelf,  v_pod, 5, 2, 7, '{"tagged_by":"v19_fixture75"}'::jsonb);

    -- (5) v3's shadow run for the same date, covering BOTH machines. The control machine is in
    --     the shadow run DELIBERATELY: the promotion must ignore it because OHMYDESK is on v19.
    INSERT INTO public.pod_refills_shadow
      (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
       current_stock, max_stock, days_cover, signal, wh_available_pod, clamp_reason,
       reasoning, velocity_instock, availability_basis)
    VALUES (v_run, 'engine_add_pod_v3', v_d, v_novo, v_novo_shelf, v_pod, 3, 1, 8, 14,
            'fx75', 99, 'fill_to_cap', '{"tagged_by":"v3_fixture75"}'::jsonb, 1.250, 'boonz_wh'),
           (v_run, 'engine_add_pod_v3', v_d, v_ctl,  v_ctl_shelf,  v_pod, 2, 2, 7, 14,
            'fx75', 99, 'fill_to_cap', '{"tagged_by":"v3_fixture75"}'::jsonb, 0.750, 'boonz_wh');

    -- (6) ⭐⭐ THE PROMOTION.
    v_promo := public.promote_v3_shadow_to_live_v3(v_d);

    -- (7) ⭐⭐ THE PARTITION. NOVO now carries v3''s row; the control still carries v19''s.
    SELECT reasoning->>'authored_by', qty INTO v_novo_author, v_novo_qty
      FROM public.pod_refills WHERE plan_date=v_d AND machine_id=v_novo;
    SELECT COALESCE(reasoning->>'authored_by','V19_UNTOUCHED'), qty INTO v_ctl_author, v_ctl_qty
      FROM public.pod_refills WHERE plan_date=v_d AND machine_id=v_ctl;

    -- (8) Idempotent: a second promotion of the same run leaves the same state.
    v_promo2 := public.promote_v3_shadow_to_live_v3(v_d);

    -- (9) ⭐ IT REFUSES rather than publishing an empty plan for a flipped cluster.
    DELETE FROM public.pod_refills_shadow WHERE run_id = v_run;
    BEGIN
      PERFORM public.promote_v3_shadow_to_live_v3(v_d);
      v_refuse := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_refuse := 'RAISED'; END;

    -- (10) After the revert the promotion is inert again.
    PERFORM public.revert_cluster_to_v19_v3('NOVO', 'fixture 75 restores the registry');
    v_after_rev := public.promote_v3_shadow_to_live_v3(v_d);

    v_payload := jsonb_build_object(
      'noop_status',   v_noop->>'status',        'noop_rows',   (v_noop->>'rows_promoted'),
      'flip_outcome',  v_flip->>'outcome',
      'scope_novo',    v_scope_novo,             'scope_ctl',   v_scope_ctl,
      'scope_n',       v_scope_n,                'mtv_n',       v_mtv_n,
      'promo_status',  v_promo->>'status',
      'promo_rows',    (v_promo->>'rows_promoted'),
      'promo_deleted', (v_promo->>'rows_deleted'),
      'promo_run',     ((v_promo->>'shadow_run_id') = v_run::text)::text,
      'promo_swap_residual', v_promo->>'residual_swap_engine',
      'novo_author',   v_novo_author,            'novo_qty',    v_novo_qty,
      'ctl_author',    v_ctl_author,             'ctl_qty',     v_ctl_qty,
      'promo2_rows',   (v_promo2->>'rows_promoted'),
      'refuse',        v_refuse,
      'after_revert',  v_after_rev->>'status');
    RAISE EXCEPTION 'GP75:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP75:%' THEN v_payload := substring(SQLERRM from 'GP75:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx75$;

-- ── RESIDUE: the probe must have left nothing behind ────────────────────────────
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'all_v19_after',  (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine<>'v19'),
  'pr_2030_gone',   (SELECT count(*) FROM public.pod_refills        WHERE plan_date = DATE '2030-05-21'),
  'shadow_2030_gone',(SELECT count(*) FROM public.pod_refills_shadow WHERE plan_date = DATE '2030-05-21'),
  'mtv_2030_gone',  (SELECT count(*) FROM public.machines_to_visit  WHERE plan_date = DATE '2030-05-21'),
  'planted_gone',   (SELECT count(*) FROM public.engine_forecast_error_v3 WHERE plan_date = DATE '2026-07-02')
);
$FX75$
);

-- ── ASSERTIONS ──────────────────────────────────────────────────────────────────
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- STATIC: the scope object
(75, 1,'v_add_engine_scope_v3 exists — the ONE object that says which engine owns a machine.','SELECT (value->>''scope_view_exists'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75, 2,'⭐ LEFT JOIN, not an inner join. A machine whose venue_group has no authority row must fall back to v19; an inner join drops it from BOTH engines and it goes silently unplanned (LAW 5 at machine grain).','SELECT (value->>''scope_left_join'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75, 3,'authenticated may read the scope view.','SELECT (value->>''scope_authd_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','true',true,'P1'),
(75, 4,'S-308 posture: authenticated may NOT write it.','SELECT (value->>''scope_authd_insert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','false',true,'P1'),
(75, 5,'S-268 posture: anon cannot read it.','SELECT (value->>''scope_anon_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','false',true,'P1'),
-- STATIC: the promotion RPC
(75, 6,'promote_v3_shadow_to_live_v3 exists with exactly ONE signature (the repurpose_machine overload foot-gun).','SELECT (value->>''promo_n_sigs'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75, 7,'Article 4: it is SECURITY DEFINER.','SELECT (value->>''promo_secdef'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','true',true,'P1'),
(75, 8,'Article 8: it sets app.via_rpc and app.rpc_name, so pod_refills'' audit trigger attributes the write.','SELECT (value->>''promo_via_rpc'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75, 9,'Article 4: it validates caller role against user_profiles, not a parameter.','SELECT (value->>''promo_role_gate'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,10,'LAW 12: it re-asserts _assert_refill_plan_writable before publishing.','SELECT (value->>''promo_law12'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,11,'⛔ It pins ONE shadow run. pod_refills_shadow PK carries run_id and pod_refills PK does not, so promoting every shadow row for a date collides on the live PK the moment a second run exists — and cron 45 guarantees one.','SELECT (value->>''promo_pins_run'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
-- STATIC: engine_add_pod
(75,12,'⭐⭐ THE BLOCKER IS GONE: engine_add_pod no longer carries the unscoped DELETE FROM pod_refills WHERE plan_date = p_plan_date. That single statement — not the SELECT scope — is what made a partial cutover physically impossible.','SELECT (value->>''v19_unscoped_wipe'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','0',true,'P1'),
(75,13,'⭐⭐ …and the scoped wipe replaced it.','SELECT (value->>''v19_scoped_wipe'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,14,'⭐ engine_add_pod no longer SIZES the clusters it does not own.','SELECT (value->>''v19_scoped_pick'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,15,'Exactly one engine_add_pod signature survives the replace.','SELECT (value->>''v19_n_sigs'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,16,'⛔ pronargdefaults stays 2. cron 13 and _build_draft_core_v3 both call engine_add_pod by name; losing the defaults changes every call site silently (the Wave-2 rule).','SELECT (value->>''v19_nargdefaults'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','2',true,'P1'),
(75,17,'#variable_conflict use_column survives, or every unqualified column reference in the engine changes meaning.','SELECT (value->>''v19_varconflict'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
-- STATIC: the builder
(75,18,'⭐⭐ THE HALT IS GONE: the builder can no longer refuse the WHOLE fleet because one cluster is on v3.','SELECT (value->>''builder_halt_gone'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','0',true,'P1'),
(75,19,'⭐⭐ …and the branch landed: the builder promotes v3''s plan for the flipped clusters.','SELECT (value->>''builder_promotes'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,20,'The builder runs the v3 shadow engine so there is a run to promote on the same night.','SELECT (value->>''builder_runs_v3'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,21,'⛔ DR-1 IS NOT UNDONE: the builder still CALLS cutover_block_reason_v3 (fixture 74 seq 13 parity). Only its response changed — branch, not halt.','SELECT (value->>''builder_calls_gate'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,22,'LAW 12: the builder''s live-plan guard is undisturbed by this edit.','SELECT (value->>''builder_law12'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,23,'LAW 11: the manual Gate-0 branch is undisturbed. No auto-fallback was introduced.','SELECT (value->>''builder_law11'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,24,'fixture 74 seq 65/66 parity: the gate still fails OPEN, so a failure of its own read can never halt the nightly plan.','SELECT (value->>''gate_failopen'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','1',true,'P1'),
(75,25,'LAW 4: this unit ships FLAG-OFF. Zero clusters are authoritative for v3.','SELECT (value->>''clusters_on_v3'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','0',true,'P1'),
(75,26,'…so the builder''s gate reports not-blocked and tonight''s plan is built exactly as before.','SELECT (value->>''block_off'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''','eq','false',true,'P1'),
-- EXECUTED
(75,30,'⭐ FLAG-OFF, EXECUTED: with 0 clusters authoritative the promotion is a no-op that touches nothing. This is the state the unit actually ships in, so it is driven before the interesting part.','SELECT (value->>''noop_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','noop_no_authoritative_machines',true,'P1'),
(75,31,'…and it promoted zero rows.','SELECT (value->>''noop_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','0',true,'P1'),
(75,32,'Setup: NOVO is genuinely flipped through the real RPC, not by writing the registry directly.','SELECT (value->>''flip_outcome'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','applied',true,'P1'),
(75,33,'⭐⭐ THE PARTITION: the flipped cluster''s machine is assigned to v3.','SELECT (value->>''scope_novo'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','v3',true,'P1'),
(75,34,'⭐⭐ THE PARTITION: a machine in any other cluster stays on v19 on the SAME plan_date. This is what DR-1 could not do at all.','SELECT (value->>''scope_ctl'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','v19',true,'P1'),
(75,35,'⭐ TOTALITY: the scope view classifies BOTH picked machines. A machine that appears in neither engine is the silent-unplanned failure LAW 5 forbids.','SELECT (value->>''scope_n'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','2',true,'P1'),
(75,36,'…and the view''s population equals machines_to_visit''s, so nothing was dropped by the join.','SELECT (value->>''mtv_n'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','2',true,'P1'),
(75,37,'⭐⭐ THE PROMOTION RAN.','SELECT (value->>''promo_status'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','promoted',true,'P1'),
(75,38,'⭐⭐ …and it promoted ONLY the flipped cluster''s row. The shadow run deliberately contained the control machine too; promoting 2 here would mean v3 had silently taken over a cluster CS never flipped.','SELECT (value->>''promo_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','1',true,'P1'),
(75,39,'…and it deleted only that cluster''s prior live row.','SELECT (value->>''promo_deleted'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','1',true,'P1'),
(75,40,'⛔ It promoted the run it pinned, not some other run for the same date.','SELECT (value->>''promo_run'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','true',true,'P1'),
(75,41,'⭐⭐ THE FLIPPED CLUSTER''S LIVE ROW IS NOW v3-AUTHORED, and says so in its own provenance.','SELECT (value->>''novo_author'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','engine_add_pod_v3',true,'P1'),
(75,42,'⭐⭐ …carrying v3''s quantity (3), not the v19 quantity (7) it replaced. Provenance without the number moving would be a cosmetic pass.','SELECT (value->>''novo_qty'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','3',true,'P1'),
(75,43,'⭐⭐ THE CONTROL MACHINE IS BYTE-UNTOUCHED — no authored_by stamp at all.','SELECT (value->>''ctl_author'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','V19_UNTOUCHED',true,'P1'),
(75,44,'⭐⭐ …and it still carries v19''s quantity (5). THIS is the assertion that proves the two engines coexist on one plan_date.','SELECT (value->>''ctl_qty'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','5',true,'P1'),
(75,45,'Idempotent: promoting the same run twice leaves the same one row, not two and not zero.','SELECT (value->>''promo2_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','1',true,'P1'),
(75,46,'⭐ IT REFUSES RATHER THAN PUBLISHING EMPTY: a flipped cluster with no v3 shadow run halts loudly instead of shipping a plan with that cluster''s machines silently missing.','SELECT (value->>''refuse'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','RAISED',true,'P1'),
(75,47,'⭐ THE REVERT MAKES IT INERT AGAIN: after revert_cluster_to_v19_v3 the promotion is a no-op, so the rollback is complete and needs no second step.','SELECT (value->>''after_revert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','noop_no_authoritative_machines',true,'P1'),
(75,48,'⛔ S-312 IS DECLARED IN THE PAYLOAD: engine_swap_pod is still fleet-wide v19 and swaps_enabled is TRUE, so a flipped cluster gets v3 refill lines and v19 swap lines. DR-1b does not fix that; it refuses to hide it.','SELECT (value->>''promo_swap_residual'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''','eq','v19_fleetwide',true,'P1'),
-- RESIDUE
(75,60,'RESIDUE: the registry is back to all-v19. A fixture that leaves a cluster flipped would hand the next sweep a halted nightly plan.','SELECT (value->>''all_v19_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''','eq','0',true,'P1'),
(75,61,'RESIDUE: no synthetic pod_refills rows survived the probe.','SELECT (value->>''pr_2030_gone'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''','eq','0',true,'P1'),
(75,62,'RESIDUE: no synthetic shadow rows survived.','SELECT (value->>''shadow_2030_gone'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''','eq','0',true,'P1'),
(75,63,'RESIDUE: no synthetic machines_to_visit rows survived.','SELECT (value->>''mtv_2030_gone'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''','eq','0',true,'P1'),
(75,64,'RESIDUE: the planted forecast evidence is gone, so it can never become cutover evidence (the S-307 lesson).','SELECT (value->>''planted_gone'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''','eq','0',true,'P1');
