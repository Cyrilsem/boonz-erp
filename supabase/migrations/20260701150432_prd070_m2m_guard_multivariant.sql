-- PRD-070 sibling guard: wh_approve_remove_receipt_multivariant REJECTS is_m2m rows.
-- APPLIED 2026-07-01 (schema_migrations version 20260701150432). Faithful CREATE OR REPLACE of the live
-- body with the is_m2m reject added after the parent action=Remove check (points to approve_m2m_transfer).
-- No other logic changed. Cody approved with the main PRD-070 migration.

CREATE OR REPLACE FUNCTION public.wh_approve_remove_receipt_multivariant(p_parent_dispatch_id uuid, p_variant_breakdown jsonb, p_approved_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'WH manager verified per-variant physical receipt'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_parent refill_dispatching%ROWTYPE;
  v_entry jsonb;
  v_entry_bpid uuid;
  v_entry_qty numeric;
  v_entry_expiry date;
  v_breakdown_total numeric := 0;
  v_child_id uuid;
  v_child_ids uuid[] := ARRAY[]::uuid[];
  v_child_results jsonb := '[]'::jsonb;
  v_receive_result jsonb;
  v_final_qty numeric;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'wh_approve_remove_receipt_multivariant', true);

  SELECT * INTO v_parent FROM refill_dispatching
  WHERE dispatch_id = p_parent_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent dispatch % not found', p_parent_dispatch_id;
  END IF;
  IF v_parent.action <> 'Remove' THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt_multivariant requires action=Remove (got %)', v_parent.action;
  END IF;
  -- PRD-070 hard guard: an M2M transfer leg must NEVER go through the warehouse-return path.
  IF COALESCE(v_parent.is_m2m, false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt_multivariant: dispatch % is an M2M transfer leg - approve via approve_m2m_transfer(%) (no warehouse credit; stock moves to the destination machine).',
      p_parent_dispatch_id, COALESCE(v_parent.m2m_transfer_id::text, 'NULL m2m_transfer_id - needs pairing backfill first');
  END IF;
  IF v_parent.item_added THEN
    RAISE EXCEPTION 'Parent dispatch % already approved at %', p_parent_dispatch_id, v_parent.wh_approved_at;
  END IF;
  IF v_parent.returned THEN
    RAISE EXCEPTION 'Parent dispatch % already returned', p_parent_dispatch_id;
  END IF;

  IF p_variant_breakdown IS NULL OR jsonb_typeof(p_variant_breakdown) <> 'array' THEN
    RAISE EXCEPTION 'p_variant_breakdown must be a JSONB array of {boonz_product_id, qty, expiry}';
  END IF;
  SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total
  FROM jsonb_array_elements(p_variant_breakdown) e;

  v_final_qty := COALESCE(v_parent.driver_confirmed_qty, ABS(v_parent.quantity));
  IF v_breakdown_total <> v_final_qty THEN
    RAISE EXCEPTION 'Variant breakdown total (%) must equal driver_confirmed_qty / parent.quantity (%)',
      v_breakdown_total, v_final_qty;
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('Multi-variant remove approval on dispatch %s: %s variants, total %s units (driver said %s) - %s',
      p_parent_dispatch_id,
      jsonb_array_length(p_variant_breakdown),
      v_breakdown_total,
      COALESCE(v_parent.driver_confirmed_qty::text, 'null'),
      p_reason),
    true);

  UPDATE refill_dispatching SET
    wh_approved_at = now(),
    wh_approved_by = p_approved_by
  WHERE dispatch_id = p_parent_dispatch_id;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_variant_breakdown)
  LOOP
    v_entry_bpid := NULLIF(v_entry->>'boonz_product_id', '')::uuid;
    v_entry_qty  := (v_entry->>'qty')::numeric;
    v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;

    IF v_entry_bpid IS NULL THEN
      RAISE EXCEPTION 'Variant entry missing boonz_product_id: %', v_entry;
    END IF;
    IF v_entry_qty <= 0 THEN CONTINUE; END IF;

    IF NOT EXISTS (SELECT 1 FROM boonz_products WHERE product_id = v_entry_bpid) THEN
      RAISE EXCEPTION 'Variant boonz_product_id % does not exist', v_entry_bpid;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM product_mapping
      WHERE pod_product_id = v_parent.pod_product_id
        AND boonz_product_id = v_entry_bpid
        AND status = 'Active'
    ) THEN
      RAISE EXCEPTION 'Variant boonz_product_id % is not mapped to parent pod_product_id %',
        v_entry_bpid, v_parent.pod_product_id;
    END IF;

    INSERT INTO refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id,
       dispatch_date, action, quantity, filled_quantity, include,
       packed, picked_up, dispatched, returned, item_added,
       expiry_date, from_warehouse_id,
       wh_approved_at, wh_approved_by, comment)
    VALUES
      (v_parent.machine_id, v_parent.shelf_id, v_parent.pod_product_id, v_entry_bpid,
       v_parent.dispatch_date, 'Remove', v_entry_qty, 0, true,
       false, false, false, false, false,
       v_entry_expiry, v_parent.from_warehouse_id,
       now(), p_approved_by,
       format('[multi-variant child of %s] %s', p_parent_dispatch_id, p_reason))
    RETURNING dispatch_id INTO v_child_id;

    v_child_ids := array_append(v_child_ids, v_child_id);

    v_receive_result := receive_dispatch_line(
      v_child_id,
      v_entry_qty,
      p_approved_by,
      CASE
        WHEN v_entry_expiry IS NOT NULL
        THEN jsonb_build_array(jsonb_build_object('expiry', v_entry_expiry, 'qty', v_entry_qty))
        ELSE NULL
      END
    );

    v_child_results := v_child_results || jsonb_build_object(
      'child_dispatch_id',  v_child_id,
      'boonz_product_id',   v_entry_bpid,
      'qty',                v_entry_qty,
      'expiry',             v_entry_expiry,
      'receive_path',       v_receive_result->>'path'
    );
  END LOOP;

  UPDATE refill_dispatching SET
    returned       = true,
    item_added     = false,
    packed         = true,
    picked_up      = true,
    dispatched     = true,
    return_reason  = format('split_into_%s_variants_see_children',
                            COALESCE(array_length(v_child_ids, 1), 0))
  WHERE dispatch_id = p_parent_dispatch_id;

  RETURN jsonb_build_object(
    'status',              'wh_approved_multivariant',
    'parent_dispatch_id',  p_parent_dispatch_id,
    'driver_said_qty',     v_parent.driver_confirmed_qty,
    'wh_verified_qty',     v_final_qty,
    'variant_count',       COALESCE(array_length(v_child_ids, 1), 0),
    'child_dispatch_ids',  v_child_ids,
    'children',            v_child_results,
    'approved_by',         p_approved_by,
    'reason',              p_reason
  );
END;
$function$;
