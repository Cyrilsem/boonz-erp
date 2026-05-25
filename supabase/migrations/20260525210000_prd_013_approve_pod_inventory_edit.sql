-- PRD-013 P1.A: unified approve_pod_inventory_edit. Dispatches by edit_type
-- per PRD §D2. SELECT FOR UPDATE on the edit row + pod row (D6). Sets all
-- three set_config markers. Atomic flip of edit_row + downstream entity in
-- one txn. Manager roles only.
-- Cody verdict: approve with revisions applied (status='Inactive' on WH
-- INSERT per CS sign-off; raise on null primary_warehouse_id; PRD-012
-- approve/reject_pod_inventory_add carry DEPRECATED notice via separate
-- patch).
-- See: docs/prds/inventory/prd_013_pod_inventory_edits_canonical_approval.md §6.A.1

CREATE OR REPLACE FUNCTION public.approve_pod_inventory_edit(
  p_edit_id                  uuid,
  p_approver_id              uuid    DEFAULT NULL,
  p_decision_note            text    DEFAULT NULL,
  p_expiry_override_accepted boolean DEFAULT false
)
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
  v_supported_types      text[] := ARRAY['expired','sold','partial_sold','return_to_warehouse','add_new_product'];
BEGIN
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: no caller identity';
  END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL
     OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: edit % not found', p_edit_id;
  END IF;
  IF v_edit.status <> 'pending' THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: edit % is %, not pending (concurrent approve or already-approved)', p_edit_id, v_edit.status;
  END IF;
  IF NOT (v_edit.edit_type = ANY(v_supported_types)) THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: edit_type % not supported by this RPC (supported: %)', v_edit.edit_type, v_supported_types;
  END IF;

  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'approve_pod_inventory_edit', true);
  PERFORM set_config('app.mutation_reason',
    format('pod_edit_approval edit_id=%s type=%s by=%s', p_edit_id, v_edit.edit_type, v_user_id), true);

  IF v_edit.edit_type <> 'add_new_product' THEN
    IF v_edit.pod_inventory_id IS NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: edit % type=% has no pod_inventory_id', p_edit_id, v_edit.edit_type;
    END IF;
    SELECT * INTO v_pod FROM public.pod_inventory WHERE pod_inventory_id = v_edit.pod_inventory_id FOR UPDATE;
    IF v_pod.pod_inventory_id IS NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: pod_inventory % not found', v_edit.pod_inventory_id;
    END IF;
  END IF;

  IF v_edit.edit_type = 'expired' THEN
    UPDATE public.pod_inventory
       SET current_stock        = 0,
           estimated_remaining  = 0,
           status               = 'Inactive',
           removal_reason       = format('expired_validated_via_edit_%s', p_edit_id),
           last_decremented_at  = now()
     WHERE pod_inventory_id = v_pod.pod_inventory_id;
    v_pod_status_after := 'Inactive';

  ELSIF v_edit.edit_type = 'sold' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: sold edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update;
    END IF;
    v_new_stock := GREATEST(0, COALESCE(v_pod.current_stock, 0) - v_edit.quantity_update);
    v_new_est   := GREATEST(0, COALESCE(v_pod.estimated_remaining, 0) - v_edit.quantity_update);
    IF v_new_stock <= 0 AND v_new_est <= 0 THEN
      UPDATE public.pod_inventory
         SET current_stock = 0, estimated_remaining = 0,
             status = 'Inactive',
             removal_reason = format('sold_drained_via_edit_%s', p_edit_id),
             last_decremented_at = now()
       WHERE pod_inventory_id = v_pod.pod_inventory_id;
      v_pod_status_after := 'Inactive';
    ELSE
      UPDATE public.pod_inventory
         SET current_stock = v_new_stock,
             estimated_remaining = v_new_est,
             last_decremented_at = now()
       WHERE pod_inventory_id = v_pod.pod_inventory_id;
      v_pod_status_after := v_pod.status;
    END IF;

  ELSIF v_edit.edit_type = 'partial_sold' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: partial_sold edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update;
    END IF;
    UPDATE public.pod_inventory
       SET current_stock = GREATEST(0, COALESCE(current_stock, 0) - v_edit.quantity_update),
           estimated_remaining = GREATEST(0, COALESCE(estimated_remaining, 0) - v_edit.quantity_update),
           last_decremented_at = now()
     WHERE pod_inventory_id = v_pod.pod_inventory_id;
    v_pod_status_after := v_pod.status;

  ELSIF v_edit.edit_type = 'return_to_warehouse' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: return_to_warehouse edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update;
    END IF;
    -- CS sign-off at G1: raise when machine has no primary_warehouse_id rather
    -- than silently routing to WH_CENTRAL (surfaces the machine-config bug).
    SELECT primary_warehouse_id INTO v_wh_dest FROM public.machines WHERE machine_id = v_edit.machine_id;
    IF v_wh_dest IS NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: machine % has no primary_warehouse_id configured; ops must set it before approving return_to_warehouse', v_edit.machine_id;
    END IF;
    SELECT wh_inventory_id INTO v_existing_wh_id
    FROM public.warehouse_inventory
    WHERE warehouse_id = v_wh_dest
      AND boonz_product_id = v_pod.boonz_product_id
      AND COALESCE(expiration_date, DATE '1970-01-01') = COALESCE(v_pod.expiration_date, DATE '1970-01-01')
    LIMIT 1;
    IF v_existing_wh_id IS NOT NULL THEN
      -- Credit existing WH row: warehouse_stock is updated (NOT status; status
      -- is governed by Amendment 002 propose-then-confirm). Strict Article 6.
      UPDATE public.warehouse_inventory
         SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_edit.quantity_update
       WHERE wh_inventory_id = v_existing_wh_id;
      v_wh_inventory_id_credited := v_existing_wh_id;
    ELSE
      -- CS sign-off at G1: new WH row INSERTed with status='Inactive' so the
      -- warehouse manager must promote via the m2 propose-then-confirm flow
      -- before the returned stock enters live counts. Honors Article 6 spirit.
      INSERT INTO public.warehouse_inventory (
        warehouse_id, boonz_product_id, snapshot_date,
        warehouse_stock, expiration_date, batch_id, status,
        provenance_reason
      ) VALUES (
        v_wh_dest, v_pod.boonz_product_id, CURRENT_DATE,
        v_edit.quantity_update, v_pod.expiration_date, format('POD_RETURN-%s', p_edit_id), 'Inactive',
        format('pod_return_via_edit_%s', p_edit_id)
      )
      RETURNING wh_inventory_id INTO v_wh_inventory_id_credited;
    END IF;
    UPDATE public.pod_inventory
       SET current_stock = 0, estimated_remaining = 0,
           status = 'Inactive',
           removal_reason = format('returned_to_warehouse_via_edit_%s', p_edit_id),
           last_decremented_at = now()
     WHERE pod_inventory_id = v_pod.pod_inventory_id;
    v_pod_status_after := 'Inactive';

  ELSIF v_edit.edit_type = 'add_new_product' THEN
    SELECT pi.boonz_product_id, bp.boonz_product_name
      INTO v_conflict_product_id, v_conflict_product
    FROM public.pod_inventory pi
    JOIN public.boonz_products bp ON bp.product_id = pi.boonz_product_id
    WHERE pi.shelf_id = v_edit.destination_shelf_id AND pi.status = 'Active'
    LIMIT 1;
    IF v_conflict_product_id IS NOT NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: shelf now in use by %. Reject or escalate.', v_conflict_product;
    END IF;
    IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: expiry % is now in the past; set p_expiry_override_accepted=true to approve anyway', v_edit.requested_expiration_date;
    END IF;
    SELECT shelf_code INTO v_shelf_code FROM public.shelf_configurations WHERE shelf_id = v_edit.destination_shelf_id;
    v_batch_id := format('POD_ADD-%s', p_edit_id);
    BEGIN
      INSERT INTO public.pod_inventory (
        machine_id, shelf_id, boonz_product_id,
        snapshot_date, current_stock, expiration_date,
        batch_id, status, snapshot_at
      ) VALUES (
        v_edit.machine_id, v_edit.destination_shelf_id, v_edit.boonz_product_id,
        CURRENT_DATE, v_edit.quantity_update, v_edit.requested_expiration_date,
        v_batch_id, 'Active', now()
      ) RETURNING pod_inventory_id INTO v_new_pod_inventory_id;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: shelf raced into use by another Active row between re-validation and INSERT';
    END;
    v_pod_status_after := 'Active';
  END IF;

  UPDATE public.pod_inventory_edits
  SET status        = 'approved',
      reviewed_by   = v_user_id,
      reviewed_at   = now(),
      pod_inventory_id = COALESCE(pod_inventory_id, v_new_pod_inventory_id),
      notes         = CASE
                        WHEN p_decision_note IS NULL OR length(trim(p_decision_note)) = 0 THEN notes
                        ELSE COALESCE(notes || E'\n[approval] ', '[approval] ') || trim(p_decision_note)
                      END
  WHERE edit_id = p_edit_id;

  SELECT session_id INTO v_open_session_id
  FROM public.inventory_control_session
  WHERE started_by = v_user_id AND status = 'open' LIMIT 1;
  IF v_open_session_id IS NOT NULL THEN
    INSERT INTO public.inventory_control_attempt (
      session_id, attempted_by,
      target_path, pod_inventory_id, edit_id, boonz_product_id,
      field_changed, old_value, new_value,
      rpc_called, rpc_response, result,
      client_correlation_id, reason
    ) VALUES (
      v_open_session_id, v_user_id,
      'pod_by_id', COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id), p_edit_id,
      COALESCE(v_pod.boonz_product_id, v_edit.boonz_product_id),
      'pod_add_approved',
      CASE WHEN v_edit.edit_type = 'add_new_product' THEN NULL
           ELSE jsonb_build_object('status', v_pod.status, 'current_stock', v_pod.current_stock,
                                   'estimated_remaining', v_pod.estimated_remaining) END,
      jsonb_build_object('status', v_pod_status_after, 'edit_type', v_edit.edit_type),
      'approve_pod_inventory_edit',
      jsonb_build_object('edit_id', p_edit_id, 'edit_type', v_edit.edit_type,
                         'pod_inventory_id', COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id),
                         'wh_inventory_id_credited', v_wh_inventory_id_credited),
      'success', gen_random_uuid(),
      COALESCE(NULLIF(trim(COALESCE(p_decision_note,'')), ''), 'pod_edit_approval')
    );
  END IF;

  RETURN jsonb_build_object(
    'result',                   'success',
    'edit_id',                  p_edit_id,
    'edit_type',                v_edit.edit_type,
    'pod_inventory_id',         COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id),
    'pod_status_after',         v_pod_status_after,
    'wh_inventory_id_credited', v_wh_inventory_id_credited,
    'session_id',               v_open_session_id,
    'batch_id',                 v_batch_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.approve_pod_inventory_edit(uuid,uuid,text,boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.approve_pod_inventory_edit(uuid,uuid,text,boolean) TO authenticated;

COMMENT ON FUNCTION public.approve_pod_inventory_edit(uuid,uuid,text,boolean) IS
  'PRD-013 P1.A unified canonical approver for pod_inventory_edits. Dispatches by edit_type (expired, sold, partial_sold, return_to_warehouse, add_new_product). SELECT FOR UPDATE on edit row and pod row. Atomic flip in one txn. Manager roles only. return_to_warehouse INSERTs new WH rows with status=Inactive per Article 6 (manager must promote via propose-then-confirm). PRD-012 approve/reject_pod_inventory_add superseded but kept for 90-day Article 13 deprecation window.';
