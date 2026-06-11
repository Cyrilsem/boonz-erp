-- ============================================================================
-- DRAFT — bulk_repair_unbound_dispatches
--
-- Wraps repair_unbound_dispatch in a per-machine loop with FEFO auto-pick.
-- The repair RPC is already live (phaseF_prd011_repair_unbound_dispatch_rpc).
-- This wrapper adds:
--   - dry-run mode that returns the diff without committing
--   - FEFO pick per row (earliest expiration_date with sufficient warehouse_stock,
--     tie-break on snapshot_date)
--   - skip-and-flag for rows where no Active WH batch has sufficient stock
--   - per-row audit reason that cites the machine + dispatch_date
--
-- Caller must pass a scoping (p_machine_id + p_dispatch_date) so CS can review
-- the diff for ONE machine on ONE date at a time before committing.
--
-- Cody articles: 1 (loop-wraps the existing canonical writer; no new write path),
-- 4 (role + reason + scoping), 12 (forward-only).
--
-- NOT YET APPLIED. Pending Supabase MCP availability + CS sign-off on the
-- approach (FEFO auto-pick vs eyeball each row).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.bulk_repair_unbound_dispatches(
  p_machine_id    uuid,
  p_dispatch_date date,
  p_reason        text,
  p_dry_run       boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
  -- Article 4: role gate
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'bulk_repair_unbound_dispatches: role % not authorized',
      COALESCE(v_caller_role, 'none');
  END IF;

  IF p_machine_id IS NULL THEN RAISE EXCEPTION 'p_machine_id required'; END IF;
  IF p_dispatch_date IS NULL THEN RAISE EXCEPTION 'p_dispatch_date required'; END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  SELECT official_name INTO v_machine_name FROM machines WHERE machine_id = p_machine_id;
  IF v_machine_name IS NULL THEN
    RAISE EXCEPTION 'machine % not found', p_machine_id;
  END IF;

  -- Loop through eligible unbound rows for this machine + date
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
    -- FEFO pick: earliest expiry with sufficient stock
    SELECT wh.wh_inventory_id, wh.expiration_date, wh.warehouse_stock
    INTO v_pick_wh, v_pick_exp, v_pick_stock
    FROM warehouse_inventory wh
    WHERE wh.boonz_product_id = v_row.boonz_product_id
      AND wh.status = 'Active'
      AND wh.warehouse_stock >= v_row.quantity
    ORDER BY wh.expiration_date NULLS LAST, wh.snapshot_date
    LIMIT 1;

    IF v_pick_wh IS NULL THEN
      v_skipped := v_skipped || jsonb_build_object(
        'dispatch_id', v_row.dispatch_id,
        'product', v_row.boonz_product_name,
        'qty', v_row.quantity,
        'reason', 'no Active WH batch with sufficient stock'
      );
      v_skipped_count := v_skipped_count + 1;
      CONTINUE;
    END IF;

    IF p_dry_run THEN
      v_results := v_results || jsonb_build_object(
        'dispatch_id', v_row.dispatch_id,
        'product', v_row.boonz_product_name,
        'qty', v_row.quantity,
        'pick_wh', v_pick_wh,
        'pick_expiry', v_pick_exp,
        'wh_stock_available', v_pick_stock,
        'mode', 'dry_run'
      );
    ELSE
      v_rpc_result := public.repair_unbound_dispatch(
        v_row.dispatch_id,
        v_pick_wh,
        format('Bulk repair %s on %s: %s', v_machine_name, p_dispatch_date, p_reason)
      );
      v_results := v_results || v_rpc_result;
      v_committed_count := v_committed_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'machine', v_machine_name,
    'dispatch_date', p_dispatch_date,
    'mode', CASE WHEN p_dry_run THEN 'dry_run' ELSE 'commit' END,
    'committed_count', v_committed_count,
    'skipped_count', v_skipped_count,
    'rows', v_results,
    'skipped', v_skipped
  );
END
$$;

REVOKE EXECUTE ON FUNCTION public.bulk_repair_unbound_dispatches(uuid,date,text,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bulk_repair_unbound_dispatches(uuid,date,text,boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.bulk_repair_unbound_dispatches(uuid,date,text,boolean) IS
  'PRD-011-refill-pipeline: bulk repair wrapper for repair_unbound_dispatch. FEFO auto-pick per row. Always dry-run by default. Per-machine + per-date scoping mandatory.';
