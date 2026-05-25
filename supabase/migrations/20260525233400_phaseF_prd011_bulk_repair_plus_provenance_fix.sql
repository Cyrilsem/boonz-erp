-- ============================================================================
-- PRD-011 Backlog A repair pass — combines:
--   1. provenance fix to repair_unbound_dispatch (manual_adjust instead of
--      dispatch_pack — the latter wasn't on the wh_provenance_event_required
--      CHECK whitelist).
--   2. New bulk_repair_unbound_dispatches wrapper: per-machine + per-date
--      FEFO auto-pick, always dry-run by default.
--
-- Applied to prod 2026-05-26 via MCP. Ran across all (machine, date) pairs
-- with NULL-bound dispatch rows in the 2026-05-19 to 2026-05-23 window:
-- 142 rows bound successfully, ~567 rows skipped (no Active WH batch with
-- sufficient stock — engine over-allocation problem, separate issue).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.repair_unbound_dispatch(
  p_dispatch_id     uuid,
  p_wh_inventory_id uuid,
  p_reason          text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
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
    RAISE EXCEPTION 'repair_unbound_dispatch: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;
  IF p_wh_inventory_id IS NULL THEN RAISE EXCEPTION 'p_wh_inventory_id required'; END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'repair_unbound_dispatch', true);
  -- CHECK constraint allow-list: manual_adjust, snapshot, status_flip, unknown_pre_migration
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_disp FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF v_disp.dispatch_id IS NULL THEN RAISE EXCEPTION 'dispatch row % not found', p_dispatch_id; END IF;
  IF v_disp.from_wh_inventory_id IS NOT NULL THEN
    RAISE EXCEPTION 'dispatch row % already bound to wh_inventory_id %; refusing retro-rewrite',
      p_dispatch_id, v_disp.from_wh_inventory_id;
  END IF;
  IF v_disp.packed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'repair_unbound_dispatch is only for already-packed rows (got packed=%)', v_disp.packed;
  END IF;
  v_qty := COALESCE(v_disp.quantity, 0);
  IF v_qty <= 0 THEN RAISE EXCEPTION 'dispatch row quantity is %; cannot bind', v_qty; END IF;

  SELECT * INTO v_wh FROM warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF v_wh.wh_inventory_id IS NULL THEN RAISE EXCEPTION 'warehouse_inventory row % not found', p_wh_inventory_id; END IF;
  IF v_wh.boonz_product_id IS DISTINCT FROM v_disp.boonz_product_id THEN
    RAISE EXCEPTION 'wh_inventory_id boonz_product_id mismatch';
  END IF;
  IF COALESCE(v_wh.warehouse_stock, 0) < v_qty THEN
    RAISE EXCEPTION 'warehouse_stock % insufficient for qty %', COALESCE(v_wh.warehouse_stock, 0), v_qty;
  END IF;

  UPDATE warehouse_inventory
  SET warehouse_stock = warehouse_stock - v_qty,
      consumer_stock  = COALESCE(consumer_stock, 0) + v_qty
  WHERE wh_inventory_id = p_wh_inventory_id;

  UPDATE refill_dispatching
  SET from_wh_inventory_id = p_wh_inventory_id,
      expiry_date = v_wh.expiration_date
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', p_dispatch_id,
    'wh_inventory_id', p_wh_inventory_id, 'expiry_date', v_wh.expiration_date,
    'qty_debited', v_qty, 'reason', p_reason, 'repaired_by', v_caller_id);
END
$$;

CREATE OR REPLACE FUNCTION public.bulk_repair_unbound_dispatches(
  p_machine_id    uuid,
  p_dispatch_date date,
  p_reason        text,
  p_dry_run       boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id   uuid := (SELECT auth.uid());
  v_caller_role text;
  v_row         record;
  v_pick_wh     uuid;
  v_pick_exp    date;
  v_pick_stock  numeric;
  v_results     jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_committed_count int := 0;
  v_skipped_count   int := 0;
  v_rpc_result  jsonb;
  v_machine_name text;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'bulk_repair_unbound_dispatches: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_machine_id IS NULL THEN RAISE EXCEPTION 'p_machine_id required'; END IF;
  IF p_dispatch_date IS NULL THEN RAISE EXCEPTION 'p_dispatch_date required'; END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;
  SELECT official_name INTO v_machine_name FROM machines WHERE machine_id = p_machine_id;
  IF v_machine_name IS NULL THEN RAISE EXCEPTION 'machine % not found', p_machine_id; END IF;

  FOR v_row IN
    SELECT rd.dispatch_id, rd.boonz_product_id, rd.quantity, bp.boonz_product_name
    FROM refill_dispatching rd
    JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
    WHERE rd.machine_id = p_machine_id
      AND rd.dispatch_date = p_dispatch_date
      AND rd.packed = true
      AND rd.from_wh_inventory_id IS NULL
      AND rd.action IN ('Refill','Add New')
    ORDER BY bp.boonz_product_name
  LOOP
    SELECT wh.wh_inventory_id, wh.expiration_date, wh.warehouse_stock
    INTO v_pick_wh, v_pick_exp, v_pick_stock
    FROM warehouse_inventory wh
    WHERE wh.boonz_product_id = v_row.boonz_product_id
      AND wh.status = 'Active'
      AND wh.warehouse_stock >= v_row.quantity
    ORDER BY wh.expiration_date NULLS LAST, wh.snapshot_date
    LIMIT 1;

    IF v_pick_wh IS NULL THEN
      v_skipped := v_skipped || jsonb_build_object('dispatch_id', v_row.dispatch_id,
        'product', v_row.boonz_product_name, 'qty', v_row.quantity,
        'reason', 'no Active WH batch with sufficient stock');
      v_skipped_count := v_skipped_count + 1;
      CONTINUE;
    END IF;

    IF p_dry_run THEN
      v_results := v_results || jsonb_build_object('dispatch_id', v_row.dispatch_id,
        'product', v_row.boonz_product_name, 'qty', v_row.quantity,
        'pick_wh', v_pick_wh, 'pick_expiry', v_pick_exp,
        'wh_stock_available', v_pick_stock, 'mode', 'dry_run');
    ELSE
      v_rpc_result := public.repair_unbound_dispatch(v_row.dispatch_id, v_pick_wh,
        format('Bulk repair %s on %s: %s', v_machine_name, p_dispatch_date, p_reason));
      v_results := v_results || v_rpc_result;
      v_committed_count := v_committed_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('machine', v_machine_name, 'dispatch_date', p_dispatch_date,
    'mode', CASE WHEN p_dry_run THEN 'dry_run' ELSE 'commit' END,
    'committed_count', v_committed_count, 'skipped_count', v_skipped_count,
    'rows', v_results, 'skipped', v_skipped);
END
$$;

REVOKE EXECUTE ON FUNCTION public.bulk_repair_unbound_dispatches(uuid,date,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bulk_repair_unbound_dispatches(uuid,date,text,boolean)
  TO authenticated, service_role;
