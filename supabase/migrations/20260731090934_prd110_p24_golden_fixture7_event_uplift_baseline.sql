-- PRD-110 P2.4 · LAW 1 · Golden fixture 7: event uplift reaches ENGINE quantities.
-- Written and baselined RED *before* engine_add_pod_v3 is wired to resolve_demand_multiplier_v3.
--
-- Fixture 31 pinned the RESOLVER. This fixture is the engine-grain downstream half: it proves the
-- resolved factor actually moves plan quantities, and that the clamp reaches them too.
--
-- ⛔ WHY THIS IS A CLEAN RED RATHER THAN AN ERROR: every object it touches already exists
-- (demand_calendar, the resolver, the engine). So a to_regclass guard cannot produce the baseline.
-- The RED comes from BEHAVIOUR: with the engine unwired, run B's velocity_effective_daily is
-- identical to run A's instead of 1.6x it, and reasoning carries no demand_factor at all.
-- That is precisely the failing baseline LAW 1 asks for.
--
-- NON-DESTRUCTIVE BY CONSTRUCTION (fixture 31's rollback-probe idiom, now the house pattern):
-- the machines_to_visit seed, all three engine runs, and every demand_calendar row are written
-- inside a PL/pgSQL subtransaction that is FORCED to roll back. PL/pgSQL variable assignments
-- survive the rollback, so measurements are kept while every table is left byte-identical.
-- Seq 17-19 pin zero residue on all three surfaces.
--
-- ⭐ All three engine runs execute inside ONE transaction, so they read the same shelf state and
-- the A/B/C comparison is exact rather than racing ambient WEIMI traffic.
--
-- plan_date: golden.render computes {{plan_date}} as DATE '2030-01-01' + fixture_id = 2030-01-08.
-- That is a TUESDAY, which is exactly the fixture's "Spider-Man vs normal Tue" premise, and it is
-- free. ⛔ fixtures.plan_date MUST equal that computed date for any fixture using {{plan_date}}.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (7,
 'Event uplift (P2.4 demand multiplier reaches engine quantities)',
 'PRD-110-GOLDEN-FIXTURES #7 - Spider-Man vs normal Tue. BUILD SPEC P2.4: effective_velocity = velocity_instock x PIfactors, clamped 0.5-2.5.',
 'P2',
 '2030-01-08',
$FX$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DO $fx7$
DECLARE
  v_pd        date := {{plan_date}};
  v_res       jsonb;
  v_run_a     uuid;
  v_run_b     uuid;
  v_run_c     uuid;
  v_a         jsonb;
  v_b         jsonb;
  v_c         jsonb;
  v_runs_ok   integer := 0;
  v_err       text := '';
  v_mid       uuid;
  v_f_base    numeric;
  v_f_b       numeric;
  v_f_c       numeric;
  v_clamped_c boolean;
  v_lines_a   integer := 0;
  v_vel_lines integer := 0;
  v_scale_mm  integer := -1;
  v_mu_mm     integer := -1;
  v_clamp_mm  integer := -1;
  v_qty_up    integer := -1;
  v_qty_down  integer := -1;
  v_df_a_mm   integer := -1;
  v_df_b_mm   integer := -1;
  v_prov_a_mm integer := -1;
  v_prov_b_mm integer := -1;
  v_base_mm   integer := -1;
  v_internal  integer := -1;
  v_prp_before bigint;
  v_prp_after  bigint;
  v_res_dc    bigint;
  v_res_mtv   bigint;
  v_res_sh    bigint;
  v_live_pr   bigint;
BEGIN
  SELECT count(*) INTO v_prp_before FROM public.pod_refill_plan;

  -- ============ probe block: EVERYTHING below is rolled back ============
  BEGIN
    DELETE FROM public.machines_to_visit WHERE plan_date = v_pd;
    INSERT INTO public.machines_to_visit
     (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
      picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
      venue_group, location_type, confirmed_at, confirmed_by)
    SELECT v_pd, machine_id, official_name, 'picked', 'operator', true,
           CASE WHEN venue_group = 'VOX' THEN 'vox' ELSE 'main' END,
           ARRAY['golden_fixture_7']::text[], 0, false, 100, now(),
           '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
           now(), 'golden_fixture_7'
      FROM public.machines
     WHERE official_name IN ('VOXMCC-1005-0201-B0','VML-1003-0400-O1');

    SELECT machine_id INTO v_mid FROM public.machines_to_visit
     WHERE plan_date = v_pd ORDER BY official_name LIMIT 1;

    -- Baseline factor BEFORE any calendar row exists: the shadow-safety premise (must be 1.0).
    SELECT r.factor INTO v_f_base
      FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;

    -- ---- RUN A: no factor authored ----
    BEGIN
      SELECT public.engine_add_pod_v3(v_pd, 14) INTO v_res;
      v_run_a := (v_res->>'run_id')::uuid; v_runs_ok := v_runs_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_err := v_err || ' A:' || SQLERRM; END;

    SELECT jsonb_object_agg(s.shelf_id::text, jsonb_build_object(
             'q',  s.qty,
             'v',  (s.reasoning->>'velocity_effective_daily'),
             'mu', (s.reasoning->>'mu_term'),
             'df', (s.reasoning->>'demand_factor'),
             'vb', (s.reasoning->>'velocity_base_daily'),
             'np', COALESCE(jsonb_array_length(s.reasoning->'demand_factor_sources'), -1)))
      INTO v_a
      FROM public.pod_refills_shadow s WHERE s.run_id = v_run_a;
    v_a := COALESCE(v_a, '{}'::jsonb);

    SELECT count(*), count(*) FILTER (WHERE (e.value->>'v')::numeric > 0)
      INTO v_lines_a, v_vel_lines FROM jsonb_each(v_a) e;

    -- ---- RUN B: one fleet-scoped EVENT factor 1.6 on the plan date only ----
    PERFORM public.set_demand_factor_v3('event', NULL, NULL, NULL::smallint,
              v_pd, v_pd, NULL, NULL, 1.6,
              'golden fixture 7 event uplift probe - rolled back');
    SELECT r.factor INTO v_f_b FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;

    BEGIN
      SELECT public.engine_add_pod_v3(v_pd, 14) INTO v_res;
      v_run_b := (v_res->>'run_id')::uuid; v_runs_ok := v_runs_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_err := v_err || ' B:' || SQLERRM; END;

    SELECT jsonb_object_agg(s.shelf_id::text, jsonb_build_object(
             'q',  s.qty,
             'v',  (s.reasoning->>'velocity_effective_daily'),
             'mu', (s.reasoning->>'mu_term'),
             'df', (s.reasoning->>'demand_factor'),
             'vb', (s.reasoning->>'velocity_base_daily'),
             'np', COALESCE(jsonb_array_length(s.reasoning->'demand_factor_sources'), -1)))
      INTO v_b
      FROM public.pod_refills_shadow s WHERE s.run_id = v_run_b;
    v_b := COALESCE(v_b, '{}'::jsonb);

    -- ---- RUN C: restate the same key at 5.0 -> raw 5.0 clamps to the 2.5 ceiling ----
    PERFORM public.set_demand_factor_v3('event', NULL, NULL, NULL::smallint,
              v_pd, v_pd, NULL, NULL, 5.0,
              'golden fixture 7 clamp probe - rolled back');
    SELECT r.factor, r.clamped INTO v_f_c, v_clamped_c
      FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;

    BEGIN
      SELECT public.engine_add_pod_v3(v_pd, 14) INTO v_res;
      v_run_c := (v_res->>'run_id')::uuid; v_runs_ok := v_runs_ok + 1;
    EXCEPTION WHEN OTHERS THEN v_err := v_err || ' C:' || SQLERRM; END;

    SELECT jsonb_object_agg(s.shelf_id::text, jsonb_build_object(
             'q',  s.qty,
             'v',  (s.reasoning->>'velocity_effective_daily'),
             'mu', (s.reasoning->>'mu_term'),
             'df', (s.reasoning->>'demand_factor'),
             'vb', (s.reasoning->>'velocity_base_daily'),
             'np', COALESCE(jsonb_array_length(s.reasoning->'demand_factor_sources'), -1)))
      INTO v_c
      FROM public.pod_refills_shadow s WHERE s.run_id = v_run_c;
    v_c := COALESCE(v_c, '{}'::jsonb);

    -- ============ measurements (all survive the rollback) ============

    -- ⭐ CORE: the authored 1.6 scales effective velocity on EVERY line, exactly.
    SELECT count(*) INTO v_scale_mm FROM jsonb_each(v_b) e
     WHERE (e.value->>'v')::numeric IS DISTINCT FROM ((v_a->e.key->>'v')::numeric * 1.6);

    -- and it therefore scales the base-stock mean term, which is what sizes the line.
    SELECT count(*) INTO v_mu_mm FROM jsonb_each(v_b) e
     WHERE (e.value->>'mu')::numeric IS DISTINCT FROM ((v_a->e.key->>'mu')::numeric * 1.6);

    -- the CLAMP reaches the engine: 5.0 authored, 2.5 applied.
    SELECT count(*) INTO v_clamp_mm FROM jsonb_each(v_c) e
     WHERE (e.value->>'v')::numeric IS DISTINCT FROM ((v_a->e.key->>'v')::numeric * 2.5);

    -- quantities: an uplift may never REDUCE a quantity, and must move at least one.
    SELECT count(*) FILTER (WHERE (e.value->>'q')::int > (v_a->e.key->>'q')::int),
           count(*) FILTER (WHERE (e.value->>'q')::int < (v_a->e.key->>'q')::int)
      INTO v_qty_up, v_qty_down FROM jsonb_each(v_b) e;

    -- LAW 5 provenance: an unfactored plan must never be mistaken for a factored one.
    SELECT count(*) INTO v_df_a_mm FROM jsonb_each(v_a) e
     WHERE (e.value->>'df')::numeric IS DISTINCT FROM 1.0;
    SELECT count(*) INTO v_prov_a_mm FROM jsonb_each(v_a) e
     WHERE (e.value->>'np')::int <> 0;
    SELECT count(*) INTO v_df_b_mm FROM jsonb_each(v_b) e
     WHERE (e.value->>'df')::numeric IS DISTINCT FROM 1.6;
    SELECT count(*) INTO v_prov_b_mm FROM jsonb_each(v_b) e
     WHERE (e.value->>'np')::int < 1;

    -- the BASE velocity is preserved unscaled, so shadow-vs-v19 diffing stays honest.
    SELECT count(*) INTO v_base_mm FROM jsonb_each(v_b) e
     WHERE (e.value->>'vb')::numeric IS DISTINCT FROM (v_a->e.key->>'vb')::numeric;

    -- single-run internal contract: effective = base x factor, on every line of run B.
    SELECT count(*) INTO v_internal FROM jsonb_each(v_b) e
     WHERE (e.value->>'v')::numeric
           IS DISTINCT FROM ((e.value->>'vb')::numeric * (e.value->>'df')::numeric);

    RAISE EXCEPTION 'fx7_rollback' USING ERRCODE = '22023';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;   -- probe rows discarded; the measurements above survive in PL/pgSQL variables
  END;
  -- ============ end probe block ============

  SELECT count(*) INTO v_prp_after FROM public.pod_refill_plan;
  SELECT count(*) INTO v_res_dc  FROM public.demand_calendar WHERE note LIKE 'golden fixture 7%';
  SELECT count(*) INTO v_res_mtv FROM public.machines_to_visit WHERE plan_date = v_pd;
  SELECT count(*) INTO v_res_sh  FROM public.pod_refills_shadow WHERE plan_date = v_pd;
  SELECT count(*) INTO v_live_pr FROM public.pod_refills WHERE plan_date = v_pd;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'obs', jsonb_build_object(
    'runs_ok',        v_runs_ok,
    'engine_err',     COALESCE(NULLIF(v_err,''),'none'),
    'lines_a',        v_lines_a,
    'vel_lines',      v_vel_lines,
    'f_base',         v_f_base,
    'f_b',            v_f_b,
    'f_c',            v_f_c,
    'clamped_c',      v_clamped_c,
    'scale_mm',       v_scale_mm,
    'mu_mm',          v_mu_mm,
    'clamp_mm',       v_clamp_mm,
    'qty_up',         v_qty_up,
    'qty_down',       v_qty_down,
    'df_a_mm',        v_df_a_mm,
    'df_b_mm',        v_df_b_mm,
    'prov_a_mm',      v_prov_a_mm,
    'prov_b_mm',      v_prov_b_mm,
    'base_mm',        v_base_mm,
    'internal_mm',    v_internal,
    'residue_dc',     v_res_dc,
    'residue_mtv',    v_res_mtv,
    'residue_shadow', v_res_sh,
    'live_pr',        v_live_pr,
    'prp_delta',      v_prp_after - v_prp_before));
END $fx7$;
$FX$,
 'P2.4 engine-grain half. Fixture 31 pins the resolver; this pins that the resolved factor reaches quantities and that the clamp reaches them too. Probe rows roll back by construction (seq 17-19 pin zero residue on demand_calendar, machines_to_visit and pod_refills_shadow).',
 true, 'failing_expected')
ON CONFLICT (fixture_id) DO NOTHING;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(7, 1,'HARNESS: all three engine passes ran without error (A baseline, B factored, C clamped)',
 $A$SELECT value->>'runs_ok' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','3',true,'P2'),
(7, 2,'HARNESS: no engine pass raised',
 $A$SELECT value->>'engine_err' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','none',true,'P2'),
(7, 3,'NON-VACUITY: the baseline run produced plan lines at all',
 $A$SELECT value->>'lines_a' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'gt','0',true,'P2'),
(7, 4,'NON-VACUITY: at least one line carries a NON-ZERO effective velocity - without this every ratio assertion below would pass vacuously on 0 = 0 x 1.6 (the S-48 / S-52 failure mode)',
 $A$SELECT value->>'vel_lines' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'gt','0',true,'P2'),
(7, 5,'SHADOW SAFETY: with no factor authored the resolver returns exactly 1.0, so v3 quantities do not move until CS authors one',
 $A$SELECT value->>'f_base' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.0000',true,'P2'),
(7, 6,'The authored fleet-scoped event factor resolves to 1.6 on the plan date',
 $A$SELECT value->>'f_b' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.6000',true,'P2'),
(7, 7,'A 5.0 authored factor is CLAMPED to the 2.5 ceiling (BUILD SPEC P2.4: clamped 0.5-2.5)',
 $A$SELECT value->>'f_c' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2.5000',true,'P2'),
(7, 8,'and the clamped flag is raised, so a clamped plan is never mistaken for an authored one',
 $A$SELECT value->>'clamped_c' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','true',true,'P2'),
(7, 9,'CORE: the 1.6 factor scales velocity_effective_daily on EVERY plan line, exactly (this is the assertion that is RED until the engine is wired to the resolver)',
 $A$SELECT value->>'scale_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,10,'CORE: and it therefore scales mu_term, which is the base-stock term that actually sizes the line',
 $A$SELECT value->>'mu_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,11,'The CLAMP reaches the engine: an authored 5.0 scales quantities by 2.5, not by 5.0',
 $A$SELECT value->>'clamp_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,12,'An uplift never REDUCES a quantity - every sizing term downstream of vel_eff is monotone non-decreasing in it',
 $A$SELECT value->>'qty_down' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,13,'and it MOVES at least one quantity - a factor that changed no plan line would be an inert feature',
 $A$SELECT value->>'qty_up' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'gt','0',true,'P2'),
(7,14,'LAW 5: an UNFACTORED line records demand_factor 1.0 explicitly, so silence is never ambiguous',
 $A$SELECT value->>'df_a_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,15,'LAW 5: and it names ZERO contributing calendar rows',
 $A$SELECT value->>'prov_a_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,16,'LAW 5: a FACTORED line records demand_factor 1.6 on every line',
 $A$SELECT value->>'df_b_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,17,'LAW 5: and NAMES the contributing calendar row, so CS can trace which authored factor moved the plan',
 $A$SELECT value->>'prov_b_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,18,'The BASE velocity is preserved unscaled alongside the effective one, so shadow-vs-v19 diffing stays honest about what the multiplier did',
 $A$SELECT value->>'base_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,19,'INTERNAL CONTRACT: on every line of the factored run, velocity_effective_daily = velocity_base_daily x demand_factor - checked WITHIN one run, so it holds independently of any cross-run comparison',
 $A$SELECT value->>'internal_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,20,'ZERO RESIDUE: no demand_calendar row survives the probe',
 $A$SELECT value->>'residue_dc' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,21,'ZERO RESIDUE: no machines_to_visit row survives the probe',
 $A$SELECT value->>'residue_mtv' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,22,'ZERO RESIDUE: no pod_refills_shadow row survives the probe, so this fixture may be re-run against production forever',
 $A$SELECT value->>'residue_shadow' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,23,'LAW 12: the fixture never wrote a LIVE plan row for its date',
 $A$SELECT value->>'live_pr' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(7,24,'ADR-shadow-plan-tables obligation 3: pod_refill_plan row count is unchanged across the whole fixture',
 $A$SELECT value->>'prp_delta' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2')
ON CONFLICT (fixture_id, seq) DO NOTHING;
