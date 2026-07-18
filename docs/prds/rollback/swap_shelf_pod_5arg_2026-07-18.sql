-- Rollback for PRD-102 D1: original 5-arg swap_shelf_pod as of 2026-07-18.
-- Forward rollback = DROP the 6-arg overload and re-create this body.
-- DROP FUNCTION IF EXISTS public.swap_shelf_pod(date, uuid, uuid, uuid, text, integer);
CREATE OR REPLACE FUNCTION public.swap_shelf_pod(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_new_pod_product_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid := auth.uid();
  v_role         text;
  v_shelf_code   text;
  v_wh           uuid;
  v_cap          int;
  v_spread_total int := 0;
  v_n_spread     int := 0;
  v_removed      jsonb := '[]'::jsonb;
  v_added        jsonb := '[]'::jsonb;
  r              record;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'swap_shelf_pod', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'swap_shelf_pod: forbidden for role %', COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL OR p_new_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'swap_shelf_pod: plan_date, machine_id, shelf_id, new_pod_product_id are required';
  END IF;
  IF COALESCE(p_reason, '') = '' OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'swap_shelf_pod: p_reason required (>= 10 chars)';
  END IF;

  SELECT shelf_code INTO v_shelf_code
    FROM public.shelf_configurations
   WHERE shelf_id = p_shelf_id AND machine_id = p_machine_id;
  IF v_shelf_code IS NULL THEN
    RAISE EXCEPTION 'swap_shelf_pod: shelf % not found on machine %', p_shelf_id, p_machine_id;
  END IF;

  SELECT primary_warehouse_id INTO v_wh FROM public.machines WHERE machine_id = p_machine_id;
  IF v_wh IS NULL THEN
    RAISE EXCEPTION 'swap_shelf_pod: machine % has no primary_warehouse_id (cannot WH-source the new pod)', p_machine_id;
  END IF;

  SELECT MAX(max_stock_weimi)::int INTO v_cap FROM public.v_shelf_max_stock WHERE shelf_id = p_shelf_id;
  IF COALESCE(v_cap, 0) <= 0 THEN
    RAISE EXCEPTION 'swap_shelf_pod: shelf % has no positive capacity (max_stock)', p_shelf_id;
  END IF;

  SELECT COALESCE(SUM(qty), 0), COUNT(*) INTO v_spread_total, v_n_spread
    FROM public.spread_pod_qty(p_machine_id, p_shelf_id, p_new_pod_product_id, v_cap);
  IF v_n_spread = 0 OR v_spread_total = 0 THEN
    RAISE EXCEPTION 'swap_shelf_pod: new pod % has no WH-available mapped variants to fill capacity % on shelf %',
      p_new_pod_product_id, v_cap, v_shelf_code;
  END IF;

  PERFORM set_config('app.mutation_reason', p_reason, true);

  FOR r IN
    SELECT rd.boonz_product_id, rd.quantity
      FROM public.refill_dispatching rd
     WHERE rd.machine_id = p_machine_id
       AND rd.shelf_id = p_shelf_id
       AND rd.dispatch_date = p_plan_date
       AND rd.include = true
       AND COALESCE(rd.skipped, false) = false
       AND COALESCE(rd.cancelled, false) = false
       AND rd.action IN ('Refill', 'Add New')
       AND COALESCE(rd.quantity, 0) > 0
       AND rd.pod_product_id IS DISTINCT FROM p_new_pod_product_id
  LOOP
    v_removed := v_removed || public.add_dispatch_row(
      p_machine_id, v_shelf_code, r.boonz_product_id, r.quantity, 'Remove',
      p_plan_date, 'unknown', NULL, NULL, COALESCE(v_role, 'system'), p_reason, NULL);
  END LOOP;

  FOR r IN
    SELECT boonz_product_id, qty
      FROM public.spread_pod_qty(p_machine_id, p_shelf_id, p_new_pod_product_id, v_cap)
  LOOP
    v_added := v_added || public.add_dispatch_row(
      p_machine_id, v_shelf_code, r.boonz_product_id, r.qty, 'Add New',
      p_plan_date, 'wh', v_wh, NULL, COALESCE(v_role, 'system'), p_reason, NULL);
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok',
    'shelf_code', v_shelf_code,
    'capacity', v_cap,
    'new_pod_product_id', p_new_pod_product_id,
    'spread_total', v_spread_total,
    'spread_variants', v_n_spread,
    'removed', v_removed,
    'added', v_added,
    'reason', p_reason
  );
END;
$function$;
