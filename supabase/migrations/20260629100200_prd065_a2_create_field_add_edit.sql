-- PRD-065 A2 — create_field_add_edit. First-class off-plan field add ("refill but not in list").
-- HELD (inserts pod_inventory_edits). Apply on CS green light.
-- Dara: resolves the destination shelf so the driver app never hand-builds an add_stock edit
-- (the 5 M&M Chocolate Nuts -> OMDBB "Chocolate Bar" case). Shelf resolution chain:
--   explicit p_destination_shelf_id  ->  else pod_product (explicit or product_mapping for the
--   machine+boonz, machine-specific then global default)  ->  slot_lifecycle current slot -> shelf_id.
-- Inserts a PENDING add_stock edit; approval still flows through canonical approve_pod_inventory_edit.
-- Satisfies the existing add_stock conditional CHECK (qty>0 + expiry + shelf all set).
-- Idempotent: already_done if a pending/approved add_stock edit OR an Active pod row already exists
-- for (machine, shelf, boonz, expiry).

CREATE OR REPLACE FUNCTION public.create_field_add_edit(
  p_machine_id          uuid,
  p_boonz_product_id    uuid,
  p_qty                 numeric,
  p_expiry              date,
  p_caller_id           uuid,
  p_reason              text DEFAULT 'off_plan_field_add',
  p_pod_product_id      uuid DEFAULT NULL,
  p_destination_shelf_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_pod     uuid := p_pod_product_id;
  v_shelf   uuid := p_destination_shelf_id;
  v_edit_id uuid;
  v_existing uuid;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'create_field_add_edit: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'create_field_add_edit: quantity must be > 0 (got %)', p_qty;
  END IF;
  IF p_expiry IS NULL THEN
    RAISE EXCEPTION 'create_field_add_edit: expiry is required for an add_stock edit';
  END IF;

  -- resolve pod_product if shelf not given directly
  IF v_shelf IS NULL THEN
    IF v_pod IS NULL THEN
      SELECT pod_product_id INTO v_pod
      FROM public.product_mapping
      WHERE boonz_product_id = p_boonz_product_id
        AND (machine_id = p_machine_id OR machine_id IS NULL)
        AND COALESCE(status,'Active') = 'Active'
      ORDER BY (machine_id = p_machine_id) DESC NULLS LAST, is_global_default DESC
      LIMIT 1;
    END IF;
    IF v_pod IS NULL THEN
      RAISE EXCEPTION 'create_field_add_edit: cannot resolve pod_product for machine % boonz % (pass p_pod_product_id or p_destination_shelf_id)', p_machine_id, p_boonz_product_id;
    END IF;
    SELECT shelf_id INTO v_shelf
    FROM public.slot_lifecycle
    WHERE machine_id = p_machine_id AND pod_product_id = v_pod
      AND COALESCE(is_current,false) = true AND COALESCE(archived,false) = false
    LIMIT 1;
    IF v_shelf IS NULL THEN
      RAISE EXCEPTION 'create_field_add_edit: no current slot for machine % pod_product % (pass p_destination_shelf_id)', p_machine_id, v_pod;
    END IF;
  END IF;

  -- idempotency: pending/approved add_stock edit already exists for this target
  SELECT edit_id INTO v_existing
  FROM public.pod_inventory_edits
  WHERE machine_id = p_machine_id AND boonz_product_id = p_boonz_product_id
    AND destination_shelf_id = v_shelf AND edit_type = 'add_stock'
    AND requested_expiration_date IS NOT DISTINCT FROM p_expiry
    AND status IN ('pending','approved')
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('status','already_done','edit_id',v_existing,'note','matching add_stock edit already exists');
  END IF;

  -- or an Active pod row already covers it
  IF EXISTS (
    SELECT 1 FROM public.pod_inventory
    WHERE machine_id = p_machine_id AND boonz_product_id = p_boonz_product_id
      AND shelf_id IS NOT DISTINCT FROM v_shelf AND status = 'Active'
      AND expiration_date IS NOT DISTINCT FROM p_expiry
  ) THEN
    RETURN jsonb_build_object('status','already_done','note','Active pod row already exists for this target');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'create_field_add_edit', true);
  PERFORM set_config('app.mutation_reason',
    format('field_add machine=%s boonz=%s qty=%s by=%s', p_machine_id, p_boonz_product_id, p_qty, v_user_id), true);

  INSERT INTO public.pod_inventory_edits
    (machine_id, boonz_product_id, pod_product_id, requested_by, edit_type, quantity_update,
     destination_shelf_id, requested_expiration_date, recheck_source, notes, status)
  VALUES
    (p_machine_id, p_boonz_product_id, v_pod, v_user_id, 'add_stock', p_qty,
     v_shelf, p_expiry, 'driver_visit', p_reason, 'pending')
  RETURNING edit_id INTO v_edit_id;

  RETURN jsonb_build_object('status','created','edit_id',v_edit_id,'machine_id',p_machine_id,
                            'destination_shelf_id',v_shelf,'pod_product_id',v_pod,'qty',p_qty,'expiry',p_expiry);
END;
$$;

REVOKE ALL ON FUNCTION public.create_field_add_edit(uuid,uuid,numeric,date,uuid,text,uuid,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_field_add_edit(uuid,uuid,numeric,date,uuid,text,uuid,uuid) TO authenticated, service_role;

-- DOWN:
-- DROP FUNCTION IF EXISTS public.create_field_add_edit(uuid,uuid,numeric,date,uuid,text,uuid,uuid);
