-- PRD-141 item 7 (B3): a receipt expiry edit changes the batch.
-- edit_purchase_order_line already allows a post-receipt expiry correction (PRD-103) but only updated
-- purchase_orders. It now also moves every Active, in-stock warehouse_inventory row of that PO line
-- (batch_id = po_id || '-' || left(po_line_id, 8) || '-B<n>') that still carries the OLD expiry to the
-- new one, logs each row to wh_batch_expiry_audit_log, and returns wh_batches_updated. Only rows with
-- the old date move: 154 of 1,067 PO-line batch groups hold more than one expiry and must not be merged.
-- Packed units already left the row (consumer_stock), and pinned dispatch lines follow through the
-- existing trg_sync_dispatch_expiry_from_pinned_wh.
-- The spec names the RPC edit_po_line_expiry; the existing edit_purchase_order_line is the one the
-- drawer calls, so it is extended instead of adding a second writer.
-- Rollback: supabase/rollbacks/prd141_07_rollback.sql.

DO $patch$
DECLARE
  v_def text; n int; i int;
  pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.edit_purchase_order_line(uuid,numeric,numeric,date,text)'::regprocedure);
  pairs := ARRAY[
    ARRAY['  v_post_receipt_expiry boolean; -- PRD-103',
          '  v_post_receipt_expiry boolean; -- PRD-103' || chr(10) || '  v_wh_batches_updated  integer := 0; -- PRD-141 item 7'],
    ARRAY['  RETURN jsonb_build_object(' || chr(10) || '    ''po_line_id'',               p_po_line_id,',
          '  -- PRD-141 item 7: move the received batches that still carry the old expiry.' || chr(10)
          || '  IF v_lock_level = ''received'' AND (v_before->>''expiry_date'') IS DISTINCT FROM v_new_expiry::text AND v_new_expiry IS NOT NULL THEN' || chr(10)
          || '    WITH moved AS (' || chr(10)
          || '      UPDATE public.warehouse_inventory wi' || chr(10)
          || '         SET expiration_date = v_new_expiry' || chr(10)
          || '       WHERE wi.batch_id LIKE v_line.po_id::text || ''-'' || left(p_po_line_id::text, 8) || ''-B%''' || chr(10)
          || '         AND wi.boonz_product_id = v_line.boonz_product_id' || chr(10)
          || '         AND wi.expiration_date IS NOT DISTINCT FROM (v_before->>''expiry_date'')::date' || chr(10)
          || '         AND wi.status = ''Active'' AND COALESCE(wi.warehouse_stock, 0) > 0' || chr(10)
          || '      RETURNING wi.wh_inventory_id' || chr(10)
          || '    ), logged AS (' || chr(10)
          || '      INSERT INTO public.wh_batch_expiry_audit_log (wh_inventory_id, old_expiration_date, new_expiration_date, changed_by, reason)' || chr(10)
          || '      SELECT moved.wh_inventory_id, (v_before->>''expiry_date'')::date, v_new_expiry, v_user_id,' || chr(10)
          || '             format(''edit_purchase_order_line %s: %s'', p_po_line_id, p_reason)' || chr(10)
          || '        FROM moved' || chr(10)
          || '      RETURNING 1' || chr(10)
          || '    )' || chr(10)
          || '    SELECT count(*) INTO v_wh_batches_updated FROM logged;' || chr(10)
          || '  END IF;' || chr(10) || chr(10)
          || '  RETURN jsonb_build_object(' || chr(10) || '    ''wh_batches_updated'',       v_wh_batches_updated,' || chr(10) || '    ''po_line_id'',               p_po_line_id,']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd141_07: anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

REVOKE EXECUTE ON FUNCTION public.edit_purchase_order_line(uuid, numeric, numeric, date, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.edit_purchase_order_line(uuid, numeric, numeric, date, text) TO authenticated, service_role;
