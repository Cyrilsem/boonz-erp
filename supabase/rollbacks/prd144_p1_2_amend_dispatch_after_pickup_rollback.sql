-- Rollback for PRD-144 P1-2: removes the protect_packed_dispatch_row exemption (anchors reversed, count
-- guarded) and drops amend_dispatch_after_pickup.
DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.protect_packed_dispatch_row()'::regprocedure);
  pairs := ARRAY[
    ARRAY['      IF NEW.pod_product_id IS DISTINCT FROM OLD.pod_product_id THEN',
          '      IF NEW.pod_product_id IS DISTINCT FROM OLD.pod_product_id' || chr(10)
          || '         AND current_setting(''app.rpc_name'', true) IS DISTINCT FROM ''amend_dispatch_after_pickup'' THEN  -- PRD-144 P1-2'],
    ARRAY['    IF NEW.shelf_id IS DISTINCT FROM OLD.shelf_id THEN',
          '    IF NEW.shelf_id IS DISTINCT FROM OLD.shelf_id' || chr(10)
          || '       AND current_setting(''app.rpc_name'', true) IS DISTINCT FROM ''amend_dispatch_after_pickup'' THEN  -- PRD-144 P1-2']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][2], ''))) / length(pairs[i][2]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_2 rollback: protect_packed_dispatch_row anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][2], pairs[i][1]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
DROP FUNCTION IF EXISTS public.amend_dispatch_after_pickup(uuid, text, numeric, boolean, text, uuid);
