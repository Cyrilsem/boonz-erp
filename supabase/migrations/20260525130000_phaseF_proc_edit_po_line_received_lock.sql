-- PRD-002: per-line received-state guard on edit_purchase_order_line.
-- Received lines (received_qty > 0 OR purchase_outcome = 'received') become
-- superadmin-only. lock_level recorded in procurement_events, write_audit_log,
-- and return jsonb so the audit history can differentiate normal edits from
-- superadmin overrides. Forward-only CREATE OR REPLACE, same 5-arg signature.
-- Cody-approved against Articles 1, 4, 5, 8, 12.

CREATE OR REPLACE FUNCTION public.edit_purchase_order_line(
  p_po_line_id uuid,
  p_new_ordered_qty numeric DEFAULT NULL,
  p_new_price_per_unit_aed numeric DEFAULT NULL,
  p_new_expiry_date date DEFAULT NULL,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller_role     text;
  v_user_id         uuid;
  v_line            public.purchase_orders%ROWTYPE;
  v_new_ordered_qty numeric;
  v_new_price       numeric;
  v_new_expiry      date;
  v_new_total       numeric;
  v_before          jsonb;
  v_after           jsonb;
  v_lock_level      text;
BEGIN
  v_user_id := auth.uid();
  SELECT role INTO v_caller_role
    FROM public.user_profiles WHERE id = v_user_id;

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'edit_purchase_order_line: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'edit_purchase_order_line: reason is required (>= 10 chars)';
  END IF;

  SELECT * INTO v_line
    FROM public.purchase_orders
   WHERE po_line_id = p_po_line_id
   FOR UPDATE;
  IF v_line.po_line_id IS NULL THEN
    RAISE EXCEPTION 'edit_purchase_order_line: po_line_id % not found', p_po_line_id;
  END IF;

  v_lock_level := CASE
    WHEN COALESCE(v_line.received_qty, 0) > 0
         OR v_line.purchase_outcome = 'received'
      THEN 'received'
    ELSE 'unreceived'
  END;

  IF v_lock_level = 'received' AND v_caller_role <> 'superadmin' THEN
    RAISE EXCEPTION 'edit_purchase_order_line: line is already received; only superadmin can edit (received_qty=%, outcome=%)',
      v_line.received_qty, COALESCE(v_line.purchase_outcome, '(null)');
  END IF;

  v_new_ordered_qty := COALESCE(p_new_ordered_qty,         v_line.ordered_qty);
  v_new_price       := COALESCE(p_new_price_per_unit_aed,  v_line.price_per_unit_aed);
  v_new_expiry      := COALESCE(p_new_expiry_date,         v_line.expiry_date);
  v_new_total       := CASE
                         WHEN v_new_ordered_qty IS NOT NULL AND v_new_price IS NOT NULL
                           THEN v_new_ordered_qty * v_new_price
                         ELSE NULL
                       END;

  IF v_new_ordered_qty IS NOT DISTINCT FROM v_line.ordered_qty
     AND v_new_price   IS NOT DISTINCT FROM v_line.price_per_unit_aed
     AND v_new_expiry  IS NOT DISTINCT FROM v_line.expiry_date
  THEN
    RAISE EXCEPTION 'edit_purchase_order_line: no changes detected (all three fields already match the submitted values)';
  END IF;

  IF v_line.received_qty IS NOT NULL
     AND v_new_ordered_qty < v_line.received_qty
  THEN
    RAISE EXCEPTION 'edit_purchase_order_line: new ordered_qty (%) < received_qty (%). Reverse receipt first.',
      v_new_ordered_qty, v_line.received_qty;
  END IF;

  v_before := jsonb_build_object(
    'ordered_qty',        v_line.ordered_qty,
    'price_per_unit_aed', v_line.price_per_unit_aed,
    'total_price_aed',    v_line.total_price_aed,
    'expiry_date',        v_line.expiry_date
  );

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'edit_purchase_order_line', true);

  UPDATE public.purchase_orders
     SET ordered_qty        = v_new_ordered_qty,
         price_per_unit_aed = v_new_price,
         expiry_date        = v_new_expiry,
         total_price_aed    = v_new_total,
         last_edited_at     = now(),
         last_edited_by     = v_user_id
   WHERE po_line_id = p_po_line_id
   RETURNING * INTO v_line;

  v_after := jsonb_build_object(
    'ordered_qty',        v_line.ordered_qty,
    'price_per_unit_aed', v_line.price_per_unit_aed,
    'total_price_aed',    v_line.total_price_aed,
    'expiry_date',        v_line.expiry_date
  );

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (
    v_line.po_id,
    'po_line_edited',
    v_user_id,
    jsonb_build_object(
      'po_line_id',  p_po_line_id,
      'before',      v_before,
      'after',       v_after,
      'reason',      p_reason,
      'actor_role',  v_caller_role,
      'lock_level',  v_lock_level
    )
  );

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'UPDATE', p_po_line_id::text, v_user_id, v_caller_role,
    true, 'edit_purchase_order_line',
    jsonb_build_object('po_id', v_line.po_id, 'before', v_before, 'after', v_after, 'reason', p_reason, 'lock_level', v_lock_level)
  );

  RETURN jsonb_build_object(
    'po_line_id', p_po_line_id,
    'po_id',      v_line.po_id,
    'before',     v_before,
    'after',      v_after,
    'reason',     p_reason,
    'lock_level', v_lock_level,
    'edited_at',  v_line.last_edited_at,
    'edited_by',  v_user_id
  );
END;
$function$;
