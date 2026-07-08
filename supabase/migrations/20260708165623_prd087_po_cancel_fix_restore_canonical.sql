-- PRD-087 FIX: the previous migration (prd087_po_edit_cancel_rpcs) wrongly
-- replaced the CANONICAL cancel_po_line (PRD-022 DF2: role gate, reason
-- >=10 chars, via_rpc GUCs, driver-task notes regeneration,
-- procurement_events + write_audit_log). Restore it VERBATIM, drop the
-- redundant update_po_line (edit_purchase_order_line is canonical), and
-- re-implement cancel_po (whole-PO cancel, the new CS feature) as a loop
-- over the canonical cancel_po_line so every side effect fires per line.

DROP FUNCTION IF EXISTS public.update_po_line(uuid, numeric, numeric, date);
DROP FUNCTION IF EXISTS public.cancel_po(text, text);
DROP FUNCTION IF EXISTS public.cancel_po_line(uuid, text);

-- ── canonical cancel_po_line (verbatim from prd022_df2) ─────────────────
CREATE OR REPLACE FUNCTION public.cancel_po_line(p_po_line_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller_id    uuid;
  v_caller_role  text;
  v_line         purchase_orders%ROWTYPE;
  v_before       jsonb;
  v_after        jsonb;
BEGIN
  v_caller_id := auth.uid();

  SELECT role INTO v_caller_role
  FROM public.user_profiles WHERE id = v_caller_id;

  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'cancel_po_line: forbidden for role %', COALESCE(v_caller_role,'(none)');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'cancel_po_line: reason is required (>=10 chars)';
  END IF;

  SELECT * INTO v_line FROM public.purchase_orders
  WHERE po_line_id = p_po_line_id FOR UPDATE;

  IF v_line.po_line_id IS NULL THEN
    RAISE EXCEPTION 'cancel_po_line: po_line_id % not found', p_po_line_id;
  END IF;

  IF v_line.purchase_outcome = 'not_purchased' THEN
    RAISE EXCEPTION 'cancel_po_line: line already marked not_purchased (no-op)';
  END IF;

  IF v_line.purchase_outcome = 'received' OR COALESCE(v_line.received_qty, 0) > 0 THEN
    RAISE EXCEPTION 'cancel_po_line: cannot cancel a received line (received_qty=%, outcome=%). Reverse the receipt first.',
      v_line.received_qty, COALESCE(v_line.purchase_outcome,'(null)');
  END IF;

  v_before := jsonb_build_object(
    'purchase_outcome', v_line.purchase_outcome,
    'received_qty',     v_line.received_qty,
    'received_date',    v_line.received_date
  );

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'cancel_po_line', true);

  UPDATE public.purchase_orders
  SET purchase_outcome = 'not_purchased',
      last_edited_at   = now(),
      last_edited_by   = v_caller_id
  WHERE po_line_id = p_po_line_id
  RETURNING * INTO v_line;

  v_after := jsonb_build_object(
    'purchase_outcome', v_line.purchase_outcome,
    'received_qty',     v_line.received_qty,
    'received_date',    v_line.received_date
  );

  -- DF2: rebuild the driver task checklist from the lines that remain (this one is now cancelled).
  -- Only touch a still-actionable task; once collected/cancelled the driver has already acted.
  UPDATE public.driver_tasks dt
  SET notes = COALESCE((
        SELECT string_agg(
                 COALESCE(bp.boonz_product_name, 'Unknown') || ' x' || po.ordered_qty::text,
                 ', ' ORDER BY bp.boonz_product_name)
        FROM public.purchase_orders po
        LEFT JOIN public.boonz_products bp ON bp.product_id = po.boonz_product_id
        WHERE po.po_id = v_line.po_id
          AND COALESCE(po.purchase_outcome, '') <> 'not_purchased'
      ), '(all lines cancelled)')
  WHERE dt.po_id = v_line.po_id
    AND dt.status IN ('pending', 'acknowledged');

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (
    v_line.po_id, 'line_not_purchased', v_caller_id,
    jsonb_build_object(
      'po_line_id',       p_po_line_id,
      'boonz_product_id', v_line.boonz_product_id,
      'before',           v_before,
      'after',            v_after,
      'reason',           p_reason,
      'rpc_name',         'cancel_po_line'
    )
  );

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'UPDATE', p_po_line_id::text,
    v_caller_id, v_caller_role, true, 'cancel_po_line',
    jsonb_build_object('before', v_before, 'after', v_after, 'reason', p_reason)
  );

  RETURN jsonb_build_object(
    'po_line_id', p_po_line_id,
    'po_id',      v_line.po_id,
    'before',     v_before,
    'after',      v_after,
    'reason',     p_reason,
    'cancelled_at', v_line.last_edited_at,
    'cancelled_by', v_caller_id
  );
END;
$function$;

-- ── NEW: cancel_po — whole-PO cancel via the canonical line RPC ──────────
CREATE OR REPLACE FUNCTION public.cancel_po(p_po_number text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_received int;
  v_line record;
  v_count int := 0;
BEGIN
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'cancel_po: reason is required (>=10 chars)';
  END IF;

  SELECT count(*) FILTER (WHERE purchase_outcome = 'received' OR COALESCE(received_qty,0) > 0)
  INTO v_received
  FROM public.purchase_orders WHERE po_number::text = p_po_number;

  IF v_received > 0 THEN
    RAISE EXCEPTION 'cancel_po: % line(s) already received on PO % — reverse receipts first', v_received, p_po_number;
  END IF;

  FOR v_line IN
    SELECT po_line_id FROM public.purchase_orders
    WHERE po_number::text = p_po_number AND purchase_outcome IS NULL
  LOOP
    -- delegate to the canonical writer so role gate, driver-note
    -- regeneration, procurement_events and write_audit_log all fire
    PERFORM public.cancel_po_line(v_line.po_line_id, p_reason);
    v_count := v_count + 1;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'cancel_po: no open lines on PO %', p_po_number;
  END IF;

  RETURN jsonb_build_object('ok', true, 'po_number', p_po_number, 'cancelled_lines', v_count);
END;
$function$;

COMMENT ON FUNCTION public.cancel_po(text, text) IS
'PRD-087: cancel an entire unreceived PO — loops the canonical cancel_po_line per open line (audit + driver-note regeneration preserved). Blocked if any line received.';
