-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- DF3: receive_purchase_order carries the same terminal auto-close block as cancel_po_line (see
-- df3_driver_tasks_autoclose_on_po_settle), fixing the 66-task driver backlog (64 stale). A
-- po_addition still pending_receive does not hold the task open (documented choice). A one-time
-- cleanup of 65 stale driver_tasks was done separately via execute_sql the same day; not part of
-- this function-body change.

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
  v_open_lines         integer;
  v_po_received_lines  integer;
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

  -- DF3: auto-close the driver task once no actionable lines remain on this PO.
  -- 'collected' when at least one line was received, 'cancelled' when the PO settled
  -- entirely as not_purchased. Close, never DELETE (S-142/S-147 precedent).
  -- A po_addition still pending_receive does NOT hold the task open by design:
  -- the driver's field work is done, receipt is a warehouse action.
  SELECT count(*) FILTER (WHERE purchase_outcome IS NULL
                             OR purchase_outcome NOT IN ('received','not_purchased')),
         count(*) FILTER (WHERE purchase_outcome = 'received')
  INTO v_open_lines, v_po_received_lines
  FROM public.purchase_orders
  WHERE po_id = p_po_id;

  IF v_open_lines = 0 THEN
    UPDATE public.driver_tasks dt
       SET status          = CASE WHEN v_po_received_lines > 0 THEN 'collected' ELSE 'cancelled' END,
           collected_at    = CASE WHEN v_po_received_lines > 0 THEN COALESCE(dt.collected_at, now()) ELSE dt.collected_at END,
           outcome_comment = COALESCE(dt.outcome_comment,'')
                             || '[auto-closed by receive_purchase_order: PO fully settled at warehouse]'
     WHERE dt.po_id = p_po_id
       AND dt.status IN ('pending','acknowledged');
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'po_id', p_po_id, 'received_date', v_today,
    'lines_received', v_received_count, 'lines_not_purchased', v_not_purchased_count,
    'additions_received', v_addition_count, 'additions_mirrored', v_mirrored_count,
    'legacy_unit_lines', v_legacy_unit_lines, 'free_goods_lines', v_free_goods_lines);
EXCEPTION WHEN OTHERS THEN RAISE;
END;
$function$;
