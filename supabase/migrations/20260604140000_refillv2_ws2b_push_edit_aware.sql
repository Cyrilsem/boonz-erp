-- Refill reliability / WS2b - push_plan_to_dispatch edit-aware (stop clobbering manual dispatch swaps).
-- STATUS: DRAFT - NOT APPLIED. Cody-reviewed below.
--
-- ROOT CAUSE (postmortem RC2 / PRD WS2 Problem A): push_plan_to_dispatch regenerates refill_dispatching
-- rows from refill_plan_output. After an operator manually swaps a shelf at dispatch level
-- (remove_dispatch_row -> include=false, edit_count++  +  add_dispatch_row -> created_by_edit=true), a
-- re-push (e.g. after a re-stitch reset refill_plan_output.dispatched=false) re-inserts the STALE plan row,
-- resurrecting the swapped-out product (VML A01: Popit came back over Coke Zero).
--
-- FIX: before inserting a plan row for (machine, dispatch_date, shelf, pod_product), check whether the
-- operator has already reworked that exact key at dispatch level - any refill_dispatching row with
-- created_by_edit, edit_count>0, cancelled, or skipped (the markers add_dispatch_row / remove_dispatch_row /
-- cancel_dispatch_line / skip_dispatch_line set). If so, DO NOT regenerate over it: consume the plan line
-- (dispatched=true), link it to the operator's row, and continue. Makes push idempotent + edit-aware.
--
-- Verbatim reproduction of push_plan_to_dispatch v4 ((p_plan_date date, p_machine_name text) - the live
-- FEFO-pin overload the FE calls), diff-gated to: + v_preserved / v_existing_edit_id decls, + the
-- edit-aware guard block, + 'lines_preserved_manual_edit' in the return, + rpc_version 'v5_ws2_edit_aware'.
-- The legacy (p_machine_name text, p_plan_date date) overload (self-tagged 'v2_legacy_overload',
-- deprecated) is NOT touched here; recommend deprecating it (Article 13) to remove the named-arg overload
-- ambiguity - flagged to CS, not auto-dropped.

CREATE OR REPLACE FUNCTION public.push_plan_to_dispatch(p_plan_date date, p_machine_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id              uuid;
  v_machine_id           uuid;
  v_primary_warehouse_id uuid;
  v_count                int := 0;
  v_skipped              int := 0;
  v_pinned_count         int := 0;
  v_procurement_gaps     int := 0;
  v_preserved            int := 0;
  line                   RECORD;
  v_shelf_id             uuid;
  v_pod_product_id       uuid;
  v_boonz_product_id     uuid;
  v_normalized_shelf     text;
  v_action               text;
  v_dispatch_comment     text;
  v_new_dispatch_id      uuid;
  v_existing_edit_id     uuid;
  v_pinned_wh_id         uuid;
  v_pinned_expiry        date;
  v_pin_eligible         boolean;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'push_plan_to_dispatch: caller % lacks required role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RETURN jsonb_build_object('status','error','error','p_plan_date is required'); END IF;
  IF p_machine_name IS NULL OR length(trim(p_machine_name)) = 0 THEN
    RETURN jsonb_build_object('status','error','error','p_machine_name is required');
  END IF;

  SELECT machine_id, primary_warehouse_id INTO v_machine_id, v_primary_warehouse_id
    FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: '||p_machine_name);
  END IF;

  FOR line IN
    SELECT * FROM refill_plan_output
    WHERE plan_date = p_plan_date AND machine_name = p_machine_name
      AND operator_status = 'approved' AND dispatched = false
  LOOP
    v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
    SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id=v_machine_id AND shelf_code=v_normalized_shelf;
    SELECT pod_product_id INTO v_pod_product_id FROM pod_products WHERE lower(trim(pod_product_name))=lower(trim(line.pod_product_name)) LIMIT 1;
    SELECT product_id INTO v_boonz_product_id FROM boonz_products WHERE lower(trim(boonz_product_name))=lower(trim(line.boonz_product_name)) LIMIT 1;

    IF v_boonz_product_id IS NULL OR v_pod_product_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    -- WS2: edit-aware idempotency. If the operator already reworked this (machine,date,shelf,pod) at
    -- dispatch level, do NOT regenerate the stale plan row over it (the A01 Popit-over-Coke-Zero clobber).
    SELECT rd.dispatch_id INTO v_existing_edit_id
      FROM refill_dispatching rd
     WHERE rd.machine_id     = v_machine_id
       AND rd.dispatch_date  = line.plan_date
       AND rd.shelf_id       = v_shelf_id
       AND rd.pod_product_id = v_pod_product_id
       AND (rd.created_by_edit OR rd.edit_count > 0 OR rd.cancelled OR rd.skipped)
     ORDER BY rd.created_at DESC NULLS LAST
     LIMIT 1;
    IF v_existing_edit_id IS NOT NULL THEN
      UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_edit_id WHERE id = line.id;
      v_preserved := v_preserved + 1;
      CONTINUE;
    END IF;

    v_action := CASE upper(trim(line.action))
      WHEN 'REFILL' THEN 'Refill' WHEN 'ADD NEW' THEN 'Add New'
      WHEN 'REMOVE' THEN 'Remove' WHEN 'MACHINE TO WAREHOUSE' THEN 'Machine To Warehouse'
      WHEN 'SWAP' THEN 'Add New' ELSE trim(line.action)
    END;

    v_dispatch_comment := CASE
      WHEN line.operator_comment IS NOT NULL AND trim(line.operator_comment) != '' THEN
        COALESCE(NULLIF(trim(line.comment), '') || E'\n', '') || E'\U0001F4AC ' || trim(line.operator_comment)
      ELSE line.comment
    END;

    -- F4 FEFO pin: warehouse-sourced Refill or Add New only.
    v_pin_eligible := (v_action IN ('Refill','Add New'))
                      AND (COALESCE(line.source_origin::text, 'warehouse') = 'warehouse');
    v_pinned_wh_id := NULL;
    v_pinned_expiry := NULL;

    IF v_pin_eligible AND v_primary_warehouse_id IS NOT NULL THEN
      SELECT wh_inventory_id, expiration_date
        INTO v_pinned_wh_id, v_pinned_expiry
      FROM warehouse_inventory
       WHERE warehouse_id = v_primary_warehouse_id
         AND boonz_product_id = v_boonz_product_id
         AND status = 'Active'
         AND coalesce(warehouse_stock, 0) > 0
       ORDER BY expiration_date ASC NULLS LAST, wh_inventory_id ASC
       LIMIT 1;

      IF v_pinned_wh_id IS NULL THEN
        v_procurement_gaps := v_procurement_gaps + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES (
          'procurement_gap',
          'warning',
          jsonb_build_object(
            'title', format('Procurement gap: %s at %s', line.boonz_product_name, p_machine_name),
            'plan_date', p_plan_date,
            'machine_name', p_machine_name,
            'machine_id', v_machine_id,
            'boonz_product_id', v_boonz_product_id,
            'boonz_product_name', line.boonz_product_name,
            'wh_id', v_primary_warehouse_id,
            'action', v_action,
            'qty_needed', line.quantity,
            'detected_by', 'push_plan_to_dispatch_FEFO_pin',
            'detected_at', now()
          )
        );
      ELSE
        v_pinned_count := v_pinned_count + 1;
      END IF;
    END IF;

    INSERT INTO refill_dispatching (
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      dispatch_date, action, quantity, include, comment,
      from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
      source_origin, from_machine_id,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES (
      v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
      line.plan_date, v_action, line.quantity, true, v_dispatch_comment,
      v_primary_warehouse_id, v_pinned_wh_id, v_pinned_expiry, v_pin_eligible,
      COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
      CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
      false, false, false, false, false
    ) RETURNING dispatch_id INTO v_new_dispatch_id;

    UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status','ok',
    'machine', p_machine_name,
    'lines_pushed', v_count,
    'lines_skipped_null_product', v_skipped,
    'lines_preserved_manual_edit', v_preserved,
    'lines_pinned_at_plan_time', v_pinned_count,
    'procurement_gaps_logged', v_procurement_gaps,
    'rpc_version','v5_ws2_edit_aware'
  );
END $function$;
