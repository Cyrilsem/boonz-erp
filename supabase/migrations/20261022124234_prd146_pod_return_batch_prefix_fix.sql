-- PRD-146 hotfix: warehouse batch_id vocabulary on pod returns (and three sibling writers).
--
-- Bug: trg_enforce_warehouse_batch_id_vocabulary (BEFORE INSERT OR UPDATE on warehouse_inventory) only accepts
-- batch_id prefixes PO-, REMOVE-, RETURNED-, RETURN-, WM-, VOXSOURCE-, TRANSFER-, RECOUNT-, ADHOC-.
-- approve_pod_inventory_edit, edit_type 'return_to_warehouse', when no warehouse lot exists for the same
-- warehouse + product + expiry, INSERTed a new lot with batch_id 'POD_RETURN-<edit_id>' and status 'Inactive'.
-- The trigger raised, the approval rolled back and the edit stayed pending (field report 22 Oct: Sun Blast Orange,
-- VOXMCC-1011-0101-B0, 2 pcs).
--
-- Fix 1 (approve_pod_inventory_edit, re-created in full; only the INSERT values change):
--   batch_id 'RETURN-POD-<edit_id>', status 'Active'. Active matches the other branch of the same IF, which credits
--   an existing lot; a return the warehouse has just approved is pickable stock.
--
-- Sweep of pg_proc for other warehouse_inventory INSERTs with a non-vocabulary batch_id literal found three more,
-- each of which raises the same way on its "no matching lot" path. Each gets a single-literal swap below, done
-- against the live body with an exactly-once anchor guard so nothing else in those functions moves:
--   apply_inventory_correction  'CORRECTION-%s'   -> 'RECOUNT-CORRECTION-%s'   (inventory page corrections)
--   record_actual_refill        'REFILL-EVENT-%s' -> 'RETURN-REFILL-EVENT-%s'  (wh_receive / wh_return credit)
--   log_manual_refill           'NEW-PURCHASE-%s' -> 'PO-NEW-PURCHASE-%s'      (WH lot only; the pod_inventory
--                                                                               NEW-PURCHASE batch is untouched)
-- Not changed: POD_ADD- and DISPATCH- (pod_inventory, not warehouse_inventory).

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
    -- [RC-05 EDIT] declare provenance for the WH credit
    PERFORM set_config('app.provenance_reason', 'm2m_return', true);
    PERFORM set_config('app.source_event_id',   p_edit_id::text, true);
    SELECT wh_inventory_id INTO v_existing_wh_id FROM public.warehouse_inventory
     WHERE warehouse_id=v_wh_dest AND boonz_product_id=v_pod.boonz_product_id
       AND COALESCE(expiration_date, DATE '1970-01-01') = COALESCE(v_pod.expiration_date, DATE '1970-01-01')
     LIMIT 1;
    IF v_existing_wh_id IS NOT NULL THEN
      UPDATE public.warehouse_inventory SET warehouse_stock=COALESCE(warehouse_stock,0) + v_edit.quantity_update
       WHERE wh_inventory_id=v_existing_wh_id;
      v_wh_inventory_id_credited := v_existing_wh_id;
    ELSE
      -- [RC-05 EDIT] removed enum-violating explicit provenance literal
      -- [PRD-146] RETURN- prefix (batch_id vocabulary) and Active (approved return is pickable stock)
      INSERT INTO public.warehouse_inventory (warehouse_id, boonz_product_id, snapshot_date, warehouse_stock, expiration_date, batch_id, status)
      VALUES (v_wh_dest, v_pod.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_pod.expiration_date, format('RETURN-POD-%s', p_edit_id), 'Active')
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
    IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: expiry % is in the past; pass p_expiry_override_accepted=true', v_edit.requested_expiration_date;
    END IF;
    SELECT * INTO v_pod FROM public.pod_inventory
     WHERE machine_id=v_edit.machine_id
       AND shelf_id=v_edit.destination_shelf_id
       AND boonz_product_id=v_edit.boonz_product_id
       AND status='Active'
       AND ((expiration_date = v_edit.requested_expiration_date) OR (expiration_date IS NULL AND v_edit.requested_expiration_date IS NULL))
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

-- Sibling writers: swap one literal each in the live body. Each anchor must occur exactly once (fails loudly if the
-- body drifted), and the re-created function keeps its signature, SECURITY DEFINER, config, owner and grants.
DO $m$
DECLARE
  r record; v_def text; v_new text; v_n int;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.apply_inventory_correction(uuid,uuid,uuid,date,numeric,text,uuid)'::regprocedure,
       $a$format('CORRECTION-%s', CURRENT_DATE)$a$,
       $a$format('RECOUNT-CORRECTION-%s', CURRENT_DATE)$a$),
      ((SELECT oid FROM pg_proc WHERE proname = 'record_actual_refill' AND pronamespace = 'public'::regnamespace)::regprocedure,
       $a$format('REFILL-EVENT-%s', to_char(p_plan_date,'YYYY-MM-DD'))$a$,
       $a$format('RETURN-REFILL-EVENT-%s', to_char(p_plan_date,'YYYY-MM-DD'))$a$),
      ((SELECT oid FROM pg_proc WHERE proname = 'log_manual_refill' AND pronamespace = 'public'::regnamespace)::regprocedure,
       $a$'Active', format('NEW-PURCHASE-%s', p_refill_date), CURRENT_DATE, p_source_warehouse_id)$a$,
       $a$'Active', format('PO-NEW-PURCHASE-%s', p_refill_date), CURRENT_DATE, p_source_warehouse_id)$a$)
    ) t(fn, old_s, new_s)
  LOOP
    v_def := pg_get_functiondef(r.fn);
    v_n := (length(v_def) - length(replace(v_def, r.old_s, ''))) / length(r.old_s);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'PRD-146: anchor for % found % times, expected 1', r.fn, v_n;
    END IF;
    v_new := replace(v_def, r.old_s, r.new_s);
    IF v_new = v_def THEN
      RAISE EXCEPTION 'PRD-146: replace on % was a no-op', r.fn;
    END IF;
    EXECUTE v_new;
  END LOOP;
END
$m$;

-- Re-assert grants on the fully re-created function (CREATE OR REPLACE keeps them; this is belt and braces).
REVOKE ALL ON FUNCTION public.approve_pod_inventory_edit(uuid, uuid, text, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_pod_inventory_edit(uuid, uuid, text, boolean) TO authenticated, service_role;
