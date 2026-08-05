-- PRD-110 P2.4 · LAW 1 · Golden fixture 31: demand multiplier resolver.
-- Written and baselined RED *before* the demand_calendar migration exists.
-- The to_regclass guard makes the baseline a clean RED rather than a scenario error.
--
-- NON-DESTRUCTIVE BY CONSTRUCTION: every probe row this fixture writes is written inside a
-- PL/pgSQL subtransaction that is FORCED to roll back. PL/pgSQL variable assignments survive
-- the rollback, so measurements are retained while the table is left byte-identical.
-- Seq 27 pins zero residue. This fixture is safe to re-run against production forever.
--
-- plan_date 2030-02-05 is a Tuesday (DOW=2) in ISO week 6. All four event probe dates
-- (+1 Wed, +2 Thu, +3 Fri, +4 Sat) fall in the SAME ISO week, so the macro_kpi leg applies
-- across all of them and only the event/dow legs move. +7 lands in ISO week 7.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (31,
 'Demand multiplier resolver (P2.4 factors)',
 'BUILD SPEC P2.4 — demand_calendar(week, machine_class|machine_id, factor, source); effective_velocity = velocity_instock x PIfactors clamped 0.5-2.5. S-02: context-intelligence absent, so source=event is RPC-written only.',
 'P2',
 '2030-02-05',
$FX$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DO $fx31$
DECLARE
  v_mid            uuid;
  v_class          text;
  v_mn             numeric;
  v_mx             numeric;
  v_raw            numeric;
  v_n              integer;
  v_clamped        boolean;
  v_prov           jsonb;
  v_rows           bigint;
  v_active         bigint;
  v_rederive_mm    bigint;
  v_null_factor    bigint;
  v_shape_rej      integer := 0;
  v_scope_rej      integer := 0;
  v_dup_rej        integer := 0;
  v_factor_rej     integer := 0;
  v_del_rej        integer := 0;
  v_upd_rej        integer := 0;
  v_specific       numeric;
  v_multiplied     numeric;
  v_clamp_hi       numeric;
  v_clamp_lo       numeric;
  v_evt_in         numeric;
  v_evt_edge_from  numeric;
  v_evt_edge_to    numeric;
  v_evt_out        numeric;
  v_dow_hit        numeric;
  v_week_hit       numeric;
  v_superseded     numeric;
  v_prov_names     integer;
  v_resid          bigint;
  v_rls            boolean;
  v_wpol           bigint;
  v_audit_trg      bigint;
  v_ao_trg         bigint;
  v_writer_def     boolean;
  v_resolver_inv   boolean;
  v_pd             date := '2030-02-05';   -- Tuesday, DOW=2, ISO week 6 of 2030
BEGIN
  -- LAW-1 baseline guard: RED, not an error, until the P2.4 migration lands.
  IF to_regclass('public.demand_calendar') IS NULL
     OR to_regprocedure('public.resolve_demand_multiplier_v3(uuid,date)') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES ({{fixture_id}}, 'obs', jsonb_build_object('objects_exist','false'));
    RETURN;
  END IF;

  SELECT demand_factor_clamp_min, demand_factor_clamp_max INTO v_mn, v_mx
    FROM public.refill_policy_params LIMIT 1;

  SELECT msp.machine_id, msp.machine_class INTO v_mid, v_class
    FROM public.machine_service_policy msp ORDER BY msp.machine_id LIMIT 1;

  SELECT count(*) INTO v_active FROM public.demand_calendar WHERE status='active';

  -- Coverage + LAW 5: the resolver answers for every machine, and never with NULL.
  SELECT count(*), count(*) FILTER (WHERE r.factor IS NULL)
    INTO v_rows, v_null_factor
    FROM public.machine_service_policy m
    CROSS JOIN LATERAL public.resolve_demand_multiplier_v3(m.machine_id, v_pd) r;

  -- ⭐ The fixture's OWN re-derivation of the resolution rule, written out in full rather than
  -- reusing the resolver, so a later edit which changes its MEANING is caught rather than
  -- mirrored (the fixture-29 doctrine). This holds whether or not the calendar is empty, so it
  -- does not rot the day CS authors the first real factor.
  WITH cls AS (
    SELECT machine_id, machine_class FROM public.machine_service_policy
  ), app AS (
    SELECT c.machine_id, dc.source, dc.factor, dc.created_at,
           CASE WHEN dc.machine_id IS NOT NULL THEN 1
                WHEN dc.machine_class IS NOT NULL THEN 2 ELSE 3 END AS sp
      FROM cls c
      JOIN public.demand_calendar dc
        ON dc.status = 'active'
       AND (dc.machine_id = c.machine_id
            OR (dc.machine_id IS NULL AND dc.machine_class = c.machine_class)
            OR (dc.machine_id IS NULL AND dc.machine_class IS NULL))
       AND (CASE dc.source
              WHEN 'macro_kpi' THEN dc.iso_year = EXTRACT(ISOYEAR FROM v_pd)::int
                                AND dc.iso_week = EXTRACT(WEEK    FROM v_pd)::int
              WHEN 'dow'       THEN dc.dow      = EXTRACT(DOW     FROM v_pd)::int
              WHEN 'event'     THEN v_pd BETWEEN dc.valid_from AND dc.valid_to
            END)
  ), win AS (
    SELECT DISTINCT ON (machine_id, source) machine_id, source, factor
      FROM app ORDER BY machine_id, source, sp, factor DESC, created_at DESC
  ), prod AS (
    SELECT c.machine_id,
             COALESCE((SELECT factor FROM win w WHERE w.machine_id=c.machine_id AND w.source='macro_kpi'),1)
           * COALESCE((SELECT factor FROM win w WHERE w.machine_id=c.machine_id AND w.source='event'),1)
           * COALESCE((SELECT factor FROM win w WHERE w.machine_id=c.machine_id AND w.source='dow'),1) AS raw
      FROM cls c
  )
  SELECT count(*) INTO v_rederive_mm
    FROM prod p
    CROSS JOIN LATERAL public.resolve_demand_multiplier_v3(p.machine_id, v_pd) r
   WHERE r.factor IS DISTINCT FROM LEAST(GREATEST(p.raw, v_mn), v_mx);

  -- Static structure: RLS on, SELECT-only policy set, both Cody-required triggers, security modes.
  SELECT c.relrowsecurity INTO v_rls FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='demand_calendar';
  SELECT count(*) INTO v_wpol FROM pg_policies
   WHERE schemaname='public' AND tablename='demand_calendar' AND cmd <> 'SELECT';
  SELECT count(*) INTO v_audit_trg FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
   WHERE c.relname='demand_calendar' AND NOT t.tgisinternal AND t.tgname='tg_audit_demand_calendar';
  SELECT count(*) INTO v_ao_trg FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
   WHERE c.relname='demand_calendar' AND NOT t.tgisinternal AND t.tgname='tg_demand_calendar_append_only';
  SELECT p.prosecdef INTO v_writer_def FROM pg_proc p
   WHERE p.oid = to_regprocedure('public.set_demand_factor_v3(text,integer,integer,smallint,date,date,uuid,text,numeric,text)');
  SELECT NOT p.prosecdef INTO v_resolver_inv FROM pg_proc p
   WHERE p.oid = to_regprocedure('public.resolve_demand_multiplier_v3(uuid,date)');

  -- ============ probe block: EVERYTHING below is rolled back ============
  BEGIN
    -- negative tests: each constraint must refuse its own violation
    BEGIN INSERT INTO public.demand_calendar (source, iso_year, note, factor)
          VALUES ('macro_kpi', 2030, 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_shape_rej := v_shape_rej + 1; END;
    BEGIN INSERT INTO public.demand_calendar (source, dow, valid_from, note, factor)
          VALUES ('dow', 2, v_pd, 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_shape_rej := v_shape_rej + 1; END;
    BEGIN INSERT INTO public.demand_calendar (source, note, factor)
          VALUES ('event', 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_shape_rej := v_shape_rej + 1; END;
    BEGIN INSERT INTO public.demand_calendar (source, dow, machine_id, machine_class, note, factor)
          VALUES ('dow', 2, v_mid, v_class, 'probe', 1.2);
    EXCEPTION WHEN check_violation THEN v_scope_rej := v_scope_rej + 1; END;
    BEGIN INSERT INTO public.demand_calendar (source, dow, note, factor)
          VALUES ('dow', 2, 'probe', 0);
    EXCEPTION WHEN check_violation THEN v_factor_rej := v_factor_rej + 1; END;

    -- DOW leg on the plan date, fleet scope
    INSERT INTO public.demand_calendar (source, dow, note, factor)
    VALUES ('dow', EXTRACT(DOW FROM v_pd)::smallint, 'probe dow', 1.20);
    SELECT r.factor INTO v_dow_hit FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;

    -- a second ACTIVE row on the same key must be refused by the partial unique index
    BEGIN INSERT INTO public.demand_calendar (source, dow, note, factor)
          VALUES ('dow', EXTRACT(DOW FROM v_pd)::smallint, 'probe dup', 1.40);
    EXCEPTION WHEN unique_violation THEN v_dup_rej := v_dup_rej + 1; END;

    -- append-only: DELETE refused, and a non-supersede UPDATE refused
    BEGIN DELETE FROM public.demand_calendar WHERE note='probe dow';
    EXCEPTION WHEN others THEN v_del_rej := v_del_rej + 1; END;
    BEGIN UPDATE public.demand_calendar SET factor = 9.9 WHERE note='probe dow';
    EXCEPTION WHEN others THEN v_upd_rej := v_upd_rej + 1; END;

    -- macro_kpi leg on the same date: sources MULTIPLY (1.20 x 1.50 = 1.80)
    INSERT INTO public.demand_calendar (source, iso_year, iso_week, note, factor)
    VALUES ('macro_kpi', EXTRACT(ISOYEAR FROM v_pd)::int, EXTRACT(WEEK FROM v_pd)::int, 'probe wk', 1.50);
    SELECT r.factor INTO v_multiplied FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;
    SELECT r.factor INTO v_week_hit   FROM public.resolve_demand_multiplier_v3(v_mid, v_pd + 7) r;

    -- most-specific scope wins WITHIN a source: a machine-scoped dow row REPLACES the fleet row
    -- (1.20 -> 2.00), it does not multiply with it. 2.00 x 1.50 = 3.00 -> clamps to the ceiling.
    INSERT INTO public.demand_calendar (source, dow, machine_id, note, factor)
    VALUES ('dow', EXTRACT(DOW FROM v_pd)::smallint, v_mid, 'probe dow machine', 2.00);
    SELECT r.factor, r.factor_raw, r.n_factors, r.clamped, r.provenance
      INTO v_clamp_hi, v_raw, v_n, v_clamped, v_prov
      FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;
    v_prov_names := jsonb_array_length(v_prov);

    -- superseded rows never resolve: retire the machine-scoped row, fleet 1.20 returns
    UPDATE public.demand_calendar SET status='superseded', superseded_at=now()
     WHERE note='probe dow machine';
    SELECT r.factor INTO v_superseded FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;

    -- specificity again, class-scoped beating fleet: 1.10 x 1.50 = 1.65
    INSERT INTO public.demand_calendar (source, dow, machine_class, note, factor)
    VALUES ('dow', EXTRACT(DOW FROM v_pd)::smallint, v_class, 'probe dow class', 1.10);
    SELECT r.factor INTO v_specific FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;

    -- low clamp binds symmetrically: 1.10 x 1.50 x 0.10 = 0.165 -> floors at 0.5
    INSERT INTO public.demand_calendar (source, valid_from, valid_to, note, factor)
    VALUES ('event', v_pd, v_pd, 'probe low', 0.10);
    SELECT r.factor INTO v_clamp_lo FROM public.resolve_demand_multiplier_v3(v_mid, v_pd) r;
    UPDATE public.demand_calendar SET status='superseded', superseded_at=now() WHERE note='probe low';

    -- event window inclusivity on both edges, and exclusion one day past valid_to.
    -- +1/+2/+3/+4 are Wed/Thu/Fri/Sat: the DOW=2 rows stop applying, the ISO-week-6 macro_kpi
    -- row (1.50) keeps applying, so the event leg is measured cleanly against 1.50.
    INSERT INTO public.demand_calendar (source, valid_from, valid_to, note, factor)
    VALUES ('event', v_pd + 1, v_pd + 3, 'probe evt', 1.60);
    SELECT r.factor INTO v_evt_edge_from FROM public.resolve_demand_multiplier_v3(v_mid, v_pd + 1) r;
    SELECT r.factor INTO v_evt_edge_to   FROM public.resolve_demand_multiplier_v3(v_mid, v_pd + 3) r;
    SELECT r.factor INTO v_evt_out       FROM public.resolve_demand_multiplier_v3(v_mid, v_pd + 4) r;
    SELECT r.factor INTO v_evt_in        FROM public.resolve_demand_multiplier_v3(v_mid, v_pd + 2) r;

    RAISE EXCEPTION 'fx31_rollback' USING ERRCODE = '22023';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;   -- probe rows discarded; the measurements above survive in PL/pgSQL variables
  END;
  -- ============ end probe block ============

  SELECT count(*) INTO v_resid FROM public.demand_calendar WHERE note LIKE 'probe%';

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'obs', jsonb_build_object(
    'objects_exist','true',
    'rows',            v_rows,
    'active_rows',     v_active,
    'rederive_mm',     v_rederive_mm,
    'null_factor',     v_null_factor,
    'shape_rej',       v_shape_rej,
    'scope_rej',       v_scope_rej,
    'factor_rej',      v_factor_rej,
    'dup_rej',         v_dup_rej,
    'del_rej',         v_del_rej,
    'upd_rej',         v_upd_rej,
    'dow_hit',         v_dow_hit,
    'multiplied',      v_multiplied,
    'week_hit',        v_week_hit,
    'clamp_hi',        v_clamp_hi,
    'clamp_lo',        v_clamp_lo,
    'clamped_flag',    v_clamped,
    'raw',             v_raw,
    'n_factors',       v_n,
    'prov_names',      v_prov_names,
    'superseded',      v_superseded,
    'specific',        v_specific,
    'evt_in',          v_evt_in,
    'evt_edge_from',   v_evt_edge_from,
    'evt_edge_to',     v_evt_edge_to,
    'evt_out',         v_evt_out,
    'residue',         v_resid,
    'rls',             v_rls,
    'write_policies',  v_wpol,
    'audit_trg',       v_audit_trg,
    'append_only_trg', v_ao_trg,
    'writer_definer',  v_writer_def,
    'resolver_invoker',v_resolver_inv,
    'clamp_mn',        v_mn,
    'clamp_mx',        v_mx
  ));
END $fx31$;
$FX$,
 'P2.4. Fixture 7 (event uplift, engine-grain) is the SEPARATE downstream fixture asserting engine quantities scale; THIS fixture pins the resolver that feeds it. Probe rows roll back by construction (seq 27 pins zero residue).',
 true, 'failing_expected')
ON CONFLICT (fixture_id) DO NOTHING;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(31, 1,'The demand_calendar table and its resolver both exist (RED until the P2.4 migration lands — this is the recorded LAW-1 baseline)',
 $A$SELECT value->>'objects_exist' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','true',true,'P2'),
(31, 2,'NON-VACUITY: the resolver answers for every machine in service policy, so the assertions below are earned rather than vacuous',
 $A$SELECT value->>'rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','31',true,'P2'),
(31, 3,'⭐ RESOLUTION RULE: the resolver matches the fixture OWN independent re-derivation for every machine — most-specific-within-source, multiplied across sources, then clamped',
 $A$SELECT value->>'rederive_mm' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(31, 4,'LAW 5: the resolver never returns NULL — a NULL factor would silently annihilate vel_eff downstream',
 $A$SELECT value->>'null_factor' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(31, 5,'⭐ SHADOW SAFETY: P2.4 ships with an EMPTY calendar, so every machine resolves to exactly 1.0 and v3 quantities do not move until CS authors a factor. When CS authors the first row THIS is the assertion that flips, deliberately',
 $A$SELECT value->>'active_rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(31, 6,'chk_shape refuses all three malformed temporal shapes (macro_kpi without a week, dow carrying a date window, event with no window)',
 $A$SELECT value->>'shape_rej' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','3',true,'P2'),
(31, 7,'chk_scope refuses a row carrying BOTH machine_id and machine_class — scope must be unambiguous',
 $A$SELECT value->>'scope_rej' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1',true,'P2'),
(31, 8,'factor CHECK refuses zero (a zero factor would zero out demand fleet-wide)',
 $A$SELECT value->>'factor_rej' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1',true,'P2'),
(31, 9,'The partial unique index refuses a second ACTIVE row on the same (source, temporal key, scope)',
 $A$SELECT value->>'dup_rej' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1',true,'P2'),
(31,10,'Article 7: DELETE is refused by tg_demand_calendar_append_only — history is superseded, never erased',
 $A$SELECT value->>'del_rej' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1',true,'P2'),
(31,11,'Article 7: an UPDATE of factor (a non-supersede column) is refused — only (status, superseded_at) may move',
 $A$SELECT value->>'upd_rej' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1',true,'P2'),
(31,12,'A fleet-scoped dow row on the plan date resolves to its factor (1.20)',
 $A$SELECT value->>'dow_hit' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.2000',true,'P2'),
(31,13,'ACROSS sources the factors MULTIPLY: dow 1.20 x macro_kpi 1.50 = 1.80',
 $A$SELECT value->>'multiplied' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.8000',true,'P2'),
(31,14,'The macro_kpi row binds to its ISO week only: one week later (ISO week 7) it no longer applies, leaving dow 1.20 alone',
 $A$SELECT value->>'week_hit' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.2000',true,'P2'),
(31,15,'⭐ WITHIN a source the most specific scope WINS rather than multiplying: machine-scoped dow 2.00 REPLACES fleet 1.20, so raw = 2.00 x 1.50 = 3.00',
 $A$SELECT value->>'raw' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','3.0000',true,'P2'),
(31,16,'That raw 3.00 is CLAMPED to the 2.5 ceiling (BUILD SPEC P2.4: clamped 0.5-2.5)',
 $A$SELECT value->>'clamp_hi' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2.5000',true,'P2'),
(31,17,'and the clamped flag is raised, so a clamped plan is never mistaken for an authored one',
 $A$SELECT value->>'clamped_flag' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','true',true,'P2'),
(31,18,'The low clamp binds symmetrically: 1.10 x 1.50 x an 0.10 event factor = 0.165, floored at 0.5 rather than collapsing demand',
 $A$SELECT value->>'clamp_lo' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0.5000',true,'P2'),
(31,19,'LAW 5: provenance names EVERY contributing row (2 sources contributing at the clamp probe)',
 $A$SELECT value->>'prov_names' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2',true,'P2'),
(31,20,'n_factors counts the CONTRIBUTING rows, not the candidate rows',
 $A$SELECT value->>'n_factors' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2',true,'P2'),
(31,21,'A superseded row never resolves: retiring the machine-scoped 2.00 returns the fleet 1.20 x 1.50 = 1.80',
 $A$SELECT value->>'superseded' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.8000',true,'P2'),
(31,22,'Class-scoped beats fleet-scoped on the same source: 1.10 x 1.50 = 1.65',
 $A$SELECT value->>'specific' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.6500',true,'P2'),
(31,23,'An event applies inside its window: on the Thursday the DOW rows lapse and macro_kpi 1.50 x event 1.60 = 2.40 (under the ceiling, so the clamp is not doing the work here)',
 $A$SELECT value->>'evt_in' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2.4000',true,'P2'),
(31,24,'valid_from is INCLUSIVE — the window opens on its first day',
 $A$SELECT value->>'evt_edge_from' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2.4000',true,'P2'),
(31,25,'valid_to is INCLUSIVE — the window still applies on its last day',
 $A$SELECT value->>'evt_edge_to' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2.4000',true,'P2'),
(31,26,'and one day past valid_to the event stops applying, leaving the ISO-week macro_kpi 1.50 alone',
 $A$SELECT value->>'evt_out' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1.5000',true,'P2'),
(31,27,'⭐ ZERO RESIDUE: every probe row rolled back. This fixture is provably non-destructive and may be re-run against production forever',
 $A$SELECT value->>'residue' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(31,28,'Article 2: RLS is enabled on demand_calendar',
 $A$SELECT value->>'rls' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','true',true,'P2'),
(31,29,'Article 3: there is NO INSERT/UPDATE/DELETE policy — writers are SECURITY DEFINER RPCs only',
 $A$SELECT value->>'write_policies' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0',true,'P2'),
(31,30,'Article 8: tg_audit_demand_calendar is installed (Cody finding, leg 48)',
 $A$SELECT value->>'audit_trg' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1',true,'P2'),
(31,31,'Article 7: tg_demand_calendar_append_only is installed (Cody finding, leg 48)',
 $A$SELECT value->>'append_only_trg' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','1',true,'P2'),
(31,32,'Article 4: the writer is SECURITY DEFINER',
 $A$SELECT value->>'writer_definer' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','true',true,'P2'),
(31,33,'The read-only resolver is SECURITY INVOKER — the safer default Cody asks for on read-only helpers',
 $A$SELECT value->>'resolver_invoker' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','true',true,'P2'),
(31,34,'The clamp bounds are PARAMETERS in refill_policy_params, not literals in the resolver body (min)',
 $A$SELECT value->>'clamp_mn' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','0.5000',true,'P2'),
(31,35,'The clamp bounds are PARAMETERS in refill_policy_params, not literals in the resolver body (max)',
 $A$SELECT value->>'clamp_mx' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$A$,'eq','2.5000',true,'P2')
ON CONFLICT (fixture_id, seq) DO NOTHING;
