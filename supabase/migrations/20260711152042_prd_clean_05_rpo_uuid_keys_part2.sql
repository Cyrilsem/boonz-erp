-- PRD-CLEAN-05 M1b: push_plan_to_dispatch v9 — prefer refill_plan_output ID columns,
-- fall back to name matching for historical rows. Rollback:
-- docs/prds/rollback/push_plan_to_dispatch_2026-07-11.sql
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
  v_remove_split         int := 0;
  v_leak_n               int := 0;
  line                   RECORD;
  v_batch                RECORD;
  v_leak                 RECORD;
  v_remaining            int;
  v_take                 int;
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
  -- PRD-071 WS-B additions
  v_pairing              jsonb := NULL;
  v_prev_via_trigger     text;
  v_prev_mutation_reason text;
  v_transfer_id          uuid;
  v_src_line             RECORD;
  v_src_machine_id       uuid;
  v_src_shelf_id         uuid;
  v_src_normalized_shelf text;
  v_first_remove_id      uuid;
  v_dest_leg_id          uuid;
  v_earliest_expiry      date;
  v_transfer_pairs       int := 0;
  v_transfer_deferred    int := 0;
  v_transfer_skipped     int := 0;
  v_slot_guard           jsonb := NULL;
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

  -- drift-kill P1: WEIMI slot guard (block rejects mismatched plan lines here,
  -- before they bridge to dispatching; warn logs to monitoring_alerts)
  v_slot_guard := public.assert_weimi_slot_match(p_plan_date, NULL, p_machine_name);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

  v_leak_n := 0;
  FOR v_leak IN
    SELECT prp.shelf_id, prp.pod_product_id, prp.action,
           prp.qty::int AS parent, COALESCE(g.children,0)::int AS children
    FROM pod_refill_plan prp
    LEFT JOIN (
      SELECT sc.shelf_id, pp.pod_product_id,
             CASE upper(trim(rpo.action))
               WHEN 'REMOVE' THEN 'REMOVE' WHEN 'MACHINE TO WAREHOUSE' THEN 'M2W' END AS pod_action,
             SUM(rpo.quantity)::int AS children
      FROM refill_plan_output rpo
      JOIN shelf_configurations sc ON sc.machine_id = v_machine_id
           AND sc.shelf_code = regexp_replace(rpo.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2')
      JOIN pod_products pp ON lower(trim(pp.pod_product_name)) = lower(trim(rpo.pod_product_name))
      WHERE rpo.plan_date = p_plan_date AND rpo.machine_name = p_machine_name
        AND rpo.operator_status = 'approved' AND rpo.dispatched = false
        AND upper(trim(rpo.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
      GROUP BY sc.shelf_id, pp.pod_product_id, 3
    ) g ON g.shelf_id = prp.shelf_id AND g.pod_product_id = prp.pod_product_id AND g.pod_action = prp.action
    WHERE prp.plan_date = p_plan_date AND prp.machine_id = v_machine_id
      AND prp.action IN ('REMOVE','M2W') AND prp.qty > 0
      AND prp.qty <> COALESCE(g.children, 0)
  LOOP
    INSERT INTO public.stitch_leakage(plan_date, machine_id, shelf_id, pod_product_id,
                                      action, parent_pod_qty, children_sum, delta, detected_by)
    VALUES (p_plan_date, v_machine_id, v_leak.shelf_id, v_leak.pod_product_id,
            v_leak.action, v_leak.parent, v_leak.children, v_leak.parent - v_leak.children,
            'push_plan_to_dispatch');
    v_leak_n := v_leak_n + 1;
  END LOOP;
  IF v_leak_n > 0 THEN
    RETURN jsonb_build_object(
      'status','conservation_violation',
      'machine', p_machine_name,
      'leaking_instructions', v_leak_n,
      'reason','SUM(approved plan children) <> pod_refill_plan qty for REMOVE/M2W — stop-ship; logged durably to stitch_leakage (PRD-053)'
    );
  END IF;

  FOR line IN
    SELECT * FROM refill_plan_output
    WHERE plan_date = p_plan_date AND machine_name = p_machine_name
      AND operator_status = 'approved' AND dispatched = false
  LOOP
    -- PRD-CLEAN-05 v9: prefer the ID columns written by write_refill_plan g8;
    -- fall back to name matching for historical rows where they are NULL.
    v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
    v_shelf_id := line.shelf_id;
    IF v_shelf_id IS NULL THEN
      SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id=v_machine_id AND shelf_code=v_normalized_shelf;
    END IF;
    v_pod_product_id := line.pod_product_id;
    IF v_pod_product_id IS NULL THEN
      SELECT pod_product_id INTO v_pod_product_id FROM pod_products WHERE lower(trim(pod_product_name))=lower(trim(line.pod_product_name)) LIMIT 1;
    END IF;
    v_boonz_product_id := line.boonz_product_id;
    IF v_boonz_product_id IS NULL THEN
      SELECT product_id INTO v_boonz_product_id FROM boonz_products WHERE lower(trim(boonz_product_name))=lower(trim(line.boonz_product_name)) LIMIT 1;
    END IF;

    IF v_boonz_product_id IS NULL OR v_pod_product_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

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

    -- PRD-071 WS-B: internal_transfer lines become pre-paired M2M writes.
    -- block_orphan_internal_transfer (PRD-070) forbids unpaired legs, so the
    -- dest line (carries from_machine_id) creates BOTH legs atomically with a
    -- shared m2m_transfer_id; the source Remove line defers to the dest push.
    -- Per-line failures log to monitoring_alerts and never fail the push.
    IF COALESCE(line.source_origin::text,'warehouse') = 'internal_transfer' THEN
      IF v_action IN ('Remove','Machine To Warehouse') THEN
        v_transfer_deferred := v_transfer_deferred + 1;
        CONTINUE;
      END IF;
      IF v_action NOT IN ('Refill','Add New') OR line.from_machine_id IS NULL THEN
        v_transfer_skipped := v_transfer_skipped + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('m2m_push_unroutable','warning', jsonb_build_object(
          'title', format('M2M line unroutable at push: %s @ %s', line.boonz_product_name, p_machine_name),
          'plan_line_id', line.id, 'plan_date', p_plan_date, 'action', v_action,
          'from_machine_id', line.from_machine_id,
          'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
        CONTINUE;
      END IF;
      BEGIN
        SELECT rpo.* INTO v_src_line
          FROM refill_plan_output rpo
          JOIN machines sm ON sm.machine_id = line.from_machine_id AND sm.official_name = rpo.machine_name
         WHERE rpo.plan_date = line.plan_date
           AND rpo.source_origin = 'internal_transfer'
           AND upper(trim(rpo.action)) IN ('REMOVE','MACHINE TO WAREHOUSE')
           AND lower(trim(rpo.pod_product_name)) = lower(trim(line.pod_product_name))
           AND rpo.quantity = line.quantity
           AND rpo.operator_status = 'approved' AND rpo.dispatched = false
         ORDER BY rpo.id
         LIMIT 1;
        IF NOT FOUND THEN
          v_transfer_skipped := v_transfer_skipped + 1;
          INSERT INTO public.monitoring_alerts (source, severity, payload)
          VALUES ('m2m_push_no_source_line','warning', jsonb_build_object(
            'title', format('M2M dest line has no matching approved source Remove: %s @ %s', line.boonz_product_name, p_machine_name),
            'plan_line_id', line.id, 'plan_date', p_plan_date, 'qty', line.quantity,
            'from_machine_id', line.from_machine_id,
            'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
          CONTINUE;
        END IF;

        v_src_machine_id := line.from_machine_id;
        v_src_normalized_shelf := regexp_replace(v_src_line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
        v_src_shelf_id := v_src_line.shelf_id;
        IF v_src_shelf_id IS NULL THEN
          SELECT shelf_id INTO v_src_shelf_id FROM shelf_configurations
           WHERE machine_id = v_src_machine_id AND shelf_code = v_src_normalized_shelf;
        END IF;

        v_transfer_id := gen_random_uuid();
        v_first_remove_id := NULL;
        v_earliest_expiry := NULL;
        v_remaining := line.quantity;

        FOR v_batch IN
          SELECT pil.expiration_date, pil.current_stock
            FROM public.v_pod_inventory_latest pil
           WHERE pil.machine_id = v_src_machine_id
             AND pil.shelf_id   = v_src_shelf_id
             AND pil.boonz_product_id = v_boonz_product_id
             AND pil.status = 'Active'
             AND COALESCE(pil.current_stock,0) > 0
           ORDER BY pil.expiration_date ASC NULLS LAST
        LOOP
          EXIT WHEN v_remaining <= 0;
          v_take := LEAST(v_batch.current_stock, v_remaining);
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id,
            is_m2m, m2m_transfer_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
            line.plan_date, 'Remove', v_take, true,
            COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name)),
            NULL, NULL, v_batch.expiration_date, false,
            'internal_transfer'::public.source_origin_enum, NULL,
            true, v_transfer_id, v_src_machine_id, 'm2m',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;
          IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;
          IF v_earliest_expiry IS NULL THEN v_earliest_expiry := v_batch.expiration_date; END IF;
          v_remaining := v_remaining - v_take;
          v_count := v_count + 1;
        END LOOP;
        IF v_remaining > 0 THEN
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id,
            is_m2m, m2m_transfer_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
            line.plan_date, 'Remove', v_remaining, true,
            format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name) || E'\n' || '[EXPIRY-TO-CONFIRM - remainder not attributable to a known batch (PRD-053)]',
            NULL, NULL, NULL, false,
            'internal_transfer'::public.source_origin_enum, NULL,
            true, v_transfer_id, v_src_machine_id, 'm2m',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;
          IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;
          v_count := v_count + 1;
        END IF;

        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id,
          is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id, source_kind,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, line.quantity, true,
          COALESCE(NULLIF(trim(v_dispatch_comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name)),
          NULL, NULL, v_earliest_expiry, false,
          'internal_transfer'::public.source_origin_enum, v_src_machine_id,
          true, v_transfer_id, v_first_remove_id, v_src_machine_id, 'm2m',
          true, false, false, false, false
        ) RETURNING dispatch_id INTO v_dest_leg_id;

        UPDATE refill_dispatching SET m2m_partner_id = v_dest_leg_id
         WHERE m2m_transfer_id = v_transfer_id AND dispatch_id <> v_dest_leg_id;

        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_dest_leg_id WHERE id = line.id;
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_first_remove_id WHERE id = v_src_line.id;
        v_count := v_count + 1;
        v_transfer_pairs := v_transfer_pairs + 1;
      EXCEPTION WHEN OTHERS THEN
        v_transfer_skipped := v_transfer_skipped + 1;
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('m2m_push_pair_failure','warning', jsonb_build_object(
          'title', format('M2M paired insert failed at push: %s @ %s', line.boonz_product_name, p_machine_name),
          'plan_line_id', line.id, 'plan_date', p_plan_date, 'error', SQLERRM,
          'detected_by','push_plan_to_dispatch_v7_prd071','detected_at', now()));
      END;
      CONTINUE;
    END IF;

    IF v_action IN ('Remove','Machine To Warehouse') THEN
      v_remaining := line.quantity;
      v_new_dispatch_id := NULL;
      FOR v_batch IN
        SELECT pil.expiration_date, pil.current_stock
          FROM public.v_pod_inventory_latest pil
         WHERE pil.machine_id = v_machine_id
           AND pil.shelf_id   = v_shelf_id
           AND pil.boonz_product_id = v_boonz_product_id
           AND pil.status = 'Active'
           AND COALESCE(pil.current_stock,0) > 0
         ORDER BY pil.expiration_date ASC NULLS LAST
      LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(v_batch.current_stock, v_remaining);
        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, v_take, true, v_dispatch_comment,
          v_primary_warehouse_id, NULL, v_batch.expiration_date, false,
          COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
          CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
          false, false, false, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;
        v_remaining := v_remaining - v_take;
        v_count := v_count + 1; v_remove_split := v_remove_split + 1;
      END LOOP;
      IF v_remaining > 0 THEN
        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, v_remaining, true,
          COALESCE(NULLIF(v_dispatch_comment,'') || E'\n', '') || '[EXPIRY-TO-CONFIRM — remainder not attributable to a known batch (PRD-053)]',
          v_primary_warehouse_id, NULL, NULL, false,
          COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
          CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
          false, false, false, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;
        v_count := v_count + 1; v_remove_split := v_remove_split + 1;
      END IF;
      UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
      CONTINUE;
    END IF;

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
          'procurement_gap', 'warning',
          jsonb_build_object(
            'title', format('Procurement gap: %s at %s', line.boonz_product_name, p_machine_name),
            'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
            'boonz_product_id', v_boonz_product_id, 'boonz_product_name', line.boonz_product_name,
            'wh_id', v_primary_warehouse_id, 'action', v_action, 'qty_needed', line.quantity,
            'detected_by', 'push_plan_to_dispatch_FEFO_pin', 'detected_at', now()
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

  -- PRD-071 WS-B: safety-net pairing pass (idempotent; failure logs, never fails the push)
  v_prev_via_trigger := current_setting('app.via_trigger', true);
  v_prev_mutation_reason := current_setting('app.mutation_reason', true);
  BEGIN
    v_pairing := public.pair_internal_transfer_m2m(p_plan_date, v_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_pairing := jsonb_build_object('status','error','error', SQLERRM);
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('m2m_pairing_failure', 'warning', jsonb_build_object(
      'title', format('M2M auto-pairing failed on push: %s @ %s', p_machine_name, p_plan_date),
      'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
      'error', SQLERRM, 'detected_by', 'push_plan_to_dispatch_v7_prd071', 'detected_at', now()));
  END;
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);
  PERFORM set_config('app.via_trigger', COALESCE(v_prev_via_trigger, ''), true);
  PERFORM set_config('app.mutation_reason', COALESCE(v_prev_mutation_reason, ''), true);

  RETURN jsonb_build_object(
    'status','ok',
    'machine', p_machine_name,
    'lines_pushed', v_count,
    'lines_skipped_null_product', v_skipped,
    'lines_preserved_manual_edit', v_preserved,
    'lines_pinned_at_plan_time', v_pinned_count,
    'remove_split_lines', v_remove_split,
    'procurement_gaps_logged', v_procurement_gaps,
    'm2m_transfer_pairs', v_transfer_pairs,
    'm2m_transfer_deferred', v_transfer_deferred,
    'm2m_transfer_skipped', v_transfer_skipped,
    'm2m_pairing', v_pairing,
    'weimi_slot_guard', v_slot_guard,
    'rpc_version','v9_id_keyed_rpo'
  );
END $function$;