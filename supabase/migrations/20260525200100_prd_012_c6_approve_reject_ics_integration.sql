-- PRD-012 C.6: integrate inventory_control_session attribution into the
-- approve_pod_inventory_add and reject_pod_inventory_add RPCs. When the
-- caller has an open inventory_control_session, the canonical writer also
-- INSERTs a row in inventory_control_attempt with target_path='pod_by_id'
-- (approve) or 'pod_by_edit_id' (reject), populating both pod_inventory_id
-- (when applicable) and edit_id per Cody's revision.
-- Schema prerequisite: 20260525200000_prd_012_c6_extend_inventory_control_attempt.sql

CREATE OR REPLACE FUNCTION public.approve_pod_inventory_add(
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
  v_conflict_product_id  uuid;
  v_conflict_product     text;
  v_shelf_code           text;
  v_new_pod_inventory_id uuid;
  v_batch_id             text;
  v_open_session_id      uuid;
BEGIN
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_add: no caller identity'; END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;
  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_add: edit % not found', p_edit_id; END IF;
  IF v_edit.edit_type <> 'add_new_product' THEN RAISE EXCEPTION 'approve_pod_inventory_add: edit % is type %, not add_new_product', p_edit_id, v_edit.edit_type; END IF;
  IF v_edit.status <> 'pending' THEN RAISE EXCEPTION 'approve_pod_inventory_add: edit % is %, not pending (case 14)', p_edit_id, v_edit.status; END IF;
  SELECT pi.boonz_product_id, bp.boonz_product_name INTO v_conflict_product_id, v_conflict_product
    FROM public.pod_inventory pi JOIN public.boonz_products bp ON bp.product_id = pi.boonz_product_id
    WHERE pi.shelf_id = v_edit.destination_shelf_id AND pi.status = 'Active' LIMIT 1;
  IF v_conflict_product_id IS NOT NULL THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: shelf now in use by %. Reject or escalate.', v_conflict_product;
  END IF;
  IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: expiry % is now in the past; set p_expiry_override_accepted=true to approve anyway', v_edit.requested_expiration_date;
  END IF;
  SELECT shelf_code INTO v_shelf_code FROM public.shelf_configurations WHERE shelf_id = v_edit.destination_shelf_id;
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'approve_pod_inventory_add', true);
  PERFORM set_config('app.mutation_reason', format('pod_add_approval edit_id=%s by=%s', p_edit_id, v_user_id), true);
  v_batch_id := format('POD_ADD-%s', p_edit_id);
  BEGIN
    INSERT INTO public.pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, batch_id, status, snapshot_at)
    VALUES (v_edit.machine_id, v_edit.destination_shelf_id, v_edit.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_edit.requested_expiration_date, v_batch_id, 'Active', now())
    RETURNING pod_inventory_id INTO v_new_pod_inventory_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: shelf raced into use by another Active row between re-validation and INSERT';
  END;
  UPDATE public.pod_inventory_edits
  SET status = 'approved', reviewed_by = v_user_id, reviewed_at = now(), pod_inventory_id = v_new_pod_inventory_id,
      notes = CASE WHEN p_decision_note IS NULL OR length(trim(p_decision_note)) = 0 THEN notes
                   ELSE COALESCE(notes || E'\n[approval] ', '[approval] ') || trim(p_decision_note) END
  WHERE edit_id = p_edit_id;

  -- PRD-012 C.6: session attribution.
  SELECT session_id INTO v_open_session_id
  FROM public.inventory_control_session
  WHERE started_by = v_user_id AND status = 'open'
  LIMIT 1;
  IF v_open_session_id IS NOT NULL THEN
    INSERT INTO public.inventory_control_attempt (
      session_id, attempted_by,
      target_path, pod_inventory_id, edit_id, boonz_product_id,
      field_changed, old_value, new_value,
      rpc_called, rpc_response, result,
      client_correlation_id, reason
    ) VALUES (
      v_open_session_id, v_user_id,
      'pod_by_id', v_new_pod_inventory_id, p_edit_id, v_edit.boonz_product_id,
      'pod_add_approved',
      NULL,
      jsonb_build_object('status','Active','current_stock', v_edit.quantity_update, 'batch_id', v_batch_id),
      'approve_pod_inventory_add',
      jsonb_build_object('edit_id', p_edit_id, 'pod_inventory_id', v_new_pod_inventory_id),
      'success',
      gen_random_uuid(),
      COALESCE(NULLIF(trim(COALESCE(p_decision_note,'')), ''), 'pod_add_approval')
    );
  END IF;

  RETURN jsonb_build_object('result','success','edit_id',p_edit_id,'pod_inventory_id',v_new_pod_inventory_id,'batch_id',v_batch_id,
    'machine_id',v_edit.machine_id,'shelf_id',v_edit.destination_shelf_id,'shelf_code',v_shelf_code,
    'boonz_product_id',v_edit.boonz_product_id,'quantity',v_edit.quantity_update,'expiration_date',v_edit.requested_expiration_date,
    'expiry_overridden',(v_edit.requested_expiration_date <= CURRENT_DATE),
    'session_id', v_open_session_id);
END;
$function$;


CREATE OR REPLACE FUNCTION public.reject_pod_inventory_add(
  p_edit_id        uuid,
  p_decision_note  text,
  p_approver_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id      uuid;
  v_caller_role  text;
  v_edit         public.pod_inventory_edits%ROWTYPE;
  v_trimmed_note text;
  v_open_session_id uuid;
BEGIN
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'reject_pod_inventory_add: no caller identity'; END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'reject_pod_inventory_add: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;
  v_trimmed_note := trim(COALESCE(p_decision_note, ''));
  IF length(v_trimmed_note) < 10 THEN RAISE EXCEPTION 'reject_pod_inventory_add: decision_note required (min 10 chars, got %)', length(v_trimmed_note); END IF;
  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN RAISE EXCEPTION 'reject_pod_inventory_add: edit % not found', p_edit_id; END IF;
  IF v_edit.edit_type <> 'add_new_product' THEN RAISE EXCEPTION 'reject_pod_inventory_add: edit % is type %, not add_new_product', p_edit_id, v_edit.edit_type; END IF;
  IF v_edit.status <> 'pending' THEN RAISE EXCEPTION 'reject_pod_inventory_add: edit % is %, not pending', p_edit_id, v_edit.status; END IF;
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'reject_pod_inventory_add', true);
  PERFORM set_config('app.mutation_reason', format('pod_add_rejection edit_id=%s by=%s', p_edit_id, v_user_id), true);
  UPDATE public.pod_inventory_edits
  SET status = 'rejected', reviewed_by = v_user_id, reviewed_at = now(),
      notes = COALESCE(notes || E'\n[rejection] ', '[rejection] ') || v_trimmed_note
  WHERE edit_id = p_edit_id;

  -- PRD-012 C.6: session attribution. target_path='pod_by_edit_id' because no
  -- pod_inventory row is created on reject; the target is the edit row itself.
  SELECT session_id INTO v_open_session_id
  FROM public.inventory_control_session
  WHERE started_by = v_user_id AND status = 'open'
  LIMIT 1;
  IF v_open_session_id IS NOT NULL THEN
    INSERT INTO public.inventory_control_attempt (
      session_id, attempted_by,
      target_path, pod_inventory_id, edit_id, boonz_product_id,
      field_changed, old_value, new_value,
      rpc_called, rpc_response, result,
      client_correlation_id, reason
    ) VALUES (
      v_open_session_id, v_user_id,
      'pod_by_edit_id', NULL, p_edit_id, v_edit.boonz_product_id,
      'pod_add_rejected',
      jsonb_build_object('status','pending'),
      jsonb_build_object('status','rejected'),
      'reject_pod_inventory_add',
      jsonb_build_object('edit_id', p_edit_id),
      'success',
      gen_random_uuid(),
      v_trimmed_note
    );
  END IF;

  RETURN jsonb_build_object('result','success','edit_id',p_edit_id,'machine_id',v_edit.machine_id,'shelf_id',v_edit.destination_shelf_id,
    'boonz_product_id',v_edit.boonz_product_id,'decision_note',v_trimmed_note,'reviewed_by',v_user_id,'reviewed_at',now(),
    'session_id', v_open_session_id);
END;
$function$;
