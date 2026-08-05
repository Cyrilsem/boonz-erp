-- PRD-110 leg 104 · golden fixture 66 — D-42 commit/stitch-tier grant sweep.
--
-- CS closed D-42 (2026-08-04, PARKING-LOT line 8293): "REVOKE `anon` AND `PUBLIC`
-- EXECUTE from all five commit/stitch-tier functions NOW — commit_refill_plan_atomic,
-- commit_refill_plan, stitch_pod_to_boonz, approve_pod_refill_plan, approve_refill_plan.
-- Same call as D-41, grant-layer only — do NOT touch the NULL-uid guard inversion
-- (fleet cron convention; crons run as postgres and bypass grants). Executing leg must:
-- (1) re-derive FE call sites first per S-158, (2) revoke both `anon` and `PUBLIC`
-- (S-140 + leg-99 trap), (3) read `proacl` back and assert the whole string, (4) add an
-- ACL fixture at this tier mirroring D-41's, per S-173 as catalog checks not substrings."
--
-- This is step (4). LAW 1: the fixture lands FIRST and is RED on exactly the grant
-- assertions the sweep migration turns green. It mirrors fixture 64 (D-41) in shape.
--
-- ⛔ MEASURED LIVE THIS LEG, NOT ASSUMED. All five carry `anon=X/postgres`. FOUR of the
-- five ALSO carry a PUBLIC grant (`=X/postgres`): approve_pod_refill_plan,
-- commit_refill_plan, commit_refill_plan_atomic, stitch_pod_to_boonz. approve_refill_plan
-- carries anon but no PUBLIC. anon is a MEMBER of PUBLIC, so an anon-only revoke leaves
-- has_function_privilege('anon', …) TRUE on those four — the exact leg-99 trap S-140 names.
--
-- ⭐ S-158 RE-DERIVATION (step 1), and it CORRECTS the ruling's own parenthetical. CS wrote
-- "RefillPlanningTab.tsx calls two of these". It calls THREE — commit_refill_plan_atomic
-- (:960), stitch_pod_to_boonz (:680) and approve_refill_plan (:1099) — and a FOURTH call
-- site exists in src/components/RefillPlanReview.tsx (:222, approve_refill_plan).
-- approve_pod_refill_plan has NO FE call site at all. Every one of those files builds its
-- client with the ANON KEY, but src/middleware.ts redirects any session-less request to
-- /login, so the JWT role at every live call site is `authenticated`, never `anon`.
-- That is why revoking anon cannot break the operator path.
--
-- ⛔ ALL FIVE ARE SECURITY DEFINER, so the GRANT *is* the access control here (S-88), and
-- this tier COMMITS PLANS and STITCHES — an unauthenticated reachable write path.

-- Detector self-test canary, per fixture 64 seq 24 / leg 99's own shipped-then-caught bug.
-- A PUBLIC grant is an EMPTY-GRANTEE acl entry, never a substring of proacl::text, so the
-- seq 9 detector must be proven able to SEE one. Fixture 66 owns its own canary rather
-- than borrowing fixture 64's, so neither fixture can break the other by being retired.
CREATE OR REPLACE FUNCTION golden._acl_canary_public_66()
RETURNS integer LANGUAGE sql IMMUTABLE AS $canary$ SELECT 1 $canary$;

GRANT EXECUTE ON FUNCTION golden._acl_canary_public_66() TO PUBLIC;

DELETE FROM golden.assertions WHERE fixture_id = 66;
DELETE FROM golden.fixtures   WHERE fixture_id = 66;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled)
VALUES (
  66,
  'D-42 grant sweep: the five commit/stitch-tier functions are not executable by anon or by PUBLIC, their three legitimate grants survive, and their bodies are byte-untouched',
  'PRD-110 leg 100 raised D-42 after D-41 shipped: D-41 swept the Stage-1 tier and never looked at the tier that COMMITS. commit_refill_plan_atomic, commit_refill_plan, stitch_pod_to_boonz, approve_pod_refill_plan and approve_refill_plan were all reachable by anon (four of them by PUBLIC as well), all five SECURITY DEFINER. CS closed D-42 on 2026-08-04: revoke both, grant-layer only, guard inversion untouched.',
  'P0',
  DATE '2030-03-08',
  $fx$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'targets', jsonb_build_object(
  'n_found',      count(*),
  'n_overloaded', count(*) FILTER (WHERE n_ovl > 1),
  'n_definer',    count(*) FILTER (WHERE prosecdef),
  'n_anon',       count(*) FILTER (WHERE has_function_privilege('anon', oid, 'EXECUTE')),
  'n_public',     COALESCE(sum(n_pub), 0))
FROM (
  SELECT p.oid, p.prosecdef,
         count(*) OVER (PARTITION BY p.proname) AS n_ovl,
         (SELECT count(*) FROM aclexplode(p.proacl) a WHERE a.grantee = 0) AS n_pub
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN (
    'commit_refill_plan_atomic','commit_refill_plan','stitch_pod_to_boonz',
    'approve_pod_refill_plan','approve_refill_plan')
) t;

-- detector self-test: the SAME expression, aimed at a function that really does
-- carry a PUBLIC grant. If this ever reads 0 the detector is broken, not the ACL.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'canary', jsonb_build_object(
  'public_grants_found',
  (SELECT count(*) FROM aclexplode(p.proacl) a WHERE a.grantee = 0))
FROM pg_proc p
WHERE p.oid = 'golden._acl_canary_public_66()'::regprocedure;
$fx$,
  'Pure ACL/grant fixture: seeds nothing, writes nothing outside golden.scratch. Mirrors fixture 64 (D-41) at the commit/stitch tier. The body md5 pins (seq 18-22) are the LAW 12 tripwire — CS scoped D-42 to the grant layer exactly as D-41, so a leg that "fixes" a guard here instead of in v3 must go red. Seq 11-15 pin the WHOLE proacl string per S-140: a revoke that quietly took service_role would strand the nightly runners with no error anywhere. Seq 24 is the detector self-test against this fixture''s own deliberately PUBLIC-granted canary.',
  true
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, enabled) VALUES

(66, 1, 'NON-VACUITY: all five target functions exist. If a rename ever drops one out of scope, the anon assertions below would pass vacuously on an empty set',
 $a$SELECT value->>'n_found' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$a$, 'eq', '5', 'P0', true),

(66, 2, 'NON-VACUITY: exactly one overload each. A second overload would carry its OWN acl and the whole-string pins below would test the wrong row (the repurpose_machine foot-gun class)',
 $a$SELECT value->>'n_overloaded' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$a$, 'eq', '0', 'P0', true),

(66, 3, 'NON-VACUITY: all five are still SECURITY DEFINER — that is WHY the grant is the whole access control here (S-88: the GRANT is the write guard, not RLS)',
 $a$SELECT value->>'n_definer' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$a$, 'eq', '5', 'P0', true),

(66, 4, 'D-42 CS acceptance test: commit_refill_plan_atomic is NOT executable by anon — this is the function that COMMITS a refill plan',
 $a$SELECT has_function_privilege('anon','public.commit_refill_plan_atomic(date,text[])','EXECUTE')::text$a$, 'eq', 'false', 'P0', true),

(66, 5, 'D-42 CS acceptance test: commit_refill_plan is NOT executable by anon',
 $a$SELECT has_function_privilege('anon','public.commit_refill_plan(date,text,uuid[])','EXECUTE')::text$a$, 'eq', 'false', 'P0', true),

(66, 6, 'D-42 CS acceptance test: stitch_pod_to_boonz is NOT executable by anon — ⛔ p_force/p_force_reason make this an override-capable writer',
 $a$SELECT has_function_privilege('anon','public.stitch_pod_to_boonz(date,boolean,boolean,text)','EXECUTE')::text$a$, 'eq', 'false', 'P0', true),

(66, 7, 'D-42 CS acceptance test: approve_pod_refill_plan is NOT executable by anon',
 $a$SELECT has_function_privilege('anon','public.approve_pod_refill_plan(date,text[])','EXECUTE')::text$a$, 'eq', 'false', 'P0', true),

(66, 8, 'D-42 CS acceptance test: approve_refill_plan is NOT executable by anon — ⭐ the only one of the five with TWO FE call sites (RefillPlanningTab.tsx:1099 and RefillPlanReview.tsx:222), both authenticated-gated by src/middleware.ts',
 $a$SELECT has_function_privilege('anon','public.approve_refill_plan(date,text[])','EXECUTE')::text$a$, 'eq', 'false', 'P0', true),

(66, 9, '⛔ NO PUBLIC GRANT on any of the five. anon is a MEMBER of PUBLIC, so a revoke naming only anon leaves has_function_privilege(anon) TRUE. FOUR of the five carried an explicit =X/postgres when D-42 was executed (approve_refill_plan did not), and the D-42 ruling named only anon and PUBLIC generically. Detected via aclexplode(grantee=0) — a PUBLIC grant is an EMPTY-grantee ACL entry, never a substring of proacl::text (seq 24 proves this detector can actually see one)',
 $a$SELECT value->>'n_public' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$a$, 'eq', '0', 'P0', true),

(66, 10, 'and the same fact stated as the live aggregate the scenario measured: zero of the five are anon-executable',
 $a$SELECT value->>'n_anon' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'targets'$a$, 'eq', '0', 'P0', true),

(66, 11, '⛔ the WHOLE proacl string (S-140), commit_refill_plan_atomic. The three legitimate grants must ALL survive: a revoke that quietly took service_role would break the nightly runner with no error anywhere',
 $a$SELECT proacl::text FROM pg_proc WHERE oid='public.commit_refill_plan_atomic(date,text[])'::regprocedure$a$, 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', 'P0', true),

(66, 12, '⛔ the WHOLE proacl string (S-140), commit_refill_plan',
 $a$SELECT proacl::text FROM pg_proc WHERE oid='public.commit_refill_plan(date,text,uuid[])'::regprocedure$a$, 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', 'P0', true),

(66, 13, '⛔ the WHOLE proacl string (S-140), stitch_pod_to_boonz',
 $a$SELECT proacl::text FROM pg_proc WHERE oid='public.stitch_pod_to_boonz(date,boolean,boolean,text)'::regprocedure$a$, 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', 'P0', true),

(66, 14, '⛔ the WHOLE proacl string (S-140), approve_pod_refill_plan',
 $a$SELECT proacl::text FROM pg_proc WHERE oid='public.approve_pod_refill_plan(date,text[])'::regprocedure$a$, 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', 'P0', true),

(66, 15, '⛔ the WHOLE proacl string (S-140), approve_refill_plan — ⭐ note this one started with NO PUBLIC entry, so its post-state proves the revoke is idempotent on a function that never carried the grant',
 $a$SELECT proacl::text FROM pg_proc WHERE oid='public.approve_refill_plan(date,text[])'::regprocedure$a$, 'eq', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}', 'P0', true),

(66, 16, 'the app must still work: authenticated retains EXECUTE on all five (the FE operator paths — three call sites in RefillPlanningTab.tsx, one in RefillPlanReview.tsx)',
 $a$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('commit_refill_plan_atomic','commit_refill_plan',
      'stitch_pod_to_boonz','approve_pod_refill_plan','approve_refill_plan')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')$a$, 'eq', '5', 'P0', true),

(66, 17, 'and service_role retains EXECUTE on all five — the nightly runners call in on this role',
 $a$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('commit_refill_plan_atomic','commit_refill_plan',
      'stitch_pod_to_boonz','approve_pod_refill_plan','approve_refill_plan')
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')$a$, 'eq', '5', 'P0', true),

(66, 18, 'LAW 12 + CS scope: commit_refill_plan_atomic body is byte-untouched by the grant sweep (md5 prosrc, never pg_get_functiondef — S-109). ⛔ This is also one of the THREE GATE md5s the RESUME POINTER carries leg to leg',
 $a$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.commit_refill_plan_atomic(date,text[])'::regprocedure$a$, 'eq', '4237fbcc', 'P0', true),

(66, 19, 'LAW 12 + CS scope: commit_refill_plan body byte-untouched — ⛔ GATE md5',
 $a$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.commit_refill_plan(date,text,uuid[])'::regprocedure$a$, 'eq', 'ed4a3df6', 'P0', true),

(66, 20, 'LAW 12 + CS scope: stitch_pod_to_boonz body byte-untouched — ⛔ GATE md5',
 $a$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.stitch_pod_to_boonz(date,boolean,boolean,text)'::regprocedure$a$, 'eq', '806340b2', 'P0', true),

(66, 21, 'LAW 12 + CS scope: approve_pod_refill_plan body byte-untouched',
 $a$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.approve_pod_refill_plan(date,text[])'::regprocedure$a$, 'eq', '76c5342b', 'P0', true),

(66, 22, 'LAW 12 + CS scope: approve_refill_plan body byte-untouched — ⛔ CS scoped D-42 to the grant layer exactly as D-41. A leg that hardens a guard in any of these five bodies must break this pin on purpose, not by accident',
 $a$SELECT left(md5(prosrc),8) FROM pg_proc WHERE oid='public.approve_refill_plan(date,text[])'::regprocedure$a$, 'eq', '029f0ef6', 'P0', true),

(66, 23, 'TIER-SCOPED (Cody revision): zero active cron jobs whose command references ANY of the five commit/stitch-tier functions. Measured live this leg = 0. ⭐ This is the assertion that is DIAGNOSABLE — a red here means a cron now calls this tier and its role must be checked against the grants below, which is exactly the D-42 question',
 $a$SELECT count(*)::text FROM cron.job WHERE active AND (
    command ILIKE '%commit_refill_plan%' OR command ILIKE '%stitch_pod_to_boonz%'
    OR command ILIKE '%approve_refill_plan%' OR command ILIKE '%approve_pod_refill_plan%')$a$, 'eq', '0', 'P0', true),

(66, 25, 'FLEET-WIDE companion to seq 23: every active cron runs as postgres (36 of 36, measured this leg), the owner, and is therefore grant-independent — the evidence that revoking anon+PUBLIC cannot strand a scheduled job (LAW 12). ⚠️ Kept DELIBERATELY SEPARATE from seq 23 per Cody: this one CAN go red for a reason unrelated to D-42 (any new non-postgres cron anywhere in the fleet). If seq 25 is red and seq 23 is green, the new cron does NOT touch this tier and D-42 is intact',
 $a$SELECT count(*)::text FROM cron.job WHERE active AND username <> 'postgres'$a$, 'eq', '0', 'P0', true),

(66, 24, '⭐ DETECTOR SELF-TEST (S-140 applied to this fixture''s own check): the seq 9 expression, aimed at golden._acl_canary_public_66() which deliberately holds an explicit PUBLIC EXECUTE grant, must FIND that grant. Without this, seq 9 reading 0 could equally mean "no PUBLIC grants" or "the detector returns 0 for everything" — which is precisely the bug leg 99 shipped and then caught',
 $a$SELECT value->>'public_grants_found' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'canary'$a$, 'eq', '1', 'P0', true);
