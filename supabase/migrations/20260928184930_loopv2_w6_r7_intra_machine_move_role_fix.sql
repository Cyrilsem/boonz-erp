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
