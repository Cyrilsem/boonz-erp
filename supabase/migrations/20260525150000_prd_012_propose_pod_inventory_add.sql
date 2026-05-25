-- PRD-012 A.2: propose_pod_inventory_add
-- Driver-callable SECURITY DEFINER RPC. Validates D2/D3/D5 then INSERTs a
-- pending row into pod_inventory_edits with edit_type='add_new_product'.
-- Cody G2 verdict: approve with revisions (mutation_reason added).
-- See: docs/prds/inventory/prd_012_driver_pod_add_workflow.md section 6.A.2

CREATE OR REPLACE FUNCTION public.propose_pod_inventory_add(
  p_machine_id        uuid,
  p_shelf_id          uuid,
  p_boonz_product_id  uuid,
  p_quantity          numeric,
  p_expiration_date   date,
  p_notes             text DEFAULT NULL,
  p_photo_path        text DEFAULT NULL,
  p_correlation_id    uuid DEFAULT NULL,
  p_proposed_by       uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id              uuid;
  v_caller_role          text;
  v_correlation_id       uuid := COALESCE(p_correlation_id, gen_random_uuid());
  v_existing_edit_id     uuid;
  v_shelf_machine_id     uuid;
  v_shelf_code           text;
  v_shelf_max_capacity   integer;
  v_product_exists       boolean;
  v_product_name         text;
  v_conflict_product_id  uuid;
  v_conflict_product     text;
  v_new_edit_id          uuid;
  v_max_expiry           date := CURRENT_DATE + INTERVAL '36 months';
BEGIN
  -- 0. Resolve caller and check role.
  v_user_id := COALESCE(p_proposed_by, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: no caller identity';
  END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL
     OR v_caller_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  -- 1. D5 idempotency check.
  SELECT edit_id INTO v_existing_edit_id
  FROM public.pod_inventory_edits
  WHERE correlation_id = v_correlation_id
    AND created_at > now() - interval '60 seconds'
  ORDER BY created_at DESC
  LIMIT 1;
  IF v_existing_edit_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'result', 'idempotent_replay',
      'edit_id', v_existing_edit_id,
      'correlation_id', v_correlation_id
    );
  END IF;

  -- 2. Input validation.
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: quantity must be > 0 (got %)', p_quantity;
  END IF;
  IF p_expiration_date IS NULL THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: expiration_date required';
  END IF;
  IF p_expiration_date <= CURRENT_DATE THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: expiry must be in the future (got %)', p_expiration_date;
  END IF;
  IF p_expiration_date > v_max_expiry THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: expiry must be within 36 months (got %, max %)', p_expiration_date, v_max_expiry;
  END IF;

  -- 3. Shelf lookup and ownership check.
  SELECT machine_id, shelf_code, max_capacity
    INTO v_shelf_machine_id, v_shelf_code, v_shelf_max_capacity
  FROM public.shelf_configurations
  WHERE shelf_id = p_shelf_id;
  IF v_shelf_machine_id IS NULL THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: shelf % not found', p_shelf_id;
  END IF;
  IF v_shelf_machine_id <> p_machine_id THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: shelf % belongs to machine %, not %', p_shelf_id, v_shelf_machine_id, p_machine_id;
  END IF;
  IF v_shelf_max_capacity IS NOT NULL AND p_quantity > v_shelf_max_capacity THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: quantity % exceeds shelf % capacity %', p_quantity, v_shelf_code, v_shelf_max_capacity;
  END IF;

  -- 4. Product existence check.
  SELECT (count(*) > 0), max(boonz_product_name) INTO v_product_exists, v_product_name
  FROM public.boonz_products
  WHERE product_id = p_boonz_product_id;
  IF NOT v_product_exists THEN
    RAISE EXCEPTION 'propose_pod_inventory_add: product % not found', p_boonz_product_id;
  END IF;

  -- 5. D2 shelf conflict.
  SELECT pi.boonz_product_id, bp.boonz_product_name
    INTO v_conflict_product_id, v_conflict_product
  FROM public.pod_inventory pi
  JOIN public.boonz_products bp ON bp.product_id = pi.boonz_product_id
  WHERE pi.shelf_id = p_shelf_id
    AND pi.status = 'Active'
  LIMIT 1;
  IF v_conflict_product_id IS NOT NULL THEN
    IF v_conflict_product_id = p_boonz_product_id THEN
      RAISE EXCEPTION 'propose_pod_inventory_add: product % already on shelf %. Use the edit flow.', v_conflict_product, v_shelf_code;
    ELSE
      RAISE EXCEPTION 'propose_pod_inventory_add: shelf % currently has %. Use the swap flow instead.', v_shelf_code, v_conflict_product;
    END IF;
  END IF;

  -- 6. Canonical writer markers (Article 4).
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'propose_pod_inventory_add', true);
  PERFORM set_config('app.mutation_reason',
    format('pod_add_proposal correlation_id=%s by=%s', v_correlation_id, v_user_id), true);

  -- 7. INSERT with unique_violation defense (idx_pie_one_pending_add_per_target).
  BEGIN
    INSERT INTO public.pod_inventory_edits (
      machine_id, boonz_product_id, requested_by, edit_type,
      quantity_update, requested_expiration_date,
      destination_shelf_id, notes, photo_path,
      correlation_id, status, pod_inventory_id
    ) VALUES (
      p_machine_id, p_boonz_product_id, v_user_id, 'add_new_product',
      p_quantity, p_expiration_date,
      p_shelf_id, p_notes, p_photo_path,
      v_correlation_id, 'pending', NULL
    )
    RETURNING edit_id INTO v_new_edit_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'propose_pod_inventory_add: a pending add for this shelf+product already exists';
  END;

  RETURN jsonb_build_object(
    'result',         'success',
    'edit_id',        v_new_edit_id,
    'correlation_id', v_correlation_id,
    'machine_id',     p_machine_id,
    'shelf_id',       p_shelf_id,
    'shelf_code',     v_shelf_code,
    'boonz_product_id', p_boonz_product_id,
    'product_name',   v_product_name,
    'quantity',       p_quantity,
    'expiration_date', p_expiration_date
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.propose_pod_inventory_add(uuid,uuid,uuid,numeric,date,text,text,uuid,uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.propose_pod_inventory_add(uuid,uuid,uuid,numeric,date,text,text,uuid,uuid) TO authenticated;

COMMENT ON FUNCTION public.propose_pod_inventory_add(uuid,uuid,uuid,numeric,date,text,text,uuid,uuid) IS
  'PRD-012 A.2 canonical writer for driver pod-add proposals. Validates shelf conflict (D2), expiry bounds (D3), idempotency by correlation_id (D5). Callable by field_staff plus manager roles. Returns jsonb with result (success | idempotent_replay) plus edit_id and the resolved shelf/product fields.';
