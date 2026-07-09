-- PRD-099 (Cody PASS): approve_return mints an approval event id so the dispatch_return flip
-- satisfies wh_provenance_event_required for manual/legacy rows (NULL source_event_id).
-- DEVIATION from the PRD's literal code (evidence-backed, per Cody): the PRD set
-- app.source_event_id=v_event, but set_warehouse_inventory_provenance fires on UPDATE and
-- unconditionally overrides NEW.source_event_id from that GUC -> it would CLOBBER pipeline rows'
-- original event id (violating acceptance). Correct: set the GUC EMPTY so the trigger does not
-- override, and let UPDATE ... COALESCE(source_event_id, v_event) govern. No schema/constraint/data change.
CREATE OR REPLACE FUNCTION public.approve_return(p_wh_inventory_id uuid, p_approver_id uuid, p_note text,
                                                 p_corrected_expiry date DEFAULT NULL, p_corrected_qty numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_role text; v_uid uuid; v_before jsonb; v_after jsonb; v_row warehouse_inventory%ROWTYPE;
        v_event uuid := gen_random_uuid();
BEGIN
  v_uid := COALESCE(p_approver_id, auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'approve_return: forbidden for role % (inventory-manager only)', COALESCE(v_role,'unknown'); END IF;
  IF COALESCE(p_note,'') = '' OR length(trim(p_note)) < 4 THEN RAISE EXCEPTION 'approve_return: p_note required (min 4 chars)'; END IF;
  SELECT * INTO v_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approve_return: wh_inventory_id % not found', p_wh_inventory_id; END IF;
  IF v_row.provenance_reason <> 'dispatch_return_unverified' AND v_row.provenance_reason <> 'unknown_pre_migration' THEN
    RAISE EXCEPTION 'approve_return: row provenance % is not a pending quarantine', v_row.provenance_reason; END IF;
  v_before := to_jsonb(v_row);
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','approve_return',true);
  PERFORM set_config('app.provenance_reason','dispatch_return',true);
  PERFORM set_config('app.source_event_id','',true);
  PERFORM set_config('app.mutation_reason', format('approve_return by %s: %s', v_uid, p_note), true);
  UPDATE public.warehouse_inventory
     SET provenance_reason = 'dispatch_return',
         source_event_id = COALESCE(source_event_id, v_event),
         expiration_date = COALESCE(p_corrected_expiry, expiration_date),
         warehouse_stock = COALESCE(p_corrected_qty, warehouse_stock)
   WHERE wh_inventory_id = p_wh_inventory_id;
  SELECT to_jsonb(w.*) INTO v_after FROM public.warehouse_inventory w WHERE wh_inventory_id = p_wh_inventory_id;
  INSERT INTO public.return_approval_log(wh_inventory_id, action, approver_id, approver_role, note, before_row, after_row)
  VALUES (p_wh_inventory_id, 'approve', v_uid, v_role, p_note, v_before,
          v_after || jsonb_build_object('approval_event_id', v_event));
  RETURN jsonb_build_object('status','approved','wh_inventory_id',p_wh_inventory_id,'now_pickable',true,
                            'approval_event_id',v_event,'corrected_expiry',p_corrected_expiry,'corrected_qty',p_corrected_qty);
END $fn$;
