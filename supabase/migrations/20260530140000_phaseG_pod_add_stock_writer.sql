-- PROGRAM 30-May punch list Phase 2/3 enabler. Applied to prod 2026-05-30 (Cody-approved).
-- Dara design: add 'add_stock' edit_type to approve_pod_inventory_edit so the
-- HUAWEI-2003 + MC-2004 recounts can increment existing batches and fold
-- multi-batch per (shelf, product) into one active row (sum stock, earliest
-- expiry FEFO), matching the receive_dispatch_line precedent.
--
-- Pod-only: NEVER touches warehouse_inventory (feedback_pod_vs_wh_expiry_scope).
-- Idempotency stance: MINIMAL (approve-once guard on status='pending' makes each
-- edit apply exactly once; recount-level re-run safety is operator discipline +
-- correlation_id per machine).

-- 1) widen edit_type to allow 'add_stock'
ALTER TABLE public.pod_inventory_edits DROP CONSTRAINT pod_inventory_edits_edit_type_check;
ALTER TABLE public.pod_inventory_edits ADD CONSTRAINT pod_inventory_edits_edit_type_check
  CHECK (edit_type = ANY (ARRAY[
    'in_stock','sold','partial_sold','expired','return_to_warehouse','transfer',
    'add_new_product','add_stock'
  ]));

-- 2) add_stock needs the same required fields as add_new_product
ALTER TABLE public.pod_inventory_edits ADD CONSTRAINT pod_inventory_edits_add_stock_required_fields
  CHECK ((edit_type <> 'add_stock')
    OR (requested_expiration_date IS NOT NULL
        AND destination_shelf_id IS NOT NULL
        AND quantity_update IS NOT NULL
        AND quantity_update > 0));

-- 3) extend approve_pod_inventory_edit with the add_stock branch
CREATE OR REPLACE FUNCTION public.approve_pod_inventory_edit(p_edit_id uuid, p_approver_id uuid DEFAULT NULL::uuid, p_decision_note text DEFAULT NULL::text, p_expiry_override_accepted boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id              uuid;
  v_caller_role          text;
  v_edit                 public.pod_inventory_edits%ROWTYPE;
  v_pod                  public.pod_inventory%ROWTYPE;
  v_shelf_code           text;
  v_new_pod_inventory_id uuid;
  v_batch_id             text;
  v_new_stock            numeric;
  v_new_est              numeric;
  v_pod_status_after     text;
  v_wh_dest              uuid;
  v_existing_wh_id       uuid;
  v_wh_inventory_id_credited uuid;
  v_conflict_product_id  uuid;
  v_conflict_product     text;
  v_open_session_id      uuid;
  v_supported_types      text[] := ARRAY['expired','sold','partial_sold','return_to_warehouse','add_new_product','add_stock'];
BEGIN
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: no caller identity'; END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;
  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: edit % not found', p_edit_id; END IF;
  IF v_edit.status <> 'pending' THEN RAISE EXCEPTION 'approve_pod_inventory_edit: edit % is %, not pending', p_edit_id, v_edit.status; END IF;
  IF NOT (v_edit.edit_type = ANY(v_supported_types)) THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: edit_type % not supported (supported: %)', v_edit.edit_type, v_supported_types;
  END IF;
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'approve_pod_inventory_edit', true);
  PERFORM set_config('app.mutation_reason', format('pod_edit_approval edit_id=%s type=%s by=%s', p_edit_id, v_edit.edit_type, v_user_id), true);
  -- add_new_product and add_stock create/merge a row; all other types need an existing pod_inventory_id
  IF v_edit.edit_type NOT IN ('add_new_product','add_stock') THEN
    IF v_edit.pod_inventory_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: edit % type=% has no pod_inventory_id', p_edit_id, v_edit.edit_type; END IF;
    SELECT * INTO v_pod FROM public.pod_inventory WHERE pod_inventory_id = v_edit.pod_inventory_id FOR UPDATE;
    IF v_pod.pod_inventory_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: pod_inventory % not found', v_edit.pod_inventory_id; END IF;
  END IF;
  IF v_edit.edit_type = 'expired' THEN
    UPDATE public.pod_inventory SET current_stock=0, estimated_remaining=0, status='Inactive',
           removal_reason=format('expired_validated_via_edit_%s', p_edit_id), last_decremented_at=now()
     WHERE pod_inventory_id=v_pod.pod_inventory_id;
    v_pod_status_after := 'Inactive';
  ELSIF v_edit.edit_type = 'sold' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN RAISE EXCEPTION 'approve_pod_inventory_edit: sold edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update; END IF;
    v_new_stock := GREATEST(0, COALESCE(v_pod.current_stock, 0) - v_edit.quantity_update);
    v_new_est   := GREATEST(0, COALESCE(v_pod.estimated_remaining, 0) - v_edit.quantity_update);
    IF v_new_stock <= 0 AND v_new_est <= 0 THEN
      UPDATE public.pod_inventory SET current_stock=0, estimated_remaining=0, status='Inactive',
             removal_reason=format('sold_drained_via_edit_%s', p_edit_id), last_decremented_at=now()
       WHERE pod_inventory_id=v_pod.pod_inventory_id;
      v_pod_status_after := 'Inactive';
    ELSE
      UPDATE public.pod_inventory SET current_stock=v_new_stock, estimated_remaining=v_new_est, last_decremented_at=now()
       WHERE pod_inventory_id=v_pod.pod_inventory_id;
      v_pod_status_after := v_pod.status;
    END IF;
  ELSIF v_edit.edit_type = 'partial_sold' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN RAISE EXCEPTION 'approve_pod_inventory_edit: partial_sold edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update; END IF;
    UPDATE public.pod_inventory SET current_stock=GREATEST(0, COALESCE(current_stock,0) - v_edit.quantity_update),
           estimated_remaining=GREATEST(0, COALESCE(estimated_remaining,0) - v_edit.quantity_update), last_decremented_at=now()
     WHERE pod_inventory_id=v_pod.pod_inventory_id;
    v_pod_status_after := v_pod.status;
  ELSIF v_edit.edit_type = 'return_to_warehouse' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN RAISE EXCEPTION 'approve_pod_inventory_edit: return_to_warehouse edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update; END IF;
    SELECT primary_warehouse_id INTO v_wh_dest FROM public.machines WHERE machine_id=v_edit.machine_id;
    IF v_wh_dest IS NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: machine % has no primary_warehouse_id configured; ops must set it before approving return_to_warehouse', v_edit.machine_id;
    END IF;
    SELECT wh_inventory_id INTO v_existing_wh_id FROM public.warehouse_inventory
     WHERE warehouse_id=v_wh_dest AND boonz_product_id=v_pod.boonz_product_id
       AND COALESCE(expiration_date, DATE '1970-01-01') = COALESCE(v_pod.expiration_date, DATE '1970-01-01')
     LIMIT 1;
    IF v_existing_wh_id IS NOT NULL THEN
      UPDATE public.warehouse_inventory SET warehouse_stock=COALESCE(warehouse_stock,0) + v_edit.quantity_update
       WHERE wh_inventory_id=v_existing_wh_id;
      v_wh_inventory_id_credited := v_existing_wh_id;
    ELSE
      INSERT INTO public.warehouse_inventory (warehouse_id, boonz_product_id, snapshot_date, warehouse_stock, expiration_date, batch_id, status, provenance_reason)
      VALUES (v_wh_dest, v_pod.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_pod.expiration_date, format('POD_RETURN-%s', p_edit_id), 'Inactive', format('pod_return_via_edit_%s', p_edit_id))
      RETURNING wh_inventory_id INTO v_wh_inventory_id_credited;
    END IF;
    UPDATE public.pod_inventory SET current_stock=0, estimated_remaining=0, status='Inactive',
           removal_reason=format('returned_to_warehouse_via_edit_%s', p_edit_id), last_decremented_at=now()
     WHERE pod_inventory_id=v_pod.pod_inventory_id;
    v_pod_status_after := 'Inactive';
  ELSIF v_edit.edit_type = 'add_new_product' THEN
    SELECT pi.boonz_product_id, bp.boonz_product_name INTO v_conflict_product_id, v_conflict_product
      FROM public.pod_inventory pi JOIN public.boonz_products bp ON bp.product_id=pi.boonz_product_id
      WHERE pi.shelf_id=v_edit.destination_shelf_id AND pi.status='Active' LIMIT 1;
    IF v_conflict_product_id IS NOT NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: shelf now in use by %. Reject or escalate.', v_conflict_product;
    END IF;
    IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: expiry % is now in the past; set p_expiry_override_accepted=true to approve anyway', v_edit.requested_expiration_date;
    END IF;
    SELECT shelf_code INTO v_shelf_code FROM public.shelf_configurations WHERE shelf_id=v_edit.destination_shelf_id;
    v_batch_id := format('POD_ADD-%s', p_edit_id);
    BEGIN
      INSERT INTO public.pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, batch_id, status, snapshot_at)
      VALUES (v_edit.machine_id, v_edit.destination_shelf_id, v_edit.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_edit.requested_expiration_date, v_batch_id, 'Active', now())
      RETURNING pod_inventory_id INTO v_new_pod_inventory_id;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: shelf raced into use by another Active row between re-validation and INSERT';
    END;
    v_pod_status_after := 'Active';
  ELSIF v_edit.edit_type = 'add_stock' THEN
    -- past-expiry guard (mirror add_new_product)
    IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: expiry % is in the past; pass p_expiry_override_accepted=true', v_edit.requested_expiration_date;
    END IF;
    -- merge key (machine, shelf, product) — matches idx_pod_inv_active_shelf, NOT shelf-only
    SELECT * INTO v_pod FROM public.pod_inventory
     WHERE machine_id=v_edit.machine_id
       AND shelf_id=v_edit.destination_shelf_id
       AND boonz_product_id=v_edit.boonz_product_id
       AND status='Active'
     FOR UPDATE;
    IF v_pod.pod_inventory_id IS NOT NULL THEN
      UPDATE public.pod_inventory
         SET current_stock       = COALESCE(current_stock,0)       + v_edit.quantity_update,
             estimated_remaining = COALESCE(estimated_remaining,0) + v_edit.quantity_update,
             expiration_date     = LEAST(expiration_date, v_edit.requested_expiration_date),
             snapshot_at         = now()
       WHERE pod_inventory_id = v_pod.pod_inventory_id;
      v_new_pod_inventory_id := v_pod.pod_inventory_id;
    ELSE
      v_batch_id := format('POD_ADD-%s', p_edit_id);
      INSERT INTO public.pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at)
      VALUES (v_edit.machine_id, v_edit.destination_shelf_id, v_edit.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_edit.quantity_update, v_edit.requested_expiration_date, v_batch_id, 'Active', now())
      RETURNING pod_inventory_id INTO v_new_pod_inventory_id;
    END IF;
    v_pod_status_after := 'Active';
  END IF;
  UPDATE public.pod_inventory_edits
  SET status='approved', reviewed_by=v_user_id, reviewed_at=now(),
      pod_inventory_id=COALESCE(pod_inventory_id, v_new_pod_inventory_id),
      notes=CASE WHEN p_decision_note IS NULL OR length(trim(p_decision_note))=0 THEN notes
                 ELSE COALESCE(notes||E'\n[approval] ','[approval] ') || trim(p_decision_note) END
  WHERE edit_id=p_edit_id;
  SELECT session_id INTO v_open_session_id FROM public.inventory_control_session WHERE started_by=v_user_id AND status='open' LIMIT 1;
  IF v_open_session_id IS NOT NULL THEN
    INSERT INTO public.inventory_control_attempt (session_id, attempted_by, target_path, pod_inventory_id, edit_id, boonz_product_id,
      field_changed, old_value, new_value, rpc_called, rpc_response, result, client_correlation_id, reason)
    VALUES (v_open_session_id, v_user_id, 'pod_by_id', COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id), p_edit_id,
      COALESCE(v_pod.boonz_product_id, v_edit.boonz_product_id), 'pod_add_approved',
      CASE WHEN v_edit.edit_type IN ('add_new_product','add_stock') THEN NULL
           ELSE jsonb_build_object('status', v_pod.status, 'current_stock', v_pod.current_stock, 'estimated_remaining', v_pod.estimated_remaining) END,
      jsonb_build_object('status', v_pod_status_after, 'edit_type', v_edit.edit_type),
      'approve_pod_inventory_edit',
      jsonb_build_object('edit_id', p_edit_id, 'edit_type', v_edit.edit_type,
        'pod_inventory_id', COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id),
        'wh_inventory_id_credited', v_wh_inventory_id_credited),
      'success', gen_random_uuid(),
      COALESCE(NULLIF(trim(COALESCE(p_decision_note,'')), ''), 'pod_edit_approval'));
  END IF;
  RETURN jsonb_build_object(
    'result','success','edit_id',p_edit_id,'edit_type',v_edit.edit_type,
    'pod_inventory_id',COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id),
    'pod_status_after',v_pod_status_after,'wh_inventory_id_credited',v_wh_inventory_id_credited,
    'session_id',v_open_session_id,'batch_id',v_batch_id);
END;
$function$;
