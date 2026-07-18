-- ROLLBACK: restore live pre-Batch-2 body of reject_return
-- captured 2026-07-18 from eizcexopcuoycuosittm
-- md5(pg_get_functiondef) = 1886d487f2bd9d36384fbe064f6a7334
CREATE OR REPLACE FUNCTION public.reject_return(p_wh_inventory_id uuid, p_approver_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_role text; v_uid uuid; v_before jsonb; v_after jsonb; v_row warehouse_inventory%ROWTYPE; v_inact jsonb; v_status_now text;
BEGIN
  v_uid := COALESCE(p_approver_id, auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'reject_return: forbidden for role % (inventory-manager only)', COALESCE(v_role,'unknown'); END IF;
  IF COALESCE(p_reason,'') = '' OR length(trim(p_reason)) < 4 THEN RAISE EXCEPTION 'reject_return: p_reason required (min 4 chars)'; END IF;
  SELECT * INTO v_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'reject_return: wh_inventory_id % not found', p_wh_inventory_id; END IF;
  v_before := to_jsonb(v_row);
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','reject_return',true);
  PERFORM set_config('app.mutation_reason', format('reject_return by %s: %s', v_uid, p_reason), true);
  UPDATE public.warehouse_inventory SET warehouse_stock = 0, disposal_reason = 'Waste' WHERE wh_inventory_id = p_wh_inventory_id;
  SELECT status INTO v_status_now FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;
  IF v_status_now = 'Active' THEN
    v_inact := public.inactivate_warehouse_row(p_wh_inventory_id, 'reject_return: '||p_reason, v_uid);
  ELSE
    v_inact := jsonb_build_object('status','already_'||lower(v_status_now)||'_skipped_inactivate');
  END IF;
  SELECT to_jsonb(w.*) INTO v_after FROM public.warehouse_inventory w WHERE wh_inventory_id = p_wh_inventory_id;
  INSERT INTO public.return_approval_log(wh_inventory_id, action, approver_id, approver_role, note, before_row, after_row)
  VALUES (p_wh_inventory_id, 'reject', v_uid, v_role, p_reason, v_before, v_after);
  RETURN jsonb_build_object('status','rejected','wh_inventory_id',p_wh_inventory_id,'written_off',true,'inactivate',v_inact);
END $function$
