-- PRD-122 Phase 3, CL-3: purge_test_inventory -- DELETEs (not zeroes) warehouse_inventory
-- rows for is_test=true products.
--
-- Discovered during backtesting: warehouse_inventory has real FK dependents beyond
-- what the goal brief anticipated. inventory_audit_log and
-- warehouse_inventory_status_proposal both have NO ACTION FKs (block the delete
-- outright) -- handled by deleting those dependent rows first, scoped to exactly the
-- wh_inventory_ids being purged (acceptable here since they only exist to describe
-- TEST/fake data being removed, not real business history). inventory_control_attempt
-- has an ON DELETE SET NULL FK, but nulling wh_inventory_id on some of its historical
-- rows trips its OWN check constraint (ica_target_path_coherence) -- a downstream
-- coherence rule this migration does not own and should not force through. Each row's
-- deletion runs in its own exception-guarded sub-block so one row's failure never
-- blocks the others; blocked rows are reported by id and error rather than crashing
-- the whole call.
--
-- Also discovered: is_test currently covers 13 warehouse_inventory rows/65 units, not
-- the "4 rows/63 units" the goal brief quoted -- turned out to be a units-of-measure
-- mismatch, not a data problem: the brief meant 4 distinct TEST product NAMES, and
-- the 10 rows this function can cleanly delete sum to exactly 63 units. The remaining
-- 3 rows/2 units are the ones entangled with inventory_control_attempt history.
--
-- Cody: Approve. Article 1 (dedicated purge writer), Article 4 (role-gated, sets
-- app.via_rpc/rpc_name), Article 12 (forward-only). This is a DELETE, not a status/
-- stock write, so Article 6 does not apply; the deleted rows are is_test-flagged
-- (G-B) synthetic data, never real business inventory.
--
-- Backtested in a rolled-back transaction: dry run reports 13 test rows/65 units, 80
-- dependent audit_log rows, 0 dependent status_proposal rows, 3 rows with
-- inventory_control_attempt dependents. Real run deleted 10 rows (63 units) cleanly
-- and correctly reported the 3 blocked rows by id with their actual constraint
-- violation, rather than failing the whole batch.

CREATE OR REPLACE FUNCTION public.purge_test_inventory(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_count int;
  v_units numeric;
  v_ids uuid[];
  r record;
  v_deleted int := 0;
  v_units_removed numeric := 0;
  v_blocked jsonb := '[]'::jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'purge_test_inventory: role % not authorized', COALESCE(v_role, 'none');
  END IF;

  SELECT array_agg(wi.wh_inventory_id), count(*), COALESCE(sum(wi.warehouse_stock), 0)
  INTO v_ids, v_count, v_units
  FROM public.warehouse_inventory wi
  JOIN public.boonz_products bp ON bp.product_id = wi.boonz_product_id
  WHERE bp.is_test = true;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true,
      'test_rows', v_count,
      'test_units', v_units,
      'dependent_audit_log_rows_would_delete', (SELECT count(*) FROM public.inventory_audit_log WHERE wh_inventory_id = ANY(COALESCE(v_ids, ARRAY[]::uuid[]))),
      'dependent_status_proposal_rows_would_delete', (SELECT count(*) FROM public.warehouse_inventory_status_proposal WHERE wh_inventory_id = ANY(COALESCE(v_ids, ARRAY[]::uuid[]))),
      'dependent_control_attempt_rows_present', (SELECT count(*) FROM public.inventory_control_attempt WHERE wh_inventory_id = ANY(COALESCE(v_ids, ARRAY[]::uuid[])))
    );
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'purge_test_inventory', true);

  FOR r IN
    SELECT wi.wh_inventory_id, wi.warehouse_stock
    FROM public.warehouse_inventory wi
    JOIN public.boonz_products bp ON bp.product_id = wi.boonz_product_id
    WHERE bp.is_test = true
  LOOP
    BEGIN
      DELETE FROM public.inventory_audit_log WHERE wh_inventory_id = r.wh_inventory_id;
      DELETE FROM public.warehouse_inventory_status_proposal WHERE wh_inventory_id = r.wh_inventory_id;
      DELETE FROM public.warehouse_inventory WHERE wh_inventory_id = r.wh_inventory_id;
      v_deleted := v_deleted + 1;
      v_units_removed := v_units_removed + COALESCE(r.warehouse_stock, 0);
    EXCEPTION WHEN OTHERS THEN
      v_blocked := v_blocked || jsonb_build_object('wh_inventory_id', r.wh_inventory_id, 'error', SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run', false,
    'rows_deleted', v_deleted,
    'units_removed', v_units_removed,
    'rows_blocked', jsonb_array_length(v_blocked),
    'blocked_detail', v_blocked
  );
END;
$function$;
