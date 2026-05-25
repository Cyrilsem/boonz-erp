-- PRD-013 P1.B: unified reject_pod_inventory_edit. Any edit_type. Requires
-- decision_note >= 10 chars. Supersedes PRD-012 reject_pod_inventory_add.

CREATE OR REPLACE FUNCTION public.reject_pod_inventory_edit(
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
  v_user_id        uuid;
  v_caller_role    text;
  v_edit           public.pod_inventory_edits%ROWTYPE;
  v_trimmed_note   text;
  v_open_session_id uuid;
BEGIN
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'reject_pod_inventory_edit: no caller identity';
  END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL
     OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'reject_pod_inventory_edit: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;
  v_trimmed_note := trim(COALESCE(p_decision_note, ''));
  IF length(v_trimmed_note) < 10 THEN
    RAISE EXCEPTION 'reject_pod_inventory_edit: decision_note required (min 10 chars, got %)', length(v_trimmed_note);
  END IF;
  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN
    RAISE EXCEPTION 'reject_pod_inventory_edit: edit % not found', p_edit_id;
  END IF;
  IF v_edit.status <> 'pending' THEN
    RAISE EXCEPTION 'reject_pod_inventory_edit: edit % is %, not pending', p_edit_id, v_edit.status;
  END IF;

  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'reject_pod_inventory_edit', true);
  PERFORM set_config('app.mutation_reason',
    format('pod_edit_rejection edit_id=%s type=%s by=%s', p_edit_id, v_edit.edit_type, v_user_id), true);

  UPDATE public.pod_inventory_edits
  SET status = 'rejected', reviewed_by = v_user_id, reviewed_at = now(),
      notes = COALESCE(notes || E'\n[rejection] ', '[rejection] ') || v_trimmed_note
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
      'pod_by_edit_id', NULL, p_edit_id, v_edit.boonz_product_id,
      'pod_add_rejected',
      jsonb_build_object('status','pending','edit_type', v_edit.edit_type),
      jsonb_build_object('status','rejected'),
      'reject_pod_inventory_edit', jsonb_build_object('edit_id', p_edit_id, 'edit_type', v_edit.edit_type),
      'success', gen_random_uuid(), v_trimmed_note
    );
  END IF;

  RETURN jsonb_build_object(
    'result','success',
    'edit_id', p_edit_id,
    'edit_type', v_edit.edit_type,
    'machine_id', v_edit.machine_id,
    'decision_note', v_trimmed_note,
    'reviewed_by', v_user_id,
    'reviewed_at', now(),
    'session_id', v_open_session_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.reject_pod_inventory_edit(uuid,text,uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.reject_pod_inventory_edit(uuid,text,uuid) TO authenticated;

COMMENT ON FUNCTION public.reject_pod_inventory_edit(uuid,text,uuid) IS
  'PRD-013 P1.B unified canonical rejector for pod_inventory_edits. Any edit_type. Requires decision_note >= 10 chars. Manager roles only. No write to pod_inventory or warehouse_inventory.';
