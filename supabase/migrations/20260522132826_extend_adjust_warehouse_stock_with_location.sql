-- ============================================================================
-- adjust_warehouse_stock — extension for wh_location + metadata audit rows
--
-- Context: investigation of the "30-second undo" pattern in inventory_audit_log
-- (2026-05-22) found 1,320 warehouse_inventory writes in 5 weeks that bypassed
-- the canonical RPC layer — all stamped with `authenticated_write_no_reason_set`.
-- Source was 6 FE call sites doing `.from("warehouse_inventory").update(...)`
-- directly, including 4 metadata-only edits (wh_location, status, expiry).
--
-- adjust_warehouse_stock already handles warehouse_stock + consumer_stock +
-- expiration_date + batch_id + status. This migration:
--   1. Adds wh_location to the line payload (additive — backward compatible)
--   2. Writes audit rows for non-quantity metadata changes (location, status,
--      expiry) — previously only qty deltas were audited
--   3. Leaves the role check, GUC machinery, and existing return shape intact
--
-- Cody Article check:
--   - A3 (canonical writer): this is the canonical writer; we're extending it.
--   - A7 (append-only audit): we add MORE rows to inventory_audit_log; we do
--     not modify or delete existing rows. delta is still computed from qty.
--   - A12 (forward-only): CREATE OR REPLACE; no DROP, no incompatible signature
--     change. Existing callers that don't pass wh_location continue to work.
--   - A14: no _v2 table; function evolves in place.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.adjust_warehouse_stock(
  p_warehouse_id uuid,
  p_lines jsonb,
  p_snapshot_date date DEFAULT CURRENT_DATE,
  p_reason text DEFAULT 'physical_count_reconciliation'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role text; v_caller_id uuid;
  v_line jsonb; v_boonz_id uuid; v_new_wh numeric; v_new_cs numeric;
  v_exp_date date; v_batch text; v_status_val text; v_wh_inv_id uuid;
  v_new_loc text; v_loc_provided boolean;
  v_old_wh numeric; v_old_cs numeric; v_old_exp date;
  v_old_loc text; v_old_status text;
  v_found boolean;
  v_updated int := 0; v_inserted int := 0; v_unchanged int := 0;
  v_details jsonb := '[]'::jsonb; v_wh_name text;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'adjust_warehouse_stock', true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  v_caller_id := auth.uid();
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'adjust_warehouse_stock: forbidden for role %', COALESCE(v_caller_role,'anon');
  END IF;

  SELECT name INTO v_wh_name FROM warehouses WHERE warehouse_id = p_warehouse_id;
  IF v_wh_name IS NULL THEN
    RAISE EXCEPTION 'adjust_warehouse_stock: warehouse % not found', p_warehouse_id;
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'adjust_warehouse_stock: p_lines must be a non-empty array';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_boonz_id   := (v_line->>'boonz_product_id')::uuid;
    v_new_wh     := COALESCE((v_line->>'new_warehouse_stock')::numeric, 0);
    v_new_cs     := COALESCE((v_line->>'new_consumer_stock')::numeric, 0);
    v_exp_date   := (v_line->>'expiration_date')::date;
    v_batch      := v_line->>'batch_id';
    v_status_val := COALESCE(v_line->>'status', 'Active');
    v_wh_inv_id  := (v_line->>'wh_inventory_id')::uuid;
    -- NEW: wh_location is optional. When the key is present (even as null),
    -- we treat it as an explicit set. When absent, we keep the existing value.
    v_loc_provided := (v_line ? 'wh_location');
    v_new_loc    := v_line->>'wh_location';

    v_found := false;

    IF v_wh_inv_id IS NOT NULL THEN
      SELECT warehouse_stock, consumer_stock, expiration_date, wh_location, status
        INTO v_old_wh, v_old_cs, v_old_exp, v_old_loc, v_old_status
        FROM warehouse_inventory
        WHERE wh_inventory_id = v_wh_inv_id AND warehouse_id = p_warehouse_id;
      IF FOUND THEN v_found := true; END IF;
    ELSE
      SELECT wh_inventory_id, warehouse_stock, consumer_stock, expiration_date, wh_location, status
        INTO v_wh_inv_id, v_old_wh, v_old_cs, v_old_exp, v_old_loc, v_old_status
        FROM warehouse_inventory
        WHERE warehouse_id = p_warehouse_id
          AND boonz_product_id = v_boonz_id
          AND expiration_date IS NOT DISTINCT FROM v_exp_date
        ORDER BY created_at ASC
        LIMIT 1;
      IF FOUND THEN v_found := true; END IF;
    END IF;

    IF v_found THEN
      -- "unchanged" now considers location and status too
      IF v_old_wh = v_new_wh
         AND COALESCE(v_old_cs,0) = v_new_cs
         AND (v_exp_date IS NULL OR v_old_exp IS NOT DISTINCT FROM v_exp_date)
         AND (NOT v_loc_provided OR v_old_loc IS NOT DISTINCT FROM v_new_loc)
         AND v_old_status IS NOT DISTINCT FROM v_status_val THEN
        v_unchanged := v_unchanged + 1;
        v_details := v_details || jsonb_build_object(
          'boonz_product_id', v_boonz_id,
          'wh_inventory_id',  v_wh_inv_id,
          'action',           'unchanged'
        );
        CONTINUE;
      END IF;

      PERFORM set_config('app.source_event_id', v_wh_inv_id::text, true);

      UPDATE warehouse_inventory
         SET warehouse_stock = v_new_wh,
             consumer_stock  = v_new_cs,
             snapshot_date   = p_snapshot_date,
             expiration_date = COALESCE(v_exp_date, expiration_date),
             batch_id        = COALESCE(v_batch, batch_id),
             status          = v_status_val,
             wh_location     = CASE WHEN v_loc_provided THEN v_new_loc ELSE wh_location END
       WHERE wh_inventory_id = v_wh_inv_id;

      -- Audit rows: one per dimension that actually changed
      IF v_old_wh IS DISTINCT FROM v_new_wh THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_old_wh, v_new_wh, p_reason||' [warehouse_stock]', now());
      END IF;
      IF COALESCE(v_old_cs,0) IS DISTINCT FROM v_new_cs THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, COALESCE(v_old_cs,0), v_new_cs, p_reason||' [consumer_stock]', now());
      END IF;
      IF v_loc_provided AND v_old_loc IS DISTINCT FROM v_new_loc THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_new_wh, v_new_wh,
                p_reason||' [wh_location: '||COALESCE(v_old_loc,'(null)')||' -> '||COALESCE(v_new_loc,'(null)')||']', now());
      END IF;
      IF v_old_status IS DISTINCT FROM v_status_val THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_new_wh, v_new_wh,
                p_reason||' [status: '||COALESCE(v_old_status,'(null)')||' -> '||COALESCE(v_status_val,'(null)')||']', now());
      END IF;
      IF v_exp_date IS NOT NULL AND v_old_exp IS DISTINCT FROM v_exp_date THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_new_wh, v_new_wh,
                p_reason||' [expiration_date: '||COALESCE(v_old_exp::text,'(null)')||' -> '||COALESCE(v_exp_date::text,'(null)')||']', now());
      END IF;

      v_updated := v_updated + 1;
      v_details := v_details || jsonb_build_object(
        'boonz_product_id', v_boonz_id,
        'wh_inventory_id',  v_wh_inv_id,
        'action',           'updated',
        'old_wh',           v_old_wh,
        'new_wh',           v_new_wh
      );
    ELSE
      v_wh_inv_id := gen_random_uuid();
      PERFORM set_config('app.source_event_id', v_wh_inv_id::text, true);

      INSERT INTO warehouse_inventory (
        wh_inventory_id, boonz_product_id, snapshot_date, warehouse_stock,
        consumer_stock, expiration_date, batch_id, status, warehouse_id,
        wh_location, created_at
      )
      VALUES (
        v_wh_inv_id, v_boonz_id, p_snapshot_date, v_new_wh,
        v_new_cs, v_exp_date, v_batch, v_status_val, p_warehouse_id,
        CASE WHEN v_loc_provided THEN v_new_loc ELSE NULL END, now()
      );

      INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at)
      VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, 0, v_new_wh, p_reason||' [new_row]', now());

      v_inserted := v_inserted + 1;
      v_details := v_details || jsonb_build_object(
        'boonz_product_id', v_boonz_id,
        'wh_inventory_id',  v_wh_inv_id,
        'action',           'inserted',
        'warehouse_stock',  v_new_wh,
        'expiration_date',  v_exp_date
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'status',           'ok',
    'warehouse',        v_wh_name,
    'warehouse_id',     p_warehouse_id,
    'lines_processed',  v_updated + v_inserted + v_unchanged,
    'lines_updated',    v_updated,
    'lines_inserted',   v_inserted,
    'lines_unchanged',  v_unchanged,
    'reason',           p_reason,
    'details',          v_details
  );
END;
$function$;

COMMIT;

-- ============================================================================
-- Verification (run separately, not in this migration):
--
-- 1. Function still has the same signature:
--    SELECT proname, pg_get_function_identity_arguments(oid) FROM pg_proc
--    WHERE proname='adjust_warehouse_stock';
--
-- 2. Smoke test the location path:
--    SELECT public.adjust_warehouse_stock(
--      (SELECT warehouse_id FROM warehouses WHERE name='WH_CENTRAL'),
--      jsonb_build_array(jsonb_build_object(
--        'wh_inventory_id', '<existing row uuid>',
--        'boonz_product_id', '<bp uuid>',
--        'new_warehouse_stock', <current qty>,
--        'wh_location', 'A3'
--      )),
--      CURRENT_DATE,
--      'smoke_test_location_only'
--    );
-- ============================================================================
