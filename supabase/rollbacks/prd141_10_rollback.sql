-- PRD-141 item 10 rollback: reverse the three anchor patches (mapping_refill_block left in place, unreferenced).
DO $rb$
DECLARE v text;
  a_new text := ' AND public.mapping_refill_block(p_machine_id, pm.pod_product_id, pm.boonz_product_id) IS NULL';
BEGIN
  v := pg_get_functiondef('public.resolve_fefo_sku_legs_v3(date,uuid,uuid,uuid,integer,text)'::regprocedure);
  EXECUTE replace(v, a_new, '');
  v := pg_get_functiondef('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)'::regprocedure);
  EXECUTE replace(v, a_new, '');
  v := pg_get_functiondef('public.write_refill_plan(date,jsonb)'::regprocedure);
  v := regexp_replace(v, '        ELSIF public\.mapping_refill_block\(v_g11_machine_id.*?(        ELSIF v_g11\.is_override THEN)', '\1', 's');
  v := regexp_replace(v, '            ''message'',format\(''G11: %s is not in the.*?mapped_ids\)\)\),', '            ''message'',''G11 not in machine mapping'',', 's');
  v := replace(v, '  v_map_block    jsonb;' || chr(10), '');
  EXECUTE v;
END $rb$;
REVOKE EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) TO authenticated, service_role;
