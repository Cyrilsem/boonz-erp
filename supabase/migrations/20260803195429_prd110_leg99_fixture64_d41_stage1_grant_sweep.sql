-- PRD-110 leg 99 · GOLDEN FIXTURE 64 — D-41: the five legacy Stage-1 functions
-- must not be reachable by an unauthenticated caller.
--
-- CS closed D-41 (2026-08-03, Cowork session): "REVOKE ALL FIVE NOW. One
-- Cody-reviewed sweep ... Grant-layer fix only — live function bodies stay
-- byte-untouched (LAW 12); the guard-pattern hardening itself ships with v3 ...
-- add the ACL assertion to the standing fixture set so a future grant regression
-- goes red."
--
-- This fixture IS that standing assertion. It is written FIRST (LAW 1) and is
-- RED at the moment it lands: all five currently carry anon=X/postgres.
--
-- ⛔ THE PARKED PREMISE WAS INCOMPLETE. D-41 was raised naming only `anon`, but
-- four of the five ALSO carry a PUBLIC grant (`=X/postgres`). `anon` is a member
-- of PUBLIC, so REVOKE ... FROM anon alone leaves
-- has_function_privilege('anon', oid, 'EXECUTE') = TRUE and CS's own acceptance
-- test fails. The sweep must revoke PUBLIC as well. seq 8 is the assertion that
-- pins that lesson so it cannot regress into a false green.
--
-- Safe by construction: this fixture seeds nothing, touches no plan table and no
-- protected entity. It reads pg_proc and cron.job only.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, notes, scenario_sql)
VALUES (
  64,
  'D-41 grant sweep: the five legacy Stage-1 functions are not executable by anon or by PUBLIC, their three legitimate grants survive, and their bodies are byte-untouched',
  'PRD-110 leg 95 — found while reading _build_draft_core_v3 ACL for the S-140 assertion. Their role gate reads "IF auth.uid() IS NOT NULL AND NOT EXISTS (...operator_admin...) THEN error", so for anon (auth.uid() = NULL) the condition short-circuits false and the guard is skipped entirely. pick_machines_for_refill and confirm_machines_to_visit WRITE. CS closed D-41 with REVOKE ALL FIVE NOW, grant-layer only.',
  'P0',
  DATE '2030-03-06',
  true,
  'Pure ACL/grant fixture: seeds nothing, writes nothing outside golden.scratch. The body md5 pins (seq 17-21) are the LAW 12 tripwire — CS scoped D-41 to the grant layer, so a leg that "fixes" the NULL-uid short-circuit here instead of in v3 must go red. The guard-pattern hardening ships with v3, not here.',
$scenario$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'targets', jsonb_build_object(
  'n_found',      count(*),
  'n_overloaded', count(*) FILTER (WHERE n_ovl > 1),
  'n_definer',    count(*) FILTER (WHERE prosecdef),
  'n_anon',       count(*) FILTER (WHERE has_function_privilege('anon', oid, 'EXECUTE')),
  'n_public',     count(*) FILTER (WHERE proacl::text LIKE '%=X/%'))
FROM (
  SELECT p.oid, p.prosecdef, p.proacl,
         count(*) OVER (PARTITION BY p.proname) AS n_ovl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN (
    '_build_draft_core_v3','build_draft_for_confirmed_v3','build_confirmed_now_v3',
    'pick_machines_for_refill','confirm_machines_to_visit')
) t;
$scenario$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
-- ── NON-VACUITY ──────────────────────────────────────────────────────────────
(64, 1, 'NON-VACUITY: all five target functions exist. If a rename ever drops one out of scope, the anon assertions below would pass vacuously on an empty set',
 $c$SELECT value->>'n_found' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$c$,
 'eq', '5', true, 'P0'),
(64, 2, 'NON-VACUITY: exactly one overload each. A second overload would carry its OWN acl and the whole-string pins below would test the wrong row (the repurpose_machine foot-gun class)',
 $c$SELECT value->>'n_overloaded' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$c$,
 'eq', '0', true, 'P0'),
(64, 3, 'NON-VACUITY: all five are still SECURITY DEFINER — that is WHY the grant is the whole access control here (S-88: the GRANT is the write guard, not RLS)',
 $c$SELECT value->>'n_definer' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$c$,
 'eq', '5', true, 'P0'),

-- ── CS ACCEPTANCE TEST, verbatim: has_function_privilege('anon', oid, 'EXECUTE') = false ──
(64, 4, 'D-41 CS acceptance test: _build_draft_core_v3 (the Stage 1 core) is NOT executable by anon',
 $c$SELECT has_function_privilege('anon','public._build_draft_core_v3(date,boolean,boolean)','EXECUTE')::text$c$,
 'eq', 'false', true, 'P0'),
(64, 5, 'D-41 CS acceptance test: build_draft_for_confirmed_v3 (CRON 13 entry point) is NOT executable by anon',
 $c$SELECT has_function_privilege('anon','public.build_draft_for_confirmed_v3(date,boolean)','EXECUTE')::text$c$,
 'eq', 'false', true, 'P0'),
(64, 6, 'D-41 CS acceptance test: build_confirmed_now_v3 is NOT executable by anon',
 $c$SELECT has_function_privilege('anon','public.build_confirmed_now_v3(date)','EXECUTE')::text$c$,
 'eq', 'false', true, 'P0'),
(64, 7, 'D-41 CS acceptance test: pick_machines_for_refill is NOT executable by anon — ⛔ this one WRITES machines_to_visit, so the exposure was an unauthenticated write path',
 $c$SELECT has_function_privilege('anon','public.pick_machines_for_refill(date,integer,integer)','EXECUTE')::text$c$,
 'eq', 'false', true, 'P0'),
(64, 8, 'D-41 CS acceptance test: confirm_machines_to_visit is NOT executable by anon — ⛔ also a writer, and its own guard carries the same NULL-uid short-circuit',
 $c$SELECT has_function_privilege('anon','public.confirm_machines_to_visit(date)','EXECUTE')::text$c$,
 'eq', 'false', true, 'P0'),

-- ── THE INCOMPLETE-PREMISE TRIPWIRE ──────────────────────────────────────────
(64, 9, '⛔ NO PUBLIC GRANT on any of the five. anon is a MEMBER of PUBLIC, so a revoke that names only anon leaves has_function_privilege(anon) TRUE. Four of the five carried =X/postgres when D-41 was executed, and the parking-lot premise named only anon. This is the assertion that stops that half-fix from ever reading green',
 $c$SELECT value->>'n_public' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$c$,
 'eq', '0', true, 'P0'),
(64, 10, 'and the same fact stated as the live aggregate the scenario measured: zero of the five are anon-executable',
 $c$SELECT value->>'n_anon' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$c$,
 'eq', '0', true, 'P0'),

-- ── THE REVOKE MUST NOT OVER-REACH: whole proacl string, S-140 ───────────────
(64, 11, '⛔ the WHOLE proacl string (S-140), _build_draft_core_v3. The three legitimate grants must ALL survive: a revoke that quietly took service_role would break the nightly runner with no error anywhere',
 $c$SELECT proacl::text FROM pg_proc WHERE oid='public._build_draft_core_v3(date,boolean,boolean)'::regprocedure$c$,
 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true, 'P0'),
(64, 12, '⛔ the WHOLE proacl string (S-140), build_draft_for_confirmed_v3 — cron 13 runs this as postgres, which is why the revoke cannot strand the nightly advisory (LAW 12)',
 $c$SELECT proacl::text FROM pg_proc WHERE oid='public.build_draft_for_confirmed_v3(date,boolean)'::regprocedure$c$,
 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true, 'P0'),
(64, 13, '⛔ the WHOLE proacl string (S-140), build_confirmed_now_v3',
 $c$SELECT proacl::text FROM pg_proc WHERE oid='public.build_confirmed_now_v3(date)'::regprocedure$c$,
 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true, 'P0'),
(64, 14, '⛔ the WHOLE proacl string (S-140), pick_machines_for_refill — cron 14 runs this as postgres',
 $c$SELECT proacl::text FROM pg_proc WHERE oid='public.pick_machines_for_refill(date,integer,integer)'::regprocedure$c$,
 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true, 'P0'),
(64, 15, '⛔ the WHOLE proacl string (S-140), confirm_machines_to_visit',
 $c$SELECT proacl::text FROM pg_proc WHERE oid='public.confirm_machines_to_visit(date)'::regprocedure$c$,
 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', true, 'P0'),
(64, 16, 'the app must still work: authenticated retains EXECUTE on all five (the FE and the operator paths)',
 $c$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('_build_draft_core_v3','build_draft_for_confirmed_v3',
      'build_confirmed_now_v3','pick_machines_for_refill','confirm_machines_to_visit')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')$c$,
 'eq', '5', true, 'P0'),
(64, 17, 'and service_role retains EXECUTE on all five — the nightly runners call in on this role',
 $c$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('_build_draft_core_v3','build_draft_for_confirmed_v3',
      'build_confirmed_now_v3','pick_machines_for_refill','confirm_machines_to_visit')
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')$c$,
 'eq', '5', true, 'P0'),

-- ── LAW 12 / CS SCOPE: grant layer ONLY, bodies byte-untouched ───────────────
(64, 18, 'LAW 12 + CS scope: _build_draft_core_v3 body is byte-untouched by the grant sweep (md5 prosrc, never pg_get_functiondef — S-109)',
 $c$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public._build_draft_core_v3(date,boolean,boolean)'::regprocedure$c$,
 'eq', 'fef941d5', true, 'P0'),
(64, 19, 'LAW 12 + CS scope: build_draft_for_confirmed_v3 body byte-untouched',
 $c$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.build_draft_for_confirmed_v3(date,boolean)'::regprocedure$c$,
 'eq', '947a3140', true, 'P0'),
(64, 20, 'LAW 12 + CS scope: build_confirmed_now_v3 body byte-untouched',
 $c$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.build_confirmed_now_v3(date)'::regprocedure$c$,
 'eq', '9c03b20e', true, 'P0'),
(64, 21, 'LAW 12 + CS scope: pick_machines_for_refill body byte-untouched',
 $c$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.pick_machines_for_refill(date,integer,integer)'::regprocedure$c$,
 'eq', 'd9f508d1', true, 'P0'),
(64, 22, 'LAW 12 + CS scope: confirm_machines_to_visit body byte-untouched — ⛔ the NULL-uid guard inversion is DELIBERATELY still here. CS scoped D-41 to the grant layer and said the guard-pattern hardening ships with v3. A leg that fixes the body here breaks this pin on purpose',
 $c$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.confirm_machines_to_visit(date)'::regprocedure$c$,
 'eq', 'a3344191', true, 'P0'),

-- ── WHY THE REVOKE IS SAFE FOR THE TWO CRONS THAT CALL THESE ────────────────
(64, 23, 'the two crons that call into this tier run as postgres (the owner), NOT as anon or authenticated — this is the evidence that revoking anon+PUBLIC cannot strand the nightly advisory (LAW 12: the nightly must still work the same night)',
 $c$SELECT count(*)::text FROM cron.job WHERE jobid IN (13,14) AND username='postgres' AND active$c$,
 'eq', '2', true, 'P0');
