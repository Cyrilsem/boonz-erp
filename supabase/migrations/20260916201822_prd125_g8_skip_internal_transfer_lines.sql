-- PRD-125 D3 hotfix (2026-09-17 00:25 Dubai, outside the daytime window; validate_refill_plan is on the plan/approve path, not field or warehouse confirmation).
-- G8 (need exceeds free stock) counted machine-to-machine dest legs (source_origin='internal_transfer') as warehouse need,
-- blocking every M2M plan. Surgical: carry source_origin through the lines CTE and exclude internal_transfer from G8 only.
DO $mig$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='validate_refill_plan';
  v_new := v_src;
  v_new := replace(v_new, E'rd.action, rd.quantity\n      FROM public.refill_dispatching rd',
                          E'rd.action, rd.quantity, rd.source_origin\n      FROM public.refill_dispatching rd');
  v_new := replace(v_new, E'rpo.action, rpo.quantity\n      FROM public.refill_plan_output rpo',
                          E'rpo.action, rpo.quantity, rpo.source_origin\n      FROM public.refill_plan_output rpo');
  v_new := replace(v_new, E'FROM lines l LEFT JOIN avail a ON a.boonz_product_id = l.boonz_product_id\n             WHERE l.action IN (''Refill'',''Add New'')\n             GROUP BY',
                          E'FROM lines l LEFT JOIN avail a ON a.boonz_product_id = l.boonz_product_id\n             WHERE l.action IN (''Refill'',''Add New'')\n               AND COALESCE(l.source_origin,''warehouse'') <> ''internal_transfer''  -- M2M dest legs are supplied by the source machine, not the warehouse\n             GROUP BY');
  IF v_new = v_src THEN RAISE EXCEPTION 'validate_refill_plan patch: no change applied'; END IF;
  IF length(v_new) - length(v_src) < 100 THEN RAISE EXCEPTION 'validate_refill_plan patch: unexpected diff size'; END IF;
  EXECUTE v_new;
END $mig$;