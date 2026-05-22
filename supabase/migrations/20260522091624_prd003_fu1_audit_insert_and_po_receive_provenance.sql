-- ============================================================================
-- PRD-003 FU#1 + FU#2 — provenance wiring
--
-- This migration depends on the column + trigger scaffolding shipped in
-- 20260521230813_prd003_wh_inventory_provenance_quarantine.sql.
--
-- FU#1: re-emit auto_audit_warehouse_inventory_insert so the AFTER INSERT
--       trigger populates inventory_audit_log.provenance_reason and
--       .source_event_id from NEW.* (the BEFORE trigger has already
--       annotated NEW from app.* GUCs).
--
-- FU#2: re-emit receive_purchase_order so every WH row it inserts carries
--       provenance_reason='po_receive' and source_event_id = the originating
--       po_line_id (for PO lines) or addition_id (for field additions).
--       Together with the BEFORE trigger from PRD-003 this means every row
--       receive_purchase_order writes ships out of quarantine immediately.
--
-- Bodies were retrieved from pg_proc via the read-only Supabase MCP
-- (mcp__claude_ai_Supabase__execute_sql) and re-emitted with the minimal
-- provenance hooks added. Function signatures unchanged. CHANGELOG-worthy
-- because both bodies now read different GUCs.
--
-- Cody Articles: 1 (no new write path — annotation only), 4 (DEFINER + role
-- check unchanged + new GUCs set), 8 (existing audit trigger continues to
-- capture rpc_name), 12 (forward-only CREATE OR REPLACE, no DROP).
-- ============================================================================

BEGIN;

-- ── FU#1 — auto_audit_warehouse_inventory_insert ────────────────────────────

CREATE OR REPLACE FUNCTION public.auto_audit_warehouse_inventory_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text;
  v_uid uuid;
BEGIN
  IF COALESCE(NEW.warehouse_stock, 0) > 0 OR COALESCE(NEW.consumer_stock, 0) > 0 THEN
    v_uid := (SELECT auth.uid());
    v_reason := COALESCE(
      current_setting('app.mutation_reason', true),
      CASE WHEN v_uid IS NULL THEN 'service_role_insert_unattributed'
           ELSE 'authenticated_insert_no_reason_set' END
    );
    INSERT INTO inventory_audit_log
      (wh_inventory_id, boonz_product_id, adjusted_by,
       old_qty, new_qty, reason, audited_at,
       provenance_reason, source_event_id)
    VALUES
      (NEW.wh_inventory_id, NEW.boonz_product_id, v_uid,
       0,
       COALESCE(NEW.warehouse_stock, 0) + COALESCE(NEW.consumer_stock, 0),
       v_reason, now(),
       NEW.provenance_reason, NEW.source_event_id);
  END IF;
  RETURN NEW;
END;
$function$;

-- Trigger binding unchanged; AFTER INSERT was created in an earlier phase.
-- We DO NOT drop+recreate the trigger here — the function replacement is
-- enough (PG re-binds to the new function body on next fire).

-- ── FU#2 — receive_purchase_order with provenance GUC ───────────────────────

CREATE OR REPLACE FUNCTION public.receive_purchase_order(
  p_po_id text,
  p_lines jsonb,
  p_additions jsonb
)
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
  v_wh_location        text;
  v_total_qty          numeric;
  v_batch_idx          integer;
  v_batch_id           text;
  v_wh_inv_id          uuid;
  v_rows               integer;
  v_received_count     integer := 0;
  v_not_purchased_count integer := 0;
  v_addition_count     integer := 0;
  v_not_purch_names    text[] := '{}';
  v_received_names     text[] := '{}';
  v_prod_name          text;
  v_batch_expiry       date;
  v_addition_expiry    date;
  v_warehouse_id       uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'receive_purchase_order', true);
  -- PRD-003 FU#2: every WH row this RPC writes is a PO receive.
  PERFORM set_config('app.provenance_reason', 'po_receive', true);

  v_caller_id := (SELECT auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller_id;
  IF v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'receive_purchase_order: role % not authorized (warehouse+ only)', COALESCE(v_role,'none');
  END IF;
  IF p_po_id IS NULL OR trim(p_po_id) = '' THEN
    RAISE EXCEPTION 'receive_purchase_order: p_po_id is required';
  END IF;

  -- PO lines
  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_po_line_id  := (v_line->>'po_line_id')::uuid;
      v_new_price   := CASE WHEN v_line->>'price_per_unit_aed' IS NOT NULL
                            THEN (v_line->>'price_per_unit_aed')::numeric ELSE NULL END;
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

      -- BUG-009 VALIDATION: every batch with qty > 0 must have expiry_date
      FOR v_batch IN SELECT * FROM jsonb_array_elements(COALESCE(v_line->'batches','[]'::jsonb)) LOOP
        IF COALESCE((v_batch->>'received_qty')::numeric, 0) > 0
           AND NULLIF(v_batch->>'expiry_date','') IS NULL THEN
          RAISE EXCEPTION
            'receive_purchase_order: PO % line % (% — %): batch has received_qty=% but missing expiry_date. Capture supplier expiry before receiving (NULL-expiry rows are forbidden, BUG-007/009).',
            p_po_id, v_po_line_id, v_prod_name, v_batch->>'wh_location',
            v_batch->>'received_qty';
        END IF;
      END LOOP;

      UPDATE public.purchase_orders
      SET received_date = v_today, received_qty = v_total_qty, purchase_outcome = 'received',
          price_per_unit_aed = COALESCE(v_new_price, price_per_unit_aed),
          total_price_aed = CASE
            WHEN v_new_price IS NOT NULL THEN v_total_qty * v_new_price
            WHEN price_per_unit_aed IS NOT NULL THEN v_total_qty * price_per_unit_aed
            ELSE NULL END,
          expiry_date = COALESCE(NULLIF((v_line->'batches'->0->>'expiry_date'),'')::date, expiry_date)
      WHERE po_line_id = v_po_line_id;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      IF v_rows = 0 THEN
        RAISE EXCEPTION 'receive_purchase_order: failed to update po_line_id %', v_po_line_id;
      END IF;

      -- PRD-003 FU#2: pin source_event_id to the originating PO line for the
      -- batch inserts below. Set inside the loop so v_po_line_id is current.
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

  -- Field additions
  IF p_additions IS NOT NULL AND jsonb_typeof(p_additions) = 'array' AND jsonb_array_length(p_additions) > 0 THEN
    FOR v_addition IN SELECT * FROM jsonb_array_elements(p_additions) LOOP
      v_product_id := (v_addition->>'boonz_product_id')::uuid;
      v_addition_id := (v_addition->>'addition_id')::uuid;
      v_batch_id   := p_po_id || '-ADD-' || left((v_addition->>'addition_id'),8);

      -- BUG-009 fix: prefer jsonb.expiry_date, fall back to po_additions.expiry_date, never accept NULL
      v_addition_expiry := COALESCE(
        NULLIF(v_addition->>'expiry_date','')::date,
        (SELECT expiry_date FROM po_additions WHERE addition_id = v_addition_id)
      );
      IF v_addition_expiry IS NULL THEN
        RAISE EXCEPTION
          'receive_purchase_order: addition % (% qty=%) has no expiry_date in jsonb or po_additions. Capture expiry before receiving.',
          v_addition->>'addition_id', v_product_id, v_addition->>'qty';
      END IF;

      UPDATE public.po_additions
      SET status = 'received', received_at = now(), received_by = v_caller_id
      WHERE addition_id = v_addition_id
        AND po_id = p_po_id AND status = 'pending_receive';

      -- PRD-003 FU#2: source_event_id for an addition row is the addition_id.
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
      jsonb_build_object('lines_received', v_received_count, 'additions_received', v_addition_count, 'products', to_json(v_received_names)));
  END IF;
  IF v_not_purchased_count > 0 THEN
    INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
    VALUES (p_po_id, 'line_not_purchased', v_caller_id,
      jsonb_build_object('count', v_not_purchased_count, 'products', to_json(v_not_purch_names)));
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'po_id', p_po_id, 'received_date', v_today,
    'lines_received', v_received_count, 'lines_not_purchased', v_not_purchased_count,
    'additions_received', v_addition_count);
EXCEPTION WHEN OTHERS THEN RAISE;
END;
$function$;

COMMIT;

-- ============================================================================
-- POST-APPLY VERIFICATION
--   1. SELECT pg_get_functiondef('public.receive_purchase_order(text,jsonb,jsonb)'::regprocedure);
--      → should contain the two new PERFORM set_config calls (provenance + source_event).
--   2. Receive a small test PO: every new warehouse_inventory row should arrive
--      with provenance_reason='po_receive', source_event_id=<the po_line_id>,
--      quarantined=false.
--   3. SELECT * FROM inventory_audit_log WHERE provenance_reason='po_receive'
--      ORDER BY audited_at DESC LIMIT 5; → INSERT audit rows now carry provenance.
--
-- STILL DEFERRED (the other 9 canonical writers):
--   pack_dispatch_line, receive_dispatch_line, return_dispatch_line,
--   return_all_dispatches_for_machine, transfer_warehouse_stock,
--   log_manual_refill, adjust_warehouse_stock, confirm_warehouse_status_proposal,
--   upsert_refill_stock_snapshot, add_sanity_increment, auto_sanity_check.
--   One follow-up migration per writer; each adds the matching
--   provenance_reason GUC. Mechanical work — bodies retrievable via the same
--   pg_proc query and patched the same way.
-- ============================================================================
