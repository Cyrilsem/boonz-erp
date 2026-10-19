-- PRD-144 P1-3: expiry editing in dispatch, backend.
-- 1. split_pod_lot(pod_inventory_id, qty_a, date_a, qty_b, date_b, reason): one Active pod lot becomes two
--    Active lots with the given quantities and expiry dates. qty_a + qty_b must equal the lot's stock
--    (nothing is created or lost). A part whose date matches another Active lot of the same product on
--    the same shelf merges into it (idx_pod_inv_active_shelf_expiry allows one Active row per date).
--    Every row change is written to pod_inventory_audit_log (source 'correction').
-- 2. record_sold_since_planning(dispatch_id, sold_qty, reason): a Remove leg whose units partly sold
--    after the plan was written is reduced by sold_qty. The event is logged in refill_dispatching_edit_log
--    as a sales_correction (inventory_events has no sales_correction kind, and its 'correction' kind
--    feeds estimate_shelf_composition_v3, which would double-count the sale). A per-expiry breakdown
--    entered before the change is cleared so the driver re-enters it against the new total.
-- Roles from auth.uid() and the stored role: field_staff, warehouse, operator_admin, superadmin, manager
-- for the split; field_staff, operator_admin, superadmin, manager for sold-since-planning.

CREATE OR REPLACE FUNCTION public.split_pod_lot(p_pod_inventory_id uuid, p_qty_a numeric, p_date_a date, p_qty_b numeric, p_date_b date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role     text;
  v_reason   text := NULLIF(trim(COALESCE(p_reason, '')), '');
  v_today    date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  o          public.pod_inventory%ROWTYPE;
  v_sib      public.pod_inventory%ROWTYPE;
  v_reused   boolean := false;
  v_parts    jsonb := '[]'::jsonb;
  v_id       uuid;
  v_qty      numeric;
  v_date     date;
  i          int;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL
     OR v_role NOT IN ('field_staff', 'warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'split_pod_lot: forbidden for role %', COALESCE(v_role, 'none');
  END IF;
  IF v_reason IS NULL OR length(v_reason) < 5 THEN
    RAISE EXCEPTION 'split_pod_lot: a reason (5+ characters) is required';
  END IF;
  IF p_qty_a IS NULL OR p_qty_b IS NULL OR p_qty_a <= 0 OR p_qty_b <= 0 THEN
    RAISE EXCEPTION 'split_pod_lot: both quantities must be above 0';
  END IF;
  IF p_date_a IS NULL OR p_date_b IS NULL OR p_date_a = p_date_b THEN
    RAISE EXCEPTION 'split_pod_lot: two different expiry dates are required';
  END IF;
  IF LEAST(p_date_a, p_date_b) < v_today - 365 OR GREATEST(p_date_a, p_date_b) > v_today + 1095 THEN
    RAISE EXCEPTION 'split_pod_lot: expiry dates must be within a year back and three years ahead';
  END IF;

  SELECT * INTO o FROM public.pod_inventory WHERE pod_inventory_id = p_pod_inventory_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'split_pod_lot: pod lot % not found', p_pod_inventory_id; END IF;
  IF o.status <> 'Active' OR COALESCE(o.current_stock, 0) <= 0 THEN
    RAISE EXCEPTION 'split_pod_lot: only an Active lot with stock can be split';
  END IF;
  IF p_qty_a + p_qty_b <> o.current_stock THEN
    RAISE EXCEPTION 'split_pod_lot: % + % must equal the lot''s % unit(s)', p_qty_a, p_qty_b, o.current_stock;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'split_pod_lot', true);
  PERFORM set_config('app.mutation_reason', format('split_pod_lot %s: %s', p_pod_inventory_id, v_reason), true);

  FOR i IN 1 .. 2 LOOP
    v_qty  := CASE i WHEN 1 THEN p_qty_a ELSE p_qty_b END;
    v_date := CASE i WHEN 1 THEN p_date_a ELSE p_date_b END;
    SELECT * INTO v_sib FROM public.pod_inventory
     WHERE machine_id = o.machine_id AND shelf_id IS NOT DISTINCT FROM o.shelf_id
       AND boonz_product_id = o.boonz_product_id AND status = 'Active'
       AND expiration_date = v_date AND pod_inventory_id <> o.pod_inventory_id
     FOR UPDATE;
    IF FOUND THEN
      UPDATE public.pod_inventory
         SET current_stock = current_stock + v_qty, estimated_remaining = COALESCE(estimated_remaining, current_stock) + v_qty,
             snapshot_at = now()
       WHERE pod_inventory_id = v_sib.pod_inventory_id;
      v_id := v_sib.pod_inventory_id;
      INSERT INTO public.pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
        source, operation, old_stock, new_stock, delta, old_status, new_status, actor, reference_id, notes)
      VALUES (v_id, o.machine_id, o.shelf_id, o.boonz_product_id, v_date, 'correction', 'update',
        v_sib.current_stock, v_sib.current_stock + v_qty, v_qty, 'Active', 'Active', auth.uid(),
        format('split_pod_lot-%s', p_pod_inventory_id), format('split: +%s merged into existing lot %s: %s', v_qty, v_date, v_reason));
      v_parts := v_parts || jsonb_build_object('pod_inventory_id', v_id, 'qty', v_qty, 'expiry', v_date, 'mode', 'merged');
    ELSIF NOT v_reused THEN
      UPDATE public.pod_inventory
         SET current_stock = v_qty, estimated_remaining = v_qty, expiration_date = v_date, snapshot_at = now()
       WHERE pod_inventory_id = o.pod_inventory_id;
      v_reused := true;
      v_id := o.pod_inventory_id;
      INSERT INTO public.pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
        source, operation, old_stock, new_stock, delta, old_status, new_status, actor, reference_id, notes)
      VALUES (v_id, o.machine_id, o.shelf_id, o.boonz_product_id, v_date, 'correction', 'update',
        o.current_stock, v_qty, v_qty - o.current_stock, 'Active', 'Active', auth.uid(),
        format('split_pod_lot-%s', p_pod_inventory_id), format('split: lot %s x%s becomes %s x%s: %s', o.expiration_date, o.current_stock, v_date, v_qty, v_reason));
      v_parts := v_parts || jsonb_build_object('pod_inventory_id', v_id, 'qty', v_qty, 'expiry', v_date, 'mode', 'original');
    ELSE
      INSERT INTO public.pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining,
        expiration_date, batch_id, status, snapshot_at)
      VALUES (o.machine_id, o.shelf_id, o.boonz_product_id, v_today, v_qty, v_qty, v_date,
        COALESCE(o.batch_id, format('SPLIT-%s', v_today)), 'Active', now())
      RETURNING pod_inventory_id INTO v_id;
      INSERT INTO public.pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
        source, operation, old_stock, new_stock, delta, old_status, new_status, actor, reference_id, notes)
      VALUES (v_id, o.machine_id, o.shelf_id, o.boonz_product_id, v_date, 'correction', 'insert',
        0, v_qty, v_qty, NULL, 'Active', auth.uid(),
        format('split_pod_lot-%s', p_pod_inventory_id), format('split: new lot %s x%s from %s: %s', v_date, v_qty, p_pod_inventory_id, v_reason));
      v_parts := v_parts || jsonb_build_object('pod_inventory_id', v_id, 'qty', v_qty, 'expiry', v_date, 'mode', 'inserted');
    END IF;
  END LOOP;

  IF NOT v_reused THEN
    -- both parts merged into existing lots: the original lot is now empty
    UPDATE public.pod_inventory SET current_stock = 0, estimated_remaining = 0, status = 'Inactive', snapshot_at = now()
     WHERE pod_inventory_id = o.pod_inventory_id;
    INSERT INTO public.pod_inventory_audit_log (pod_inventory_id, machine_id, shelf_id, boonz_product_id, expiration_date,
      source, operation, old_stock, new_stock, delta, old_status, new_status, actor, reference_id, notes)
    VALUES (o.pod_inventory_id, o.machine_id, o.shelf_id, o.boonz_product_id, o.expiration_date, 'correction', 'update',
      o.current_stock, 0, -o.current_stock, 'Active', 'Inactive', auth.uid(),
      format('split_pod_lot-%s', p_pod_inventory_id), format('split: both parts merged into existing lots: %s', v_reason));
  END IF;

  RETURN jsonb_build_object('status', 'ok', 'pod_inventory_id', p_pod_inventory_id,
    'from', jsonb_build_object('qty', o.current_stock, 'expiry', o.expiration_date), 'parts', v_parts);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.split_pod_lot(uuid, numeric, date, numeric, date, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.split_pod_lot(uuid, numeric, date, numeric, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_sold_since_planning(p_dispatch_id uuid, p_sold_qty numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role   text;
  d        public.refill_dispatching%ROWTYPE;
  v_new    numeric;
  v_note   text;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('field_staff', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'record_sold_since_planning: forbidden for role %', COALESCE(v_role, 'none');
  END IF;
  SELECT * INTO d FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'record_sold_since_planning: dispatch % not found', p_dispatch_id; END IF;
  IF d.action <> 'Remove' OR NOT COALESCE(d.include, true) OR COALESCE(d.cancelled, false)
     OR COALESCE(d.returned, false) OR COALESCE(d.item_added, false) OR d.driver_confirmed_qty IS NOT NULL THEN
    RAISE EXCEPTION 'record_sold_since_planning: only an open Remove leg (not yet confirmed) can be reduced';
  END IF;
  IF p_sold_qty IS NULL OR p_sold_qty <= 0 OR p_sold_qty > d.quantity THEN
    RAISE EXCEPTION 'record_sold_since_planning: sold quantity must be between 1 and %', d.quantity;
  END IF;
  v_new := d.quantity - p_sold_qty;
  v_note := format('sales_correction: %s sold since planning (Remove %s -> %s)%s', p_sold_qty, d.quantity, v_new,
              CASE WHEN NULLIF(trim(COALESCE(p_reason, '')), '') IS NOT NULL THEN ': ' || trim(p_reason) ELSE '' END);

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'record_sold_since_planning', true);
  PERFORM set_config('app.mutation_reason', v_note, true);

  UPDATE public.refill_dispatching
     SET quantity = v_new,
         filled_quantity = CASE WHEN filled_quantity IS NOT NULL AND filled_quantity > v_new THEN v_new ELSE filled_quantity END,
         driver_confirmed_breakdown = NULL,
         original_quantity = COALESCE(original_quantity, d.quantity),
         last_edited_by = auth.uid(), last_edited_by_role = v_role, last_edited_at = now(),
         edit_count = COALESCE(edit_count, 0) + 1
   WHERE dispatch_id = p_dispatch_id;

  INSERT INTO public.refill_dispatching_edit_log (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
  VALUES (p_dispatch_id, auth.uid(), v_role, 'qty',
    jsonb_build_object('quantity', d.quantity, 'filled_quantity', d.filled_quantity),
    jsonb_build_object('quantity', v_new, 'sales_correction', p_sold_qty, 'event', 'sales_correction'),
    v_note);

  RETURN jsonb_build_object('status', 'ok', 'dispatch_id', p_dispatch_id, 'sold_since_planning', p_sold_qty,
    'remove_qty_before', d.quantity, 'remove_qty_after', v_new);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.record_sold_since_planning(uuid, numeric, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.record_sold_since_planning(uuid, numeric, text) TO authenticated;
