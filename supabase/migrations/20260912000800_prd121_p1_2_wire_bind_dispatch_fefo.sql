-- PRD-121 P1.2: multi-batch FEFO split was built but never wired in -- the "abandoned
-- engine" root cause.
--
-- push_plan_to_dispatch's own inline FEFO pin logic already documents, in its own
-- comment, that it deliberately refuses to pin a line when the single earliest batch
-- (or its cumulative predecessors) doesn't alone cover the full quantity -- "a genuine
-- multi-batch split is deliberately left unbound here for bind_dispatch_fefo (PRD-118
-- item H) to resolve afterward." That handoff was never made: bind_dispatch_fefo exists,
-- is correct (walks FEFO, splits across batches via driver_confirmed_breakdown exactly
-- like set_dispatch_line_breakdown's shape, respects reserved_for_machine_id, excludes
-- phantom rows via the canonical _is_phantom_wh_row_v3), but has ZERO callers anywhere in
-- the live system -- not push_plan_to_dispatch, not approve_refill_plan, no cron, no FE
-- (grepped src/ and pg_proc: its only callers, restitch_after_edits and
-- create_spot_purchase_v3, are themselves never called by anything either). Every line
-- push_plan_to_dispatch left unbound for exactly this reason has stayed unbound forever.
--
-- Fix: call bind_dispatch_fefo(p_plan_date, ARRAY[p_machine_name], v_user_id) from
-- push_plan_to_dispatch's own tail, alongside its two existing post-loop auto-repair
-- calls (pair_internal_transfer_m2m, repair_remove_leg_shelf_lot_bulk) -- same
-- BEGIN/EXCEPTION-WHEN-OTHERS safety pattern, so a bind failure logs a monitoring_alert
-- and never aborts the push itself. bind_dispatch_fefo's own role gate
-- (warehouse/operator_admin/superadmin/manager, or NULL caller) is IDENTICAL to
-- push_dispatch_authorized_roles() -- verified no legitimate push_plan_to_dispatch caller
-- can be rejected by the inline call. bind_dispatch_fefo's own floor
-- (Active/not-quarantined/not-expired/not-phantom, same shape as v_wh_pickable) is
-- unchanged -- it already matches what push_plan_to_dispatch's own single-batch pin logic
-- accepts, so wiring it in does not introduce a new, inconsistent standard.
--
-- NOT done here, and explicitly flagged rather than guessed: "prefer batches with expiry
-- > plan_date+21" as a blanket ordering preference. Pure FEFO (earliest-expiry-first) and
-- "prefer long-dated" are in direct tension for the common case -- validate_refill_plan's
-- own G9 already treats <21-day-remaining stock as a WARNING, never a hard exclusion, and
-- no existing FEFO picker in this codebase (wh_fefo_for_line, bind_dispatch_fefo, the
-- G6 rebind mechanism) implements a >21-day preference. Bolting one onto bind_dispatch_fefo
-- alone, only now, would make it diverge from its own siblings rather than converge with
-- them. Recommend a CS decision on the intended shape before building it.
--
-- Cody: approve. Articles 1 (push_plan_to_dispatch remains the sole writer sequencing
-- this; bind_dispatch_fefo is its own established, unchanged DEFINER writer, not a new
-- write path), 4 (role gates match, verified), 12 (forward-only CREATE OR REPLACE, same
-- signature, md5-guarded), 16 (bind_dispatch_fefo's existing floor already matches its
-- sibling pickers -- no new divergent predicate introduced).

DO $mig$ DECLARE v_def text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='push_plan_to_dispatch' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'b0e84e22816bd4da07f340a414426c9a' THEN
    RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

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
  v_secondary_warehouse_id uuid;
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
  v_storage_temp         text;
  v_line_wh_id           uuid;
  v_wh_candidates        uuid[];
  v_pinned_route_wh      uuid;
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
  v_tombstoned           int := 0;
  v_lane_weimi_stock     int;
  v_flavor_corrected     int := 0;
  v_no_lot_on_shelf      int := 0;
  v_src_group            RECORD;
  v_dest_leg_id_first    uuid;
  v_bulk_repair          jsonb := NULL;
  v_fefo_bind            jsonb := NULL;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY (public.push_dispatch_authorized_roles())
  ) THEN
    RAISE EXCEPTION 'push_plan_to_dispatch: caller % lacks required role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RETURN jsonb_build_object('status','error','error','p_plan_date is required'); END IF;
  IF p_machine_name IS NULL OR length(trim(p_machine_name)) = 0 THEN
    RETURN jsonb_build_object('status','error','error','p_machine_name is required');
  END IF;

  SELECT machine_id, primary_warehouse_id, secondary_warehouse_id
    INTO v_machine_id, v_primary_warehouse_id, v_secondary_warehouse_id
    FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: '||p_machine_name);
  END IF;

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
      AND prp.status <> 'superseded'
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
    IF line.dispatch_id IS NOT NULL AND EXISTS (
      SELECT 1
        FROM public.refill_dispatching rd
        JOIN public.refill_dispatching_edit_log el
          ON el.dispatch_id = rd.dispatch_id AND el.edit_kind = 'remove'
       WHERE rd.dispatch_id   = line.dispatch_id
         AND rd.dispatch_date = p_plan_date
         AND COALESCE(rd.include, true) = false
    ) THEN
      v_tombstoned := v_tombstoned + 1;
      CONTINUE;
    END IF;

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

    -- PRD-118 item E, Addendum 2 §E-2: a removed (include=false) row must never
    -- absorb a fresh plan line. This was the actual cause of push_plan_to_dispatch's
    -- observed "one-shot" behaviour for a corrected row after a remove.
    SELECT rd.dispatch_id INTO v_existing_edit_id
      FROM refill_dispatching rd
     WHERE rd.machine_id     = v_machine_id
       AND rd.dispatch_date  = line.plan_date
       AND rd.shelf_id       = v_shelf_id
       AND rd.pod_product_id = v_pod_product_id
       AND (rd.created_by_edit OR rd.edit_count > 0)
       AND COALESCE(rd.include,   true) = true
       AND COALESCE(rd.skipped,   false) = false
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.returned,  false) = false
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

    IF v_action IN ('Refill','Add New')
       AND COALESCE(line.source_origin::text, 'warehouse') = 'warehouse' THEN
      SELECT rd.dispatch_id INTO v_existing_edit_id
        FROM refill_dispatching rd
       WHERE rd.machine_id       = v_machine_id
         AND rd.dispatch_date    = line.plan_date
         AND rd.shelf_id         = v_shelf_id
         AND rd.boonz_product_id = v_boonz_product_id
         AND rd.action           = v_action
         AND rd.include          = true
         AND COALESCE(rd.skipped,   false) = false
         AND COALESCE(rd.cancelled, false) = false
         AND COALESCE(rd.returned,  false) = false
         AND COALESCE(rd.is_m2m,    false) = false
       ORDER BY rd.created_at DESC NULLS LAST
       LIMIT 1;
      IF v_existing_edit_id IS NOT NULL THEN
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_edit_id WHERE id = line.id;
        v_preserved := v_preserved + 1;
        CONTINUE;
      END IF;
    END IF;

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
          SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id, pil.pod_inventory_id
            FROM public.v_pod_inventory_latest pil
           WHERE pil.machine_id = v_src_machine_id
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
            source_origin, from_machine_id, pod_lot_id,
            is_m2m, m2m_transfer_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_src_machine_id, COALESCE(v_batch.lot_shelf_id, v_src_shelf_id), v_pod_product_id, v_boonz_product_id,
            line.plan_date, 'Remove', v_take, true,
            COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name)),
            NULL, NULL, v_batch.expiration_date, false,
            'internal_transfer'::public.source_origin_enum, NULL, v_batch.pod_inventory_id,
            true, v_transfer_id, v_src_machine_id, 'm2m',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;
          IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;
          IF v_earliest_expiry IS NULL THEN v_earliest_expiry := v_batch.expiration_date; END IF;
          v_remaining := v_remaining - v_take;
          v_count := v_count + 1;
        END LOOP;
        IF v_remaining = line.quantity THEN
          FOR v_batch IN
            SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id,
                   pil.pod_inventory_id, pil.boonz_product_id AS lot_boonz_product_id
              FROM public.v_pod_inventory_latest pil
             WHERE pil.machine_id = v_src_machine_id
               AND pil.shelf_id = v_src_shelf_id
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
              source_origin, from_machine_id, pod_lot_id,
              is_m2m, m2m_transfer_id, source_machine_id, source_kind,
              packed, picked_up, dispatched, returned, item_added
            ) VALUES (
              v_src_machine_id, COALESCE(v_batch.lot_shelf_id, v_src_shelf_id), v_pod_product_id, v_batch.lot_boonz_product_id,
              line.plan_date, 'Remove', v_take, true,
              COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name))
                || format(E'\n[FLAVOR-CORRECTED: plan named %s, shelf actually holds %s]', line.boonz_product_name,
                     (SELECT bp3.boonz_product_name FROM boonz_products bp3 WHERE bp3.product_id = v_batch.lot_boonz_product_id)),
              NULL, NULL, v_batch.expiration_date, false,
              'internal_transfer'::public.source_origin_enum, NULL, v_batch.pod_inventory_id,
              true, v_transfer_id, v_src_machine_id, 'm2m',
              true, false, false, false, false
            ) RETURNING dispatch_id INTO v_new_dispatch_id;
            IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;
            IF v_earliest_expiry IS NULL THEN v_earliest_expiry := v_batch.expiration_date; END IF;
            v_remaining := v_remaining - v_take;
            v_count := v_count + 1; v_flavor_corrected := v_flavor_corrected + 1;
          END LOOP;
        END IF;
        IF v_remaining > 0 THEN
          IF v_remaining = line.quantity THEN
            INSERT INTO refill_dispatching (
              machine_id, shelf_id, pod_product_id, boonz_product_id,
              dispatch_date, action, quantity, include, comment,
              from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
              source_origin, from_machine_id,
              is_m2m, m2m_transfer_id, source_machine_id, source_kind,
              packed, picked_up, dispatched, returned, item_added
            ) VALUES (
              v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
              line.plan_date, 'Remove', 0, true,
              format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name) || E'\n' || '[NO LOT ON SHELF — nothing to remove here; resolved automatically, no driver action needed]',
              NULL, NULL, NULL, false,
              'internal_transfer'::public.source_origin_enum, NULL,
              true, v_transfer_id, v_src_machine_id, 'm2m',
              true, false, false, false, false
            ) RETURNING dispatch_id INTO v_new_dispatch_id;
            IF v_first_remove_id IS NULL THEN v_first_remove_id := v_new_dispatch_id; END IF;
            v_no_lot_on_shelf := v_no_lot_on_shelf + 1;
          ELSE
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
          END IF;
          v_count := v_count + 1;
        END IF;

        v_dest_leg_id_first := NULL;
        FOR v_src_group IN
          SELECT rd_src.boonz_product_id AS grp_boonz_product_id,
                 SUM(rd_src.quantity)::int AS grp_qty,
                 MIN(rd_src.expiry_date) AS grp_earliest_expiry,
                 (array_agg(rd_src.dispatch_id ORDER BY rd_src.created_at))[1] AS grp_first_dispatch_id
            FROM public.refill_dispatching rd_src
           WHERE rd_src.m2m_transfer_id = v_transfer_id AND rd_src.is_m2m = true
             AND rd_src.machine_id = v_src_machine_id
           GROUP BY rd_src.boonz_product_id
        LOOP
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id,
            is_m2m, m2m_transfer_id, m2m_partner_id, source_machine_id, source_kind,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_machine_id, v_shelf_id, v_pod_product_id, v_src_group.grp_boonz_product_id,
            line.plan_date, v_action, v_src_group.grp_qty, true,
            COALESCE(NULLIF(trim(v_dispatch_comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name))
              || CASE WHEN v_src_group.grp_boonz_product_id <> v_boonz_product_id
                      THEN format(E'\n[FLAVOR-CORRECTED: destination adopts %s pulled at source, plan named %s]',
                             (SELECT bp4.boonz_product_name FROM boonz_products bp4 WHERE bp4.product_id = v_src_group.grp_boonz_product_id),
                             line.boonz_product_name)
                      ELSE '' END,
            NULL, NULL, v_src_group.grp_earliest_expiry, false,
            'internal_transfer'::public.source_origin_enum, v_src_machine_id,
            true, v_transfer_id, v_src_group.grp_first_dispatch_id, v_src_machine_id, 'm2m',
            true, false, false, false, false
          ) RETURNING dispatch_id INTO v_dest_leg_id;

          UPDATE refill_dispatching SET m2m_partner_id = v_dest_leg_id
           WHERE m2m_transfer_id = v_transfer_id AND is_m2m = true
             AND machine_id = v_src_machine_id AND boonz_product_id = v_src_group.grp_boonz_product_id;

          IF v_dest_leg_id_first IS NULL THEN v_dest_leg_id_first := v_dest_leg_id; END IF;
          v_count := v_count + 1;
        END LOOP;

        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_dest_leg_id_first WHERE id = line.id;
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_first_remove_id WHERE id = v_src_line.id;
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
      SELECT w.current_stock INTO v_lane_weimi_stock
        FROM public.weimi_aisle_snapshots w
       WHERE w.machine_id = v_machine_id
         AND w.slot_code = LEFT(v_normalized_shelf,1) || (SUBSTR(v_normalized_shelf,2)::int)::text
         AND w.snapshot_date BETWEEN line.plan_date - 3 AND line.plan_date + 3
       ORDER BY ABS(w.snapshot_date - line.plan_date) ASC, w.snapshot_at DESC
       LIMIT 1;
      IF v_lane_weimi_stock IS NOT NULL AND line.quantity > v_lane_weimi_stock THEN
        PERFORM public.safe_monitoring_alert('remove_qty_exceeds_lane', 'warning',
          jsonb_build_object('machine', p_machine_name, 'shelf', v_normalized_shelf,
            'pod_product_id', v_pod_product_id, 'plan_qty', line.quantity,
            'lane_stock', v_lane_weimi_stock, 'plan_date', line.plan_date,
            'plan_line_id', line.id, 'detected_by', 'push_plan_to_dispatch'));
      END IF;

      v_remaining := line.quantity;
      v_new_dispatch_id := NULL;
      FOR v_batch IN
        SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id, pil.pod_inventory_id
          FROM public.v_pod_inventory_latest pil
         WHERE pil.machine_id = v_machine_id
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
          source_origin, from_machine_id, pod_lot_id,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_machine_id, COALESCE(v_batch.lot_shelf_id, v_shelf_id), v_pod_product_id, v_boonz_product_id,
          line.plan_date, v_action, v_take, true, v_dispatch_comment,
          v_primary_warehouse_id, NULL, v_batch.expiration_date, false,
          COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
          CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
          v_batch.pod_inventory_id,
          false, false, false, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;
        v_remaining := v_remaining - v_take;
        v_count := v_count + 1; v_remove_split := v_remove_split + 1;
      END LOOP;
      IF v_remaining = line.quantity THEN
        FOR v_batch IN
          SELECT pil.expiration_date, pil.current_stock, pil.shelf_id AS lot_shelf_id,
                 pil.pod_inventory_id, pil.boonz_product_id AS lot_boonz_product_id
            FROM public.v_pod_inventory_latest pil
           WHERE pil.machine_id = v_machine_id
             AND pil.shelf_id = v_shelf_id
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
            source_origin, from_machine_id, pod_lot_id,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_machine_id, COALESCE(v_batch.lot_shelf_id, v_shelf_id), v_pod_product_id, v_batch.lot_boonz_product_id,
            line.plan_date, v_action, v_take, true,
            COALESCE(NULLIF(v_dispatch_comment,'') || E'\n', '')
              || format('[FLAVOR-CORRECTED: plan named %s, shelf actually holds %s]', line.boonz_product_name,
                   (SELECT bp3.boonz_product_name FROM boonz_products bp3 WHERE bp3.product_id = v_batch.lot_boonz_product_id)),
            v_primary_warehouse_id, NULL, v_batch.expiration_date, false,
            COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
            CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
            v_batch.pod_inventory_id,
            false, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;
          v_remaining := v_remaining - v_take;
          v_count := v_count + 1; v_remove_split := v_remove_split + 1; v_flavor_corrected := v_flavor_corrected + 1;
        END LOOP;
      END IF;
      IF v_remaining > 0 THEN
        IF v_remaining = line.quantity THEN
          INSERT INTO refill_dispatching (
            machine_id, shelf_id, pod_product_id, boonz_product_id,
            dispatch_date, action, quantity, include, comment,
            from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
            source_origin, from_machine_id,
            packed, picked_up, dispatched, returned, item_added
          ) VALUES (
            v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
            line.plan_date, v_action, 0, true,
            COALESCE(NULLIF(v_dispatch_comment,'') || E'\n', '') || '[NO LOT ON SHELF — nothing to remove here; resolved automatically, no driver action needed]',
            v_primary_warehouse_id, NULL, NULL, false,
            COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
            CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
            false, false, false, false, false
          ) RETURNING dispatch_id INTO v_new_dispatch_id;
          v_no_lot_on_shelf := v_no_lot_on_shelf + 1;
        ELSE
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
        END IF;
        v_count := v_count + 1; v_remove_split := v_remove_split + 1;
      END IF;
      UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
      CONTINUE;
    END IF;

    v_pin_eligible := (v_action IN ('Refill','Add New'))
                      AND (COALESCE(line.source_origin::text, 'warehouse') = 'warehouse');
    v_pinned_wh_id := NULL;
    v_pinned_expiry := NULL;
    v_pinned_route_wh := NULL;

    SELECT storage_temp_requirement INTO v_storage_temp
      FROM boonz_products WHERE product_id = v_boonz_product_id;
    v_line_wh_id := CASE WHEN v_storage_temp = 'cold' THEN public.wh_central_id()
                         ELSE v_primary_warehouse_id END;
    v_wh_candidates := CASE WHEN v_storage_temp = 'cold' THEN ARRAY[v_line_wh_id]
                            ELSE ARRAY[v_line_wh_id, v_secondary_warehouse_id] END;

    IF v_pin_eligible AND v_line_wh_id IS NOT NULL THEN
      SELECT f.wh_inventory_id, f.expiration_date, f.warehouse_id
        INTO v_pinned_wh_id, v_pinned_expiry, v_pinned_route_wh
      FROM public.wh_fefo_for_line(
             v_machine_id, v_boonz_product_id, line.plan_date, line.quantity,
             v_wh_candidates) f
      WHERE f.is_satisfiable
        AND f.net_running >= line.quantity
      ORDER BY f.pick_rank
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
            'wh_id', v_line_wh_id, 'action', v_action, 'qty_needed', line.quantity,
            'detected_by', 'push_plan_to_dispatch_FEFO_pin_rc01', 'detected_at', now()
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
      v_line_wh_id, v_pinned_wh_id, v_pinned_expiry, v_pin_eligible,
      COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
      CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
      false, false, false, false, false
    )
    ON CONFLICT (dispatch_date, machine_id, shelf_id, boonz_product_id, action)
      WHERE ( include = true AND action IN ('Refill','Add New')
              AND COALESCE(filled_quantity,0)=0
              AND packed=false AND item_added=false AND returned=false
              AND skipped=false AND cancelled=false
              AND created_by_edit=false AND is_m2m=false )
    DO UPDATE SET
      quantity             = EXCLUDED.quantity,
      comment              = EXCLUDED.comment,
      from_wh_inventory_id = EXCLUDED.from_wh_inventory_id,
      expiry_date          = EXCLUDED.expiry_date,
      pinned_at_plan_time  = EXCLUDED.pinned_at_plan_time,
      from_warehouse_id    = EXCLUDED.from_warehouse_id
    RETURNING dispatch_id INTO v_new_dispatch_id;

    UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
    v_count := v_count + 1;
  END LOOP;

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
  BEGIN
    v_bulk_repair := public.repair_remove_leg_shelf_lot_bulk(p_plan_date, p_machine_name,
      'auto-run at push (PRD-120 L5 item 2): close any Remove leg the flavor fallback still left NULL', NULL, false);
  EXCEPTION WHEN OTHERS THEN
    v_bulk_repair := jsonb_build_object('status','error','error', SQLERRM);
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('push_auto_repair_failure', 'warning', jsonb_build_object(
      'title', format('Auto-repair of NULL pod_lot_id Remove legs failed on push: %s @ %s', p_machine_name, p_plan_date),
      'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
      'error', SQLERRM, 'detected_by', 'push_plan_to_dispatch_v14_prd120_l5', 'detected_at', now()));
  END;
  -- PRD-121 P1.2: the multi-batch FEFO split push's own inline pin logic explicitly
  -- defers to. Never wired in before now -- see migration header.
  BEGIN
    v_fefo_bind := public.bind_dispatch_fefo(p_plan_date, ARRAY[p_machine_name], v_user_id);
  EXCEPTION WHEN OTHERS THEN
    v_fefo_bind := jsonb_build_object('status','error','error', SQLERRM);
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('push_fefo_bind_failure', 'warning', jsonb_build_object(
      'title', format('Multi-batch FEFO bind failed on push: %s @ %s', p_machine_name, p_plan_date),
      'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
      'error', SQLERRM, 'detected_by', 'push_plan_to_dispatch_v16_prd121_p1_2', 'detected_at', now()));
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
    'lines_tombstoned', v_tombstoned,
    'remove_flavor_corrected', v_flavor_corrected,
    'remove_no_lot_on_shelf', v_no_lot_on_shelf,
    'auto_repair_null_pod_lot', v_bulk_repair,
    'fefo_multi_batch_bind', v_fefo_bind,
    'rpc_version','v16_prd121_p1_2_fefo_bind'
  );
END $function$;
