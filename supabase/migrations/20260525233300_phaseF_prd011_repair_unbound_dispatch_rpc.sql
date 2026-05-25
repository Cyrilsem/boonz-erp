-- ============================================================================
-- PRD-011-refill-pipeline — repair_unbound_dispatch RPC
--
-- Post-hoc binds a packed-but-NULL-bound refill_dispatching row to a chosen
-- WH batch. Atomically moves warehouse_stock -> consumer_stock to match the
-- already-packed state. Refuses retro-rewrite of already-bound rows.
--
-- Root cause: Engine v10 / Stitch v12 WH-decouple stopped pre-pinning at
-- publish time. pack_dispatch_line should set from_wh_inventory_id at pack
-- time but anonymous direct UPDATE bypasses it (same class as Phase G P4 A.8).
-- 612 such rows existed in the 21-day window before this RPC shipped.
--
-- Applied to prod 2026-05-26 via MCP.
--
-- Cody articles: 1 (sole post-hoc bind path), 4 (role + input + reason),
-- 8 (audit chain via universal trigger), 12 (forward-only).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.repair_unbound_dispatch(
  p_dispatch_id     uuid,
  p_wh_inventory_id uuid,
  p_reason          text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id   uuid := (SELECT auth.uid());
  v_caller_role text;
  v_disp        refill_dispatching%ROWTYPE;
  v_wh          warehouse_inventory%ROWTYPE;
  v_qty         numeric;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'repair_unbound_dispatch: role % not authorized',
      COALESCE(v_caller_role, 'none');
  END IF;

  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;
  IF p_wh_inventory_id IS NULL THEN RAISE EXCEPTION 'p_wh_inventory_id required'; END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'repair_unbound_dispatch', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_pack', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_disp FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF v_disp.dispatch_id IS NULL THEN
    RAISE EXCEPTION 'dispatch row % not found', p_dispatch_id;
  END IF;

  IF v_disp.from_wh_inventory_id IS NOT NULL THEN
    RAISE EXCEPTION 'dispatch row % already bound to wh_inventory_id %; refusing retro-rewrite',
      p_dispatch_id, v_disp.from_wh_inventory_id;
  END IF;

  IF v_disp.packed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'repair_unbound_dispatch is only for already-packed rows (got packed=%); use pack_dispatch_line for unpacked rows',
      v_disp.packed;
  END IF;

  v_qty := COALESCE(v_disp.quantity, 0);
  IF v_qty <= 0 THEN
    RAISE EXCEPTION 'dispatch row quantity is %; cannot bind', v_qty;
  END IF;

  SELECT * INTO v_wh FROM warehouse_inventory
  WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF v_wh.wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'warehouse_inventory row % not found', p_wh_inventory_id;
  END IF;

  IF v_wh.boonz_product_id IS DISTINCT FROM v_disp.boonz_product_id THEN
    RAISE EXCEPTION 'wh_inventory_id % boonz_product_id (%) does not match dispatch boonz_product_id (%)',
      p_wh_inventory_id, v_wh.boonz_product_id, v_disp.boonz_product_id;
  END IF;

  IF COALESCE(v_wh.warehouse_stock, 0) < v_qty THEN
    RAISE EXCEPTION 'warehouse_stock % insufficient for qty %',
      COALESCE(v_wh.warehouse_stock, 0), v_qty;
  END IF;

  UPDATE warehouse_inventory
  SET warehouse_stock = warehouse_stock - v_qty,
      consumer_stock  = COALESCE(consumer_stock, 0) + v_qty
  WHERE wh_inventory_id = p_wh_inventory_id;

  UPDATE refill_dispatching
  SET from_wh_inventory_id = p_wh_inventory_id,
      expiry_date = v_wh.expiration_date
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'ok', true,
    'dispatch_id', p_dispatch_id,
    'wh_inventory_id', p_wh_inventory_id,
    'expiry_date', v_wh.expiration_date,
    'qty_debited', v_qty,
    'reason', p_reason,
    'repaired_by', v_caller_id
  );
END
$$;

REVOKE EXECUTE ON FUNCTION public.repair_unbound_dispatch(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.repair_unbound_dispatch(uuid,uuid,text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.repair_unbound_dispatch(uuid,uuid,text) IS
  'PRD-011-refill-pipeline: post-hoc bind a packed-but-NULL-bound refill_dispatching row to a specific WH batch.';
