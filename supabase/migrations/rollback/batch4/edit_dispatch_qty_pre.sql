-- ROLLBACK PRE-IMAGE (Batch 4 / RC-07) — VERBATIM live body captured 2026-07-18 from eizcexopcuoycuosittm
-- object: edit_dispatch_qty(uuid,numeric,text,text,text)
-- md5(pg_get_functiondef) = e9f99a0dd72c6504539acf186d542748
-- restore via: CREATE OR REPLACE (same signature)
CREATE OR REPLACE FUNCTION public.edit_dispatch_qty(p_dispatch_id uuid, p_new_qty numeric, p_edit_role text, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row    refill_dispatching%ROWTYPE;
  v_role   text;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','edit_dispatch_qty',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: edit_dispatch_qty requires warehouse / operator_admin / superadmin / manager';
  END IF;

  IF p_new_qty IS NULL OR p_new_qty < 0 THEN RAISE EXCEPTION 'invalid p_new_qty'; END IF;
  IF p_edit_role NOT IN ('driver','warehouse_manager','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'invalid p_edit_role';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch % not found', p_dispatch_id; END IF;
  IF v_row.item_added THEN
    RAISE EXCEPTION 'dispatch % already item_added — edit blocked', p_dispatch_id;
  END IF;

  v_before := jsonb_build_object('quantity', v_row.quantity);

  UPDATE public.refill_dispatching
  SET quantity            = p_new_qty,
      original_quantity   = COALESCE(original_quantity, v_row.quantity),
      edit_count          = edit_count + 1,
      last_edited_by      = auth.uid(),
      last_edited_by_role = p_edit_role,
      last_edited_at      = now()
  WHERE dispatch_id = p_dispatch_id;

  v_after := jsonb_build_object('quantity', p_new_qty);

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, auth.uid(), p_edit_role, 'qty', v_before, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'edit_kind','qty',
                            'before', v_before, 'after', v_after);
END $function$

