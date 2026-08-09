-- PRD-113 A3 — the warehouse return-approval queue excludes in-machine moves,
--                and every approve-a-return RPC refuses one outright.
--
-- Two layers, on purpose:
--   (1) the QUEUE stops offering the leg, so nobody is asked to approve phantom stock;
--   (2) the RPCs REFUSE it, so a stale FE tab, a direct call or a script cannot credit it
--       anyway. Layer 2 is the real guard; layer 1 is the ergonomics.
--
-- Both layers read the SAME predicate, public.is_internal_move_dispatch (Article 16), so a
-- leg the trigger somehow failed to stamp is still caught live.
--
-- The genuine M2W / driver-return flow is byte-identical except for this one exclusion:
-- every other predicate, message, side effect and return shape below is unchanged.
--
-- ADDITIVE ONLY: CREATE OR REPLACE on three existing functions and one existing view. No
-- signature changes, no drops, no data writes.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE QUEUE
-- ─────────────────────────────────────────────────────────────────────────────
-- Unchanged from the PRD-054-A / PRD-070 body except for the final AND.
CREATE OR REPLACE VIEW public.v_pending_wh_remove_confirmations AS
 SELECT rd.dispatch_id,
    m.official_name AS machine,
    bp.boonz_product_name,
    rd.quantity AS planned_qty,
    rd.driver_confirmed_qty,
    rd.driver_confirmed_breakdown,
    rd.driver_confirmed_at,
    rd.driver_confirmed_by,
    rd.expiry_date AS dispatch_expiry,
    rd.comment,
    EXTRACT(epoch FROM now() - rd.driver_confirmed_at) / 3600.0 AS hours_awaiting_approval
   FROM refill_dispatching rd
     JOIN machines m ON m.machine_id = rd.machine_id
     JOIN boonz_products bp ON bp.product_id = rd.boonz_product_id
  WHERE rd.action = 'Remove'::text
    AND rd.driver_confirmed_at IS NOT NULL
    AND rd.wh_approved_at IS NULL
    AND COALESCE(rd.item_added, false) = false
    AND COALESCE(rd.returned,   false) = false
    AND COALESCE(rd.is_m2m,     false) = false
    -- PRD-113: an in-machine move is not a warehouse return. The units are still in the
    -- machine, one shelf over. There is nothing to receive and nothing to credit.
    AND NOT COALESCE(public.is_internal_move_dispatch(rd.dispatch_id), false)
  ORDER BY rd.driver_confirmed_at;

COMMENT ON VIEW public.v_pending_wh_remove_confirmations IS
  'Warehouse return-approval queue: Remove legs a driver confirmed that the WH manager has '
  'not yet verified. Excludes M2M transfer legs (PRD-070) and, since PRD-113, in-machine '
  'move legs — product relocated to another shelf of the SAME machine never reaches the '
  'warehouse, so crediting it would create phantom stock.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE APPROVE GUARDS
-- ─────────────────────────────────────────────────────────────────────────────
-- Placed immediately after the existing is_m2m guard in each function: same position, same
-- shape, same failure mode. Everything else is the shipped body, unchanged.

CREATE OR REPLACE FUNCTION public.wh_approve_remove_receipt(
  p_dispatch_id uuid,
  p_actual_qty numeric DEFAULT NULL::numeric,
  p_batch_breakdown jsonb DEFAULT NULL::jsonb,
  p_approved_by uuid DEFAULT NULL::uuid,
  p_reason text DEFAULT 'WH manager verified physical receipt'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_final_qty numeric;
  v_final_breakdown jsonb;
  v_receive_result jsonb;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.action <> 'Remove' THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt only for action=Remove (got %)', v_dispatch.action;
  END IF;
  IF COALESCE(v_dispatch.is_m2m, false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt: dispatch % is an M2M transfer leg - approve via approve_m2m_transfer(%) (no warehouse credit; stock moves to the destination machine).',
      p_dispatch_id, COALESCE(v_dispatch.m2m_transfer_id::text, 'NULL m2m_transfer_id - needs pairing backfill first');
  END IF;
  -- PRD-113 hard guard: an in-machine move must NEVER be credited to the warehouse.
  IF COALESCE(public.is_internal_move_dispatch(p_dispatch_id), false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt: dispatch % is an INTERNAL MOVE - nothing to credit. These units moved to another shelf of the SAME machine (%) and never reached the warehouse; approving would create phantom warehouse stock. If this really is a warehouse return, call clear_internal_move_flag(%, <reason>) first - it is the only sanctioned way to re-open this credit, it requires a 10+ character reason, and it is durable.',
      p_dispatch_id, v_dispatch.machine_id, p_dispatch_id;
  END IF;
  IF v_dispatch.item_added THEN
    RAISE EXCEPTION 'Dispatch % already approved (item_added=true at %)',
      p_dispatch_id, v_dispatch.wh_approved_at;
  END IF;
  IF v_dispatch.returned THEN
    RAISE EXCEPTION 'Dispatch already marked returned';
  END IF;

  v_final_qty := COALESCE(p_actual_qty, v_dispatch.driver_confirmed_qty);
  v_final_breakdown := COALESCE(p_batch_breakdown, v_dispatch.driver_confirmed_breakdown);
  IF v_final_qty IS NULL THEN
    RAISE EXCEPTION 'No qty available - driver did not confirm and p_actual_qty was NULL. Use approve_stuck_remove for orphans.';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'wh_approve_remove_receipt', true);
  PERFORM set_config('app.mutation_reason',
    format('wh_approve_remove_receipt by %s: %s units verified (driver said %s, WH says %s) - %s',
      COALESCE(p_approved_by::text, 'wh_manager'),
      v_final_qty,
      COALESCE(v_dispatch.driver_confirmed_qty::text, 'none'),
      v_final_qty,
      p_reason), true);

  UPDATE refill_dispatching SET
    wh_approved_at = now(),
    wh_approved_by = p_approved_by
  WHERE dispatch_id = p_dispatch_id;

  v_receive_result := receive_dispatch_line(p_dispatch_id, v_final_qty, p_approved_by, v_final_breakdown);

  RETURN jsonb_build_object(
    'status', 'wh_approved',
    'dispatch_id', p_dispatch_id,
    'driver_said_qty', v_dispatch.driver_confirmed_qty,
    'wh_verified_qty', v_final_qty,
    'discrepancy', v_final_qty - COALESCE(v_dispatch.driver_confirmed_qty, v_final_qty),
    'approved_by', p_approved_by,
    'reason', p_reason,
    'receive_result', v_receive_result
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.wh_approve_remove_receipt_multivariant(
  p_parent_dispatch_id uuid,
  p_variant_breakdown jsonb,
  p_approved_by uuid DEFAULT NULL::uuid,
  p_reason text DEFAULT 'WH manager verified per-variant physical receipt'::text)
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
  -- PRD-113 hard guard: an in-machine move must NEVER be credited to the warehouse.
  IF COALESCE(public.is_internal_move_dispatch(p_parent_dispatch_id), false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt_multivariant: dispatch % is an INTERNAL MOVE - nothing to credit. These units moved to another shelf of the SAME machine (%) and never reached the warehouse; approving would create phantom warehouse stock. If this really is a warehouse return, call clear_internal_move_flag(%, <reason>) first - it is the only sanctioned way to re-open this credit, it requires a 10+ character reason, and it is durable.',
      p_parent_dispatch_id, v_parent.machine_id, p_parent_dispatch_id;
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

    -- NOTE (PRD-113): these child rows are born wh_approved_at = now(), so
    -- tg_mark_internal_move_pair leaves them alone by construction — its UPDATE arm only
    -- touches legs with wh_approved_at IS NULL. A settled credit is never relabelled.
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


CREATE OR REPLACE FUNCTION public.approve_stuck_remove(
  p_dispatch_id uuid,
  p_qty_received numeric,
  p_batch_breakdown jsonb DEFAULT NULL::jsonb,
  p_approved_by uuid DEFAULT NULL::uuid,
  p_reason text DEFAULT 'Driver did not confirm in field — manually approved by WH manager'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_receive_result jsonb;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.action <> 'Remove' THEN
    RAISE EXCEPTION 'approve_stuck_remove only works for action=Remove (got %)', v_dispatch.action;
  END IF;
  -- PRD-113 hard guard: the orphan path credits the warehouse exactly like the two
  -- wh_approve_* RPCs, so it needs the identical refusal. Without it this is the back door.
  IF COALESCE(public.is_internal_move_dispatch(p_dispatch_id), false) THEN
    RAISE EXCEPTION 'approve_stuck_remove: dispatch % is an INTERNAL MOVE - nothing to credit. These units moved to another shelf of the SAME machine (%) and never reached the warehouse; approving would create phantom warehouse stock. If this really is a warehouse return, call clear_internal_move_flag(%, <reason>) first - it is the only sanctioned way to re-open this credit, it requires a 10+ character reason, and it is durable.',
      p_dispatch_id, v_dispatch.machine_id, p_dispatch_id;
  END IF;
  IF v_dispatch.item_added THEN
    RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id;
  END IF;
  IF v_dispatch.returned THEN
    RAISE EXCEPTION 'Dispatch % already marked returned', p_dispatch_id;
  END IF;
  IF NOT v_dispatch.packed THEN
    RAISE EXCEPTION 'Dispatch % not yet packed', p_dispatch_id;
  END IF;
  IF p_qty_received IS NULL OR p_qty_received < 0 THEN
    RAISE EXCEPTION 'p_qty_received must be >= 0';
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('approve_stuck_remove by %s: %s (planned %s, received %s)',
      COALESCE(p_approved_by::text, 'wh_manager'), p_reason,
      v_dispatch.quantity, p_qty_received), true);

  -- Hand off to canonical receive_dispatch_line for REMOVE so all credit/archival logic stays in one place
  v_receive_result := receive_dispatch_line(p_dispatch_id, p_qty_received, p_approved_by, p_batch_breakdown);

  RETURN jsonb_build_object(
    'status', 'approved_remove',
    'dispatch_id', p_dispatch_id,
    'product', (SELECT boonz_product_name FROM boonz_products WHERE product_id = v_dispatch.boonz_product_id),
    'planned_qty', v_dispatch.quantity,
    'qty_received', p_qty_received,
    'approved_by', p_approved_by,
    'reason', p_reason,
    'receive_result', v_receive_result
  );
END;
$function$;
