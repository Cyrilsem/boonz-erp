-- PRD-012 A.3: approve_pod_inventory_add
-- Manager-callable SECURITY DEFINER. Locks the edit row, re-validates shelf
-- conflict and expiry at approval time, INSERTs pod_inventory row with
-- batch_id = format('POD_ADD-%s', edit_id), UPDATEs edit row to approved.
-- Cody G2 verdict: approve with revisions (unique_violation guard added).
-- See: docs/prds/inventory/prd_012_driver_pod_add_workflow.md section 6.A.3

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
BEGIN
  -- 0. Resolve caller and check role (manager-only).
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: no caller identity';
  END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL
     OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  -- 1. Lock the edit row (case 14: concurrent approve).
  SELECT * INTO v_edit
  FROM public.pod_inventory_edits
  WHERE edit_id = p_edit_id
  FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: edit % not found', p_edit_id;
  END IF;
  IF v_edit.edit_type <> 'add_new_product' THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: edit % is type %, not add_new_product', p_edit_id, v_edit.edit_type;
  END IF;
  IF v_edit.status <> 'pending' THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: edit % is %, not pending (case 14: concurrent approve)', p_edit_id, v_edit.status;
  END IF;

  -- 2. Re-validate shelf conflict (case 10).
  SELECT pi.boonz_product_id, bp.boonz_product_name
    INTO v_conflict_product_id, v_conflict_product
  FROM public.pod_inventory pi
  JOIN public.boonz_products bp ON bp.product_id = pi.boonz_product_id
  WHERE pi.shelf_id = v_edit.destination_shelf_id
    AND pi.status = 'Active'
  LIMIT 1;
  IF v_conflict_product_id IS NOT NULL THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: shelf now in use by %. Reject or escalate.', v_conflict_product;
  END IF;

  -- 3. Re-validate expiry (case 11).
  IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
    RAISE EXCEPTION 'approve_pod_inventory_add: expiry % is now in the past; set p_expiry_override_accepted=true to approve anyway', v_edit.requested_expiration_date;
  END IF;

  -- 4. Resolve shelf_code for the response.
  SELECT shelf_code INTO v_shelf_code
  FROM public.shelf_configurations
  WHERE shelf_id = v_edit.destination_shelf_id;

  -- 5. Canonical writer markers (Article 4).
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'approve_pod_inventory_add', true);
  PERFORM set_config('app.mutation_reason', format('pod_add_approval edit_id=%s by=%s', p_edit_id, v_user_id), true);

  v_batch_id := format('POD_ADD-%s', p_edit_id);

  -- 6. INSERT pod_inventory row with unique_violation defense
  --    (idx_pod_inv_active_shelf enforces one Active row per machine+shelf+product).
  BEGIN
    INSERT INTO public.pod_inventory (
      machine_id, shelf_id, boonz_product_id,
      snapshot_date, current_stock, expiration_date,
      batch_id, status, snapshot_at
    ) VALUES (
      v_edit.machine_id, v_edit.destination_shelf_id, v_edit.boonz_product_id,
      CURRENT_DATE, v_edit.quantity_update, v_edit.requested_expiration_date,
      v_batch_id, 'Active', now()
    )
    RETURNING pod_inventory_id INTO v_new_pod_inventory_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'approve_pod_inventory_add: shelf raced into use by another Active row between re-validation and INSERT';
  END;

  -- 7. Close the edit row.
  UPDATE public.pod_inventory_edits
  SET status        = 'approved',
      reviewed_by   = v_user_id,
      reviewed_at   = now(),
      pod_inventory_id = v_new_pod_inventory_id,
      notes         = CASE
                        WHEN p_decision_note IS NULL OR length(trim(p_decision_note)) = 0 THEN notes
                        ELSE COALESCE(notes || E'\n[approval] ', '[approval] ') || trim(p_decision_note)
                      END
  WHERE edit_id = p_edit_id;

  RETURN jsonb_build_object(
    'result',           'success',
    'edit_id',          p_edit_id,
    'pod_inventory_id', v_new_pod_inventory_id,
    'batch_id',         v_batch_id,
    'machine_id',       v_edit.machine_id,
    'shelf_id',         v_edit.destination_shelf_id,
    'shelf_code',       v_shelf_code,
    'boonz_product_id', v_edit.boonz_product_id,
    'quantity',         v_edit.quantity_update,
    'expiration_date',  v_edit.requested_expiration_date,
    'expiry_overridden', (v_edit.requested_expiration_date <= CURRENT_DATE)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.approve_pod_inventory_add(uuid,uuid,text,boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.approve_pod_inventory_add(uuid,uuid,text,boolean) TO authenticated;

COMMENT ON FUNCTION public.approve_pod_inventory_add(uuid,uuid,text,boolean) IS
  'PRD-012 A.3 canonical writer. Locks edit row, re-validates D2 shelf conflict and D3 expiry, then INSERTs pod_inventory row with batch_id POD_ADD-(edit_id). Manager-only. Returns jsonb with the new pod_inventory_id and approval metadata.';
