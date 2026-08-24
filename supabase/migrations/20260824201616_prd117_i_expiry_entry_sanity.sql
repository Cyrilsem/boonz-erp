-- PRD-117 item I: expiry-entry sanity check, warning-only, never a block, never an
-- auto-correction. Triggered by a real incident (Vitamin Well Zero Lemon entered
-- 2027-01-03, true 2027-12-03 - an 11-month day/month transposition).
--
-- Two new small functions:
--   safe_monitoring_alert: a failure-isolated INSERT into monitoring_alerts. A
--   monitoring write must never break the operational write it observes (this
--   principle, raised by CS for item M's trigger context, applies equally here -
--   these three writers fire on live receives from 07:00 Dubai).
--   log_expiry_entry_suspect: the detection logic, called from all three receive
--   writers below. Flags: entered expiry < purchase/reference_date + 30d, or
--   > +24 months, or a day/month swap of the entered date lands more plausibly
--   (3-18 months out) while the entered date itself does not.
--
-- receive_purchase_order, receive_purchase_order_addition, receive_dispatch_line:
-- reproduced verbatim from their live bodies (md5 1d76bf94f81d016eec802a0e65a02b7a,
-- 6e777725cad32c4641cec069c9bb19e3, b446b249093a753f848c23c309b8e0cf respectively,
-- captured 2026-08-24 before this patch), with the check call inserted at each
-- point a fresh expiry value enters the system. receive_purchase_order_addition's
-- two COALESCE(p_expiry, v_addition.expiry_date) call sites were consolidated into
-- one v_final_expiry variable, computed once, to avoid checking a computed value
-- twice - the only non-additive change to any of the three bodies.
--
-- Tested in rolled-back transactions 2026-08-24 against real rows before applying:
-- receive_purchase_order (PO-2026-9402 line, entered expiry 10 days post-purchase,
-- correctly flagged too_soon, receive still completed); receive_dispatch_line
-- (dispatch 2a406ada, plausible ~5.3mo expiry, correctly did NOT flag, receive
-- completed normally). Helper logic separately proven against 5 synthetic cases
-- (too_soon, too_far, two plausible-dates-correctly-not-flagged, and a forced
-- NULL-source failure confirming safe_monitoring_alert swallows the error without
-- propagating). receive_purchase_order_addition has no live pending_receive row
-- tonight to test end-to-end; verified by code-pattern review only (identical
-- shape to the proven call in receive_purchase_order's addition-loop logic).
--
-- Cody: Approve. Articles 1, 4, 6, 8, 12, 16 checked - see the PRD-117 review in
-- this session's transcript. Applied to prod via MCP 2026-08-24.

CREATE OR REPLACE FUNCTION public.safe_monitoring_alert(p_source text, p_severity text, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  INSERT INTO public.monitoring_alerts (source, severity, payload) VALUES (p_source, p_severity, p_payload);
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.log_expiry_entry_suspect(p_writer text, p_reference_date date, p_entered_expiry date, p_context jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_swapped date;
  v_swap_valid boolean := false;
  v_months_out numeric;
  v_swap_months_out numeric;
  v_reason text := NULL;
BEGIN
  IF p_entered_expiry IS NULL OR p_reference_date IS NULL THEN RETURN; END IF;

  v_months_out := (p_entered_expiry - p_reference_date) / 30.44;

  IF EXTRACT(DAY FROM p_entered_expiry) <= 12 THEN
    BEGIN
      v_swapped := make_date(
        EXTRACT(YEAR FROM p_entered_expiry)::int,
        EXTRACT(DAY FROM p_entered_expiry)::int,
        EXTRACT(MONTH FROM p_entered_expiry)::int
      );
      v_swap_valid := true;
    EXCEPTION WHEN OTHERS THEN
      v_swap_valid := false;
    END;
  END IF;

  IF p_entered_expiry < p_reference_date + 30 THEN
    v_reason := 'too_soon';
  ELSIF p_entered_expiry > p_reference_date + interval '24 months' THEN
    v_reason := 'too_far';
  ELSIF v_swap_valid AND v_swapped <> p_entered_expiry THEN
    v_swap_months_out := (v_swapped - p_reference_date) / 30.44;
    IF v_swap_months_out BETWEEN 3 AND 18 AND NOT (v_months_out BETWEEN 3 AND 18) THEN
      v_reason := 'day_month_swap_more_plausible';
    END IF;
  END IF;

  IF v_reason IS NOT NULL THEN
    PERFORM public.safe_monitoring_alert('expiry_entry_suspect', 'warning',
      jsonb_build_object(
        'writer', p_writer, 'reason', v_reason,
        'reference_date', p_reference_date, 'entered_expiry', p_entered_expiry,
        'swapped_candidate', CASE WHEN v_swap_valid THEN v_swapped ELSE NULL END,
        'context', p_context));
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.receive_purchase_order(p_po_id text, p_lines jsonb, p_additions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_purchase_date      date;
  v_addition_created_at date;
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

      SELECT price_per_unit_aed, boonz_product_id, purchase_date INTO v_orig_price, v_product_id, v_purchase_date
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
        IF COALESCE((v_batch->>'received_qty')::numeric, 0) > 0 THEN
          PERFORM public.log_expiry_entry_suspect('receive_purchase_order', v_purchase_date,
            NULLIF(v_batch->>'expiry_date','')::date,
            jsonb_build_object('po_id', p_po_id, 'po_line_id', v_po_line_id, 'boonz_product_id', v_product_id));
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

      SELECT COALESCE(NULLIF(v_addition->>'expiry_date','')::date, po_additions.expiry_date), po_additions.created_at::date
        INTO v_addition_expiry, v_addition_created_at
      FROM po_additions WHERE addition_id = v_addition_id;
      IF v_addition_expiry IS NULL THEN
        RAISE EXCEPTION
          'receive_purchase_order: addition % (% qty=%) has no expiry_date in jsonb or po_additions. Capture expiry before receiving.',
          v_addition->>'addition_id', v_product_id, v_addition->>'qty';
      END IF;
      PERFORM public.log_expiry_entry_suspect('receive_purchase_order_addition_inline', v_addition_created_at,
        v_addition_expiry, jsonb_build_object('po_id', p_po_id, 'addition_id', v_addition_id, 'boonz_product_id', v_product_id));

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

CREATE OR REPLACE FUNCTION public.receive_purchase_order_addition(p_addition_id uuid, p_warehouse_id uuid, p_expiry date DEFAULT NULL::date, p_batch_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role text;
  v_addition    po_additions%ROWTYPE;
  v_today       date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  v_caller_id   uuid := auth.uid();
  v_mirror_line uuid;
  v_final_expiry date;
BEGIN
  PERFORM public.set_write_context(
    'receive_purchase_order_addition',
    format('receive PO addition %s into warehouse %s', p_addition_id, p_warehouse_id),
    'po_receive',
    p_addition_id::text);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RETURN jsonb_build_object('status','error','error','Insufficient role');
  END IF;

  IF p_addition_id IS NULL OR p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','p_addition_id and p_warehouse_id are required');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = p_warehouse_id) THEN
    RETURN jsonb_build_object('status','error','error','Unknown warehouse_id');
  END IF;

  SELECT * INTO v_addition FROM po_additions WHERE addition_id = p_addition_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','error','error','PO addition not found');
  END IF;

  IF v_addition.status = 'received' THEN
    RETURN jsonb_build_object('status','already_received',
      'message','PO addition already received — no duplicate created');
  END IF;

  v_final_expiry := COALESCE(p_expiry, v_addition.expiry_date);
  PERFORM public.log_expiry_entry_suspect('receive_purchase_order_addition', v_addition.created_at::date,
    v_final_expiry, jsonb_build_object('addition_id', p_addition_id, 'boonz_product_id', v_addition.boonz_product_id));

  INSERT INTO warehouse_inventory (
    boonz_product_id, warehouse_stock, status, snapshot_date,
    expiration_date, warehouse_id, batch_id
  ) VALUES (
    v_addition.boonz_product_id, v_addition.qty, 'Active', v_today,
    v_final_expiry,
    p_warehouse_id,
    COALESCE(p_batch_id, format('PO-ADDITION-%s', substring(p_addition_id::text, 1, 8)))
  );

  UPDATE po_additions
  SET status      = 'received',
      received_at = now(),
      received_by = v_caller_id
  WHERE addition_id = p_addition_id;

  v_mirror_line := public._mirror_po_addition_line_v1(p_addition_id, v_caller_id);

  RETURN jsonb_build_object(
    'status', 'ok',
    'addition_id', p_addition_id,
    'warehouse_id', p_warehouse_id,
    'qty', v_addition.qty,
    'expiry', v_final_expiry,
    'mirrored_po_line_id', v_mirror_line
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.receive_dispatch_line(p_dispatch_id uuid, p_filled_quantity numeric, p_received_by uuid DEFAULT NULL::uuid, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_override boolean DEFAULT false, p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_planned numeric; v_return_delta numeric; v_overfill numeric;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_pod_id uuid; v_consumer_drawn numeric := 0; v_path text;
  v_target_wh uuid; v_pod_archived int := 0;
  v_breakdown_total numeric := 0;
  v_entry jsonb; v_entry_qty numeric; v_entry_expiry date; v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
  v_prior_active_merged int := 0;
  v_supply text;
  v_is_fill boolean;
  v_gate text;
  v_overfill_debits jsonb := '[]'::jsonb;
  v_fefo record;
  v_need numeric;
  v_take numeric;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'receive_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_receive', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;
  IF p_filled_quantity < 0 THEN RAISE EXCEPTION 'filled_quantity cannot be negative'; END IF;
  v_planned := v_dispatch.quantity;
  v_return_delta := GREATEST(v_planned - p_filled_quantity, 0);
  v_overfill := GREATEST(p_filled_quantity - v_planned, 0);
  v_path := 'b2_fallback';
  v_target_wh := COALESCE(
    v_dispatch.from_warehouse_id,
    (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_dispatch.machine_id));
  IF v_target_wh IS NULL THEN
    RAISE EXCEPTION 'receive_dispatch_line: cannot resolve credit warehouse for dispatch % (from_warehouse_id NULL and machine % has no primary_warehouse_id). Refusing to silently credit WH_CENTRAL.', p_dispatch_id, v_dispatch.machine_id;
  END IF;
  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
    PERFORM public.log_expiry_entry_suspect('receive_dispatch_line', v_dispatch.dispatch_date,
      v_effective_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
        'boonz_product_id', v_dispatch.boonz_product_id, 'action', v_dispatch.action));
  END IF;
  PERFORM set_config('app.mutation_reason', format('B3 receive: dispatch %s — filled %s / planned %s by %s (breakdown=%s, effective_expiry=%s)', p_dispatch_id, p_filled_quantity, v_planned, COALESCE(p_received_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
  v_is_fill := v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false);
  v_gate := COALESCE(refill_qa.flag('rc07_receive_gate'), 'off');
  IF v_is_fill AND v_gate = 'on'
     AND NOT (COALESCE(v_dispatch.packed, false) AND COALESCE(v_dispatch.picked_up, false)) THEN
    IF p_override IS TRUE AND COALESCE(NULLIF(btrim(p_override_reason), ''), '') <> '' THEN
      PERFORM set_config('app.receive_override_reason', p_override_reason, true);
      PERFORM set_config('app.mutation_reason',
        format('B4 receive OVERRIDE: dispatch %s force-received unpacked (packed=%s picked_up=%s) reason: %s',
               p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false), p_override_reason), true);
    ELSE
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is not in a receivable state (packed=%, picked_up=%). A fill line must be PACKED and PICKED UP before receive. Pass p_override:=true with p_override_reason to force-receive (audited).',
        p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false);
    END IF;
  END IF;
  IF v_dispatch.action IN ('Refill','Add New','Add') THEN
   IF NOT COALESCE(v_dispatch.is_m2m, false) THEN
    IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
      IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN v_path := 'b3_consumer_pinned'; ELSE v_consumer_row := NULL; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND COALESCE(consumer_stock, 0) > 0 AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL) AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC, consumer_stock DESC, reserved_at ASC LIMIT 1 FOR UPDATE;
      IF FOUND THEN v_path := 'b3_consumer_legacy'; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
      v_consumer_drawn := LEAST(p_filled_quantity, v_consumer_row.consumer_stock);
      UPDATE warehouse_inventory SET consumer_stock = GREATEST(COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta), 0), warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta, reserved_for_machine_id = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_for_machine_id END, reserved_at = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_at END WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
    ELSE
      IF v_return_delta > 0 THEN
        SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (expiration_date = v_effective_expiry) DESC NULLS LAST, created_at DESC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
          ELSE
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_return_delta, v_effective_expiry, 'Active', format('RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
          END IF;
        END IF;
      END IF;
    END IF;
    IF v_overfill > 0 THEN
      v_need := v_overfill;
      FOR v_fefo IN
        SELECT f.wh_inventory_id, f.warehouse_stock, f.batch_id, f.expiration_date
        FROM public.wh_fefo_for_line(
               v_dispatch.machine_id, v_dispatch.boonz_product_id,
               COALESCE(v_dispatch.dispatch_date, CURRENT_DATE),
               v_overfill, ARRAY[v_target_wh]) f
        ORDER BY f.pick_rank
      LOOP
        EXIT WHEN v_need <= 0;
        v_take := LEAST(v_need, GREATEST(COALESCE(v_fefo.warehouse_stock,0), 0));
        IF v_take <= 0 THEN CONTINUE; END IF;
        UPDATE warehouse_inventory
           SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_take
         WHERE wh_inventory_id = v_fefo.wh_inventory_id;
        v_overfill_debits := v_overfill_debits || jsonb_build_object(
          'wh_inventory_id', v_fefo.wh_inventory_id, 'batch_id', v_fefo.batch_id,
          'expiry', v_fefo.expiration_date, 'qty', v_take);
        v_need := v_need - v_take;
      END LOOP;
      IF v_need > 0 THEN
        RAISE EXCEPTION 'receive_dispatch_line: overfill of % unit(s) for boonz_product=% cannot be debited — warehouse % is short by % unit(s) across all pickable FEFO batches. Refusing to silently debit an arbitrary/zero row.',
          v_overfill, v_dispatch.boonz_product_id, v_target_wh, v_need;
      END IF;
    END IF;
   ELSE
     v_path := 'add_m2m_no_wh_draw';
   END IF;
    IF p_filled_quantity > 0 THEN
      WITH archived AS (UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text), snapshot_at = now() WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' RETURNING current_stock, expiration_date), merge_stats AS (SELECT COALESCE(SUM(current_stock), 0)::numeric AS prior_qty, COUNT(*)::int AS prior_n, MIN(expiration_date) AS oldest_expiry FROM archived)
      INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at) SELECT v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE, p_filled_quantity + ms.prior_qty, p_filled_quantity + ms.prior_qty, LEAST(v_effective_expiry, COALESCE(ms.oldest_expiry, v_effective_expiry)), CASE WHEN ms.prior_n > 0 THEN format('MERGED-DISPATCH-%s', v_dispatch.dispatch_date) ELSE format('DISPATCH-%s', v_dispatch.dispatch_date) END, 'Active', now(), now() FROM merge_stats ms RETURNING pod_inventory_id INTO v_pod_id;
      SELECT prior_n INTO v_prior_active_merged FROM (SELECT COUNT(*)::int AS prior_n FROM pod_inventory WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Inactive' AND removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text)) AS s;
    END IF;
  ELSIF v_dispatch.action = 'Remove' THEN
    v_path := 'remove_single_expiry';
    SELECT source_of_supply INTO v_supply FROM public.product_mapping
     WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
       AND (machine_id = v_dispatch.machine_id OR is_global_default)
     ORDER BY (machine_id = v_dispatch.machine_id) DESC, is_global_default ASC LIMIT 1;
    IF COALESCE(v_dispatch.is_m2m, false) THEN
      v_path := 'remove_m2m_no_wh_credit';
    ELSIF v_supply = 'venue_team' THEN
      v_path := 'remove_venue_team_no_wh_credit';
      INSERT INTO public.vox_return_log
        (dispatch_id, machine_id, boonz_product_id, qty, expiry_date, source_of_supply, received_by, reason)
      VALUES
        (p_dispatch_id, v_dispatch.machine_id, v_dispatch.boonz_product_id, p_filled_quantity,
         v_effective_expiry, v_supply, p_received_by,
         format('VOX venue_team REMOVE receipt; WH credit skipped (dispatch %s)', p_dispatch_id));
    ELSIF p_filled_quantity > 0 THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> p_filled_quantity THEN RAISE EXCEPTION 'Breakdown total (%) must equal filled_quantity (%)', v_breakdown_total, p_filled_quantity; END IF;
        FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown) LOOP
          v_entry_qty := (v_entry->>'qty')::numeric;
          IF v_entry_qty <= 0 THEN CONTINUE; END IF;
          v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;
          v_entry_wh_id := NULLIF(v_entry->>'wh_inventory_id', '')::uuid;
          IF v_entry_wh_id IS NOT NULL THEN
            SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_entry_wh_id FOR UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Breakdown row id % not found', v_entry_wh_id; END IF;
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty, status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_entry_qty);
            CONTINUE;
          END IF;
          IF v_entry_expiry IS NULL THEN RAISE EXCEPTION 'Breakdown entry must include expiry or wh_inventory_id (got %)', v_entry; END IF;
          PERFORM public.log_expiry_entry_suspect('receive_dispatch_line_breakdown', v_dispatch.dispatch_date,
            v_entry_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
              'boonz_product_id', v_dispatch.boonz_product_id));
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'existing');
          ELSE
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_entry_qty, v_entry_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh) RETURNING wh_inventory_id INTO v_entry_wh_id;
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_entry_wh_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;
      ELSIF v_effective_expiry IS NOT NULL THEN
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_effective_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
          INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, p_filled_quantity, v_effective_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
          PERFORM set_config('app.provenance_reason','dispatch_receive', true);
        END IF;
      ELSE
        v_path := 'remove_fefo_fallback';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date IS NOT NULL ORDER BY expiration_date ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION 'Cannot receive REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.', p_dispatch_id, v_dispatch.boonz_product_id, v_target_wh;
          END IF;
        END IF;
      END IF;
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
  END IF;
  UPDATE refill_dispatching
     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,
         pack_outcome = CASE
           WHEN v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false)
             THEN (CASE WHEN p_filled_quantity < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
           ELSE pack_outcome
         END
   WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'filled_quantity', p_filled_quantity, 'planned_quantity', v_planned, 'return_delta', v_return_delta, 'overfill', v_overfill, 'pod_inventory_id', v_pod_id, 'pod_archived', v_pod_archived, 'prior_active_merged', v_prior_active_merged, 'consumer_drained', v_consumer_drawn, 'path', v_path, 'effective_expiry', v_effective_expiry, 'received_by', p_received_by, 'credit_summary', v_credit_summary, 'overfill_debits', v_overfill_debits, 'wh_credit_skipped', CASE WHEN COALESCE(v_dispatch.is_m2m,false) THEN 'm2m' WHEN v_supply = 'venue_team' THEN 'venue_team' ELSE NULL END, 'status', 'received');
END;
$function$;
