-- PRD-012 A.4: reject_pod_inventory_add
-- Manager-callable SECURITY DEFINER. Locks edit row, requires non-empty
-- decision_note (>= 10 chars, case 12), UPDATEs status to rejected.
-- Cody G2 verdict: approve with revisions applied.
-- See: docs/prds/inventory/prd_012_driver_pod_add_workflow.md section 6.A.4

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
BEGIN
  -- 0. Resolve caller and check role (manager-only).
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'reject_pod_inventory_add: no caller identity';
  END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL
     OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'reject_pod_inventory_add: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  -- 1. Decision note required, min 10 chars (case 12).
  v_trimmed_note := trim(COALESCE(p_decision_note, ''));
  IF length(v_trimmed_note) < 10 THEN
    RAISE EXCEPTION 'reject_pod_inventory_add: decision_note required (min 10 chars, got %)', length(v_trimmed_note);
  END IF;

  -- 2. Lock the edit row.
  SELECT * INTO v_edit
  FROM public.pod_inventory_edits
  WHERE edit_id = p_edit_id
  FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN
    RAISE EXCEPTION 'reject_pod_inventory_add: edit % not found', p_edit_id;
  END IF;
  IF v_edit.edit_type <> 'add_new_product' THEN
    RAISE EXCEPTION 'reject_pod_inventory_add: edit % is type %, not add_new_product', p_edit_id, v_edit.edit_type;
  END IF;
  IF v_edit.status <> 'pending' THEN
    RAISE EXCEPTION 'reject_pod_inventory_add: edit % is %, not pending', p_edit_id, v_edit.status;
  END IF;

  -- 3. Canonical writer markers (Article 4).
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'reject_pod_inventory_add', true);
  PERFORM set_config('app.mutation_reason', format('pod_add_rejection edit_id=%s by=%s', p_edit_id, v_user_id), true);

  -- 4. Close the edit row with the required note appended.
  UPDATE public.pod_inventory_edits
  SET status      = 'rejected',
      reviewed_by = v_user_id,
      reviewed_at = now(),
      notes       = COALESCE(notes || E'\n[rejection] ', '[rejection] ') || v_trimmed_note
  WHERE edit_id = p_edit_id;

  RETURN jsonb_build_object(
    'result',          'success',
    'edit_id',         p_edit_id,
    'machine_id',      v_edit.machine_id,
    'shelf_id',        v_edit.destination_shelf_id,
    'boonz_product_id', v_edit.boonz_product_id,
    'decision_note',   v_trimmed_note,
    'reviewed_by',     v_user_id,
    'reviewed_at',     now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.reject_pod_inventory_add(uuid,text,uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.reject_pod_inventory_add(uuid,text,uuid) TO authenticated;

COMMENT ON FUNCTION public.reject_pod_inventory_add(uuid,text,uuid) IS
  'PRD-012 A.4 canonical writer. Locks edit row, requires decision_note minimum 10 chars, UPDATEs status to rejected. Manager-only. Returns jsonb with the edit metadata and rejection note.';
