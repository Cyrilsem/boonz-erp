-- Loop 2026-09-25/28 (CS ONE LOOP, W6 R7): add_intra_machine_move edited_by_role NULL fix.
--
-- Applied 2026-09-28 night window. add_intra_machine_move is a field-app dispatch function;
-- this loop's hard rule restricts migrations touching dispatch/field-app functions to the
-- 22:00-06:00 Dubai window.
--
-- Confirmed against the live function body before writing anything (matches the exact bug class
-- already fixed once this loop, in A1/add_m2m_transfer): both rows of the
-- refill_dispatching_edit_log INSERT hardcode edited_by_role to a literal NULL
-- ("auth.uid(), NULL, 'add', NULL,"), never even COALESCE(v_role, ...). Confirmed live that
-- refill_dispatching_edit_log.edited_by_role is NOT NULL, so every real call to
-- add_intra_machine_move fails with 23502 on this INSERT -- the function is completely unusable as
-- currently deployed. v_role is already computed earlier in the function body (used for the
-- caller-role authorization check), so it just needs to be reused here.
--
-- Surgical: only the two edited_by_role NULL literals in the edit_log INSERT are touched. The
-- refill_dispatching rows' own last_edited_by_role columns (nullable, not erroring) are left
-- unchanged -- out of R7's named scope.
DO $mig$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='add_intra_machine_move';

  v_new := replace(v_src,
    E'auth.uid(), NULL, \'add\', NULL,',
    E'auth.uid(), COALESCE(v_role, \'system\'), \'add\', NULL,');

  IF v_new = v_src THEN
    RAISE EXCEPTION 'add_intra_machine_move patch: anchor not found, aborting';
  END IF;
  EXECUTE v_new;
END $mig$;
