-- PRD-090 forward-fix: footprint subquery used pod_inventory.pod_product_id (nonexistent;
-- pod_inventory keys on boonz_product_id). The engine works in pod_product_id; correct source
-- is slot_lifecycle. Bug shipped dark-inert (subquery pruned when flag off) but would crash on
-- enable. Standalone-validated: 19 niche pods (<=2 machines) of 69 placed.
DO $outer$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.engine_add_pod(date,integer)'::regprocedure);
  IF position('FROM pod_inventory pi JOIN machines mm ON mm.machine_id=pi.machine_id AND mm.status=''Active'' WHERE pi.pod_product_id = cv.pod_product_id AND pi.removed_at IS NULL' IN v_def) = 0 THEN
    IF position('FROM slot_lifecycle sl JOIN machines mm ON mm.machine_id=sl.machine_id AND mm.status=''Active'' WHERE sl.pod_product_id = cv.pod_product_id' IN v_def) > 0 THEN RETURN; END IF;
    RAISE EXCEPTION 'PRD-090-fix: footprint anchor not found';
  END IF;
  v_def := replace(v_def, 'FROM pod_inventory pi JOIN machines mm ON mm.machine_id=pi.machine_id AND mm.status=''Active'' WHERE pi.pod_product_id = cv.pod_product_id AND pi.removed_at IS NULL',
    'FROM slot_lifecycle sl JOIN machines mm ON mm.machine_id=sl.machine_id AND mm.status=''Active'' WHERE sl.pod_product_id = cv.pod_product_id AND sl.is_current AND NOT sl.archived');
  v_def := replace(v_def, 'SELECT count(DISTINCT pi.machine_id) FROM slot_lifecycle sl', 'SELECT count(DISTINCT sl.machine_id) FROM slot_lifecycle sl');
  EXECUTE v_def;
END $outer$;
