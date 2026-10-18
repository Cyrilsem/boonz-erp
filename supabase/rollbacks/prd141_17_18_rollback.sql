-- PRD-141 items 17/18 rollback. v_machine_pack_status keeps the appended columns (CREATE OR REPLACE cannot
-- drop them); make them inert by restating them as 0 / false, and take the tag out of write_refill_plan.
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_viewdef('public.v_machine_pack_status'::regclass, true);
  v := regexp_replace(v, 'CASE\s+WHEN l\.dispatch_date >= .*?END AS in_transit_n', '0::bigint AS in_transit_n', 's');
  v := regexp_replace(v, 'CASE\s+WHEN l\.dispatch_date >= .*?END AS in_transit_units', '0::numeric AS in_transit_units', 's');
  v := regexp_replace(v, 'l\.dispatch_date >= [^\n]*AS in_transit\n', 'false AS in_transit' || chr(10), 's');
  EXECUTE 'CREATE OR REPLACE VIEW public.v_machine_pack_status AS ' || v;
  v := pg_get_functiondef('public.write_refill_plan(date,jsonb)'::regprocedure);
  v := regexp_replace(v, '      NULLIF\(concat_ws\('' '', NULLIF\(line->>''comment'', ''''\),.*?HAVING count\(\*\) > 0\)\), ''''\),', '      line->>''comment'',', 's');
  v := regexp_replace(v, '\n    ''top_up_on_transit_machines'', \(SELECT .*?''Add''\)\),', '', 's');
  EXECUTE v;
END $rb$;
REVOKE EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.write_refill_plan(date, jsonb) TO authenticated, service_role;
-- FE part (Home In the van card, dispatching badge, pack-screen top-up banner): git revert the commit
-- "feat(prd-141): items 17 and 18 in-transit bags and top-up tag". Revert FE first, then run the SQL above.
