-- PRD-110 P4.4b Migration B — post-facto fill capture at the machine, phase 1.
--
-- Builds, per docs/prds/PRD-110-P4.4b-DARA-post-facto-fill-design.md §4/§6:
--   1. public._resolve_open_walkin_po_v3  — the PO-resolution rule, lifted (D-F)
--   2. public.receive_dispatch_line_sourced_v3 — the driver-facing split receive
--   3. an allowlist entry in enforce_canonical_dispatch_write for (2)
--
-- ⛔ receive_dispatch_line is NOT touched. Its line-112 overfill guard was RIGHT;
--    phase 1 calls it with n only, so the guard is never asked about spot units.

-- ---------------------------------------------------------------------------
-- 1. _resolve_open_walkin_po_v3 (D-F)
--
-- Design §3 declared this `(p_supplier_id, p_po_id) RETURNS text`. Corrected here
-- on live evidence: purchase_orders is LINE-grained (PK po_line_id, no header
-- table) and create_purchase_order takes p_lines NOT NULL, so a po_id for a
-- minted PO cannot exist without its lines — the helper must take them. It
-- returns jsonb rather than text because the resolution PATH and its warnings are
-- load-bearing for the caller (see the S-145 branch below), and dropping them on
-- the floor is the silent-information failure LAW 5 exists to prevent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._resolve_open_walkin_po_v3(
  p_supplier_id uuid,
  p_lines       jsonb,
  p_po_id       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_caller     uuid;
  v_role       text;
  v_today      date := CURRENT_DATE;
  v_po_id      text;
  v_po_path    text;
  v_po_number  int;
  v_sup_type   text;
  v_sup_status text;
  v_warnings   text[] := '{}';
BEGIN
  v_caller := (SELECT auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION '_resolve_open_walkin_po_v3: at least one line is required (purchase_orders is LINE-grained - a PO with no lines does not exist)';
  END IF;

  SELECT procurement_type, status INTO v_sup_type, v_sup_status
    FROM public.suppliers WHERE supplier_id = p_supplier_id;
  IF v_sup_type IS NULL AND v_sup_status IS NULL THEN
    RAISE EXCEPTION '_resolve_open_walkin_po_v3: supplier % not found', p_supplier_id;
  END IF;
  IF v_sup_status IS DISTINCT FROM 'Active' THEN
    RAISE EXCEPTION '_resolve_open_walkin_po_v3: supplier % is % - Active required', p_supplier_id, COALESCE(v_sup_status,'NULL');
  END IF;
  IF v_sup_type IS DISTINCT FROM 'walk_in' THEN
    RAISE EXCEPTION '_resolve_open_walkin_po_v3: supplier % is procurement_type % - a spot buy is walk_in by definition', p_supplier_id, COALESCE(v_sup_type,'NULL');
  END IF;

  IF p_po_id IS NOT NULL AND btrim(p_po_id) <> '' THEN
    IF NOT EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_id = p_po_id) THEN
      RAISE EXCEPTION '_resolve_open_walkin_po_v3: p_po_id % not found', p_po_id;
    END IF;
    v_po_id   := p_po_id;
    v_po_path := 'explicit';
    PERFORM public.add_purchase_order_lines(v_po_id, p_lines);
  ELSE
    SELECT po.po_id INTO v_po_id
      FROM public.purchase_orders po
     WHERE po.supplier_id   = p_supplier_id
       AND po.purchase_date = v_today
       AND po.received_date IS NULL
       AND COALESCE(po.purchase_outcome,'') <> 'not_purchased'
     ORDER BY po.po_number DESC
     LIMIT 1;

    -- S-145. add_purchase_order_lines is operator_admin/superadmin only, verified
    -- live this leg. P4.4b's PRIMARY caller is a driver (field_staff), so for the
    -- driver path this branch is ALWAYS taken and the resolution rule is always
    -- "mint", never "attach". That is correct - create_purchase_order does admit
    -- field_staff - but it is not what the rule's name suggests, so the caller is
    -- TOLD, exactly as the P4.4 incumbent tells a warehouse caller.
    IF v_po_id IS NOT NULL AND v_role IN ('operator_admin','superadmin') THEN
      v_po_path := 'attached';
      PERFORM public.add_purchase_order_lines(v_po_id, p_lines);
    ELSE
      IF v_po_id IS NOT NULL THEN
        v_warnings := array_append(v_warnings,
          format('an open walk-in PO (%s) exists today but attaching is owner-only for role %s - minted a new PO instead',
                 v_po_id, COALESCE(v_role,'none')));
      END IF;
      v_po_id   := 'PO-' || to_char(v_today,'YYYY') || '-SPOT'
                   || upper(left(replace(gen_random_uuid()::text,'-',''),8));
      v_po_path := 'minted';
      -- The incumbent owns po_number_seq self-healing, the PRD-1 blocked-product
      -- guardrail and procurement_events. A post-facto fill of a decommissioned
      -- product must fail exactly as a planned order does.
      PERFORM public.create_purchase_order(v_po_id, p_supplier_id, v_today, p_lines, false);
    END IF;
  END IF;

  SELECT po_number INTO v_po_number FROM public.purchase_orders WHERE po_id = v_po_id LIMIT 1;

  RETURN jsonb_build_object(
    'po_id', v_po_id, 'po_number', v_po_number, 'po_path', v_po_path,
    'caller_role', v_role, 'warnings', to_jsonb(v_warnings));
END;
$fn$;

-- S-140/S-178: Supabase default privileges arm every new public object at birth,
-- and a GRANT does not reduce an existing ACL. This is an INTERNAL helper - no
-- role calls it directly; receive_dispatch_line_sourced_v3 reaches it as definer.
REVOKE ALL ON FUNCTION public._resolve_open_walkin_po_v3(uuid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._resolve_open_walkin_po_v3(uuid, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION public._resolve_open_walkin_po_v3(uuid, jsonb, text) FROM authenticated;

-- ---------------------------------------------------------------------------
-- 2. receive_dispatch_line_sourced_v3 — phase 1, at the machine
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_dispatch_line_sourced_v3(
  p_dispatch_id      uuid,
  p_qty_from_wh      numeric,
  p_qty_spot         numeric,
  p_spot_supplier_id uuid    DEFAULT NULL,
  p_spot_breakdown   jsonb   DEFAULT NULL,
  p_unit_price_aed   numeric DEFAULT NULL,
  p_receipt_photo    text    DEFAULT NULL,
  p_note             text    DEFAULT NULL,
  p_received_by      uuid    DEFAULT NULL,
  p_dry_run          boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_prev_via    text;
  v_prev_rpc    text;
  v_prev_prov   text;
  v_caller      uuid;
  v_role        text;
  v_d           refill_dispatching%ROWTYPE;
  v_n           numeric;
  v_m           numeric;
  v_wh          jsonb;
  v_items       jsonb;
  v_sku_res     boolean;
  v_line        jsonb;
  v_idx         int := 0;
  v_prod        uuid;
  v_qty         numeric;
  v_sum         numeric := 0;
  v_po          jsonb;
  v_po_id       text;
  v_po_lines    jsonb;
  v_cap         numeric;
  v_enf         text;
  v_warnings    text[] := '{}';
  v_spot_rows   jsonb := '[]'::jsonb;
  v_sf_id       uuid;
  v_events      jsonb := '[]'::jsonb;
  v_ev          jsonb;
  v_tasks       int := 0;
  v_result      jsonb;
BEGIN
  -- Article 4 (PRD-016B / S-160): the app.* GUCs leak across statements. Capture
  -- the inbound values now and RESTORE them on every exit path.
  v_prev_via  := current_setting('app.via_rpc', true);
  v_prev_rpc  := current_setting('app.rpc_name', true);
  v_prev_prov := current_setting('app.provenance_reason', true);

  BEGIN
    ------------------------------------------------------------------ 1. gate
    v_caller := (SELECT auth.uid());
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;
    -- field_staff and up: unlike P4.4 (a warehouse RECEIVE), this IS the
    -- driver-facing path named in create_spot_purchase_v3's own refusal message.
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: role % not authorized (field_staff and up)', COALESCE(v_role,'none');
    END IF;

    -------------------------------------------------------------- 2. validate
    v_n := COALESCE(p_qty_from_wh, 0);
    v_m := COALESCE(p_qty_spot, 0);

    IF v_n < 0 OR v_m < 0 THEN
      RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: quantities cannot be negative (from_wh=%, spot=%)', v_n, v_m;
    END IF;
    IF v_n + v_m <= 0 THEN
      RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: nothing to record - from_wh + spot must be > 0. To record a line that was not filled at all, use the not-filled path, not a zero split.';
    END IF;

    SELECT * INTO v_d FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: dispatch % not found', p_dispatch_id;
    END IF;
    IF COALESCE(v_d.item_added, false) THEN
      RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: dispatch % already received', p_dispatch_id;
    END IF;

    IF v_m > 0 THEN
      -- The spot leg puts units on a SHELF. Only a fill leg has one, and an m2m
      -- leg's units come from another machine, not a counter.
      IF v_d.action NOT IN ('Refill','Add New','Add') OR COALESCE(v_d.is_m2m, false) THEN
        RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: a spot fill is only valid on a Refill/Add New/Add leg that is not m2m (dispatch % is action=%, is_m2m=%). Record the % spot unit(s) against the fill leg they went into.',
          p_dispatch_id, v_d.action, COALESCE(v_d.is_m2m,false), v_m;
      END IF;
      IF v_d.shelf_id IS NULL THEN
        RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: dispatch % has no shelf_id, so the % spot unit(s) have nowhere to land in shelf_composition. Bind the line to a shelf first - dropping them would lose real stock silently (LAW 5).',
          p_dispatch_id, v_m;
      END IF;
      IF p_spot_supplier_id IS NULL THEN
        RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: p_spot_supplier_id is REQUIRED when spot qty > 0 - name the walk-in supplier the % unit(s) were bought from.', v_m;
      END IF;
    END IF;

    ------------------------------------------------- 3. the split, made explicit
    -- p_spot_breakdown is genuinely optional (BUILD SPEC: "pod-level accepted
    -- when SKUs unknown"). NULL means the driver could not enumerate flavours -
    -- an honest pod-level record beats an invented split.
    IF v_m > 0 THEN
      IF p_spot_breakdown IS NULL THEN
        v_items   := jsonb_build_array(jsonb_build_object('boonz_product_id', v_d.boonz_product_id, 'qty', v_m));
        v_sku_res := false;
      ELSE
        IF jsonb_typeof(p_spot_breakdown) <> 'array' OR jsonb_array_length(p_spot_breakdown) = 0 THEN
          RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: p_spot_breakdown must be a non-empty array of {boonz_product_id, qty}, or NULL for a pod-level record';
        END IF;
        FOR v_line IN SELECT * FROM jsonb_array_elements(p_spot_breakdown) LOOP
          v_idx  := v_idx + 1;
          v_prod := NULLIF(v_line->>'boonz_product_id','')::uuid;
          v_qty  := COALESCE((v_line->>'qty')::numeric, 0);
          IF v_prod IS NULL THEN
            RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: breakdown line %: boonz_product_id is required', v_idx;
          END IF;
          IF NOT EXISTS (SELECT 1 FROM public.boonz_products WHERE product_id = v_prod) THEN
            RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: breakdown line %: boonz_product_id % not found', v_idx, v_prod;
          END IF;
          IF v_qty <= 0 THEN
            RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: breakdown line %: qty must be > 0 (got %)', v_idx, v_qty;
          END IF;
          v_sum := v_sum + v_qty;
        END LOOP;
        IF v_sum <> v_m THEN
          RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: breakdown totals % but spot qty is % - the split must account for every spot unit (LAW 5)', v_sum, v_m;
        END IF;
        v_items   := p_spot_breakdown;
        v_sku_res := true;
      END IF;

      -- D-D pre-auth cap, same dial as P4.4. Leaving the driver path uncapped
      -- while the warehouse path is capped would make the cap advisory in the
      -- one place a human is standing at a till.
      SELECT spot_buy_price_cap_aed, spot_buy_cap_enforcement INTO v_cap, v_enf
        FROM public.refill_policy_params LIMIT 1;
      IF p_unit_price_aed IS NOT NULL AND COALESCE(v_enf,'off') <> 'off' AND p_unit_price_aed > v_cap THEN
        IF v_enf = 'block' THEN
          RAISE EXCEPTION 'receive_dispatch_line_sourced_v3: unit price %.2f AED exceeds spot_buy_price_cap_aed %.2f and spot_buy_cap_enforcement=block', p_unit_price_aed, v_cap;
        END IF;
        v_warnings := array_append(v_warnings, format('unit price %s AED over cap %s AED', p_unit_price_aed, v_cap));
      END IF;
    END IF;

    --------------------------------------------------------------- 4. WH leg
    -- ⭐ THE WHOLE FIX IN ONE LINE: the incumbent is called with n ONLY, so
    -- v_overfill = GREATEST(n - planned, 0) and its line-112 guard is never asked
    -- a question about units that were never its business. The guard is untouched.
    SELECT public.receive_dispatch_line(p_dispatch_id, v_n, p_received_by) INTO v_wh;

    ------------------------------------------------------------- 5. spot leg
    IF v_m > 0 THEN
      SELECT jsonb_agg(jsonb_build_object(
               'boonz_product_id',   i->>'boonz_product_id',
               'ordered_qty',        (i->>'qty')::numeric,
               'price_per_unit_aed', p_unit_price_aed))
        INTO v_po_lines
        FROM jsonb_array_elements(v_items) i;

      -- expiry_date is deliberately absent from the PO line: it is NULL until the
      -- receipt is read in phase 2. ⛔ Never default it - 2099-12-31 is the
      -- sentinel shape (P0.4) and would make spot goods immortal in FEFO.
      v_po    := public._resolve_open_walkin_po_v3(p_spot_supplier_id, v_po_lines, NULL);
      v_po_id := v_po->>'po_id';
      IF jsonb_array_length(COALESCE(v_po->'warnings','[]'::jsonb)) > 0 THEN
        SELECT array_cat(v_warnings, ARRAY(SELECT jsonb_array_elements_text(v_po->'warnings'))) INTO v_warnings;
      END IF;

      v_idx := 0;
      FOR v_line IN SELECT * FROM jsonb_array_elements(v_items) LOOP
        v_idx  := v_idx + 1;
        v_prod := (v_line->>'boonz_product_id')::uuid;
        v_qty  := (v_line->>'qty')::numeric;

        INSERT INTO public.spot_fill_v3
          (dispatch_id, machine_id, shelf_id, boonz_product_id, qty, sku_resolved,
           supplier_id, po_id, status, unit_price_aed, expiry_date, receipt_photo,
           created_by, note)
        VALUES
          (p_dispatch_id, v_d.machine_id, v_d.shelf_id, v_prod, v_qty, v_sku_res,
           p_spot_supplier_id, v_po_id, 'pending', p_unit_price_aed, NULL, p_receipt_photo,
           COALESCE(p_received_by, v_caller), p_note)
        RETURNING spot_fill_id INTO v_sf_id;

        v_spot_rows := v_spot_rows || jsonb_build_object(
          'spot_fill_id', v_sf_id, 'boonz_product_id', v_prod, 'qty', v_qty);

        -- Composition AND the event in one call: record_inventory_event_v3 is the
        -- only writer of inventory_events in the database (probed), and it moves
        -- the shelf_composition bucket in the same transaction. Doing the two
        -- separately is how they drift. expiry bucket NULL until phase 2.
        -- ⭐ Without this event cron 44's estimator would read the count rise as a
        -- venue_fill or flag it as an anomaly (the fixture-19 path).
        SELECT public.record_inventory_event_v3(
                 v_d.shelf_id, v_prod, v_qty, 'spot_buy_receive', NULL,
                 format('spot_fill:%s', v_sf_id),
                 format('P4.4b post-facto fill: %s unit(s) bought at a counter and put straight on the shelf (PO %s)', v_qty, v_po_id))
          INTO v_ev;
        v_events := v_events || jsonb_build_object('spot_fill_id', v_sf_id, 'event_id', v_ev->>'event_id',
                                                   'est_qty_after', v_ev->'est_qty_after');
      END LOOP;

      ------------------------------------------- 6. the line now reads n + m
      -- Article 4: record_inventory_event_v3 clobbered app.rpc_name and does not
      -- restore it. Re-assert OUR name immediately before the protected write -
      -- inheriting a leaked 'receive_dispatch_line' would let this write pass
      -- enforce_canonical_dispatch_write under another writer's identity.
      PERFORM set_config('app.via_rpc',  'true', true);
      PERFORM set_config('app.rpc_name', 'receive_dispatch_line_sourced_v3', true);
      PERFORM set_config('app.mutation_reason',
        format('P4.4b post-facto fill: dispatch %s filled %s = %s from warehouse + %s spot-bought (supplier %s, PO %s) by %s',
               p_dispatch_id, v_n + v_m, v_n, v_m, p_spot_supplier_id, v_po_id,
               COALESCE(p_received_by::text, v_caller::text, 'system')), true);

      UPDATE public.refill_dispatching
         SET filled_quantity = v_n + v_m
       WHERE dispatch_id = p_dispatch_id;

      ------------------------------------------------- 7. S-142 close the task
      -- create_purchase_order raises a walk-in driver task telling a driver to go
      -- buy goods he is already holding - and here he has already put them in the
      -- machine. Close it, never DELETE it (Article 7). S-147: 'collected' is the
      -- terminal state in the status CHECK and it is literally true.
      UPDATE public.driver_tasks
         SET status          = 'collected',
             collected_at    = COALESCE(collected_at, now()),
             outcome         = COALESCE(outcome, 'purchased_full'),
             outcome_comment = COALESCE(outcome_comment,'')
                               || '[auto-closed by receive_dispatch_line_sourced_v3: goods already bought and already in the machine]'
       WHERE po_id = v_po_id
         AND status IN ('pending','acknowledged');
      GET DIAGNOSTICS v_tasks = ROW_COUNT;

      INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
      VALUES (v_po_id, 'post_facto_fill_recorded', v_caller,
        jsonb_build_object(
          'dispatch_id', p_dispatch_id, 'machine_id', v_d.machine_id, 'shelf_id', v_d.shelf_id,
          'qty_from_wh', v_n, 'qty_spot', v_m, 'filled_quantity', v_n + v_m,
          'supplier_id', p_spot_supplier_id, 'po_path', v_po->>'po_path',
          'sku_resolved', v_sku_res, 'spot_fills', v_spot_rows, 'events', v_events,
          'tasks_closed', v_tasks, 'receipt_photo', p_receipt_photo, 'note', p_note,
          'warnings', to_jsonb(v_warnings)));
    END IF;

    v_result := jsonb_build_object(
      'ok', true,
      'dispatch_id', p_dispatch_id,
      'action', v_d.action,
      'planned_quantity', v_d.quantity,
      'qty_from_wh', v_n,
      'qty_spot', v_m,
      'filled_quantity', v_n + v_m,
      'wh_leg', v_wh,
      'spot_fills', v_spot_rows,
      'composition_events', v_events,
      'sku_resolved', CASE WHEN v_m > 0 THEN v_sku_res ELSE NULL END,
      'po_id', v_po_id,
      'po_number', v_po->>'po_number',
      'po_path', v_po->>'po_path',
      'driver_tasks_closed', v_tasks,
      'phase_2_pending', (v_m > 0),
      'phase_2_note', CASE WHEN v_m > 0
        THEN 'The spot units are ON THE SHELF and FINANCIALLY UNRECEIVED until receive_spot_fill_po_v3 is run with the receipt expiries. That gap is a real business state, not a defect.'
        ELSE NULL END,
      'warnings', to_jsonb(v_warnings),
      'dry_run', p_dry_run, 'committed', true);

    IF p_dry_run THEN
      RAISE EXCEPTION 'PRD110_P44B_DRY_RUN';
    END IF;

  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.via_rpc',           COALESCE(v_prev_via,''),  true);
    PERFORM set_config('app.rpc_name',          COALESCE(v_prev_rpc,''),  true);
    PERFORM set_config('app.provenance_reason', COALESCE(v_prev_prov,''), true);

    IF SQLERRM = 'PRD110_P44B_DRY_RUN' THEN
      RETURN v_result || jsonb_build_object(
        'dry_run', true, 'committed', false,
        'deferred_constraints_unchecked', true,
        'note', 'S-133: a rolled-back dry run does NOT check DEFERRED constraints');
    END IF;
    RAISE;
  END;

  -- Article 4: restore on the success path too.
  PERFORM set_config('app.via_rpc',           COALESCE(v_prev_via,''),  true);
  PERFORM set_config('app.rpc_name',          COALESCE(v_prev_rpc,''),  true);
  PERFORM set_config('app.provenance_reason', COALESCE(v_prev_prov,''), true);

  RETURN v_result;
END;
$fn$;

REVOKE ALL ON FUNCTION public.receive_dispatch_line_sourced_v3(uuid, numeric, numeric, uuid, jsonb, numeric, text, text, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.receive_dispatch_line_sourced_v3(uuid, numeric, numeric, uuid, jsonb, numeric, text, text, uuid, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.receive_dispatch_line_sourced_v3(uuid, numeric, numeric, uuid, jsonb, numeric, text, text, uuid, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.receive_dispatch_line_sourced_v3(uuid, numeric, numeric, uuid, jsonb, numeric, text, text, uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. enforce_canonical_dispatch_write - allowlist the new canonical writer.
-- Built by substitution over pg_get_functiondef(); single overload confirmed,
-- anchor verified to match EXACTLY ONCE before substituting. Additive only:
-- one array element, in the same place RC-04 and PRD-107 added theirs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_canonical_dispatch_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_via_rpc text := current_setting('app.via_rpc', true); v_rpc_name text := current_setting('app.rpc_name', true);
  v_via_trigger text := current_setting('app.via_trigger', true); v_uid uuid := auth.uid(); v_role text;
  v_allowlist text[] := ARRAY[
    'write_refill_plan','pack_dispatch_line','receive_dispatch_line','return_dispatch_line',
    'swap_between_machines','repair_unbound_dispatch','repair_orphan_internal_transfer',
    'cancel_dispatch_line','mark_dispatch_vox_sourced','mark_internal_transfer',
    'sync_dispatch_expiry_from_pinned_wh','add_dispatch_row','approve_refill_plan','auto_generate_refill_plan',
    'edit_dispatch_product','edit_dispatch_qty','edit_dispatch_shelf','inject_swap','push_plan_to_dispatch','remove_dispatch_row',
    'set_dispatch_source','wh_approve_remove_receipt_multivariant','update_dispatch_comment','set_dispatch_include','insert_driver_remove_line',
    'skip_dispatch_line','convert_removes_to_m2m_transfer',
    -- RC-04 prep 2026-07-19: verified context-setting single-writers (Category-A)
    'mark_picked_up','driver_confirm_remove','wh_approve_remove_receipt','review_driver_addition',
    'release_stale_unpacked_dispatches','decline_dispatch_return','unskip_dispatch_line',
    -- PRD-107 2026-07-29: orphaned swap-leg guard flags needs_review at pack close
    'confirm_machine_packed',
    -- PRD-110 P4.4b 2026-08-04: the post-facto fill path re-asserts its OWN
    -- name before writing filled_quantity. Without this entry it would pass
    -- only on receive_dispatch_line's LEAKED GUC, under another writer's
    -- identity - a guard satisfied for the wrong reason (S-160 family).
    'receive_dispatch_line_sourced_v3'];
  v_pre_image jsonb; v_post_image jsonb; v_pk text;
BEGIN
  IF coalesce(v_via_rpc,'')='true' AND coalesce(v_rpc_name,'') = ANY(v_allowlist) THEN RETURN coalesce(NEW, OLD); END IF;
  IF coalesce(v_via_trigger,'') = 'true' THEN RETURN coalesce(NEW, OLD); END IF;
  IF v_uid IS NOT NULL THEN SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid; END IF;
  IF TG_OP='DELETE' THEN v_pre_image := to_jsonb(OLD); v_pk := OLD.dispatch_id::text;
  ELSIF TG_OP='UPDATE' THEN v_pre_image := to_jsonb(OLD); v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text;
  ELSE v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text; END IF;
  INSERT INTO public.bypass_violation_log (table_name, operation, actor, caller_role, rpc_name, via_rpc, app_via_trigger, row_pk, pre_image, post_image, client_info)
  VALUES (TG_TABLE_NAME, TG_OP, v_uid, v_role, v_rpc_name, coalesce(v_via_rpc,'')='true', v_via_trigger, v_pk, v_pre_image, v_post_image, current_setting('application_name', true));
  RAISE WARNING 'enforce_canonical_dispatch_write: bypass on %.% (op=%, rpc_name=%, via_rpc=%, actor=%).', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, coalesce(v_rpc_name,'<null>'), coalesce(v_via_rpc,'<null>'), coalesce(v_uid::text,'<null>');
  RETURN coalesce(NEW, OLD);
END $function$
;
