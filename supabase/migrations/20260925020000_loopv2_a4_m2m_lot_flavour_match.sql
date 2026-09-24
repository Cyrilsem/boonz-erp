-- Loop 2026-09-25 A4 (G4): M2M destination lot binding must bind to source-shelf pod lots of
-- the SAME boonz_product_id (flavour), falling back to NULL, never binding another flavour's lot.
--
-- Root cause confirmed live before writing anything: both push_plan_to_dispatch's M2M source
-- (Remove) leg lot lookup and add_m2m_transfer's Remove leg lot lookup select the earliest-expiry
-- Active pod_inventory row on the source shelf via v_pod_inventory_latest, filtered only on
-- machine_id, shelf_id, status, current_stock -- with NO boonz_product_id filter, even though the
-- view carries that column. On a shelf holding more than one Active lot (a flavour changeover in
-- progress, or several SKUs sharing one physical lane), this always returns whichever lot happens
-- to expire soonest, regardless of which product is actually being moved.
--
-- Confirmed on the named evidence: ADDMIND-1007 A16 (machine_id 60a64b01-483a-48c9-a842-
-- ca09468452a6, shelf_id fa98304f-c0da-4a03-abdb-b1418672332c) carries three Active lots on that
-- one shelf: Vitamin Well Zero peach (expires 2027-01-10), Vitamin Well Zero Lemon (expiry NULL),
-- and Vitamin Well Antioxidant (expires 2026-09-27). The unfiltered query always returns the
-- Antioxidant row, so any M2M transfer moving Zero peach or Zero Lemon off that shelf got the
-- Antioxidant lot's near-term expiry stamped onto the Remove leg, which the grouped destination
-- insert then propagates via MIN(rd_src.expiry_date) -- tripping the 48h floor on stock that was
-- never actually close to expiring.
--
-- Fix: add "AND pil.boonz_product_id = <the product actually being transferred>" to both lookups.
-- Verified live (read-only, no writes) before this migration: filtered to Zero peach's
-- boonz_product_id returns 2027-01-10 as expected; filtered to Zero Lemon's boonz_product_id
-- returns NULL expiry (its own Active lot has no expiration_date); filtered to a nonexistent
-- product returns no row at all, which SELECT INTO correctly turns into NULL/NULL -- the intended
-- fallback, never another flavour's lot.
--
-- Surgical: only the two SELECT statements gain the one boonz_product_id predicate each. No other
-- line changes. The equivalent shelf-only lookup used for the plain (non-M2M) Remove/Machine To
-- Warehouse leg further down in push_plan_to_dispatch is a separate, non-M2M code path outside
-- A4's scope and is left untouched; see STATE.md open issues.
--
-- Smoke calls (rolled back, 2026-09-25 before apply): both functions recompiled and exercised
-- inside BEGIN/ROLLBACK against real data (ADDMIND-1007 A16, the exact named evidence), confirming
-- the filtered SELECT returns the matching product's lot, not Antioxidant's. Results in STATE.md.
--
-- Incidental fix found while smoke testing (still A4's own migration, same function): add_m2m_
-- transfer hardcoded edited_by_role to a literal NULL in its own edit_log inserts regardless of
-- v_role, violating refill_dispatching_edit_log's NOT NULL constraint on every call. Fixed with
-- the same COALESCE(v_role,'system') fallback A1 already established for cancel_m2m_transfer.

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
  v_remove_lot_expiry    date;
  v_remove_lot_id        uuid;
  v_source_kind          text;
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
      'reason','SUM(approved plan children) <> pod_refill_plan qty for REMOVE/M2W -- stop-ship; logged durably to stitch_leakage (PRD-053)'
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

    v_source_kind := CASE COALESCE(line.source_origin::text, 'warehouse')
      WHEN 'warehouse' THEN 'wh'
      WHEN 'vox_at_venue' THEN 'venue'
      WHEN 'internal_transfer' THEN 'm2m'
      ELSE 'unknown'
    END;

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

        -- Loop 2026-09-25 A4: filter to the SAME boonz_product_id being transferred
        -- (v_boonz_product_id, the plan's declared product for this destination line). Without
        -- this filter the lookup returned whichever Active lot on the source shelf expired
        -- soonest, regardless of product -- confirmed live on ADDMIND-1007 A16, which always
        -- returned the Antioxidant lot (2026-09-27) for Zero peach and Zero Lemon transfers. No
        -- matching lot for this product on the shelf now falls back to NULL (SELECT INTO with no
        -- matching row), never to another flavour's lot.
        SELECT pil.expiration_date, pil.pod_inventory_id
          INTO v_remove_lot_expiry, v_remove_lot_id
          FROM public.v_pod_inventory_latest pil
         WHERE pil.machine_id = v_src_machine_id
           AND pil.shelf_id = v_src_shelf_id
           AND pil.boonz_product_id = v_boonz_product_id
           AND pil.status = 'Active'
           AND COALESCE(pil.current_stock,0) > 0
         ORDER BY pil.expiration_date ASC NULLS LAST
         LIMIT 1;

        -- Loop 2026-09-25 A1: picked_up changes from true to false on the source (Remove) leg
        -- ONLY. This is the sole functional change that migration made to this INSERT.
        INSERT INTO refill_dispatching (
          machine_id, shelf_id, pod_product_id, boonz_product_id,
          dispatch_date, action, quantity, include, comment,
          from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
          source_origin, from_machine_id, pod_lot_id,
          is_m2m, m2m_transfer_id, source_machine_id, source_kind,
          packed, picked_up, dispatched, returned, item_added
        ) VALUES (
          v_src_machine_id, v_src_shelf_id, v_pod_product_id, v_boonz_product_id,
          line.plan_date, 'Remove', line.quantity, true,
          CASE WHEN v_remove_lot_expiry IS NULL THEN
            COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name))
              || E'\n[EXPIRY-TO-CONFIRM -- remainder not attributable to a known batch (PRD-053)]'
          ELSE
            COALESCE(NULLIF(trim(v_src_line.comment),''), format('M2M: %s -> %s', v_src_line.machine_name, p_machine_name))
          END,
          NULL, NULL, v_remove_lot_expiry, false,
          'internal_transfer'::public.source_origin_enum, NULL, v_remove_lot_id,
          true, v_transfer_id, v_src_machine_id, 'm2m',
          true, false, true, false, false
        ) RETURNING dispatch_id INTO v_new_dispatch_id;
        v_first_remove_id := v_new_dispatch_id;
        v_earliest_expiry := v_remove_lot_expiry;
        v_count := v_count + 1;

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

      -- Not touched by A4: this is the plain (non-M2M) Remove/Machine To Warehouse leg lookup,
      -- outside A4's named scope. See STATE.md open issues.
      SELECT pil.expiration_date, pil.pod_inventory_id
        INTO v_remove_lot_expiry, v_remove_lot_id
        FROM public.v_pod_inventory_latest pil
       WHERE pil.machine_id = v_machine_id
         AND pil.shelf_id = v_shelf_id
         AND pil.status = 'Active'
         AND COALESCE(pil.current_stock,0) > 0
       ORDER BY pil.expiration_date ASC NULLS LAST
       LIMIT 1;

      INSERT INTO refill_dispatching (
        machine_id, shelf_id, pod_product_id, boonz_product_id,
        dispatch_date, action, quantity, include, comment,
        from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
        source_origin, from_machine_id, pod_lot_id, source_kind, source_warehouse_id,
        packed, picked_up, dispatched, returned, item_added
      ) VALUES (
        v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
        line.plan_date, v_action, line.quantity, true,
        CASE WHEN v_remove_lot_expiry IS NULL THEN
          COALESCE(NULLIF(v_dispatch_comment,'') || E'\n', '') || '[EXPIRY-TO-CONFIRM -- remainder not attributable to a known batch (PRD-053)]'
        ELSE v_dispatch_comment END,
        v_primary_warehouse_id, NULL, v_remove_lot_expiry, false,
        COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
        CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
        v_remove_lot_id,
        CASE WHEN v_source_kind = 'wh' AND v_primary_warehouse_id IS NULL THEN 'unknown' ELSE v_source_kind END,
        CASE WHEN v_source_kind = 'wh' THEN v_primary_warehouse_id ELSE NULL END,
        false, false, false, false, false
      ) RETURNING dispatch_id INTO v_new_dispatch_id;
      v_count := v_count + 1; v_remove_split := v_remove_split + 1;
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
      source_origin, from_machine_id, source_kind, source_warehouse_id,
      packed, picked_up, dispatched, returned, item_added
    ) VALUES (
      v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
      line.plan_date, v_action, line.quantity, true, v_dispatch_comment,
      v_line_wh_id, v_pinned_wh_id, v_pinned_expiry, v_pin_eligible,
      COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
      CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
      CASE WHEN v_source_kind = 'wh' AND v_line_wh_id IS NULL THEN 'unknown' ELSE v_source_kind END,
      CASE WHEN v_source_kind = 'wh' THEN v_line_wh_id ELSE NULL END,
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
      from_warehouse_id    = EXCLUDED.from_warehouse_id,
      source_kind          = EXCLUDED.source_kind,
      source_warehouse_id  = EXCLUDED.source_warehouse_id
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
    'rpc_version','v21_loopv2_a4_m2m_lot_flavour_match'
  );
END $function$;

CREATE OR REPLACE FUNCTION public.add_m2m_transfer(p_source_machine_id uuid, p_source_shelf_code text, p_dest_machine_id uuid, p_dest_shelf_code text, p_boonz_product_id uuid, p_quantity numeric, p_dispatch_date date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role              text;
  v_src_shelf_id      uuid;
  v_dest_shelf_id     uuid;
  v_src_pod_product   uuid;
  v_dest_pod_product  uuid;
  v_lot_expiry        date;
  v_lot_id            uuid;
  v_transfer_id       uuid := gen_random_uuid();
  v_remove_id         uuid;
  v_add_id            uuid;
  v_slot              record;
  v_staged_remove     boolean;
  v_src_name          text;
  v_dest_name         text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','add_m2m_transfer',true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
    RAISE EXCEPTION 'forbidden: add_m2m_transfer requires operator_admin / superadmin / manager / warehouse';
  END IF;

  IF p_source_machine_id IS NULL OR p_dest_machine_id IS NULL OR p_boonz_product_id IS NULL
     OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_source_machine_id, p_dest_machine_id, p_boonz_product_id, p_quantity (>0) required';
  END IF;
  IF p_source_machine_id = p_dest_machine_id THEN
    RAISE EXCEPTION 'source and destination machines must differ. For a move within one machine, use add_intra_machine_move (PRD-130 F5).';
  END IF;

  SELECT official_name INTO v_src_name FROM public.machines WHERE machine_id = p_source_machine_id;
  SELECT official_name INTO v_dest_name FROM public.machines WHERE machine_id = p_dest_machine_id;
  IF v_src_name IS NULL THEN RAISE EXCEPTION 'source machine % not found', p_source_machine_id; END IF;
  IF v_dest_name IS NULL THEN RAISE EXCEPTION 'dest machine % not found', p_dest_machine_id; END IF;

  SELECT shelf_id INTO v_src_shelf_id FROM public.shelf_configurations
   WHERE machine_id = p_source_machine_id AND shelf_code = p_source_shelf_code;
  IF v_src_shelf_id IS NULL THEN RAISE EXCEPTION 'source shelf_code % not found on %', p_source_shelf_code, v_src_name; END IF;

  SELECT shelf_id INTO v_dest_shelf_id FROM public.shelf_configurations
   WHERE machine_id = p_dest_machine_id AND shelf_code = p_dest_shelf_code;
  IF v_dest_shelf_id IS NULL THEN RAISE EXCEPTION 'dest shelf_code % not found on %', p_dest_shelf_code, v_dest_name; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pod_inventory
    WHERE machine_id = p_source_machine_id AND boonz_product_id = p_boonz_product_id
      AND status = 'Active' AND current_stock > 0
  ) THEN
    RAISE EXCEPTION 'Source machine % does not carry an Active lot of boonz_product % (current_stock > 0)', v_src_name, p_boonz_product_id;
  END IF;

  SELECT sl.pod_product_id INTO v_src_pod_product
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_source_machine_id AND sl.shelf_id = v_src_shelf_id
    AND sl.is_current = true AND sl.archived = false
    AND EXISTS (SELECT 1 FROM public.product_mapping pm WHERE pm.pod_product_id = sl.pod_product_id
                  AND pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active')
  ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;
  IF v_src_pod_product IS NULL THEN
    SELECT pm.pod_product_id INTO v_src_pod_product FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
      AND (pm.machine_id = p_source_machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = p_source_machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
  END IF;
  IF v_src_pod_product IS NULL THEN
    RAISE EXCEPTION 'no Active product_mapping for boonz_product % on source machine %', p_boonz_product_id, v_src_name;
  END IF;

  SELECT sl.pod_product_id INTO v_dest_pod_product
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = p_dest_machine_id AND sl.shelf_id = v_dest_shelf_id
    AND sl.is_current = true AND sl.archived = false
    AND EXISTS (SELECT 1 FROM public.product_mapping pm WHERE pm.pod_product_id = sl.pod_product_id
                  AND pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active')
  ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;
  IF v_dest_pod_product IS NULL THEN
    SELECT pm.pod_product_id INTO v_dest_pod_product FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_boonz_product_id AND pm.status = 'Active'
      AND (pm.machine_id = p_dest_machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = p_dest_machine_id) DESC NULLS LAST, pm.is_global_default DESC LIMIT 1;
  END IF;
  IF v_dest_pod_product IS NULL THEN
    RAISE EXCEPTION 'no Active product_mapping for boonz_product % on dest machine %', p_boonz_product_id, v_dest_name;
  END IF;

  SELECT ssi.pod_product_id, ssi.pod_product_name, ssi.match_method
    INTO v_slot
  FROM public.v_shelf_slot_identity ssi
  WHERE ssi.machine_id = p_dest_machine_id AND ssi.shelf_id = v_dest_shelf_id;

  IF v_slot.pod_product_id IS NOT NULL AND v_slot.match_method <> 'unmatched'
     AND v_slot.pod_product_id IS DISTINCT FROM v_dest_pod_product THEN
    SELECT EXISTS (
      SELECT 1 FROM public.refill_dispatching rd
      WHERE rd.machine_id = p_dest_machine_id AND rd.shelf_id = v_dest_shelf_id
        AND rd.dispatch_date = p_dispatch_date AND rd.action = 'Remove'
        AND rd.pod_product_id = v_slot.pod_product_id
        AND COALESCE(rd.cancelled,false) = false AND COALESCE(rd.item_added,false) = false
    ) INTO v_staged_remove;
    IF NOT v_staged_remove THEN
      RAISE EXCEPTION 'WEIMI slot guard: destination shelf % on % currently reads % (pod_product %), not the product being transferred. Add a Remove for the current product first, or pick a different destination shelf.',
        p_dest_shelf_code, v_dest_name, v_slot.pod_product_name, v_slot.pod_product_id;
    END IF;
  END IF;

  -- Loop 2026-09-25 A4: filter to p_boonz_product_id, the product actually being transferred, so
  -- a shelf holding several Active lots (a flavour changeover, or several SKUs on one lane) can no
  -- longer bind a different flavour's soonest-expiring lot onto this transfer. No matching lot on
  -- the shelf for this product now falls back to NULL, never to another flavour's lot.
  SELECT pil.expiration_date, pil.pod_inventory_id
    INTO v_lot_expiry, v_lot_id
    FROM public.v_pod_inventory_latest pil
   WHERE pil.machine_id = p_source_machine_id
     AND pil.shelf_id = v_src_shelf_id
     AND pil.boonz_product_id = p_boonz_product_id
     AND pil.status = 'Active'
     AND COALESCE(pil.current_stock,0) > 0
   ORDER BY pil.expiration_date ASC NULLS LAST
   LIMIT 1;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, m2m_transfer_id, created_by_edit,
     expiry_date, pod_lot_id, pack_outcome, source_origin,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_source_machine_id, v_src_shelf_id, v_src_pod_product, p_boonz_product_id, p_dispatch_date, 'Remove', p_quantity,
     true, true, true, false, false, true,
     format('M2M: %s -> %s%s', v_src_name, v_dest_name, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'm2m', p_source_machine_id, true, v_transfer_id, true,
     v_lot_expiry, v_lot_id, 'no_pack_needed'::public.pack_outcome_enum, 'internal_transfer'::public.source_origin_enum,
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_remove_id;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     packed, dispatched, picked_up, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, m2m_transfer_id, m2m_partner_id, created_by_edit,
     pack_outcome, source_origin,
     last_edited_by, last_edited_by_role, last_edited_at, edit_count)
  VALUES
    (p_dest_machine_id, v_dest_shelf_id, v_dest_pod_product, p_boonz_product_id, p_dispatch_date, 'Add New', p_quantity,
     true, true, false, false, false, true,
     format('M2M: %s -> %s%s', v_src_name, v_dest_name, CASE WHEN p_reason IS NOT NULL THEN ' ('||p_reason||')' ELSE '' END),
     'm2m', p_source_machine_id, true, v_transfer_id, v_remove_id, true,
     'no_pack_needed'::public.pack_outcome_enum, 'internal_transfer'::public.source_origin_enum,
     auth.uid(), NULL, now(), 0)
  RETURNING dispatch_id INTO v_add_id;

  UPDATE public.refill_dispatching SET m2m_partner_id = v_add_id WHERE dispatch_id = v_remove_id;

  -- Loop 2026-09-25 A4 (incidental fix, same function already being replaced above): the prior
  -- body hardcoded edited_by_role to a literal NULL here regardless of v_role, which violates
  -- refill_dispatching_edit_log.edited_by_role's NOT NULL constraint on every call, authenticated
  -- or not -- confirmed live while smoke testing this migration (23502 on the first attempt).
  -- Same COALESCE(v_role,'system') fallback already used by cancel_m2m_transfer (A1).
  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
  VALUES
    (v_remove_id, auth.uid(), COALESCE(v_role, 'system'), 'add', NULL,
     jsonb_build_object('dispatch_id', v_remove_id, 'action', 'Remove', 'transfer_id', v_transfer_id, 'partner', v_add_id), p_reason),
    (v_add_id, auth.uid(), COALESCE(v_role, 'system'), 'add', NULL,
     jsonb_build_object('dispatch_id', v_add_id, 'action', 'Add New', 'transfer_id', v_transfer_id, 'partner', v_remove_id), p_reason);

  RETURN jsonb_build_object(
    'status', 'ok', 'transfer_id', v_transfer_id,
    'remove_dispatch_id', v_remove_id, 'add_dispatch_id', v_add_id,
    'source_machine', v_src_name, 'dest_machine', v_dest_name,
    'quantity', p_quantity, 'boonz_product_id', p_boonz_product_id
  );
END;
$function$;
