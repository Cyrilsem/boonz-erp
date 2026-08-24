-- PRD-116b: driver multi-variant split children lost the parent Remove leg's transfer tagging
-- (source_kind fell to 'unknown', source_machine_id NULL, is_m2m/is_internal_move false), so
-- in-machine moves surfaced in the warehouse returns queue (PRD-113b root cause, MPMCC 08-20).
-- Fix: the child row inherits source_kind / source_machine_id / is_m2m / is_internal_move /
-- from_warehouse_id from the most recent matching parent Remove leg on the same
-- machine+shelf+pod_product+date. Role/validation/audit surface unchanged. Cody OK 1,4,8,12.
-- Applied to prod via MCP 2026-08-23 21:57 UTC.
CREATE OR REPLACE FUNCTION public.insert_driver_remove_line(p_machine_id uuid, p_boonz_product_id uuid, p_pod_product_id uuid, p_shelf_id uuid, p_quantity numeric, p_expiry_date date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_caller_id uuid := auth.uid(); v_caller_role text; v_dispatch_id uuid;
        v_parent refill_dispatching%ROWTYPE;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'insert_driver_remove_line: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity required (qty > 0)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'insert_driver_remove_line', true);

  -- PRD-116b: the parent leg this split refines. Matching is deliberately narrow:
  -- same machine, shelf, pod product, today, an included non-cancelled Remove.
  SELECT * INTO v_parent FROM refill_dispatching rd
   WHERE rd.machine_id = p_machine_id
     AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
     AND rd.pod_product_id = p_pod_product_id
     AND rd.dispatch_date = CURRENT_DATE
     AND rd.action = 'Remove' AND rd.include
     AND COALESCE(rd.cancelled, false) = false
   ORDER BY rd.created_at DESC LIMIT 1;

  INSERT INTO refill_dispatching
    (machine_id, boonz_product_id, pod_product_id, shelf_id,
     dispatch_date, action, quantity, filled_quantity, expiry_date,
     packed, picked_up, dispatched, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, is_internal_move, from_warehouse_id)
  VALUES
    (p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
     CURRENT_DATE, 'Remove', p_quantity, 0, p_expiry_date,
     true, true, false, false, false, true,
     format('[DRIVER-INSERT] %s', p_reason),
     COALESCE(v_parent.source_kind, 'unknown'), v_parent.source_machine_id,
     COALESCE(v_parent.is_m2m, false), COALESCE(v_parent.is_internal_move, false),
     v_parent.from_warehouse_id)
  RETURNING dispatch_id INTO v_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', v_dispatch_id,
    'machine_id', p_machine_id, 'qty', p_quantity, 'reason', p_reason,
    'inherited_from_parent', v_parent.dispatch_id);
END $function$;
