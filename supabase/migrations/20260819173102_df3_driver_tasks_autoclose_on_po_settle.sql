-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- DF3: cancel_po_line, after the DF2 notes rebuild, closes the open driver_tasks row once zero
-- actionable lines remain on the PO ('collected' if >=1 line was received, else 'cancelled'),
-- appending an [auto-closed by cancel_po_line] marker. cancel_po delegates and inherits the fix.

create or replace function public.cancel_po_line(p_po_line_id uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_caller_id    uuid;
  v_caller_role  text;
  v_line         purchase_orders%ROWTYPE;
  v_before       jsonb;
  v_after        jsonb;
  v_open_lines     integer;
  v_received_lines integer;
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

  -- DF3: if no actionable lines remain on this PO, close the open driver task.
  -- 'collected' when at least one line was actually received, else 'cancelled'.
  SELECT count(*) FILTER (WHERE po.purchase_outcome IS NULL
                             OR po.purchase_outcome NOT IN ('received','not_purchased')),
         count(*) FILTER (WHERE po.purchase_outcome = 'received')
  INTO v_open_lines, v_received_lines
  FROM public.purchase_orders po
  WHERE po.po_id = v_line.po_id;

  IF v_open_lines = 0 THEN
    UPDATE public.driver_tasks dt
       SET status          = CASE WHEN v_received_lines > 0 THEN 'collected' ELSE 'cancelled' END,
           collected_at    = CASE WHEN v_received_lines > 0 THEN COALESCE(dt.collected_at, now()) ELSE dt.collected_at END,
           outcome_comment = COALESCE(dt.outcome_comment,'')
                             || '[auto-closed by cancel_po_line: no actionable lines remain on PO]'
     WHERE dt.po_id = v_line.po_id
       AND dt.status IN ('pending','acknowledged');
  END IF;

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
