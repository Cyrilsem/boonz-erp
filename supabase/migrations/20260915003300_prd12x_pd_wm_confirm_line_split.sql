-- ONE-LOOP-2 Block D (PRD-123 P1/P2): wm_confirm_line_split lets the
-- warehouse manager confirm one returned line as several batches, each with
-- its own qty/expiry/outcome, and optionally re-attribute flavour within
-- the line's pod product. Reuses wm_confirm_line's per-entry validation and
-- credit logic verbatim (role check, outcome enum, 2099 sentinel refusal,
-- disposal_code rules, redeploy_pending requirements, top-up-else-insert),
-- looped once per entry, with wh_approved_at/by stamped once after the
-- loop. wm_confirm_line itself is NOT touched -- it is on the daytime
-- do-not-touch list, and R2.3 (giving it the same variance recording) is
-- explicitly deferred rather than edited live today.
--
-- R2.1/R2.2: variance is computed once (sum of entry qty vs the line's own
-- planned qty) and is never blocking -- the count is the truth. A variance
-- beyond 20% or 3 units writes one monitoring_alerts row
-- (return_count_variance).
--
-- Added to enforce_canonical_dispatch_write's allowlist: this function
-- stamps refill_dispatching.wh_approved_at/by exactly like wm_confirm_line
-- does.
CREATE OR REPLACE FUNCTION public.wm_confirm_line_split(
  p_line_id uuid,
  p_splits jsonb,
  p_reason text,
  p_caller uuid DEFAULT auth.uid(),
  p_dry_run boolean DEFAULT true
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_line record;
  v_target_wh uuid;
  v_entry jsonb;
  v_i int;
  v_qty numeric;
  v_expiry date;
  v_outcome text;
  v_boonz_product_id uuid;
  v_target_machine_id uuid;
  v_disposal_code text;
  v_sum_qty numeric := 0;
  v_variance_qty numeric;
  v_variance_pct numeric;
  v_preview jsonb := '[]'::jsonb;
  v_existing warehouse_inventory%ROWTYPE;
  v_wh_inventory_id uuid;
  v_credited_mode text;
  v_value_aed numeric;
  v_event_id uuid;
  v_waste_by date;
  v_n_entries int;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'wm_confirm_line_split', true);

  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'forbidden: wm_confirm_line_split requires warehouse, operator_admin, superadmin, or manager';
  END IF;

  IF p_line_id IS NULL THEN RAISE EXCEPTION 'wm_confirm_line_split: p_line_id is required'; END IF;
  IF COALESCE(p_reason,'') = '' THEN RAISE EXCEPTION 'wm_confirm_line_split: p_reason is required'; END IF;
  IF p_splits IS NULL OR jsonb_typeof(p_splits) <> 'array' THEN
    RAISE EXCEPTION 'wm_confirm_line_split: p_splits must be a jsonb array';
  END IF;
  v_n_entries := jsonb_array_length(p_splits);
  IF v_n_entries < 1 OR v_n_entries > 20 THEN
    RAISE EXCEPTION 'wm_confirm_line_split: p_splits must have between 1 and 20 entries (got %)', v_n_entries;
  END IF;

  SELECT * INTO v_line FROM public.v_wm_confirmations WHERE line_id = p_line_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wm_confirm_line_split: % is not an open Warehouse Confirmations line', p_line_id;
  END IF;

  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);
  IF v_target_wh IS NULL THEN
    RAISE EXCEPTION 'wm_confirm_line_split: machine % has no primary_warehouse_id', v_line.machine_id;
  END IF;

  FOR v_i IN 0..v_n_entries-1 LOOP
    v_entry := p_splits -> v_i;
    v_qty := (v_entry->>'qty')::numeric;
    v_expiry := NULLIF(v_entry->>'expiry','')::date;
    v_outcome := v_entry->>'outcome';
    v_target_machine_id := NULLIF(v_entry->>'target_machine_id','')::uuid;
    v_disposal_code := NULLIF(v_entry->>'disposal_code','');
    v_boonz_product_id := NULLIF(v_entry->>'boonz_product_id','')::uuid;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      RAISE EXCEPTION 'wm_confirm_line_split: entry % qty must be > 0', v_i;
    END IF;
    IF v_outcome NOT IN ('restocked','redeploy_pending','waste') THEN
      RAISE EXCEPTION 'wm_confirm_line_split: entry % outcome must be restocked | redeploy_pending | waste (got %)', v_i, v_outcome;
    END IF;
    IF v_expiry IS NOT NULL AND v_expiry = '2099-12-31'::date THEN
      RAISE EXCEPTION 'wm_confirm_line_split: entry % expiry cannot be the 2099-12-31 sentinel', v_i;
    END IF;
    IF v_outcome = 'waste' AND COALESCE(v_disposal_code,'') = '' THEN
      RAISE EXCEPTION 'wm_confirm_line_split: entry % disposal_code is required when outcome=waste', v_i;
    END IF;
    IF v_disposal_code IS NOT NULL AND v_disposal_code NOT IN ('Waste','Returning to supplier','Returned to supplier') THEN
      RAISE EXCEPTION 'wm_confirm_line_split: entry % disposal_code must be Waste|Returning to supplier|Returned to supplier (got %)', v_i, v_disposal_code;
    END IF;
    IF v_outcome = 'redeploy_pending' AND (v_target_machine_id IS NULL OR v_expiry IS NULL) THEN
      RAISE EXCEPTION 'wm_confirm_line_split: entry % redeploy_pending requires target_machine_id and expiry', v_i;
    END IF;
    IF v_boonz_product_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.product_mapping pm
       WHERE pm.boonz_product_id = v_boonz_product_id
         AND pm.pod_product_id = v_line.pod_product_id AND pm.status = 'Active'
    ) THEN
      RAISE EXCEPTION 'wm_confirm_line_split: entry % boonz_product_id % has no Active mapping to this line''s pod product', v_i, v_boonz_product_id;
    END IF;

    v_sum_qty := v_sum_qty + v_qty;
  END LOOP;

  v_variance_qty := v_sum_qty - v_line.qty;
  v_variance_pct := CASE WHEN v_line.qty > 0 THEN ROUND(100.0 * v_variance_qty / v_line.qty, 1) ELSE NULL END;

  IF p_dry_run THEN
    FOR v_i IN 0..v_n_entries-1 LOOP
      v_entry := p_splits -> v_i;
      v_preview := v_preview || jsonb_build_array(jsonb_build_object(
        'entry_index', v_i,
        'qty', (v_entry->>'qty')::numeric,
        'expiry', v_entry->>'expiry',
        'outcome', v_entry->>'outcome',
        'boonz_product_id', COALESCE(NULLIF(v_entry->>'boonz_product_id','')::uuid, v_line.boonz_product_id),
        'target_warehouse_id', v_target_wh
      ));
    END LOOP;
    RETURN jsonb_build_object(
      'status', 'dry_run_ok', 'line_id', p_line_id, 'entries', v_preview,
      'planned_qty', v_line.qty, 'counted_qty', v_sum_qty,
      'variance_qty', v_variance_qty, 'variance_pct', v_variance_pct
    );
  END IF;

  FOR v_i IN 0..v_n_entries-1 LOOP
    v_entry := p_splits -> v_i;
    v_qty := (v_entry->>'qty')::numeric;
    v_expiry := NULLIF(v_entry->>'expiry','')::date;
    v_outcome := v_entry->>'outcome';
    v_target_machine_id := NULLIF(v_entry->>'target_machine_id','')::uuid;
    v_disposal_code := NULLIF(v_entry->>'disposal_code','');
    v_boonz_product_id := COALESCE(NULLIF(v_entry->>'boonz_product_id','')::uuid, v_line.boonz_product_id);
    v_waste_by := CASE WHEN v_outcome = 'redeploy_pending' THEN v_expiry - 2 ELSE NULL END;

    SELECT avg_cost INTO v_value_aed FROM public.boonz_products WHERE product_id = v_boonz_product_id;
    v_value_aed := v_value_aed * v_qty;

    SELECT * INTO v_existing FROM public.warehouse_inventory
     WHERE boonz_product_id = v_boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active'
       AND ((expiration_date = v_expiry) OR (expiration_date IS NULL AND v_expiry IS NULL))
     ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

    IF FOUND THEN
      v_credited_mode := 'topped_up'; v_wh_inventory_id := v_existing.wh_inventory_id;
      UPDATE public.warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock,0) + v_qty,
        reserved_for_machine_id = CASE WHEN v_outcome = 'redeploy_pending' THEN v_target_machine_id ELSE reserved_for_machine_id END
       WHERE wh_inventory_id = v_wh_inventory_id;
    ELSE
      v_credited_mode := 'inserted';
      INSERT INTO public.warehouse_inventory
        (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id, reserved_for_machine_id, provenance_reason)
      VALUES
        (v_boonz_product_id, v_qty, v_expiry, 'Active', format('WM-CONFIRM-SPLIT-%s-%s', p_line_id, v_i), CURRENT_DATE, v_target_wh,
         CASE WHEN v_outcome = 'redeploy_pending' THEN v_target_machine_id ELSE NULL END, 'manual_adjust')
      RETURNING wh_inventory_id INTO v_wh_inventory_id;
    END IF;

    IF v_outcome = 'waste' THEN
      PERFORM public.warehouse_expire_writeoff(v_wh_inventory_id, p_reason, v_user_id, v_disposal_code);
    END IF;

    INSERT INTO public.disposition_events
      (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state,
       disposal_code, target_machine_id, waste_by, value_aed, reason, dispatch_id, wh_inventory_id)
    VALUES
      (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_boonz_product_id, v_expiry, v_qty, v_outcome,
       CASE WHEN v_outcome = 'waste' THEN v_disposal_code ELSE NULL END,
       CASE WHEN v_outcome = 'redeploy_pending' THEN v_target_machine_id ELSE NULL END,
       v_waste_by, v_value_aed,
       p_reason || CASE WHEN v_variance_qty <> 0
         THEN format(' [split variance: counted %s vs planned %s, %s%%]', v_sum_qty, v_line.qty, v_variance_pct)
         ELSE '' END,
       v_line.dispatch_id, v_wh_inventory_id)
    RETURNING event_id INTO v_event_id;
  END LOOP;

  IF v_line.source = 'dispatch_return' THEN
    UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id WHERE dispatch_id = p_line_id;
  ELSE
    UPDATE public.disposition_events SET superseded_by_event = v_event_id WHERE event_id = p_line_id;
  END IF;

  IF ABS(COALESCE(v_variance_pct, 0)) > 20 OR ABS(v_variance_qty) > 3 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('return_count_variance', 'warning', jsonb_build_object(
      'title', format('Return count variance on %s %s', v_line.machine_name, v_line.shelf_code),
      'line_id', p_line_id, 'machine', v_line.machine_name, 'shelf', v_line.shelf_code,
      'product', v_line.boonz_product_name, 'expected', v_line.qty, 'counted', v_sum_qty,
      'variance_qty', v_variance_qty, 'variance_pct', v_variance_pct, 'detected_at', now()));
  END IF;

  RETURN jsonb_build_object(
    'status', 'confirmed', 'line_id', p_line_id, 'entries', v_n_entries,
    'planned_qty', v_line.qty, 'counted_qty', v_sum_qty,
    'variance_qty', v_variance_qty, 'variance_pct', v_variance_pct
  );
END;
$function$;
