-- PRD-110 · S-28 follow-up · REVOKE the anon EXECUTE grant that default privileges
-- re-attached when the estimator was dropped and recreated.
--
-- WHAT HAPPENED. The 2-arg estimate_shelf_composition_v3 carried
--   postgres=X | authenticated=X | service_role=X   (no anon).
-- The S-28 migration dropped it and created the 3-arg version, whose ACL read
--   postgres=X | anon=X | authenticated=X | service_role=X.
-- The migration DID run `REVOKE ALL ... FROM PUBLIC`, but PUBLIC is not anon: Supabase's
-- `ALTER DEFAULT PRIVILEGES ... GRANT EXECUTE ON FUNCTIONS TO anon, authenticated,
-- service_role` re-attached the anon grant to the newly created object. This is RISK 73's
-- mirror image - there it was "REVOKE anon alone is not least privilege" on a view; here it
-- is "REVOKE PUBLIC alone is not least privilege" on a function.
--
-- WHY IT MATTERS. The estimator is SECURITY DEFINER and its role check is
--   `IF v_actor IS NOT NULL AND NOT EXISTS (... operator_admin/superadmin ...) THEN RAISE`.
-- For an anonymous caller auth.uid() is NULL, so the check is SKIPPED, and p_dry_run is only
-- a default - `estimate_shelf_composition_v3(<shelf>, false)` would have written real
-- inventory_events. Restoring the pre-migration ACL closes it.
--
-- Article 12: forward-only fix for a defect introduced by the previous migration; REVOKE is
-- idempotent, so re-running is safe.
-- ⚠️ STANDING RULE for every DROP+CREATE of a function in this project: default privileges
-- re-grant to anon/authenticated/service_role. Restate the intended ACL explicitly and then
-- ASSERT it, exactly as this migration does.

REVOKE ALL ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean)
   TO postgres, authenticated, service_role;

DO $chk$
DECLARE v_acl text;
BEGIN
  SELECT array_to_string(p.proacl, ' | ') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3';

  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'estimator ACL still grants anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X%' OR v_acl NOT LIKE '%service_role=X%'
     OR v_acl NOT LIKE '%postgres=X%' THEN
    RAISE EXCEPTION 'estimator ACL lost a grant the pre-S-28 function had: %', v_acl;
  END IF;
  RAISE NOTICE 'estimator ACL restored to pre-S-28 shape: %', v_acl;
END
$chk$;
