-- 2026-09-18 00:06 Dubai, outside the daytime freeze.
-- insert_driver_remove_line's M2M branch excluded parent legs carrying item_added=true, but
-- push_plan_to_dispatch's pairing sets item_added=true on BOTH M2M legs. Net effect: no driver
-- could ever split a mixed-flavour M2M lane (blocked Anthony on AMZ-1046 A02 Zigi, 17 Sep).
-- Surgical: drop item_added from that predicate only. Everything else untouched.
DO $mig$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='insert_driver_remove_line';

  v_new := replace(v_src,
    E'       AND COALESCE(rd.is_m2m, false) = true\n       AND NOT COALESCE(rd.item_added, false)\n',
    E'       AND COALESCE(rd.is_m2m, false) = true\n       -- item_added is set on BOTH legs by push pairing, so it cannot be used to\n       -- exclude a parent here (fix 2026-09-18, was blocking every mixed-lane split)\n');

  IF v_new = v_src THEN
    RAISE EXCEPTION 'insert_driver_remove_line patch: predicate not found, aborting';
  END IF;
  EXECUTE v_new;
END $mig$;