-- p_pods NULL = every active site in vox_sites (never 'Pre-VOX' / 'Other')
DO $patch$
DECLARE fn text; d text;
  old_f text := 'selected_machines AS (SELECT * FROM vox_machines WHERE (p_pods IS NULL OR site = ANY(p_pods)))';
  new_f text := 'selected_machines AS (SELECT * FROM vox_machines WHERE site = ANY(COALESCE(p_pods, ARRAY(SELECT vs.site FROM vox_sites vs WHERE vs.is_active))))';
BEGIN
  FOREACH fn IN ARRAY ARRAY['get_vox_commercial_report','get_vox_commercial_txn_lines','get_vox_consumer_report'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname=fn;
    IF position(old_f in d)=0 THEN RAISE EXCEPTION 'anchor missing in %', fn; END IF;
    EXECUTE replace(d, old_f, new_f);
  END LOOP;
END $patch$;