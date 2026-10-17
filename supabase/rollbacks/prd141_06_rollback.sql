-- PRD-141 item 6 rollback. Fast path (no DDL): UPDATE public.refill_policy_params SET min_shelf_life_days = 0;
-- (then the G8 / picker floor equals today, as before; the manual-quarantine exclusion in G8 stays).
-- Full path: remove the two patches.
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.validate_refill_plan(date,text[],text)'::regprocedure);
  v := regexp_replace(v, '\n               AND NOT COALESCE\(wi\.manually_quarantined,false\)\n               AND \(wi\.expiration_date IS NULL OR wi\.expiration_date >= p_plan_date \+ [^\n]*', '');
  v := replace(v, '||'' (WH_CENTRAL ''||(SELECT ps.message FROM public.pickable_stock(x.boonz_product_id, NULL, p_plan_date) ps)||'')''', '');
  EXECUTE v;
  v := pg_get_functiondef('public.wh_fefo_for_line(uuid,uuid,date,numeric,uuid[])'::regprocedure);
  v := regexp_replace(v, 'vp\.expiration_date >= p_plan_date \+ COALESCE\(\(SELECT rpp\.min_shelf_life_days[^\n]*', 'vp.expiration_date >= p_plan_date)');
  EXECUTE v;
END $rb$;
