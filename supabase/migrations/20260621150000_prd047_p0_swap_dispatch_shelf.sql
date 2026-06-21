-- PRD-047 P0: swap_dispatch_shelf - atomic one-tap shelf swap (Remove old + Add New) for the
-- packing page. Forward CREATE OR REPLACE. Canonical writer to refill_dispatching via the existing
-- canonical add_dispatch_row (title-case action guard, role gate, mapping check, edit-log audit) -
-- both calls run in this one transaction, so the pair is atomic (both lines or neither). The Add New
-- is WH-sourced (source_kind='wh', the machine's primary warehouse); FEFO batch is chosen at pack
-- time by pack_dispatch_line. swaps_enabled untouched.

CREATE OR REPLACE FUNCTION public.swap_dispatch_shelf(
  p_plan_date date, p_machine_id uuid, p_shelf_id uuid,
  p_remove_boonz_id uuid, p_remove_qty numeric,
  p_add_boonz_id uuid, p_add_qty numeric, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_role      text;
  v_shelf_code text;
  v_wh        uuid;
  v_removed   jsonb := NULL;
  v_added     jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'swap_dispatch_shelf', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'swap_dispatch_shelf: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL
     OR p_remove_boonz_id IS NULL OR p_add_boonz_id IS NULL THEN
    RAISE EXCEPTION 'swap_dispatch_shelf: plan_date, machine_id, shelf_id, remove_boonz_id, add_boonz_id are required';
  END IF;
  IF COALESCE(p_reason,'') = '' OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'swap_dispatch_shelf: p_reason required (>= 10 chars)';
  END IF;
  IF COALESCE(p_add_qty,0) <= 0 THEN
    RAISE EXCEPTION 'swap_dispatch_shelf: p_add_qty must be > 0';
  END IF;

  SELECT shelf_code INTO v_shelf_code FROM public.shelf_configurations
   WHERE shelf_id = p_shelf_id AND machine_id = p_machine_id;
  IF v_shelf_code IS NULL THEN
    RAISE EXCEPTION 'swap_dispatch_shelf: shelf % not found on machine %', p_shelf_id, p_machine_id;
  END IF;

  SELECT primary_warehouse_id INTO v_wh FROM public.machines WHERE machine_id = p_machine_id;
  IF v_wh IS NULL THEN
    RAISE EXCEPTION 'swap_dispatch_shelf: machine % has no primary_warehouse_id (cannot WH-source the Add New)', p_machine_id;
  END IF;

  PERFORM set_config('app.mutation_reason', p_reason, true);

  -- Atomic: both writes in this transaction. If the Add New fails (e.g. no mapping), the Remove
  -- rolls back with it. Title-case actions enforced by add_dispatch_row.
  IF COALESCE(p_remove_qty,0) > 0 THEN
    v_removed := public.add_dispatch_row(
      p_machine_id, v_shelf_code, p_remove_boonz_id, p_remove_qty, 'Remove',
      p_plan_date, 'unknown', NULL, NULL, COALESCE(v_role,'system'), p_reason, NULL);
  END IF;

  v_added := public.add_dispatch_row(
    p_machine_id, v_shelf_code, p_add_boonz_id, p_add_qty, 'Add New',
    p_plan_date, 'wh', v_wh, NULL, COALESCE(v_role,'system'), p_reason, NULL);

  RETURN jsonb_build_object('status','ok','shelf_code',v_shelf_code,
    'removed', v_removed, 'added', v_added, 'reason', p_reason);
END;
$function$;

REVOKE ALL ON FUNCTION public.swap_dispatch_shelf(date,uuid,uuid,uuid,numeric,uuid,numeric,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.swap_dispatch_shelf(date,uuid,uuid,uuid,numeric,uuid,numeric,text) TO authenticated, service_role;
