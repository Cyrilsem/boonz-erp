-- PRD-145 P3-2: edit a dispatch line by its total, not by one lot row.
-- pack_dispatch_line splits one plan line into one refill_dispatching row per warehouse lot (the first lot on the
-- row itself, each further lot on a child row with parent_dispatch_id). The edit dialog showed one lot row, so the
-- team read "6 became 5". A line is the group (machine_id, shelf_id, boonz_product_id, action, source_kind,
-- coalesce(parent_dispatch_id, dispatch_id)) of include=true rows. pack_dispatch_line writes its lot child rows without
-- source_kind, so a child takes its root's source_kind.
--
-- amend_dispatch_line_total(p_group, p_new_total, p_reason)
--   unpacked line   sets quantity on its one row (same as edit_dispatch_qty)
--   packed line     lowers from the newest-expiry lot first (CS 20 Oct: the van keeps the shortest-dated stock),
--                   raises on the FEFO live lot(s); each lot is credited or debited the way pack_dispatch_line moves
--                   it (warehouse_stock <-> consumer_stock). A lot row emptied by a lower is set include=false.
--   refuses         received / returned / driver-confirmed lines (amend_dispatch_after_pickup owns those), M2M lines,
--                   packed lines that are not warehouse-sourced, lines mixing packed and unpacked rows.
--   logs            one refill_dispatching_edit_log row per row touched ('qty', or 'add' for a new lot row).
-- Roles: operator_admin and warehouse (stored role, auth.uid()).
CREATE FUNCTION public.amend_dispatch_line_total(p_group jsonb, p_new_total numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role     text;
  v_reason   text := NULLIF(trim(COALESCE(p_reason, '')), '');
  v_machine  uuid := NULLIF(p_group->>'machine_id', '')::uuid;
  v_shelf    uuid := NULLIF(p_group->>'shelf_id', '')::uuid;
  v_bp       uuid := NULLIF(p_group->>'boonz_product_id', '')::uuid;
  v_action   text := p_group->>'action';
  v_kind     text := COALESCE(NULLIF(p_group->>'source_kind', ''), 'unknown');
  v_root     uuid := NULLIF(p_group->>'root_dispatch_id', '')::uuid;
  v_rows     public.refill_dispatching[];
  r          public.refill_dispatching;
  v_rootrow  public.refill_dispatching;
  v_n        int;
  v_packed_n int;
  v_total    numeric;
  v_planned  numeric;
  v_need     numeric;
  v_take     numeric;
  v_lot      record;
  v_child    uuid;
  v_before   jsonb;
  v_after    jsonb;
  v_today    date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_wh       uuid;
  v_qty_snap jsonb;
  v_changes  jsonb := '[]'::jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('operator_admin', 'warehouse') THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: operator_admin or warehouse only (role %)', COALESCE(v_role, 'none');
  END IF;
  IF v_reason IS NULL OR length(v_reason) < 5 THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: a reason (5+ characters) is required';
  END IF;
  IF p_new_total IS NULL OR p_new_total < 0 OR p_new_total <> trunc(p_new_total) THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: the new total must be a whole number of units, 0 or more (got %)', p_new_total;
  END IF;
  IF v_machine IS NULL OR v_shelf IS NULL OR v_bp IS NULL OR v_action IS NULL OR v_root IS NULL THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: p_group needs machine_id, shelf_id, boonz_product_id, action, source_kind, root_dispatch_id (got %)', p_group;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'amend_dispatch_line_total', true);
  PERFORM set_config('app.source_event_id', v_root::text, true);
  PERFORM set_config('app.mutation_reason', format('amend_dispatch_line_total %s -> %s: %s', v_root, p_new_total, v_reason), true);

  -- The group is re-derived here from its key; the client never names the rows.
  PERFORM 1 FROM public.refill_dispatching x
    WHERE x.machine_id = v_machine AND x.shelf_id = v_shelf AND x.boonz_product_id = v_bp
      AND x.action = v_action AND COALESCE(x.parent_dispatch_id, x.dispatch_id) = v_root
    FOR UPDATE;
  SELECT array_agg(x ORDER BY x.expiry_date DESC NULLS FIRST, x.created_at DESC) INTO v_rows
    FROM public.refill_dispatching x
   WHERE x.machine_id = v_machine AND x.shelf_id = v_shelf AND x.boonz_product_id = v_bp
     AND x.action = v_action
     -- pack_dispatch_line writes lot child rows without source_kind; a child belongs to its root's line.
     AND ((x.dispatch_id = v_root AND COALESCE(x.source_kind, 'unknown') = v_kind) OR x.parent_dispatch_id = v_root)
     AND COALESCE(x.include, true) AND NOT COALESCE(x.cancelled, false) AND NOT COALESCE(x.skipped, false);
  v_n := COALESCE(array_length(v_rows, 1), 0);
  IF v_n = 0 THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: no active rows for this line (%)', p_group;
  END IF;
  FOREACH r IN ARRAY v_rows LOOP
    -- picked_up alone does not block: tg_auto_pickup_on_machine_complete sets it on every packed row as soon as the
    -- machine's last line is packed, before the van leaves.
    IF COALESCE(r.item_added, false) OR COALESCE(r.returned, false) OR r.delivered_at IS NOT NULL OR r.driver_confirmed_at IS NOT NULL THEN
      RAISE EXCEPTION 'amend_dispatch_line_total: dispatch % is already received, returned or confirmed by the driver; use amend_dispatch_after_pickup', r.dispatch_id;
    END IF;
    IF COALESCE(r.is_m2m, false) THEN
      RAISE EXCEPTION 'amend_dispatch_line_total: dispatch % is a machine-to-machine leg; use edit_transfer_qty', r.dispatch_id;
    END IF;
  END LOOP;
  SELECT count(*) FILTER (WHERE COALESCE(x.packed, false)) INTO v_packed_n FROM unnest(v_rows) x;
  SELECT * INTO v_rootrow FROM unnest(v_rows) x WHERE x.dispatch_id = v_root;

  -- Unpacked line: one row, quantity only (edit_dispatch_qty semantics).
  IF v_packed_n = 0 THEN
    IF v_n > 1 OR v_rootrow.dispatch_id IS NULL THEN
      RAISE EXCEPTION 'amend_dispatch_line_total: unpacked line % has % rows; expected 1', v_root, v_n;
    END IF;
    v_before := jsonb_build_object('quantity', v_rootrow.quantity);
    UPDATE public.refill_dispatching
       SET quantity = p_new_total, original_quantity = COALESCE(original_quantity, v_rootrow.quantity),
           edit_count = COALESCE(edit_count, 0) + 1, last_edited_by = auth.uid(), last_edited_by_role = v_role, last_edited_at = now()
     WHERE dispatch_id = v_root;
    INSERT INTO public.refill_dispatching_edit_log (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
    VALUES (v_root, auth.uid(), v_role, 'qty', v_before, jsonb_build_object('quantity', p_new_total, 'line_total', p_new_total),
            format('amend_dispatch_line_total: %s', v_reason));
    RETURN jsonb_build_object('status', 'ok', 'mode', 'unpacked', 'root_dispatch_id', v_root,
                              'before_total', v_rootrow.quantity, 'after_total', p_new_total);
  END IF;
  IF v_packed_n < v_n THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: line % mixes packed and unpacked rows; finish packing first', v_root;
  END IF;
  IF v_kind <> 'wh' THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: packed line % is sourced from % (warehouse lines only)', v_root, v_kind;
  END IF;
  IF p_new_total < 1 THEN
    RAISE EXCEPTION 'amend_dispatch_line_total: a packed line keeps at least 1 unit; to send it all back use repack_machine';
  END IF;

  SELECT COALESCE(sum(COALESCE(x.filled_quantity, 0)), 0) INTO v_total FROM unnest(v_rows) x;
  v_planned := COALESCE(v_rootrow.original_quantity, v_rootrow.quantity, v_total);
  IF p_new_total = v_total THEN
    RETURN jsonb_build_object('status', 'unchanged', 'root_dispatch_id', v_root, 'total', v_total);
  END IF;
  v_wh := COALESCE(v_rootrow.from_warehouse_id, (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_machine));

  IF p_new_total < v_total THEN
    -- Lower: newest-expiry lot first (v_rows is ordered expiry DESC).
    PERFORM set_config('app.provenance_reason', 'dispatch_return', true);
    v_need := v_total - p_new_total;
    FOREACH r IN ARRAY v_rows LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_need, COALESCE(r.filled_quantity, 0));
      CONTINUE WHEN v_take <= 0;
      IF r.from_wh_inventory_id IS NULL THEN
        RAISE EXCEPTION 'amend_dispatch_line_total: dispatch % has no lot pin; cannot credit the warehouse', r.dispatch_id;
      END IF;
      UPDATE public.warehouse_inventory
         SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_take,
             consumer_stock = GREATEST(COALESCE(consumer_stock, 0) - v_take, 0)
       WHERE wh_inventory_id = r.from_wh_inventory_id;
      v_before := jsonb_build_object('quantity', r.quantity, 'filled_quantity', r.filled_quantity, 'include', r.include,
                                     'from_wh_inventory_id', r.from_wh_inventory_id, 'expiry_date', r.expiry_date);
      UPDATE public.refill_dispatching
         SET filled_quantity = r.filled_quantity - v_take, quantity = r.filled_quantity - v_take,
             include = (r.filled_quantity - v_take) > 0,
             skip_reason = CASE WHEN (r.filled_quantity - v_take) > 0 THEN skip_reason
                                ELSE format('amend_dispatch_line_total: lot emptied (%s)', v_reason) END,
             original_quantity = COALESCE(original_quantity, r.quantity),
             edit_count = COALESCE(edit_count, 0) + 1, last_edited_by = auth.uid(), last_edited_by_role = v_role, last_edited_at = now()
       WHERE dispatch_id = r.dispatch_id;
      v_after := v_before || jsonb_build_object('quantity', r.filled_quantity - v_take, 'filled_quantity', r.filled_quantity - v_take,
                                                'include', (r.filled_quantity - v_take) > 0, 'credited', v_take);
      INSERT INTO public.refill_dispatching_edit_log (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
      VALUES (r.dispatch_id, auth.uid(), v_role, 'qty', v_before, v_after, format('amend_dispatch_line_total: %s', v_reason));
      v_changes := v_changes || jsonb_build_object('dispatch_id', r.dispatch_id, 'wh_inventory_id', r.from_wh_inventory_id,
                                                   'expiry', r.expiry_date, 'delta', -v_take);
      v_need := v_need - v_take;
    END LOOP;
  ELSE
    -- Raise: FEFO live lot(s) in the line's warehouse, the same pickable rule pack_dispatch_line uses.
    PERFORM set_config('app.provenance_reason', 'dispatch_pack', true);
    v_need := p_new_total - v_total;
    -- conserve_split_dispatch_quantity decrements a sibling when a packed child is inserted; the quantities of the
    -- line's rows are restored after each insert so the line total stays what this function wrote.
    FOR v_lot IN
      SELECT p.wh_inventory_id, p.expiration_date, p.warehouse_stock
        FROM public.v_wh_pickable p
       WHERE p.boonz_product_id = v_bp AND p.warehouse_id = v_wh
         AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = v_machine)
         AND COALESCE(p.warehouse_stock, 0) > 0
         AND (p.expiration_date IS NULL OR p.expiration_date >= v_today)
       ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
    LOOP
      EXIT WHEN v_need <= 0;
      v_take := LEAST(v_need, v_lot.warehouse_stock);
      UPDATE public.warehouse_inventory
         SET warehouse_stock = warehouse_stock - v_take, consumer_stock = COALESCE(consumer_stock, 0) + v_take
       WHERE wh_inventory_id = v_lot.wh_inventory_id AND warehouse_stock >= v_take;
      IF NOT FOUND THEN CONTINUE; END IF;
      SELECT * INTO r FROM public.refill_dispatching x
       WHERE x.dispatch_id = ANY (SELECT y.dispatch_id FROM unnest(v_rows) y) AND x.from_wh_inventory_id = v_lot.wh_inventory_id
       ORDER BY (x.dispatch_id = v_root) DESC LIMIT 1;
      IF r.dispatch_id IS NOT NULL THEN
        v_before := jsonb_build_object('quantity', r.quantity, 'filled_quantity', r.filled_quantity,
                                       'from_wh_inventory_id', r.from_wh_inventory_id, 'expiry_date', r.expiry_date);
        UPDATE public.refill_dispatching
           SET filled_quantity = COALESCE(filled_quantity, 0) + v_take, quantity = COALESCE(filled_quantity, 0) + v_take,
               original_quantity = COALESCE(original_quantity, r.quantity),
               edit_count = COALESCE(edit_count, 0) + 1, last_edited_by = auth.uid(), last_edited_by_role = v_role, last_edited_at = now()
         WHERE dispatch_id = r.dispatch_id;
        INSERT INTO public.refill_dispatching_edit_log (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
        VALUES (r.dispatch_id, auth.uid(), v_role, 'qty', v_before,
                v_before || jsonb_build_object('quantity', COALESCE(r.filled_quantity, 0) + v_take,
                                               'filled_quantity', COALESCE(r.filled_quantity, 0) + v_take, 'debited', v_take),
                format('amend_dispatch_line_total: %s', v_reason));
        v_changes := v_changes || jsonb_build_object('dispatch_id', r.dispatch_id, 'wh_inventory_id', v_lot.wh_inventory_id,
                                                     'expiry', v_lot.expiration_date, 'delta', v_take);
      ELSE
        SELECT jsonb_object_agg(x.dispatch_id::text, x.quantity) INTO v_qty_snap
          FROM public.refill_dispatching x WHERE x.dispatch_id = ANY (SELECT y.dispatch_id FROM unnest(v_rows) y);
        INSERT INTO public.refill_dispatching (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action,
               quantity, filled_quantity, include, packed, picked_up, dispatched, returned, item_added, expiry_date,
               from_wh_inventory_id, from_warehouse_id, source_kind, source_warehouse_id, pack_outcome, source_origin, parent_dispatch_id)
        VALUES (v_machine, v_shelf, v_rootrow.pod_product_id, v_bp, v_rootrow.dispatch_date, v_action,
               v_take, v_take, true, true, false, false, false, false, v_lot.expiration_date,
               v_lot.wh_inventory_id, v_rootrow.from_warehouse_id, v_rootrow.source_kind, v_rootrow.source_warehouse_id,
               'packed', v_rootrow.source_origin, v_root)
        RETURNING dispatch_id INTO v_child;
        UPDATE public.refill_dispatching x SET quantity = (v_qty_snap->>x.dispatch_id::text)::numeric
         WHERE x.dispatch_id = ANY (SELECT y.dispatch_id FROM unnest(v_rows) y)
           AND x.quantity IS DISTINCT FROM (v_qty_snap->>x.dispatch_id::text)::numeric;
        INSERT INTO public.refill_dispatching_edit_log (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
        VALUES (v_child, auth.uid(), v_role, 'add', NULL,
                jsonb_build_object('quantity', v_take, 'filled_quantity', v_take, 'from_wh_inventory_id', v_lot.wh_inventory_id,
                                   'expiry_date', v_lot.expiration_date, 'parent_dispatch_id', v_root, 'debited', v_take),
                format('amend_dispatch_line_total: %s', v_reason));
        v_changes := v_changes || jsonb_build_object('dispatch_id', v_child, 'wh_inventory_id', v_lot.wh_inventory_id,
                                                     'expiry', v_lot.expiration_date, 'delta', v_take, 'new_row', true);
      END IF;
      v_need := v_need - v_take;
    END LOOP;
    IF v_need > 0 THEN
      RAISE EXCEPTION 'amend_dispatch_line_total: the warehouse is short by % unit(s) for this line; nothing changed', v_need;
    END IF;
  END IF;

  -- The root row carries the line's pack outcome against the plan.
  UPDATE public.refill_dispatching
     SET pack_outcome = (CASE WHEN p_new_total < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
   WHERE dispatch_id = v_root AND include AND pack_outcome IS DISTINCT FROM
         (CASE WHEN p_new_total < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum;

  RETURN jsonb_build_object('status', 'ok', 'mode', 'packed', 'root_dispatch_id', v_root,
                            'before_total', v_total, 'after_total', p_new_total, 'planned', v_planned, 'lots', v_changes);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.amend_dispatch_line_total(jsonb, numeric, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.amend_dispatch_line_total(jsonb, numeric, text) TO authenticated, service_role;

-- The canonical-write guard on refill_dispatching logs any writer not on its allowlist as a bypass.
DO $patch$
DECLARE
  v_def text; n int;
  c_old text := $a$    'close_return_backlog'];$a$;
  c_new text := $a$    'close_return_backlog','amend_dispatch_line_total'];$a$;
BEGIN
  v_def := pg_get_functiondef('public.enforce_canonical_dispatch_write()'::regprocedure);
  n := (length(v_def) - length(replace(v_def, c_old, ''))) / length(c_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_2: enforce_canonical_dispatch_write anchor count %', n; END IF;
  EXECUTE replace(v_def, c_old, c_new);
END
$patch$;
