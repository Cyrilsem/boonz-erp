-- Rollback for W6/R7 (add_intra_machine_move edited_by_role NULL fix), captured 2026-09-28 night
-- window. Reverses the DO-block patch via the same replace() pattern in reverse -- byte-exact,
-- no transcription risk. Restores the literal NULL that made every real call to
-- add_intra_machine_move fail with 23502 (matches the pre-patch state exactly).
DO $rollback$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='add_intra_machine_move';

  v_new := replace(v_src,
    E'auth.uid(), COALESCE(v_role, \'system\'), \'add\', NULL,',
    E'auth.uid(), NULL, \'add\', NULL,');

  IF v_new = v_src THEN
    RAISE EXCEPTION 'add_intra_machine_move rollback: anchor not found, aborting';
  END IF;
  EXECUTE v_new;
END $rollback$;
