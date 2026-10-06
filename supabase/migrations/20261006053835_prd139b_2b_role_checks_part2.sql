-- PRD-139b Item 2B part 2: remaining 6 of the 15 named writers.
-- See part 1 migration for the full investigation writeup.

-- ============================================================
-- 10. record_actual_refill -- class (b): fails open when BOTH auth.uid() and p_actor
--     are NULL. The documented p_actor fallback (for genuine NULL-auth service calls)
--     is preserved; only the double-NULL gap is closed.
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_actual_refill(p_machine_name text, p_plan_date date, p_lines jsonb, p_source text DEFAULT 'cs'::text, p_actor uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_machine_id uuid;
  v_event_id   uuid;
  v_actor      uuid;
  v_line       jsonb;
  v_action     text;
  v_bpid       uuid;
  v_shelf_code text;
  v_shelf_id   uuid;
  v_qty        numeric;
  v_setmode    text;
  v_exp        date;
  v_wh         uuid;
  v_partner    text;
  v_partner_id uuid;
  v_notes      text;
  v_cur        numeric;
  v_newqty     numeric;
  v_pod_delta  numeric;
  v_pod_res    jsonb;
  v_pod_id     uuid;
  v_rpo_action text;
  v_applied    int := 0;
  v_lineno     int := 0;
  -- warehouse-effect working state
  v_debit_needed numeric;
  v_remaining    numeric;
  v_take         numeric;
  v_avail        numeric;
  v_pick         record;
  v_lock_id      uuid;
  v_lock_stock   numeric;
  v_credit_id    uuid;
  v_wh_moves     jsonb;
  v_discrepancy  jsonb;
  v_line_details jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.set_write_context('record_actual_refill',
    COALESCE(p_reason,'record_actual_refill'), NULL, NULL);

  -- resolve + validate machine
  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'record_actual_refill: machine % not found', p_machine_name; END IF;
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'p_lines empty'; END IF;

  -- [RC-02/RC-11 EDIT] actor of record = auth.uid() when present (cannot be
  -- spoofed); p_actor is fallback attribution for NULL-auth service calls.
  -- Any non-NULL actor must hold an inventory-manager role. If both are set
  -- and disagree, the authenticated identity wins and p_actor is ignored.
  -- request.jwt.claims is NO LONGER forged (nested gated RPC call removed).
  v_actor := COALESCE(auth.uid(), p_actor);
  -- PRD-139b 2B: was "IF v_actor IS NOT NULL THEN ... END IF" -- when BOTH auth.uid()
  -- and p_actor were NULL, the role check never ran at all. Fixed to fail closed.
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'record_actual_refill: no caller identity (neither session nor p_actor)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE id = v_actor
                 AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])) THEN
    RAISE EXCEPTION 'record_actual_refill: actor % is not an inventory manager', v_actor;
  END IF;

  -- header (persists even if apply fails, so a failure is recorded)
  INSERT INTO refill_events (machine_id, plan_date, source, captured_by, status, reason)
  VALUES (v_machine_id, p_plan_date, p_source, v_actor,
          CASE WHEN p_dry_run THEN 'dry_run' ELSE 'pending' END, p_reason)
  RETURNING event_id INTO v_event_id;

  BEGIN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_lineno   := v_lineno + 1;
      v_action   := v_line->>'action';
      v_bpid     := (v_line->>'boonz_product_id')::uuid;
      v_shelf_code := v_line->>'shelf_code';
      v_qty      := (v_line->>'qty')::numeric;
      v_setmode  := COALESCE(v_line->>'set_mode','delta');
      v_exp      := NULLIF(v_line->>'expiration_date','')::date;
      v_wh       := NULLIF(v_line->>'warehouse_id','')::uuid;
      v_partner  := v_line->>'partner_machine';
      v_notes    := v_line->>'notes';
      v_shelf_id := NULL; v_pod_id := NULL; v_partner_id := NULL;
      v_cur := NULL; v_newqty := NULL; v_pod_delta := NULL;
      v_debit_needed := NULL; v_wh_moves := NULL; v_discrepancy := NULL;

      IF v_action IS NULL OR v_action NOT IN
         ('refill','remove','write_off','transfer_out','transfer_in','wh_return','wh_receive') THEN
        RAISE EXCEPTION 'line %: bad action %', v_lineno, v_action; END IF;
      IF v_bpid IS NULL THEN RAISE EXCEPTION 'line %: boonz_product_id required', v_lineno; END IF;
      IF NOT EXISTS (SELECT 1 FROM boonz_products WHERE product_id = v_bpid) THEN
        RAISE EXCEPTION 'line %: product % not found', v_lineno, v_bpid; END IF;
      IF v_partner IS NOT NULL THEN
        SELECT machine_id INTO v_partner_id FROM machines WHERE official_name = v_partner; END IF;

      -- resolve shelf for pod-affecting actions
      IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
        IF v_shelf_code IS NULL THEN RAISE EXCEPTION 'line %: shelf_code required for %', v_lineno, v_action; END IF;
        SELECT shelf_id INTO v_shelf_id FROM shelf_configurations
          WHERE machine_id = v_machine_id AND shelf_code = v_shelf_code;
        IF v_shelf_id IS NULL THEN RAISE EXCEPTION 'line %: shelf % not on machine', v_lineno, v_shelf_code; END IF;
      END IF;

      -- POD arithmetic (computed in BOTH modes so dry_run previews deltas)
      IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
        SELECT current_stock INTO v_cur FROM pod_inventory
          WHERE machine_id = v_machine_id AND shelf_id = v_shelf_id AND boonz_product_id = v_bpid
            AND status='Active' AND (expiration_date = v_exp OR (expiration_date IS NULL AND v_exp IS NULL))
          LIMIT 1;
        IF v_setmode = 'set' THEN
          v_newqty := v_qty;
        ELSIF v_action IN ('remove','write_off','transfer_out') THEN
          v_newqty := GREATEST(COALESCE(v_cur,0) - v_qty, 0);
          -- [RC-02 EDIT] clamp no longer silent
          IF COALESCE(v_cur,0) < v_qty THEN
            v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
              'pod_remove_exceeds_stock', jsonb_build_object(
                'requested', v_qty, 'shelf_stock_before', COALESCE(v_cur,0)));
          END IF;
        ELSE
          v_newqty := COALESCE(v_cur,0) + v_qty;
        END IF;
        v_pod_delta := v_newqty - COALESCE(v_cur,0);
        IF v_action IN ('refill','transfer_in') AND v_setmode = 'set' AND v_pod_delta < 0 THEN
          v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
            'set_below_current', jsonb_build_object(
              'shelf_stock_before', COALESCE(v_cur,0), 'set_to', v_qty, 'pod_delta', v_pod_delta));
        END IF;
      END IF;

      -- WAREHOUSE debit planning (refill only; delta = pod units actually loaded)
      IF v_wh IS NOT NULL AND v_action = 'refill' THEN
        v_debit_needed := GREATEST(COALESCE(v_pod_delta,0), 0);
        IF p_dry_run AND v_debit_needed > 0 THEN
          SELECT COALESCE(MAX(f.total_pickable), 0) INTO v_avail
            FROM public.wh_fefo_for_line(v_machine_id, v_bpid, p_plan_date, v_debit_needed, ARRAY[v_wh]) f;
          IF v_avail < v_debit_needed THEN
            v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
              'wh_shortfall', jsonb_build_object(
                'needed', v_debit_needed, 'pickable', v_avail,
                'short', v_debit_needed - v_avail, 'preview', true));
          END IF;
        END IF;
      END IF;

      IF NOT p_dry_run THEN
        -- POD effect (unchanged path: canonical pod RPC)
        IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
          SELECT public.adjust_pod_inventory(
            p_machine_name, p_plan_date,
            jsonb_build_array(jsonb_build_object(
              'boonz_product_id', v_bpid, 'new_qty', v_newqty,
              'expiration_date', v_exp, 'shelf_code', v_shelf_code,
              'batch_id', 'RECORD-'||to_char(p_plan_date,'YYYY-MM-DD'))),
            COALESCE(p_reason,'record_actual_refill')) INTO v_pod_res;
          v_pod_id := (v_pod_res->'details'->0->>'pod_inventory_id')::uuid;
        END IF;

        -- WAREHOUSE effect: direct row-targeted writes with refill_event provenance
        IF v_wh IS NOT NULL AND v_action = 'refill' AND v_debit_needed > 0 THEN
          PERFORM public.set_write_context('record_actual_refill',
            format('record_actual_refill event=%s line=%s refill %s x%s from wh %s',
                   v_event_id, v_lineno, v_shelf_code, v_qty, v_wh),
            'refill_event', v_event_id::text);
          v_remaining := v_debit_needed;
          v_wh_moves  := '[]'::jsonb;
          -- canonical machine-scoped FEFO picks, driver-declared expiry first
          FOR v_pick IN
            SELECT f.wh_inventory_id, f.expiration_date, f.batch_id
              FROM public.wh_fefo_for_line(v_machine_id, v_bpid, p_plan_date, v_debit_needed, ARRAY[v_wh]) f
             ORDER BY (f.expiration_date IS NOT DISTINCT FROM v_exp) DESC, f.pick_rank
          LOOP
            EXIT WHEN v_remaining <= 0;
            SELECT wh_inventory_id, warehouse_stock INTO v_lock_id, v_lock_stock
              FROM warehouse_inventory
             WHERE wh_inventory_id = v_pick.wh_inventory_id
               AND status = 'Active' AND warehouse_stock > 0
             FOR UPDATE;
            IF NOT FOUND THEN CONTINUE; END IF;
            v_take := LEAST(v_remaining, v_lock_stock);
            UPDATE warehouse_inventory
               SET warehouse_stock = warehouse_stock - v_take,
                   snapshot_date   = p_plan_date
             WHERE wh_inventory_id = v_lock_id;
            v_wh_moves := v_wh_moves || jsonb_build_object(
              'wh_inventory_id', v_lock_id, 'delta', -v_take,
              'expiration_date', v_pick.expiration_date, 'batch_id', v_pick.batch_id);
            v_remaining := v_remaining - v_take;
          END LOOP;
          IF v_remaining > 0 THEN
            v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
              'wh_shortfall', jsonb_build_object(
                'needed', v_debit_needed, 'debited', v_debit_needed - v_remaining,
                'short', v_remaining));
          END IF;
          IF jsonb_array_length(v_wh_moves) = 0 THEN v_wh_moves := NULL; END IF;

        ELSIF v_wh IS NOT NULL AND v_action IN ('wh_receive','wh_return') THEN
          PERFORM public.set_write_context('record_actual_refill',
            format('record_actual_refill event=%s line=%s %s x%s to wh %s',
                   v_event_id, v_lineno, v_action, v_qty, v_wh),
            'refill_event', v_event_id::text);
          SELECT wh_inventory_id INTO v_credit_id FROM warehouse_inventory
            WHERE boonz_product_id = v_bpid AND warehouse_id = v_wh AND status='Active'
              AND (expiration_date = v_exp OR (expiration_date IS NULL AND v_exp IS NULL))
            ORDER BY created_at DESC LIMIT 1
            FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory
               SET warehouse_stock = COALESCE(warehouse_stock,0) + v_qty,
                   snapshot_date   = p_plan_date
             WHERE wh_inventory_id = v_credit_id;
          ELSE
            INSERT INTO warehouse_inventory
              (boonz_product_id, warehouse_id, warehouse_stock, expiration_date, status,
               batch_id, snapshot_date)
            VALUES
              (v_bpid, v_wh, v_qty, v_exp, 'Active',
               format('REFILL-EVENT-%s', to_char(p_plan_date,'YYYY-MM-DD')), p_plan_date)
            RETURNING wh_inventory_id INTO v_credit_id;
          END IF;
          v_wh_moves := jsonb_build_array(jsonb_build_object(
            'wh_inventory_id', v_credit_id, 'delta', v_qty, 'expiration_date', v_exp));
        END IF;

        -- restore the generic write context for subsequent statements
        PERFORM public.set_write_context('record_actual_refill',
          COALESCE(p_reason,'record_actual_refill'), NULL, NULL);

        -- discrepancies never pass silently: one monitoring alert per line
        IF v_discrepancy IS NOT NULL THEN
          INSERT INTO monitoring_alerts (source, severity, payload)
          VALUES ('rc02_record_actual_refill_discrepancy', 'warning',
            jsonb_build_object(
              'event_id', v_event_id, 'line_no', v_lineno,
              'machine', p_machine_name, 'plan_date', p_plan_date,
              'boonz_product_id', v_bpid, 'action', v_action,
              'shelf_code', v_shelf_code, 'warehouse_id', v_wh,
              'discrepancy', v_discrepancy));
        END IF;

        -- LOG effect (refill_plan_output) for machine-facing actions only
        v_rpo_action := CASE
          WHEN v_action IN ('refill','transfer_in') THEN 'Refill'
          WHEN v_action IN ('remove','write_off','transfer_out') THEN 'Remove'
          ELSE NULL END;
        IF v_rpo_action IS NOT NULL THEN
          INSERT INTO refill_plan_output
            (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name,
             action, quantity, operator_status, operator_comment, reviewed_at, dispatched, comment)
          SELECT p_plan_date, p_machine_name, v_shelf_code,
                 bp.boonz_product_name, bp.boonz_product_name, v_rpo_action, v_qty,
                 'approved',
                 COALESCE(p_reason,'record_actual_refill')
                   || CASE WHEN v_partner IS NOT NULL THEN ' ('||v_action||' '||v_partner||')' ELSE '' END,
                 now(), false, 'record_actual_refill'
          FROM boonz_products bp WHERE bp.product_id = v_bpid;
        END IF;
      END IF;

      INSERT INTO refill_event_lines
        (event_id, action, boonz_product_id, shelf_id, qty, set_mode, expiration_date,
         warehouse_id, partner_machine_id, result_pod_inventory_id, applied, notes,
         discrepancy, wh_moves)
      VALUES
        (v_event_id, v_action, v_bpid, v_shelf_id, v_qty, v_setmode, v_exp,
         v_wh, v_partner_id, v_pod_id, (NOT p_dry_run), v_notes,
         v_discrepancy, v_wh_moves);
      v_applied := v_applied + 1;

      v_line_details := v_line_details || jsonb_build_object(
        'line_no', v_lineno, 'action', v_action, 'shelf_code', v_shelf_code,
        'pod_before', v_cur, 'pod_after', v_newqty, 'pod_delta', v_pod_delta,
        'wh_debit_needed', v_debit_needed, 'wh_moves', v_wh_moves,
        'discrepancy', v_discrepancy);
    END LOOP;

    IF p_dry_run THEN
      UPDATE refill_events SET status = 'dry_run' WHERE event_id = v_event_id;
    ELSE
      UPDATE refill_events SET status = 'applied', applied_at = now() WHERE event_id = v_event_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- subtransaction rolled back ALL target writes + line inserts; record the failure on the header
    UPDATE refill_events SET status = 'failed', error_text = SQLERRM WHERE event_id = v_event_id;
    RETURN jsonb_build_object('status','failed','event_id',v_event_id,'failed_at_line',v_lineno,'error',SQLERRM);
  END;

  RETURN jsonb_build_object(
    'status', CASE WHEN p_dry_run THEN 'dry_run_ok' ELSE 'applied' END,
    'event_id', v_event_id, 'machine', p_machine_name, 'plan_date', p_plan_date,
    'lines', v_applied,
    'line_details', v_line_details);
END;
$function$;

-- ============================================================
-- 11. wm_confirm_line -- class (b)+(c): prefers client-supplied p_caller over
--     auth.uid() AND fails open when the combined caller is NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION public.wm_confirm_line(p_line_id uuid, p_qty numeric, p_expiry date, p_outcome text, p_target_machine_id uuid DEFAULT NULL::uuid, p_disposal_code text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_caller uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true, p_batch_breakdown jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(auth.uid(), p_caller);
  v_role text; v_line record; v_target_wh uuid; v_existing warehouse_inventory%ROWTYPE;
  v_wh_inventory_id uuid; v_credited_mode text; v_state text; v_waste_by date;
  v_value_aed numeric; v_event_id uuid;
  v_row jsonb; v_row_idx integer; v_row_qty numeric; v_row_expiry date;
  v_breakdown_sum numeric; v_last_event_id uuid; v_events jsonb := '[]'::jsonb;
BEGIN
  -- PRD-139b 2B: was "COALESCE(p_caller, auth.uid())" (client-supplied value preferred
  -- over the session identity -- spoofable) and "IF v_user_id IS NOT NULL AND NOT EXISTS
  -- (...)" (fails open when both are NULL). Fixed: auth.uid() wins whenever a session
  -- exists, p_caller is now only a fallback for a genuine NULL-auth service call, and a
  -- NULL caller is refused rather than silently let through.
  IF v_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN RAISE EXCEPTION 'forbidden: wm_confirm_line requires warehouse, operator_admin, superadmin, or manager'; END IF;
  IF p_line_id IS NULL THEN RAISE EXCEPTION 'wm_confirm_line: p_line_id is required'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'wm_confirm_line: p_qty must be > 0'; END IF;
  IF p_outcome NOT IN ('restocked','redeploy_pending','waste','acknowledged') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_outcome must be restocked | redeploy_pending | waste | acknowledged (got %)', p_outcome; END IF;
  IF p_expiry IS NOT NULL AND p_expiry = '2099-12-31'::date THEN
    RAISE EXCEPTION 'wm_confirm_line: p_expiry cannot be the 2099-12-31 sentinel — supply the real batch date or NULL'; END IF;
  IF p_outcome = 'waste' AND COALESCE(p_disposal_code,'') = '' THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code is required when p_outcome=waste'; END IF;
  IF p_disposal_code IS NOT NULL AND p_disposal_code NOT IN ('Waste','Returning to supplier','Returned to supplier') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code must be Waste|Returning to supplier|Returned to supplier (got %)', p_disposal_code; END IF;
  IF p_outcome = 'redeploy_pending' AND (p_target_machine_id IS NULL OR p_expiry IS NULL) THEN
    RAISE EXCEPTION 'wm_confirm_line: redeploy_pending requires p_target_machine_id and p_expiry'; END IF;
  IF COALESCE(p_reason,'') = '' THEN RAISE EXCEPTION 'wm_confirm_line: p_reason is required'; END IF;

  IF p_batch_breakdown IS NOT NULL THEN
    IF jsonb_typeof(p_batch_breakdown) <> 'array' OR jsonb_array_length(p_batch_breakdown) = 0 THEN
      RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown must be a non-empty jsonb array';
    END IF;
    v_breakdown_sum := 0;
    FOR v_row_idx IN 0 .. jsonb_array_length(p_batch_breakdown) - 1 LOOP
      v_row := p_batch_breakdown -> v_row_idx;
      v_row_qty := (v_row ->> 'qty')::numeric;
      IF v_row_qty IS NULL OR v_row_qty <= 0 THEN
        RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown[%].qty must be > 0', v_row_idx;
      END IF;
      IF (v_row ->> 'expiration_date') IS NULL THEN
        RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown[%].expiration_date is required', v_row_idx;
      END IF;
      IF (v_row ->> 'expiration_date')::date = '2099-12-31'::date THEN
        RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown[%].expiration_date cannot be the 2099-12-31 sentinel', v_row_idx;
      END IF;
      v_breakdown_sum := v_breakdown_sum + v_row_qty;
    END LOOP;
    IF v_breakdown_sum <> p_qty THEN
      RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown rows sum to % but p_qty is %', v_breakdown_sum, p_qty;
    END IF;
  END IF;

  SELECT * INTO v_line FROM public.v_wm_confirmations WHERE line_id = p_line_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'wm_confirm_line: % is not an open Warehouse Confirmations line', p_line_id; END IF;

  IF v_line.source IN ('refill_return_ack', 'quarantine_batch') THEN
    IF p_batch_breakdown IS NOT NULL THEN
      RAISE EXCEPTION 'wm_confirm_line: p_batch_breakdown is not supported for source % (acknowledge-only, no warehouse_inventory credit)', v_line.source;
    END IF;
    IF p_outcome <> 'acknowledged' THEN
      RAISE EXCEPTION 'wm_confirm_line: source % only accepts p_outcome=acknowledged (got %)', v_line.source, p_outcome;
    END IF;

    IF p_dry_run THEN
      RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source,
        'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'outcome', 'acknowledged');
    END IF;

    IF v_line.source = 'refill_return_ack' THEN
      PERFORM public.set_write_context('wm_confirm_line',
        format('wm_confirm_line line=%s source=%s qty=%s outcome=acknowledged by=%s: %s',
          p_line_id, v_line.source, p_qty, COALESCE(v_user_id::text,'system'), p_reason),
        'dispatch_return', p_line_id::text);
      UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id
       WHERE dispatch_id = p_line_id;
    ELSE
      PERFORM set_config('app.via_rpc',  'true', true);
      PERFORM set_config('app.rpc_name', 'wm_confirm_line', true);
      PERFORM set_config('app.mutation_reason',
        format('wm_confirm_line line=%s source=quarantine_batch qty=%s outcome=acknowledged by=%s: %s',
          p_line_id, p_qty, COALESCE(v_user_id::text,'system'), p_reason), true);
      UPDATE public.warehouse_inventory SET provenance_reason = 'manual_adjust'
       WHERE wh_inventory_id = p_line_id;
    END IF;

    INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason, dispatch_id, wh_inventory_id)
    VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, p_expiry, p_qty,
      'restocked', format('[%s] %s', v_line.source, p_reason),
      CASE WHEN v_line.source = 'refill_return_ack' THEN p_line_id ELSE NULL END,
      CASE WHEN v_line.source = 'quarantine_batch' THEN p_line_id ELSE NULL END)
    RETURNING event_id INTO v_event_id;

    RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source, 'event_id', v_event_id, 'outcome', 'acknowledged', 'qty', p_qty);
  END IF;

  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);
  IF v_target_wh IS NULL THEN RAISE EXCEPTION 'wm_confirm_line: machine % has no primary_warehouse_id', v_line.machine_id; END IF;
  SELECT avg_cost INTO v_value_aed FROM public.boonz_products WHERE product_id = v_line.boonz_product_id;
  v_state := p_outcome;

  IF p_dry_run THEN
    IF p_batch_breakdown IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source, 'machine_id', v_line.machine_id,
        'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'outcome', p_outcome,
        'target_warehouse_id', v_target_wh, 'target_machine_id', p_target_machine_id,
        'batch_breakdown', p_batch_breakdown);
    END IF;
    v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN p_expiry - 2 ELSE NULL END;
    RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source, 'machine_id', v_line.machine_id,
      'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
      'target_warehouse_id', v_target_wh, 'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed * p_qty);
  END IF;

  PERFORM public.set_write_context('wm_confirm_line',
    format('wm_confirm_line line=%s source=%s qty=%s expiry=%s outcome=%s by=%s: %s',
      p_line_id, v_line.source, p_qty, p_expiry, p_outcome, COALESCE(v_user_id::text,'system'), p_reason),
    CASE WHEN p_outcome = 'waste' THEN 'expiry_writeoff' ELSE 'dispatch_return' END, p_line_id::text);

  IF p_batch_breakdown IS NOT NULL THEN
    FOR v_row_idx IN 0 .. jsonb_array_length(p_batch_breakdown) - 1 LOOP
      v_row := p_batch_breakdown -> v_row_idx;
      v_row_qty := (v_row ->> 'qty')::numeric;
      v_row_expiry := (v_row ->> 'expiration_date')::date;

      SELECT * INTO v_existing FROM public.warehouse_inventory
       WHERE boonz_product_id = v_line.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active'
         AND expiration_date = v_row_expiry
       ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

      IF FOUND THEN
        v_credited_mode := 'topped_up'; v_wh_inventory_id := v_existing.wh_inventory_id;
        UPDATE public.warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock,0) + v_row_qty,
          reserved_for_machine_id = CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE reserved_for_machine_id END
         WHERE wh_inventory_id = v_wh_inventory_id;
      ELSE
        v_credited_mode := 'inserted';
        INSERT INTO public.warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id, reserved_for_machine_id)
        VALUES (v_line.boonz_product_id, v_row_qty, v_row_expiry, 'Active', format('WM-CONFIRM-%s-%s', p_line_id, v_row_idx), CURRENT_DATE, v_target_wh,
          CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END)
        RETURNING wh_inventory_id INTO v_wh_inventory_id;
      END IF;

      IF p_outcome = 'waste' THEN PERFORM public.warehouse_expire_writeoff(v_wh_inventory_id, p_reason, v_user_id, p_disposal_code); END IF;

      v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN v_row_expiry - 2 ELSE NULL END;
      INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state,
         disposal_code, target_machine_id, waste_by, value_aed, reason, dispatch_id, wh_inventory_id)
      VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, v_row_expiry, v_row_qty, v_state,
         CASE WHEN p_outcome = 'waste' THEN p_disposal_code ELSE NULL END,
         CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END,
         v_waste_by, v_value_aed * v_row_qty, p_reason, v_line.dispatch_id, v_wh_inventory_id)
      RETURNING event_id INTO v_event_id;

      v_last_event_id := v_event_id;
      v_events := v_events || jsonb_build_object('wh_inventory_id', v_wh_inventory_id, 'credited_mode', v_credited_mode,
        'qty', v_row_qty, 'expiry', v_row_expiry, 'event_id', v_event_id);
    END LOOP;

    IF v_line.source = 'dispatch_return' THEN
      UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id WHERE dispatch_id = p_line_id;
    ELSE
      UPDATE public.disposition_events SET superseded_by_event = v_last_event_id WHERE event_id = p_line_id;
    END IF;

    RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source,
      'qty', p_qty, 'outcome', p_outcome, 'target_machine_id', p_target_machine_id, 'batches', v_events);
  END IF;

  v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN p_expiry - 2 ELSE NULL END;
  v_value_aed := v_value_aed * p_qty;

  SELECT * INTO v_existing FROM public.warehouse_inventory
   WHERE boonz_product_id = v_line.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active'
     AND ((expiration_date = p_expiry) OR (expiration_date IS NULL AND p_expiry IS NULL))
   ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    v_credited_mode := 'topped_up'; v_wh_inventory_id := v_existing.wh_inventory_id;
    UPDATE public.warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock,0) + p_qty,
      reserved_for_machine_id = CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE reserved_for_machine_id END
     WHERE wh_inventory_id = v_wh_inventory_id;
  ELSE
    v_credited_mode := 'inserted';
    INSERT INTO public.warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id, reserved_for_machine_id)
    VALUES (v_line.boonz_product_id, p_qty, p_expiry, 'Active', format('WM-CONFIRM-%s', p_line_id), CURRENT_DATE, v_target_wh,
      CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END)
    RETURNING wh_inventory_id INTO v_wh_inventory_id;
  END IF;

  IF p_outcome = 'waste' THEN PERFORM public.warehouse_expire_writeoff(v_wh_inventory_id, p_reason, v_user_id, p_disposal_code); END IF;

  INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state,
     disposal_code, target_machine_id, waste_by, value_aed, reason, dispatch_id, wh_inventory_id)
  VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, p_expiry, p_qty, v_state,
     CASE WHEN p_outcome = 'waste' THEN p_disposal_code ELSE NULL END,
     CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END,
     v_waste_by, v_value_aed, p_reason, v_line.dispatch_id, v_wh_inventory_id)
  RETURNING event_id INTO v_event_id;

  IF v_line.source = 'dispatch_return' THEN
    UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id WHERE dispatch_id = p_line_id;
  ELSE
    UPDATE public.disposition_events SET superseded_by_event = v_event_id WHERE event_id = p_line_id;
  END IF;

  RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source, 'event_id', v_event_id,
    'wh_inventory_id', v_wh_inventory_id, 'credited_mode', v_credited_mode,
    'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
    'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed);
END $function$;

-- ============================================================
-- 12. cancel_po_line -- class (b)
-- ============================================================
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
  v_open_lines     integer;
  v_received_lines integer;
BEGIN
  v_caller_id := auth.uid();

  SELECT role INTO v_caller_role
  FROM public.user_profiles WHERE id = v_caller_id;

  -- PRD-139b 2B: was "IF v_caller_role NOT IN (...)" -- a NULL caller/role fell through.
  IF v_caller_id IS NULL OR v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
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

-- ============================================================
-- 13. set_product_mapping_splits -- class (c): looked up role by the CLIENT-SUPPLIED
--     p_caller_id only, never checked auth.uid() at all. p_caller_id kept in the
--     signature (still used for logging only, unchanged).
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_product_mapping_splits(p_pod_product_id uuid, p_machine_id uuid, p_splits jsonb, p_reason text, p_caller_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role text;
  v_entry jsonb;
  v_boonz_id uuid;
  v_pct numeric;
  v_sum numeric := 0;
  v_n int;
  v_wanted_ids uuid[] := '{}';
  v_activated int := 0;
  v_deactivated int := 0;
BEGIN
  -- PRD-139b 2B: was "WHERE id = p_caller_id" -- a client could pass any uuid (e.g. an
  -- admin's) and inherit that role. Now resolves the real session identity.
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_caller_role IS NULL OR v_caller_role NOT IN ('operator_admin', 'superadmin', 'manager', 'warehouse') THEN
    RAISE EXCEPTION 'set_product_mapping_splits: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_pod_product_id is required';
  END IF;
  IF p_machine_id IS NULL THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_machine_id is required';
  END IF;
  IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_splits must be a jsonb array';
  END IF;
  v_n := jsonb_array_length(p_splits);
  IF v_n < 1 THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_splits must have at least one entry';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'set_product_mapping_splits: p_reason is required';
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_splits) LOOP
    v_boonz_id := NULLIF(v_entry ->> 'boonz_product_id', '')::uuid;
    v_pct := (v_entry ->> 'split_pct')::numeric;
    IF v_boonz_id IS NULL THEN
      RAISE EXCEPTION 'set_product_mapping_splits: every split needs a boonz_product_id';
    END IF;
    IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
      RAISE EXCEPTION 'set_product_mapping_splits: split_pct for % must be between 0 and 100 (got %)', v_boonz_id, v_pct;
    END IF;
    IF v_boonz_id = ANY (v_wanted_ids) THEN
      RAISE EXCEPTION 'set_product_mapping_splits: boonz_product_id % appears more than once in p_splits', v_boonz_id;
    END IF;
    v_wanted_ids := array_append(v_wanted_ids, v_boonz_id);
    v_sum := v_sum + v_pct;
  END LOOP;

  IF round(v_sum) <> 100 THEN
    RAISE EXCEPTION 'set_product_mapping_splits: Active splits must total 100 (got %)', v_sum;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_product_mapping_splits', true);
  PERFORM set_config('app.mutation_reason',
    format('set_product_mapping_splits: pod=%s machine=%s reason=%s caller=%s',
      p_pod_product_id, p_machine_id, p_reason, p_caller_id), true);

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_splits) LOOP
    v_boonz_id := (v_entry ->> 'boonz_product_id')::uuid;
    v_pct := (v_entry ->> 'split_pct')::numeric;
    INSERT INTO product_mapping (pod_product_id, boonz_product_id, machine_id, split_pct, mix_weight, status)
    VALUES (p_pod_product_id, v_boonz_id, p_machine_id, v_pct, v_pct / 100.0, 'Active')
    ON CONFLICT (pod_product_id, boonz_product_id, machine_id)
    DO UPDATE SET split_pct = EXCLUDED.split_pct, mix_weight = EXCLUDED.mix_weight,
      status = 'Active', updated_at = now();
    v_activated := v_activated + 1;
  END LOOP;

  UPDATE product_mapping
  SET status = 'Inactive', split_pct = 0, mix_weight = 0, updated_at = now()
  WHERE pod_product_id = p_pod_product_id
    AND machine_id = p_machine_id
    AND status = 'Active'
    AND NOT (boonz_product_id = ANY (v_wanted_ids));
  GET DIAGNOSTICS v_deactivated = ROW_COUNT;

  RETURN jsonb_build_object(
    'status', 'ok', 'pod_product_id', p_pod_product_id, 'machine_id', p_machine_id,
    'activated', v_activated, 'deactivated', v_deactivated, 'total_pct', v_sum);
END;
$function$;

-- ============================================================
-- 14. set_machine_status -- class (b)+(c): prefers client-supplied p_caller over
--     auth.uid() AND fails open when both are NULL. p_caller kept in the signature as a
--     fallback for genuine NULL-auth service calls, same pattern as record_actual_refill.
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_machine_status(p_machine_id uuid, p_status text DEFAULT NULL::text, p_adyen_status text DEFAULT NULL::text, p_adyen_inventory_in_store text DEFAULT NULL::text, p_installation_date date DEFAULT NULL::date, p_reason text DEFAULT NULL::text, p_caller uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := COALESCE(auth.uid(), p_caller);
  v_role text;
  v_row public.machines%ROWTYPE;
  v_new_status text;
  v_new_adyen_status text;
  v_new_adyen_inventory_in_store text;
  v_new_installation_date date;
  v_event_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_machine_status', true);

  -- PRD-139b 2B: was "COALESCE(p_caller, auth.uid())" (client-supplied value preferred
  -- over the session identity -- spoofable) wrapped in "IF v_caller IS NOT NULL THEN
  -- ... END IF" (fails open when both are NULL). Fixed: auth.uid() wins whenever a
  -- session exists, p_caller is only a fallback for a genuine NULL-auth service call,
  -- and a NULL/unauthorized caller is refused.
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;
  IF v_caller IS NULL OR v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'set_machine_status: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  IF p_machine_id IS NULL THEN
    RAISE EXCEPTION 'set_machine_status: p_machine_id required';
  END IF;
  IF length(COALESCE(p_reason,'')) < 10 THEN
    RAISE EXCEPTION 'set_machine_status: p_reason must be at least 10 characters';
  END IF;
  IF p_status IS NULL AND p_adyen_status IS NULL AND p_adyen_inventory_in_store IS NULL AND p_installation_date IS NULL THEN
    RAISE EXCEPTION 'set_machine_status: at least one of p_status/p_adyen_status/p_adyen_inventory_in_store/p_installation_date must be provided';
  END IF;

  SELECT * INTO v_row FROM public.machines WHERE machine_id = p_machine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_machine_status: machine % not found', p_machine_id;
  END IF;

  v_new_status := COALESCE(p_status, v_row.status);
  v_new_adyen_status := COALESCE(p_adyen_status, v_row.adyen_status);
  v_new_adyen_inventory_in_store := COALESCE(p_adyen_inventory_in_store, v_row.adyen_inventory_in_store);
  v_new_installation_date := COALESCE(p_installation_date, v_row.installation_date);

  UPDATE public.machines
     SET status = v_new_status,
         adyen_status = v_new_adyen_status,
         adyen_inventory_in_store = v_new_adyen_inventory_in_store,
         installation_date = v_new_installation_date,
         updated_at = now()
   WHERE machine_id = p_machine_id;

  INSERT INTO public.machine_status_events (
    machine_id, old_status, new_status,
    old_adyen_status, new_adyen_status,
    old_adyen_inventory_in_store, new_adyen_inventory_in_store,
    old_installation_date, new_installation_date,
    reason, changed_by, changed_by_role, via_rpc, rpc_name
  ) VALUES (
    p_machine_id, v_row.status, v_new_status,
    v_row.adyen_status, v_new_adyen_status,
    v_row.adyen_inventory_in_store, v_new_adyen_inventory_in_store,
    v_row.installation_date, v_new_installation_date,
    p_reason, v_caller, v_role, true, 'set_machine_status'
  ) RETURNING event_id INTO v_event_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'machine_id', p_machine_id,
    'event_id', v_event_id,
    'before', jsonb_build_object(
      'status', v_row.status, 'adyen_status', v_row.adyen_status,
      'adyen_inventory_in_store', v_row.adyen_inventory_in_store,
      'installation_date', v_row.installation_date),
    'after', jsonb_build_object(
      'status', v_new_status, 'adyen_status', v_new_adyen_status,
      'adyen_inventory_in_store', v_new_adyen_inventory_in_store,
      'installation_date', v_new_installation_date)
  );
END;
$function$;

-- ============================================================
-- 15. repurpose_machine -- class (a), no role check existed.
-- ============================================================
CREATE OR REPLACE FUNCTION public.repurpose_machine(p_old_machine_id uuid, p_new_official_name text, p_new_pod_location text, p_new_location_type text, p_new_building_id text DEFAULT NULL::text, p_new_source_of_supply text DEFAULT NULL::text, p_new_venue_group text DEFAULT 'INDEPENDENT'::text)
 RETURNS TABLE(old_machine_id uuid, new_machine_id uuid, slots_archived integer, aliases_wired integer, result text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_new_machine_id   uuid := gen_random_uuid();
  v_slots_archived   int;
  v_old_official     text;
  v_old_weimi_name   text;
  v_new_weimi_name   text;
  v_aliases_wired    int := 0;
  v_caller_role      text; -- PRD-139b 2B
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'repurpose_machine', true);

  -- PRD-139b 2B: fail-closed role check, no check existed before.
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_caller_role IS NULL
     OR v_caller_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'repurpose_machine: forbidden for role %', COALESCE(v_caller_role, 'none (no session)');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.machines
    WHERE machine_id = p_old_machine_id AND repurposed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Machine % does not exist or is already repurposed', p_old_machine_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.machines
    WHERE official_name = p_new_official_name
      AND repurposed_at IS NULL
      AND machine_id    != p_old_machine_id
  ) THEN
    RAISE EXCEPTION 'An active machine with name % already exists', p_new_official_name;
  END IF;

  IF p_new_venue_group NOT IN ('ADDMIND','VOX','VML','WPP','OHMYDESK','INDEPENDENT') THEN
    RAISE EXCEPTION 'Invalid venue_group: %. Must be one of ADDMIND, VOX, VML, WPP, OHMYDESK, INDEPENDENT.', p_new_venue_group;
  END IF;

  SELECT official_name, COALESCE(pod_location, official_name)
  INTO   v_old_official, v_old_weimi_name
  FROM   public.machines
  WHERE  machine_id = p_old_machine_id;

  v_new_weimi_name := COALESCE(NULLIF(TRIM(p_new_pod_location), ''), p_new_official_name);

  UPDATE public.machines
  SET repurposed_at = CURRENT_DATE, previous_location = official_name,
      adyen_status = 'Switched off', adyen_inventory_in_store = 'Switched off',
      include_in_refill = false, updated_at = now()
  WHERE machine_id = p_old_machine_id;

  UPDATE public.slot_lifecycle SET archived = true
  WHERE machine_id = p_old_machine_id AND archived = false;
  GET DIAGNOSTICS v_slots_archived = ROW_COUNT;

  INSERT INTO public.machines (
    machine_id, official_name, pod_location, location_type,
    building_id, source_of_supply, venue_group,
    adyen_status, adyen_inventory_in_store, include_in_refill, created_at, updated_at
  ) VALUES (
    v_new_machine_id, p_new_official_name, v_new_weimi_name, p_new_location_type,
    p_new_building_id, p_new_source_of_supply, p_new_venue_group,
    'Online today', 'Live', true, now(), now()
  );

  UPDATE public.machine_name_aliases SET machine_id = p_old_machine_id
  WHERE original_name = v_old_weimi_name AND machine_id IS NULL;

  UPDATE public.machine_name_aliases SET machine_id = p_old_machine_id
  WHERE original_name = REPLACE(v_old_weimi_name, '-', '_') AND machine_id IS NULL;

  INSERT INTO public.machine_name_aliases (original_name, official_name, machine_id, is_active)
  VALUES (v_old_weimi_name, v_old_official, p_old_machine_id, true)
  ON CONFLICT (machine_id, original_name) DO NOTHING;

  INSERT INTO public.machine_name_aliases (original_name, official_name, machine_id, is_active)
  VALUES (v_new_weimi_name, p_new_official_name, v_new_machine_id, true)
  ON CONFLICT (machine_id, original_name) DO NOTHING;

  INSERT INTO public.machine_name_aliases (original_name, official_name, machine_id, is_active)
  VALUES (p_new_official_name, p_new_official_name, v_new_machine_id, true)
  ON CONFLICT (machine_id, original_name) DO NOTHING;

  v_aliases_wired := 2;

  RETURN QUERY SELECT p_old_machine_id, v_new_machine_id, v_slots_archived, v_aliases_wired, 'success'::text;
END;
$function$;
