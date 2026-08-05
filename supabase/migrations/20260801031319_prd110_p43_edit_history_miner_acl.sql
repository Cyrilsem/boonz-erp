SET LOCAL statement_timeout = '60s';

-- PRD-110 P4.3a follow-up: bring mine_edit_history_v3 onto the v3 ACL fleet
-- convention (S-104). Supabase default privileges grant EXECUTE to anon
-- EXPLICITLY, so the REVOKE ... FROM PUBLIC in the parent migration did not
-- remove it. Its P4.1 siblings (submit_feedback_v3, propose_pin_from_feedback_v3,
-- approve_feedback_proposal_v3) all sit at postgres/authenticated/service_role.
-- An anonymous caller could otherwise reach a miner that mints CS-gated
-- proposals; auth.uid() is NULL for anon, so the role gate would short-circuit
-- (S-121) and admit it.
REVOKE EXECUTE ON FUNCTION public.mine_edit_history_v3(date,integer,integer,uuid,integer,boolean) FROM anon;

DO $chk$
DECLARE v_acl text;
BEGIN
  SELECT COALESCE(array_to_string(proacl,' ; '),'NULL') INTO v_acl
    FROM pg_proc WHERE proname = 'mine_edit_history_v3';
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'prd110_p43 acl fix: anon still holds a grant (%)', v_acl;
  END IF;
END $chk$;
