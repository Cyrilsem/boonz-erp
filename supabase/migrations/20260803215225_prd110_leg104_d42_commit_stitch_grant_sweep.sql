-- PRD-110 leg 104 · D-42 EXECUTED — revoke anon + PUBLIC EXECUTE from the five
-- commit/stitch-tier functions.
--
-- CS closed D-42 (2026-08-04, PARKING-LOT line 8293): "REVOKE `anon` AND `PUBLIC`
-- EXECUTE from all five commit/stitch-tier functions NOW — commit_refill_plan_atomic,
-- commit_refill_plan, stitch_pod_to_boonz, approve_pod_refill_plan, approve_refill_plan.
-- Same call as D-41, grant-layer only — do NOT touch the NULL-uid guard inversion
-- (fleet cron convention; crons 13/14/42-46 run as postgres and bypass grants)."
--
-- Golden fixture 66 (the preceding migration) is the standing assertion. It landed FIRST
-- (LAW 1) and was RED on exactly the grant assertions this migration turns green.
--
-- ⛔ WHY D-42 EXISTS AT ALL: D-41 swept the Stage-1 tier — the functions that BUILD a
-- draft — and never looked at the tier that COMMITS one. Leg 100 found it. All five here
-- are SECURITY DEFINER, so the GRANT is the entire access control (S-88), and this tier
-- writes committed plans and stitches pod->boonz.
--
-- ⛔ WHY `PUBLIC` IS IN SCOPE, MEASURED LIVE (the leg-99 trap, S-140). FOUR of the five
-- also carry a PUBLIC grant (`=X/postgres`): approve_pod_refill_plan, commit_refill_plan,
-- commit_refill_plan_atomic, stitch_pod_to_boonz. `anon` is a member of PUBLIC, so
-- REVOKE ... FROM anon alone would leave has_function_privilege('anon', oid, 'EXECUTE')
-- TRUE on those four and CS's own acceptance test would FAIL. approve_refill_plan carries
-- anon but NO PUBLIC entry; its REVOKE ... FROM PUBLIC is a harmless no-op, kept for
-- symmetry exactly as _build_draft_core_v3's was under D-41.
--
-- ⭐ STEP (1) OF THE RULING — FE CALL SITES RE-DERIVED PER S-158, AND THE RULING'S OWN
-- PARENTHETICAL WAS WRONG. CS wrote "RefillPlanningTab.tsx calls two of these". It calls
-- THREE: commit_refill_plan_atomic (:960), stitch_pod_to_boonz (:680), approve_refill_plan
-- (:1099). A FOURTH call site is src/components/RefillPlanReview.tsx:222
-- (approve_refill_plan). approve_pod_refill_plan has NO FE call site.
-- All of those files build their client with the ANON KEY — but src/middleware.ts calls
-- supabase.auth.getUser() and redirects any session-less request to /login, so the JWT
-- role at every live call site is `authenticated`, never `anon`. Revoking anon therefore
-- cannot break the operator path, and `authenticated` is explicitly preserved below.
--
-- ⚠️ THE GUARD INVERSION IS NOT CURED HERE, BY DESIGN — same scope split CS drew for D-41.
-- This migration removes reachability, not the inversion. Fixture 66 seq 18-22 pin all
-- five bodies by md5(prosrc) so that split cannot be silently crossed in either direction.
-- Three of those five pins are the GATE md5s the RESUME POINTER already carries leg to leg
-- (commit_refill_plan ed4a3df6 · stitch_pod_to_boonz 806340b2 · commit_refill_plan_atomic
-- 4237fbcc), so the fixture and the relay pointer now agree by construction.
--
-- LAW 4 is untouched: nothing here writes refill_plan_output, pod_refills or
-- machines_to_visit. This is a grant-layer change only.

REVOKE EXECUTE ON FUNCTION public.commit_refill_plan_atomic(date, text[]) FROM anon;
REVOKE EXECUTE ON FUNCTION public.commit_refill_plan_atomic(date, text[]) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.commit_refill_plan(date, text, uuid[]) FROM anon;
REVOKE EXECUTE ON FUNCTION public.commit_refill_plan(date, text, uuid[]) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.stitch_pod_to_boonz(date, boolean, boolean, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.stitch_pod_to_boonz(date, boolean, boolean, text) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.approve_pod_refill_plan(date, text[]) FROM anon;
REVOKE EXECUTE ON FUNCTION public.approve_pod_refill_plan(date, text[]) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.approve_refill_plan(date, text[]) FROM anon;
REVOKE EXECUTE ON FUNCTION public.approve_refill_plan(date, text[]) FROM PUBLIC;

-- ── VERIFY IN-MIGRATION (S-140): read proacl BACK and assert the WHOLE string,
-- plus CS's literal acceptance test, plus the LAW 12 body pins. Any deviation aborts.
DO $$
DECLARE
  r          record;
  v_expected text := '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}';
  v_n        int  := 0;
  v_md5      jsonb := jsonb_build_object(
    'commit_refill_plan_atomic', '4237fbcc',
    'commit_refill_plan',        'ed4a3df6',
    'stitch_pod_to_boonz',       '806340b2',
    'approve_pod_refill_plan',   '76c5342b',
    'approve_refill_plan',       '029f0ef6');
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, p.oid::regprocedure::text AS sig, p.proacl::text AS acl,
           left(md5(p.prosrc),8) AS body_md5,
           has_function_privilege('anon',         p.oid, 'EXECUTE') AS anon_x,
           has_function_privilege('authenticated',p.oid, 'EXECUTE') AS auth_x,
           has_function_privilege('service_role', p.oid, 'EXECUTE') AS svc_x
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'commit_refill_plan_atomic','commit_refill_plan','stitch_pod_to_boonz',
      'approve_pod_refill_plan','approve_refill_plan')
  LOOP
    v_n := v_n + 1;

    IF r.anon_x THEN
      RAISE EXCEPTION 'D-42 FAILED: % still EXECUTable by anon (acl=%)', r.sig, r.acl;
    END IF;
    IF NOT r.auth_x THEN
      RAISE EXCEPTION 'D-42 OVER-REACH: % lost authenticated EXECUTE (acl=%)', r.sig, r.acl;
    END IF;
    IF NOT r.svc_x THEN
      RAISE EXCEPTION 'D-42 OVER-REACH: % lost service_role EXECUTE (acl=%)', r.sig, r.acl;
    END IF;
    IF r.acl IS DISTINCT FROM v_expected THEN
      RAISE EXCEPTION 'D-42 ACL MISMATCH on %: got % want %', r.sig, r.acl, v_expected;
    END IF;
    -- LAW 12: grant-layer only. If a body moved, this migration is not what it claims.
    IF r.body_md5 IS DISTINCT FROM (v_md5 ->> r.proname) THEN
      RAISE EXCEPTION 'D-42 SCOPE BREACH: % body md5 is %, expected % — this migration is grant-layer ONLY',
        r.sig, r.body_md5, (v_md5 ->> r.proname);
    END IF;
  END LOOP;

  IF v_n <> 5 THEN
    RAISE EXCEPTION 'D-42 NON-VACUITY FAILED: matched % functions, expected 5', v_n;
  END IF;

  RAISE NOTICE 'D-42 OK: 5/5 revoked from anon+PUBLIC, three legitimate grants intact, five bodies byte-untouched';
END $$;
