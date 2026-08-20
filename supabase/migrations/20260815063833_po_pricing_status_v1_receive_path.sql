-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Part 3/4 of the 2026-08-15 pricing_status rollout (see 20260815092204_po_pricing_status_v1.sql).
-- Bodies below are as of this migration (pre-DF3); the DF3 auto-close terminal block added
-- 2026-08-19 lives in df3_receive_purchase_order_autoclose_task, not here.

create or replace function public._mirror_po_addition_line_v1(p_addition_id uuid, p_actor_id uuid default null::uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
DECLARE
  v_a             public.po_additions%ROWTYPE;
  v_po_number     integer;
  v_supplier_id   uuid;
  v_purchase_date date;
  v_line_id       uuid;
  v_unit          numeric;
  v_total         numeric;
  v_today         date := CURRENT_DATE;
  v_actor         uuid := COALESCE(p_actor_id, (SELECT auth.uid()));
BEGIN
  IF p_addition_id IS NULL THEN RETURN NULL; END IF;

  SELECT * INTO v_a FROM public.po_additions WHERE addition_id = p_addition_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT po_line_id INTO v_line_id
    FROM public.purchase_orders WHERE source_addition_id = p_addition_id;
  IF v_line_id IS NOT NULL THEN RETURN v_line_id; END IF;

  SELECT po_number, supplier_id, purchase_date
    INTO v_po_number, v_supplier_id, v_purchase_date
    FROM public.purchase_orders WHERE po_id = v_a.po_id
    ORDER BY purchase_date LIMIT 1;

  IF v_po_number IS NULL AND v_supplier_id IS NULL THEN RETURN NULL; END IF;

  v_unit  := COALESCE(v_a.price_per_unit_aed,
                      CASE WHEN v_a.total_price_aed IS NOT NULL AND v_a.qty > 0
                           THEN ROUND(v_a.total_price_aed / v_a.qty, 4) END);
  v_total := COALESCE(v_a.total_price_aed,
                      CASE WHEN v_a.price_per_unit_aed IS NOT NULL
                           THEN ROUND(v_a.qty * v_a.price_per_unit_aed, 2) END);

  INSERT INTO public.purchase_orders (
    po_id, po_number, supplier_id, boonz_product_id, purchase_date,
    ordered_qty, received_qty, price_per_unit_aed, total_price_aed,
    expiry_date, received_date, purchase_outcome, source_addition_id,
    pricing_status
  ) VALUES (
    v_a.po_id, v_po_number, v_supplier_id, v_a.boonz_product_id,
    COALESCE(v_purchase_date, v_today),
    v_a.qty, v_a.qty, v_unit, v_total,
    v_a.expiry_date, COALESCE(v_a.received_at::date, v_today), 'received', p_addition_id,
    v_a.pricing_status
  )
  ON CONFLICT (source_addition_id) WHERE source_addition_id IS NOT NULL DO NOTHING
  RETURNING po_line_id INTO v_line_id;

  IF v_line_id IS NULL THEN
    SELECT po_line_id INTO v_line_id
      FROM public.purchase_orders WHERE source_addition_id = p_addition_id;
    RETURN v_line_id;
  END IF;

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (v_a.po_id, 'po_addition_line_mirrored', v_actor,
    jsonb_build_object('addition_id', p_addition_id, 'po_line_id', v_line_id,
      'boonz_product_id', v_a.boonz_product_id, 'qty', v_a.qty,
      'price_per_unit_aed', v_unit, 'total_price_aed', v_total,
      'pricing_status', v_a.pricing_status,
      'note', 'financial mirror only - no warehouse batch created by this write'));

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'INSERT', v_line_id::text, v_actor,
    (SELECT role FROM public.user_profiles WHERE id = v_actor),
    true, '_mirror_po_addition_line_v1',
    jsonb_build_object('po_id', v_a.po_id, 'addition_id', p_addition_id,
                       'qty', v_a.qty, 'total_price_aed', v_total,
                       'pricing_status', v_a.pricing_status));

  RETURN v_line_id;
END;
$function$;

create or replace function public.receive_purchase_order(p_po_id text, p_lines jsonb, p_additions jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_caller_id          uuid;
  v_role               text;
  v_today              date := CURRENT_DATE;
  v_line               jsonb;
  v_batch              jsonb;
  v_addition           jsonb;
  v_po_line_id         uuid;
  v_addition_id        uuid;
  v_product_id         uuid;
  v_orig_price         numeric;
  v_new_price          numeric;
  v_line_total         numeric;
  v_line_pstat         text;
  v_legacy_unit_lines  integer := 0;
  v_free_goods_lines   integer := 0;
  v_add_pstat          text;
  v_wh_location        text;
  v_total_qty          numeric;
  v_batch_idx          integer;
  v_batch_id           text;
  v_wh_inv_id          uuid;
  v_rows               integer;
  v_received_count     integer := 0;
  v_not_purchased_count integer := 0;
  v_addition_count     integer := 0;
  v_mirrored_count     integer := 0;
  v_mirror_line_id     uuid;
  v_not_purch_names    text[] := '{}';
  v_received_names     text[] := '{}';
  v_prod_name          text;
  v_batch_expiry       date;
  v_addition_expiry    date;
  v_warehouse_id       uuid := public.wh_central_id();
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'receive_purchase_order', true);
  PERFORM set_config('app.provenance_reason', 'po_receive', true);

  v_caller_id := (SELECT auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller_id;
  IF v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'receive_purchase_order: role % not authorized (warehouse+ only)', COALESCE(v_role,'none');
  END IF;
  IF p_po_id IS NULL OR trim(p_po_id) = '' THEN
    RAISE EXCEPTION 'receive_purchase_order: p_po_id is required';
  END IF;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_po_line_id  := (v_line->>'po_line_id')::uuid;
      v_new_price   := CASE WHEN NULLIF(v_line->>'price_per_unit_aed','') IS NOT NULL
                            THEN (v_line->>'price_per_unit_aed')::numeric ELSE NULL END;
      v_line_total  := CASE WHEN NULLIF(v_line->>'total_price_aed','') IS NOT NULL
                            THEN (v_line->>'total_price_aed')::numeric ELSE NULL END;
      v_line_pstat  := COALESCE(NULLIF(v_line->>'pricing_status',''), 'priced');
      IF v_line_pstat NOT IN ('priced','free_goods') THEN v_line_pstat := 'priced'; END IF;
      v_wh_location := NULLIF(v_line->>'wh_location', '');

      SELECT price_per_unit_aed, boonz_product_id INTO v_orig_price, v_product_id
      FROM public.purchase_orders WHERE po_line_id = v_po_line_id AND po_id = p_po_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'receive_purchase_order: po_line_id % not found in PO %', v_po_line_id, p_po_id;
      END IF;
      SELECT boonz_product_name INTO v_prod_name FROM public.boonz_products WHERE product_id = v_product_id;

      IF (v_line->>'close_as_not_purchased')::boolean IS TRUE THEN
        UPDATE public.purchase_orders SET received_date = v_today, received_qty = 0, purchase_outcome = 'not_purchased'
        WHERE po_line_id = v_po_line_id;
        v_not_purchased_count := v_not_purchased_count + 1;
        v_not_purch_names := array_append(v_not_purch_names, COALESCE(v_prod_name,'?'));
        CONTINUE;
      END IF;

      v_batch_idx := 0; v_total_qty := 0;
      SELECT COALESCE(SUM((b->>'received_qty')::numeric), 0) INTO v_total_qty
      FROM jsonb_array_elements(COALESCE(v_line->'batches','[]'::jsonb)) AS b
      WHERE (b->>'received_qty')::numeric > 0;
      IF v_total_qty <= 0 THEN CONTINUE; END IF;

      FOR v_batch IN SELECT * FROM jsonb_array_elements(COALESCE(v_line->'batches','[]'::jsonb)) LOOP
        IF COALESCE((v_batch->>'received_qty')::numeric, 0) > 0
           AND NULLIF(v_batch->>'expiry_date','') IS NULL THEN
          RAISE EXCEPTION
            'receive_purchase_order: PO % line % (% - %): batch has received_qty=% but missing expiry_date. Capture supplier expiry before receiving (NULL-expiry rows are forbidden, BUG-007/009).',
            p_po_id, v_po_line_id, v_prod_name, v_batch->>'wh_location',
            v_batch->>'received_qty';
        END IF;
      END LOOP;

      IF v_line_total IS NULL AND v_new_price IS NOT NULL THEN
        v_legacy_unit_lines := v_legacy_unit_lines + 1;
      END IF;
      IF v_line_pstat = 'free_goods' THEN
        v_free_goods_lines := v_free_goods_lines + 1;
      END IF;

      UPDATE public.purchase_orders
      SET received_date = v_today, received_qty = v_total_qty, purchase_outcome = 'received',
          pricing_status = v_line_pstat,
          price_per_unit_aed = CASE
            WHEN v_line_total IS NOT NULL AND v_total_qty > 0
              THEN ROUND(v_line_total / v_total_qty, 4)
            ELSE COALESCE(v_new_price, price_per_unit_aed) END,
          total_price_aed = CASE
            WHEN v_line_total IS NOT NULL THEN v_line_total
            WHEN v_new_price IS NOT NULL THEN v_total_qty * v_new_price
            WHEN price_per_unit_aed IS NOT NULL THEN v_total_qty * price_per_unit_aed
            ELSE NULL END,
          expiry_date = COALESCE(NULLIF((v_line->'batches'->0->>'expiry_date'),'')::date, expiry_date)
      WHERE po_line_id = v_po_line_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'receive_purchase_order: failed to update po_line_id %', v_po_line_id;
      END IF;

      PERFORM set_config('app.source_event_id', v_po_line_id::text, true);

      FOR v_batch IN SELECT * FROM jsonb_array_elements(COALESCE(v_line->'batches','[]'::jsonb)) LOOP
        CONTINUE WHEN COALESCE((v_batch->>'received_qty')::numeric,0) <= 0;
        v_batch_idx := v_batch_idx + 1;
        v_batch_id  := p_po_id || '-' || left(v_po_line_id::text,8) || '-B' || v_batch_idx;
        v_batch_expiry := NULLIF(v_batch->>'expiry_date','')::date;

        INSERT INTO public.warehouse_inventory (
          boonz_product_id, warehouse_stock, expiration_date,
          batch_id, wh_location, status, snapshot_date, warehouse_id
        ) VALUES (
          v_product_id, (v_batch->>'received_qty')::numeric, v_batch_expiry,
          v_batch_id, v_wh_location, 'Active', v_today, v_warehouse_id
        ) RETURNING wh_inventory_id INTO v_wh_inv_id;

        IF v_new_price IS NOT NULL AND v_new_price IS DISTINCT FROM v_orig_price THEN
          BEGIN
            INSERT INTO public.inventory_audit_log (
              wh_inventory_id, boonz_product_id, adjusted_by,
              old_qty, new_qty, delta, reason
            ) VALUES (
              v_wh_inv_id, v_product_id, v_caller_id,
              COALESCE(v_orig_price,0), v_new_price, v_new_price - COALESCE(v_orig_price,0),
              'price_adjusted_at_receipt');
          EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'audit log failed for wh_inv %: %', v_wh_inv_id, SQLERRM;
          END;
        END IF;
      END LOOP;
      v_received_count := v_received_count + 1;
      v_received_names := array_append(v_received_names, COALESCE(v_prod_name,'?'));
    END LOOP;
  END IF;

  IF p_additions IS NOT NULL AND jsonb_typeof(p_additions) = 'array' AND jsonb_array_length(p_additions) > 0 THEN
    FOR v_addition IN SELECT * FROM jsonb_array_elements(p_additions) LOOP
      v_product_id := (v_addition->>'boonz_product_id')::uuid;
      v_addition_id := (v_addition->>'addition_id')::uuid;
      v_batch_id   := p_po_id || '-ADD-' || left((v_addition->>'addition_id'),8);

      v_addition_expiry := COALESCE(
        NULLIF(v_addition->>'expiry_date','')::date,
        (SELECT expiry_date FROM po_additions WHERE addition_id = v_addition_id)
      );
      IF v_addition_expiry IS NULL THEN
        RAISE EXCEPTION
          'receive_purchase_order: addition % (% qty=%) has no expiry_date in jsonb or po_additions. Capture expiry before receiving.',
          v_addition->>'addition_id', v_product_id, v_addition->>'qty';
      END IF;

      v_add_pstat := NULLIF(v_addition->>'pricing_status','');
      IF v_add_pstat IS NOT NULL AND v_add_pstat NOT IN ('priced','free_goods') THEN
        v_add_pstat := NULL;
      END IF;
      IF v_add_pstat = 'free_goods' THEN
        v_free_goods_lines := v_free_goods_lines + 1;
      END IF;

      UPDATE public.po_additions
      SET status = 'received', received_at = now(), received_by = v_caller_id,
          pricing_status = COALESCE(v_add_pstat, pricing_status)
      WHERE addition_id = v_addition_id
        AND po_id = p_po_id AND status = 'pending_receive';

      v_mirror_line_id := public._mirror_po_addition_line_v1(v_addition_id, v_caller_id);
      IF v_mirror_line_id IS NOT NULL THEN
        v_mirrored_count := v_mirrored_count + 1;
      END IF;

      PERFORM set_config('app.source_event_id', v_addition_id::text, true);

      INSERT INTO public.warehouse_inventory (
        boonz_product_id, warehouse_stock, expiration_date,
        batch_id, wh_location, status, snapshot_date, warehouse_id
      ) VALUES (
        v_product_id, (v_addition->>'qty')::numeric, v_addition_expiry,
        v_batch_id, NULLIF(v_addition->>'wh_location',''), 'Active', v_today, v_warehouse_id
      );
      v_addition_count := v_addition_count + 1;
    END LOOP;
  END IF;

  IF v_received_count > 0 OR v_addition_count > 0 THEN
    INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
    VALUES (p_po_id, 'goods_received', v_caller_id,
      jsonb_build_object('lines_received', v_received_count, 'additions_received', v_addition_count,
                         'additions_mirrored', v_mirrored_count, 'products', to_json(v_received_names),
                         'legacy_unit_entry', v_legacy_unit_lines > 0,
                         'legacy_unit_lines', v_legacy_unit_lines,
                         'free_goods_lines', v_free_goods_lines));
  END IF;
  IF v_not_purchased_count > 0 THEN
    INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
    VALUES (p_po_id, 'line_not_purchased', v_caller_id,
      jsonb_build_object('count', v_not_purchased_count, 'products', to_json(v_not_purch_names)));
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'po_id', p_po_id, 'received_date', v_today,
    'lines_received', v_received_count, 'lines_not_purchased', v_not_purchased_count,
    'additions_received', v_addition_count, 'additions_mirrored', v_mirrored_count,
    'legacy_unit_lines', v_legacy_unit_lines, 'free_goods_lines', v_free_goods_lines);
EXCEPTION WHEN OTHERS THEN RAISE;
END;
$function$;
