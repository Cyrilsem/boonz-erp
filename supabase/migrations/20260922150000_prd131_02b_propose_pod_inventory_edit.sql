-- PRD-131 B2b (folded in from PRD-130 F7). Root cause, confirmed against write_audit_log: of
-- 913 INSERTs into pod_inventory_edits, 615 (67%) are via_rpc=false, rpc_name=NULL -- direct
-- table writes from the app across every edit_type field staff use day to day (sold 503,
-- expired 141, return_to_warehouse 105, partial_sold 71, in_stock 10, transfer 1), not just the
-- one 21 Sep 11:45 row PRD-130 flagged. add_new_product is already covered by
-- propose_pod_inventory_add (1 row, via_rpc=true). add_stock (82 rows) has no RPC in this
-- codebase either, but the PRD-131 signature CS specified has no expiry/destination-shelf
-- parameter, so add_stock and add_new_product stay out of this RPC's scope (they need
-- requested_expiration_date + destination_shelf_id, which propose_pod_inventory_add already
-- handles for add_new_product; add_stock is a separate, pre-existing gap, not created by this
-- migration and not silently absorbed here without a signature CS didn't ask for).
--
-- propose_pod_inventory_edit(p_machine_id, p_shelf_code, p_boonz_product_id, p_edit_type,
-- p_qty, p_reason) covers the six edit_types that lack a dedicated RPC today: in_stock, sold,
-- partial_sold, expired, return_to_warehouse, transfer. Resolves the shelf's current Active
-- pod_inventory lot (optionally product-scoped) and proposes an edit against it, status
-- 'pending', same review path (approve_pod_inventory_edit / reject_pod_inventory_edit) as every
-- other edit already uses.
--
-- RLS is NOT revoked in this migration. The app has not been switched to call this RPC yet
-- (that is a separate FE change); revoking INSERT now would break the app's core inventory
-- flow before the replacement is live. The revoke is a follow-up step once the app cutover is
-- confirmed in production -- tracked in docs/PRD-131-movement-kind.md.

CREATE OR REPLACE FUNCTION public.propose_pod_inventory_edit(
  p_machine_id uuid,
  p_shelf_code text,
  p_boonz_product_id uuid,
  p_edit_type text,
  p_qty numeric,
  p_reason text,
  p_caller_id uuid DEFAULT NULL::uuid,
  p_correlation_id uuid DEFAULT NULL::uuid
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id          uuid := COALESCE(p_caller_id, auth.uid());
  v_role             text;
  v_correlation_id   uuid := COALESCE(p_correlation_id, gen_random_uuid());
  v_existing_edit_id uuid;
  v_shelf_id         uuid;
  v_shelf_code       text;
  v_pod_inventory_id uuid;
  v_pod_product_id   uuid;
  v_expiration_date  date;
  v_recheck_source   text;
  v_new_edit_id      uuid;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'propose_pod_inventory_edit: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_edit_type NOT IN ('in_stock','sold','partial_sold','expired','return_to_warehouse','transfer') THEN
    RAISE EXCEPTION 'propose_pod_inventory_edit: p_edit_type must be one of in_stock, sold, partial_sold, expired, return_to_warehouse, transfer. add_new_product goes through propose_pod_inventory_add; add_stock has no covering RPC yet.';
  END IF;

  IF p_edit_type IN ('sold','partial_sold','return_to_warehouse') AND (p_qty IS NULL OR p_qty <= 0) THEN
    RAISE EXCEPTION 'propose_pod_inventory_edit: p_qty must be > 0 for edit_type=%', p_edit_type;
  END IF;
  IF p_qty IS NULL OR p_qty < 0 THEN
    RAISE EXCEPTION 'propose_pod_inventory_edit: p_qty must be >= 0';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'propose_pod_inventory_edit: p_reason must be at least 10 characters';
  END IF;

  SELECT edit_id INTO v_existing_edit_id FROM public.pod_inventory_edits
    WHERE correlation_id = v_correlation_id AND created_at > now() - interval '60 seconds'
    ORDER BY created_at DESC LIMIT 1;
  IF v_existing_edit_id IS NOT NULL THEN
    RETURN jsonb_build_object('result','idempotent_replay','edit_id',v_existing_edit_id,'correlation_id',v_correlation_id);
  END IF;

  SELECT shelf_id, shelf_code INTO v_shelf_id, v_shelf_code
  FROM public.shelf_configurations
  WHERE machine_id = p_machine_id AND shelf_code = p_shelf_code;
  IF v_shelf_id IS NULL THEN
    RAISE EXCEPTION 'propose_pod_inventory_edit: shelf_code % not found on machine %', p_shelf_code, p_machine_id;
  END IF;

  SELECT pi.pod_inventory_id, pi.boonz_product_id, pi.expiration_date
    INTO v_pod_inventory_id, v_pod_product_id, v_expiration_date
  FROM public.pod_inventory pi
  WHERE pi.machine_id = p_machine_id
    AND pi.shelf_id = v_shelf_id
    AND pi.status = 'Active'
    AND (p_boonz_product_id IS NULL OR pi.boonz_product_id = p_boonz_product_id)
  ORDER BY pi.expiration_date ASC NULLS LAST
  LIMIT 1;

  IF v_pod_inventory_id IS NULL THEN
    RAISE EXCEPTION 'propose_pod_inventory_edit: no Active pod_inventory lot on shelf % of machine % for this product', v_shelf_code, p_machine_id;
  END IF;

  v_recheck_source := CASE WHEN v_role = 'warehouse' THEN 'warehouse' ELSE 'driver_visit' END;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','propose_pod_inventory_edit', true);
  PERFORM set_config('app.mutation_reason',
    format('PRD-131 B2b propose %s correlation_id=%s by=%s: %s', p_edit_type, v_correlation_id, v_user_id, p_reason), true);

  INSERT INTO public.pod_inventory_edits
    (pod_inventory_id, machine_id, boonz_product_id, pod_product_id, requested_by, edit_type,
     quantity_update, notes, correlation_id, status, recheck_source)
  VALUES
    (v_pod_inventory_id, p_machine_id, COALESCE(p_boonz_product_id, v_pod_product_id), NULL,
     v_user_id, p_edit_type, p_qty, p_reason, v_correlation_id, 'pending', v_recheck_source)
  RETURNING edit_id INTO v_new_edit_id;

  RETURN jsonb_build_object('result','success','edit_id',v_new_edit_id,'correlation_id',v_correlation_id,
    'machine_id',p_machine_id,'shelf_id',v_shelf_id,'shelf_code',v_shelf_code,
    'pod_inventory_id',v_pod_inventory_id,'edit_type',p_edit_type,'quantity_update',p_qty);
END;
$function$;
