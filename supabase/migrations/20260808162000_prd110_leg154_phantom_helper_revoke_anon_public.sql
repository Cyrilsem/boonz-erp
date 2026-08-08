-- PRD-110 leg 154 - UNIT A, third part: do not ship NEW anon/PUBLIC exposure.
--
-- 20260808161000 created public._is_phantom_wh_row_v3 and it landed carrying Supabase's
-- schema defaults: {=X/postgres, ..., anon=X/postgres, ...} - both PUBLIC and anon EXECUTE.
-- That is the D-30 shape (leg 91) and S-268 says a bare REVOKE ... FROM PUBLIC does NOT
-- remove them, because `anon` holds its grant BY NAME. Both are revoked here, by name.
--
-- ⭐ SUBSTANTIVELY the exposure is nil - this is a pure scalar predicate over two literals
-- that reads no table and returns a boolean - and its sibling _is_sentinel_wh_row_v3 carries
-- the identical ACL today. This migration therefore does NOT touch the sibling: that one is
-- the authorisation scope of a SECURITY DEFINER writer and its grants are their own question.
-- The point here is narrower and non-negotiable: a unit does not LEAVE BEHIND more exposure
-- than it found, even harmless exposure.
--
-- ⛔ `authenticated` KEEPS EXECUTE, deliberately. resolve_fefo_sku_legs_v3 is SECURITY
-- INVOKER and is granted to `authenticated` (RPC_REGISTRY line 1428); it calls this helper,
-- so the caller must hold EXECUTE on it or the binder breaks for every FE caller.

REVOKE EXECUTE ON FUNCTION public._is_phantom_wh_row_v3(text, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._is_phantom_wh_row_v3(text, date) FROM anon;

-- S-140: read proacl BACK WHOLE and assert it, rather than inferring the end state from the
-- fact that two REVOKEs did not error.
DO $do$
DECLARE v_acl text; v_ok boolean;
BEGIN
  SELECT COALESCE(proacl::text, '<null>') INTO v_acl
    FROM pg_proc
   WHERE proname = '_is_phantom_wh_row_v3' AND pronamespace = 'public'::regnamespace;

  v_ok := v_acl NOT LIKE '%anon=%'
      AND v_acl NOT LIKE '{=X%'          -- a leading '=X/...' entry IS the PUBLIC grant
      AND v_acl LIKE '%authenticated=X%';

  IF NOT v_ok THEN
    RAISE EXCEPTION 'REFUSE: _is_phantom_wh_row_v3 proacl is % - expected no PUBLIC, no anon, and authenticated retained', v_acl;
  END IF;
END $do$;
