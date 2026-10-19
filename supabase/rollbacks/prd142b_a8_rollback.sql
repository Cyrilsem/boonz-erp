-- Rollback for prd142b_a8_phantom_shelves: removes the cabinet filter from both bodies, then drops the helper.
DO $do$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.get_strategy_machine_detail(uuid)'::regprocedure);
  EXECUTE replace(v, E'\n      AND strategy_cabinet_in_scope(c.machine_id, c.shelf_code)  -- PRD-142b A8: no phantom cabinets', '');
  v := pg_get_functiondef('public.build_machine_features(date)'::regprocedure);
  EXECUTE replace(v, ' AND strategy_cabinet_in_scope(sc.machine_id, sc.shelf_code)', '');
END
$do$;
DROP FUNCTION IF EXISTS public.strategy_cabinet_in_scope(uuid, text);
