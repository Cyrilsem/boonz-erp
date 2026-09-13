-- PRD-122 Phase 3, CL-2: purge_warehouse_ghosts -- zeroes non-Active WH_CENTRAL rows
-- that are still carrying live warehouse_stock (24 rows/109 units as of 13 Sep --
-- inventory sitting under a status like Inactive/Expired/Removed that never got
-- zeroed when it left Active, so it silently keeps counting toward totals).
--
-- Extends disposal_reason's controlled vocabulary with a date-stamped
-- ghost_purge_YYYY-MM-DD pattern (one CHECK regex covers every future run date
-- without a fresh migration each time).
--
-- purge_warehouse_ghosts(p_warehouse_id, p_dry_run DEFAULT true) targets ONLY rows
-- with status <> 'Active' AND warehouse_stock > 0 for the given warehouse: zeroes
-- warehouse_stock and stamps disposal_reason. After the real write, asserts no
-- Active row was touched (checks for any Active row carrying today's ghost_purge_*
-- disposal_reason) and RAISEs to abort the whole transaction if that assertion ever
-- fails, rather than returning a falsely-clean result.
--
-- Cody: Approve. Article 1 (dedicated writer, no other function performs this),
-- Article 4 (role-gated, sets app.via_rpc/rpc_name, validates p_warehouse_id),
-- Article 6 (writes warehouse_inventory.warehouse_stock -- same role-gated-RPC
-- precedent as the rest of this phase), Article 12 (forward-only).
--
-- Backtested in a rolled-back transaction: dry run matches the mission's stated
-- baseline exactly (24 ghost rows, 109 units). Real run zeroed and stamped all 24;
-- the post-write safety assertion never fired; WH_CENTRAL's 145 Active rows /
-- 1298 units were confirmed completely unchanged afterward.

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT warehouse_inventory_disposal_reason_check;

ALTER TABLE public.warehouse_inventory ADD CONSTRAINT warehouse_inventory_disposal_reason_check
  CHECK (disposal_reason IS NULL OR disposal_reason = 'Waste' OR disposal_reason = 'Returning to supplier'
    OR disposal_reason = 'Returned to supplier' OR disposal_reason = 'audit_zero'
    OR disposal_reason ~ '^ghost_purge_\d{4}-\d{2}-\d{2}$');

CREATE OR REPLACE FUNCTION public.purge_warehouse_ghosts(p_warehouse_id uuid, p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_count int;
  v_units numeric;
  v_disposal text := format('ghost_purge_%s', CURRENT_DATE);
  v_touched_active int;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'purge_warehouse_ghosts: role % not authorized', COALESCE(v_role, 'none');
  END IF;

  IF p_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'purge_warehouse_ghosts: p_warehouse_id is required';
  END IF;

  SELECT count(*), COALESCE(sum(warehouse_stock), 0) INTO v_count, v_units
  FROM public.warehouse_inventory
  WHERE warehouse_id = p_warehouse_id AND status <> 'Active' AND COALESCE(warehouse_stock, 0) > 0;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true,
      'warehouse_id', p_warehouse_id,
      'ghost_rows', v_count,
      'ghost_units', v_units,
      'would_set_disposal_reason', v_disposal
    );
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'purge_warehouse_ghosts', true);

  UPDATE public.warehouse_inventory
  SET warehouse_stock = 0,
      disposal_reason = v_disposal
  WHERE warehouse_id = p_warehouse_id AND status <> 'Active' AND COALESCE(warehouse_stock, 0) > 0;

  SELECT count(*) INTO v_touched_active FROM public.warehouse_inventory
  WHERE warehouse_id = p_warehouse_id AND status = 'Active' AND disposal_reason = v_disposal;
  IF v_touched_active > 0 THEN
    RAISE EXCEPTION 'purge_warehouse_ghosts: SAFETY VIOLATION -- % Active rows were touched, aborting', v_touched_active;
  END IF;

  RETURN jsonb_build_object(
    'dry_run', false,
    'warehouse_id', p_warehouse_id,
    'ghost_rows_purged', v_count,
    'ghost_units_zeroed', v_units,
    'disposal_reason', v_disposal
  );
END;
$function$;
