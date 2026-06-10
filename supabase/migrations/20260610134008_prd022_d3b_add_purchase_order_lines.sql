-- PRD-022 D3b — owner-only writer to append lines to an existing (open) PO.
-- Migration name: prd022_d3b_add_purchase_order_lines
-- Articles: 1 (operation-scoped canonical writer for "append to open PO"), 4 (DEFINER validates),
--           8 (audit), 12 (forward-only). Dara decided Option B (dedicated sibling writer).
--
-- Owner-only (operator_admin/superadmin). New lines reuse the existing PO's po_number / supplier_id /
-- purchase_date, pass create's exact line validation (blocked-product check, qty>0), regenerate the
-- driver task notes (DF2 mechanism), and audit. Refuses appends to a fully-received/closed PO.
-- The DF1 trigger trg_po_number_one_po_id skips this (NEW.po_id already exists), so reusing the
-- po_number is correct.

CREATE OR REPLACE FUNCTION public.add_purchase_order_lines(
  p_po_id text,
  p_lines jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id    uuid;
  v_role         text;
  v_po_number    integer;
  v_supplier_id  uuid;
  v_purchase_date date;
  v_line         jsonb;
  v_prod_name    text;
  v_block_reason text;
  v_added        integer := 0;
BEGIN
  v_caller_id := (SELECT auth.uid());

  -- Article 4: owner-only gate (stricter than create_purchase_order, per D3b).
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller_id;
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin') THEN
    RAISE EXCEPTION 'add_purchase_order_lines: forbidden for role % (owner-only)', COALESCE(v_role,'none');
  END IF;

  IF p_po_id IS NULL OR trim(p_po_id) = '' THEN
    RAISE EXCEPTION 'add_purchase_order_lines: p_po_id is required';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) != 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'add_purchase_order_lines: at least one line is required';
  END IF;

  -- Load the existing PO header (po_number/supplier_id/purchase_date reused for the new lines).
  SELECT po_number, supplier_id, purchase_date
    INTO v_po_number, v_supplier_id, v_purchase_date
    FROM public.purchase_orders
   WHERE po_id = p_po_id
   ORDER BY purchase_date
   LIMIT 1;
  IF v_po_number IS NULL AND v_supplier_id IS NULL THEN
    RAISE EXCEPTION 'add_purchase_order_lines: po_id % not found', p_po_id;
  END IF;

  -- Appendability guard: the PO must still have at least one open (un-received, un-cancelled) line.
  -- A fully received / fully cancelled PO is closed; a forgotten item is a NEW PO, not a graft.
  IF NOT EXISTS (
    SELECT 1 FROM public.purchase_orders
     WHERE po_id = p_po_id
       AND received_date IS NULL
       AND COALESCE(purchase_outcome,'') <> 'not_purchased'
  ) THEN
    RAISE EXCEPTION 'add_purchase_order_lines: PO % has no open lines (fully received or cancelled) - create a new PO instead', p_po_id;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'add_purchase_order_lines', true);

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF (v_line->>'boonz_product_id') IS NULL THEN
      RAISE EXCEPTION 'add_purchase_order_lines: boonz_product_id required in every line';
    END IF;
    IF COALESCE((v_line->>'ordered_qty')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'add_purchase_order_lines: ordered_qty must be > 0';
    END IF;

    SELECT boonz_product_name INTO v_prod_name
      FROM public.boonz_products
     WHERE product_id = (v_line->>'boonz_product_id')::uuid;

    -- PRD-1 guardrail (identical to create_purchase_order): never order a blocked product.
    v_block_reason := public.boonz_product_block_reason((v_line->>'boonz_product_id')::uuid);
    IF v_block_reason IS NOT NULL THEN
      RAISE EXCEPTION 'add_purchase_order_lines: product "%" is BLOCKED for ordering (rule: %). Remove this line.',
        COALESCE(v_prod_name, (v_line->>'boonz_product_id')), v_block_reason;
    END IF;

    INSERT INTO public.purchase_orders (
      po_id, po_number, supplier_id, boonz_product_id,
      purchase_date, ordered_qty,
      price_per_unit_aed, total_price_aed, expiry_date, received_date
    ) VALUES (
      p_po_id, v_po_number, v_supplier_id,
      (v_line->>'boonz_product_id')::uuid,
      COALESCE(v_purchase_date, CURRENT_DATE),
      (v_line->>'ordered_qty')::numeric,
      CASE WHEN v_line->>'price_per_unit_aed' IS NOT NULL
           THEN (v_line->>'price_per_unit_aed')::numeric ELSE NULL END,
      CASE WHEN v_line->>'price_per_unit_aed' IS NOT NULL
           THEN (v_line->>'ordered_qty')::numeric * (v_line->>'price_per_unit_aed')::numeric
           ELSE NULL END,
      CASE WHEN v_line->>'expiry_date' IS NOT NULL AND v_line->>'expiry_date' != ''
           THEN (v_line->>'expiry_date')::date ELSE NULL END,
      NULL
    );
    v_added := v_added + 1;
  END LOOP;

  -- DF2 mechanism: regenerate the driver task checklist from the now-larger open line set.
  UPDATE public.driver_tasks dt
  SET notes = COALESCE((
        SELECT string_agg(
                 COALESCE(bp.boonz_product_name, 'Unknown') || ' x' || po.ordered_qty::text,
                 ', ' ORDER BY bp.boonz_product_name)
        FROM public.purchase_orders po
        LEFT JOIN public.boonz_products bp ON bp.product_id = po.boonz_product_id
        WHERE po.po_id = p_po_id
          AND COALESCE(po.purchase_outcome, '') <> 'not_purchased'
      ), '(all lines cancelled)')
  WHERE dt.po_id = p_po_id
    AND dt.status IN ('pending', 'acknowledged');

  -- Audit (Article 8).
  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (
    p_po_id, 'lines_appended', v_caller_id,
    jsonb_build_object(
      'po_number',  v_po_number,
      'lines_added', v_added,
      'rpc_name',   'add_purchase_order_lines'
    )
  );

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'INSERT', p_po_id, v_caller_id, v_role,
    true, 'add_purchase_order_lines',
    jsonb_build_object('po_number', v_po_number, 'lines_added', v_added)
  );

  RETURN jsonb_build_object(
    'po_id',       p_po_id,
    'po_number',   v_po_number,
    'lines_added', v_added
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.add_purchase_order_lines(text, jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION public.add_purchase_order_lines(text, jsonb) IS
  'PRD-022 D3b. Owner-only (operator_admin/superadmin) append of lines to an existing OPEN PO. Reuses the PO po_number/supplier_id/purchase_date; same blocked-product + qty validation as create_purchase_order; regenerates driver_tasks.notes; audits. Refuses fully-received/cancelled POs. No new driver_task/notification (the PO already has one).';
