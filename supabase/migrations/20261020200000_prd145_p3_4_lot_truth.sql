-- PRD-145 P3-4: lot truth at pack.
-- 19-20 Oct: push_plan_to_dispatch pinned 37 lines to warehouse_inventory lots of 1 to 3 units that were not on the
-- shelf (ghost lots); the operator repinned them by hand and deducted 81 units from the real lots. A warehouse edit after
-- push did not move the pin.
--   pack_dispatch_line          already records the lot actually picked on each row (expiry_date, from_wh_inventory_id
--                               follow the pick, one child row per further lot). Its child rows now also carry the
--                               line's source_kind, from_warehouse_id and source_warehouse_id (they were written blank,
--                               so a child did not group with its line).
--   tg_repin_dispatch_on_lot_change   AFTER UPDATE on warehouse_inventory (adjust_warehouse_stock, the warehouse confirm
--                               path and every other writer): when a lot goes to 0, leaves Active, or changes expiry,
--                               each unpacked warehouse line pinned to it moves to the FEFO live lot of the same product
--                               in the same warehouse (a lot that covers the line first) and the move is logged in
--                               refill_dispatching_edit_log as edit_kind 'repin' (new kind, added to both checks).
--   get_ghost_lot_candidates()  Active lots of 1 to 3 units where another Active lot of the same product in the same
--                               warehouse holds at least 5x the stock (2099 venue placeholders excluded).
--   zero_ghost_lot(id, reason)  warehouse role only; a current candidate only; adjust_warehouse_stock to 0 with the lot's
--                               consumer_stock, expiry, batch and status passed back unchanged (Article 6: this code
--                               never sets status; the existing propose_inactivate_on_zero_stock rule marks any lot that
--                               reaches 0 Inactive, as it does for every count to 0).
--   get_plan_pin_preview(date)  read-only: per planned warehouse line, the lot the push would pin (same rule as
--                               push_plan_to_dispatch), its expiry and units, and tail_lot when it holds under 4 units
--                               and a bigger live lot of the product exists in that warehouse.
ALTER TABLE public.refill_dispatching_edit_log DROP CONSTRAINT refill_dispatching_edit_log_edit_kind_check;
ALTER TABLE public.refill_dispatching_edit_log ADD CONSTRAINT refill_dispatching_edit_log_edit_kind_check
  CHECK (edit_kind = ANY (ARRAY['qty', 'shelf', 'product', 'source', 'add', 'remove', 'decline_swap',
                                'cancel_m2m_transfer', 'variant_split', 'repin']));
ALTER TABLE public.refill_dispatching_edit_log DROP CONSTRAINT refill_dispatching_edit_log_state_coherence;
ALTER TABLE public.refill_dispatching_edit_log ADD CONSTRAINT refill_dispatching_edit_log_state_coherence
  CHECK (((edit_kind = 'add') AND (before_state IS NULL) AND (after_state IS NOT NULL))
      OR ((edit_kind = 'remove') AND (before_state IS NOT NULL) AND (after_state IS NULL))
      OR ((edit_kind = ANY (ARRAY['qty', 'shelf', 'product', 'source', 'decline_swap', 'cancel_m2m_transfer',
                                  'variant_split', 'repin']))
          AND (before_state IS NOT NULL) AND (after_state IS NOT NULL)));

DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.pack_dispatch_line(uuid,jsonb,uuid)'::regprocedure);
  pairs := ARRAY[
    ARRAY[$a$item_added, expiry_date, from_wh_inventory_id, pack_outcome, source_origin, parent_dispatch_id) VALUES ($a$,
          $a$item_added, expiry_date, from_wh_inventory_id, pack_outcome, source_origin, parent_dispatch_id, source_kind, from_warehouse_id, source_warehouse_id) VALUES ($a$],
    ARRAY[$a$v_wh_row.expiration_date, v_wh_row.wh_inventory_id, 'packed', v_dispatch.source_origin, p_dispatch_id) RETURNING dispatch_id INTO v_new_child_id;$a$,
          $a$v_wh_row.expiration_date, v_wh_row.wh_inventory_id, 'packed', v_dispatch.source_origin, p_dispatch_id, v_dispatch.source_kind, v_dispatch.from_warehouse_id, v_dispatch.source_warehouse_id) RETURNING dispatch_id INTO v_new_child_id;  -- PRD-145 P3-4: the child is part of the line$a$]
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_4: pack_dispatch_line anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;

  -- The repin trigger writes refill_dispatching under its own name; the canonical-write guard must know it.
  v_def := pg_get_functiondef('public.enforce_canonical_dispatch_write()'::regprocedure);
  pairs := ARRAY[ARRAY[$a$'mark_picked_up',$a$, $a$'mark_picked_up','repin_dispatch_to_fefo',$a$]];
  n := (length(v_def) - length(replace(v_def, pairs[1][1], ''))) / length(pairs[1][1]);
  IF n <> 1 THEN RAISE EXCEPTION 'prd145_p3_4: enforce_canonical_dispatch_write anchor count %', n; END IF;
  EXECUTE replace(v_def, pairs[1][1], pairs[1][2]);
END
$patch$;

CREATE FUNCTION public.tg_repin_dispatch_on_lot_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_prev_via text; v_prev_rpc text; v_prev_reason text;
  r record; v_target record; v_why text; v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
BEGIN
  v_why := CASE
    WHEN COALESCE(NEW.warehouse_stock, 0) <= 0 AND COALESCE(OLD.warehouse_stock, 0) > 0 THEN 'lot went to 0'
    WHEN NEW.status IS DISTINCT FROM OLD.status AND OLD.status = 'Active' THEN format('lot left Active (%s)', NEW.status)
    WHEN NEW.expiration_date IS DISTINCT FROM OLD.expiration_date
      THEN format('lot expiry changed %s -> %s', OLD.expiration_date, NEW.expiration_date)
  END;
  IF v_why IS NULL THEN RETURN NULL; END IF;

  v_prev_via := current_setting('app.via_rpc', true);
  v_prev_rpc := current_setting('app.rpc_name', true);
  v_prev_reason := current_setting('app.mutation_reason', true);
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'repin_dispatch_to_fefo', true);

  FOR r IN
    SELECT d.dispatch_id, d.machine_id, d.boonz_product_id, d.quantity, d.from_wh_inventory_id, d.expiry_date
      FROM public.refill_dispatching d
     WHERE d.from_wh_inventory_id = NEW.wh_inventory_id
       AND NOT COALESCE(d.packed, false) AND COALESCE(d.include, true)
       AND NOT COALESCE(d.cancelled, false) AND NOT COALESCE(d.skipped, false)
       AND NOT COALESCE(d.is_m2m, false) AND d.action IN ('Refill', 'Add New', 'Add')
       AND COALESCE(d.source_kind, 'wh') = 'wh'
       AND d.source_origin IS DISTINCT FROM 'vox_at_venue'
     FOR UPDATE
  LOOP
    SELECT p.wh_inventory_id, p.expiration_date, p.warehouse_stock INTO v_target
      FROM public.v_wh_pickable p
     WHERE p.boonz_product_id = r.boonz_product_id AND p.warehouse_id = NEW.warehouse_id
       AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = r.machine_id)
       AND p.expiration_date IS DISTINCT FROM DATE '2099-12-31'
     ORDER BY (p.warehouse_stock >= COALESCE(r.quantity, 0)) DESC, p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
     LIMIT 1;
    -- No live lot: the pin stays and pack_dispatch_line's rebind reports the gap at pack time.
    -- Same lot (an expiry correction on the best lot): sync_dispatch_expiry_from_pinned_wh carries the date.
    CONTINUE WHEN v_target.wh_inventory_id IS NULL OR v_target.wh_inventory_id = NEW.wh_inventory_id;
    PERFORM set_config('app.mutation_reason',
      format('repin_dispatch_to_fefo: %s, dispatch %s moved to lot %s', v_why, r.dispatch_id, v_target.wh_inventory_id), true);
    UPDATE public.refill_dispatching
       SET from_wh_inventory_id = v_target.wh_inventory_id, expiry_date = v_target.expiration_date
     WHERE dispatch_id = r.dispatch_id;
    INSERT INTO public.refill_dispatching_edit_log (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
    VALUES (r.dispatch_id, auth.uid(), 'system', 'repin',
            jsonb_build_object('from_wh_inventory_id', r.from_wh_inventory_id, 'expiry_date', r.expiry_date),
            jsonb_build_object('from_wh_inventory_id', v_target.wh_inventory_id, 'expiry_date', v_target.expiration_date,
                               'lot_stock', v_target.warehouse_stock),
            format('PRD-145 P3-4 repin: %s', v_why));
  END LOOP;

  PERFORM set_config('app.via_rpc', COALESCE(v_prev_via, ''), true);
  PERFORM set_config('app.rpc_name', COALESCE(v_prev_rpc, ''), true);
  PERFORM set_config('app.mutation_reason', COALESCE(v_prev_reason, ''), true);
  RETURN NULL;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.tg_repin_dispatch_on_lot_change() FROM public, anon, authenticated;
CREATE TRIGGER trg_repin_dispatch_on_lot_change
  AFTER UPDATE OF warehouse_stock, expiration_date, status ON public.warehouse_inventory
  FOR EACH ROW
  WHEN ((COALESCE(new.warehouse_stock, 0) <= 0 AND COALESCE(old.warehouse_stock, 0) > 0)
        OR new.expiration_date IS DISTINCT FROM old.expiration_date
        OR (new.status IS DISTINCT FROM old.status AND old.status = 'Active'))
  EXECUTE FUNCTION public.tg_repin_dispatch_on_lot_change();

CREATE FUNCTION public.get_ghost_lot_candidates()
 RETURNS TABLE(wh_inventory_id uuid, warehouse_id uuid, warehouse_name text, boonz_product_id uuid, boonz_product_name text,
               expiration_date date, warehouse_stock numeric, big_lot_id uuid, big_lot_expiry date, big_lot_stock numeric,
               pinned_unpacked_rows int)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT s.wh_inventory_id, s.warehouse_id, w.name, s.boonz_product_id, bp.boonz_product_name,
         s.expiration_date, s.warehouse_stock, b.wh_inventory_id, b.expiration_date, b.warehouse_stock,
         (SELECT count(*)::int FROM public.refill_dispatching d
           WHERE d.from_wh_inventory_id = s.wh_inventory_id AND NOT COALESCE(d.packed, false)
             AND COALESCE(d.include, true) AND NOT COALESCE(d.cancelled, false))
    FROM public.warehouse_inventory s
    JOIN public.warehouses w ON w.warehouse_id = s.warehouse_id
    LEFT JOIN public.boonz_products bp ON bp.product_id = s.boonz_product_id
    CROSS JOIN LATERAL (
      SELECT x.wh_inventory_id, x.expiration_date, x.warehouse_stock FROM public.warehouse_inventory x
       WHERE x.boonz_product_id = s.boonz_product_id AND x.warehouse_id = s.warehouse_id AND x.status = 'Active'
         AND x.wh_inventory_id <> s.wh_inventory_id AND x.expiration_date IS DISTINCT FROM DATE '2099-12-31'
         AND COALESCE(x.warehouse_stock, 0) >= 5 * s.warehouse_stock
       ORDER BY x.warehouse_stock DESC LIMIT 1) b
   WHERE s.status = 'Active' AND s.warehouse_stock BETWEEN 1 AND 3
     AND s.expiration_date IS DISTINCT FROM DATE '2099-12-31'
   ORDER BY w.name, bp.boonz_product_name, s.expiration_date;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_ghost_lot_candidates() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_ghost_lot_candidates() TO authenticated, service_role;

CREATE FUNCTION public.zero_ghost_lot(p_wh_inventory_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text; v_reason text := NULLIF(trim(COALESCE(p_reason, '')), ''); v_lot public.warehouse_inventory; v_res jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS DISTINCT FROM 'warehouse' THEN
    RAISE EXCEPTION 'zero_ghost_lot: warehouse manager only (role %)', COALESCE(v_role, 'none');
  END IF;
  IF v_reason IS NULL OR length(v_reason) < 5 THEN
    RAISE EXCEPTION 'zero_ghost_lot: a reason (5+ characters) is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.get_ghost_lot_candidates() c WHERE c.wh_inventory_id = p_wh_inventory_id) THEN
    RAISE EXCEPTION 'zero_ghost_lot: lot % is not on the Lots to count list (count it through the normal stock edit)', p_wh_inventory_id;
  END IF;
  SELECT * INTO v_lot FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;
  v_res := public.adjust_warehouse_stock(v_lot.warehouse_id,
    jsonb_build_array(jsonb_build_object(
      'wh_inventory_id', v_lot.wh_inventory_id, 'boonz_product_id', v_lot.boonz_product_id,
      'new_warehouse_stock', 0, 'new_consumer_stock', COALESCE(v_lot.consumer_stock, 0),
      'expiration_date', v_lot.expiration_date, 'batch_id', v_lot.batch_id, 'status', v_lot.status)),
    (now() AT TIME ZONE 'Asia/Dubai')::date,
    format('PRD-145 P3-4 lot counted at 0: %s', v_reason));
  RETURN jsonb_build_object('status', 'ok', 'wh_inventory_id', p_wh_inventory_id, 'old_stock', v_lot.warehouse_stock,
    'repinned_rows', (SELECT count(*) FROM public.refill_dispatching_edit_log l
                       WHERE l.edit_kind = 'repin' AND l.edited_at = now()
                         AND l.before_state->>'from_wh_inventory_id' = p_wh_inventory_id::text),
    'adjust', v_res);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.zero_ghost_lot(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.zero_ghost_lot(uuid, text) TO authenticated, service_role;

CREATE FUNCTION public.get_plan_pin_preview(p_plan_date date)
 RETURNS TABLE(plan_id uuid, machine_name text, shelf_code text, boonz_product_name text, quantity numeric,
               wh_inventory_id uuid, expiration_date date, lot_stock numeric, tail_lot boolean,
               bigger_lot_id uuid, bigger_lot_expiry date, bigger_lot_stock numeric)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH lines AS (
    SELECT rpo.id, rpo.machine_name, rpo.shelf_code, rpo.boonz_product_name, rpo.quantity, rpo.plan_date,
           m.machine_id, rpo.boonz_product_id,
           CASE WHEN bp.storage_temp_requirement = 'cold' THEN ARRAY[public.wh_central_id()::uuid]
                ELSE ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id] END AS whs
      FROM public.refill_plan_output rpo
      JOIN public.machines m ON m.official_name = rpo.machine_name
      LEFT JOIN public.boonz_products bp ON bp.product_id = rpo.boonz_product_id
     WHERE rpo.plan_date = p_plan_date AND NOT COALESCE(rpo.dispatched, false)
       AND rpo.operator_status IN ('pending', 'approved')
       AND rpo.action IN ('Refill', 'Add New')
       AND COALESCE(rpo.source_origin::text, 'warehouse') = 'warehouse'
       AND rpo.boonz_product_id IS NOT NULL
  )
  SELECT l.id, l.machine_name, l.shelf_code, l.boonz_product_name, l.quantity,
         pin.wh_inventory_id, pin.expiration_date, pin.warehouse_stock,
         (pin.warehouse_stock < 4 AND big.wh_inventory_id IS NOT NULL),
         big.wh_inventory_id, big.expiration_date, big.warehouse_stock
    FROM lines l
    LEFT JOIN LATERAL (
      SELECT f.wh_inventory_id, f.expiration_date, f.warehouse_stock, f.warehouse_id
        FROM public.wh_fefo_for_line(l.machine_id, l.boonz_product_id, l.plan_date, l.quantity, l.whs) f
       WHERE f.is_satisfiable AND f.net_running >= l.quantity
       ORDER BY f.pick_rank LIMIT 1) pin ON true
    LEFT JOIN LATERAL (
      SELECT p.wh_inventory_id, p.expiration_date, p.warehouse_stock FROM public.v_wh_pickable p
       WHERE p.boonz_product_id = l.boonz_product_id AND p.warehouse_id = pin.warehouse_id
         AND p.wh_inventory_id <> pin.wh_inventory_id AND p.warehouse_stock > pin.warehouse_stock
         AND p.expiration_date IS DISTINCT FROM DATE '2099-12-31'
       ORDER BY p.warehouse_stock DESC LIMIT 1) big ON true
   ORDER BY l.machine_name, l.shelf_code;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_plan_pin_preview(date) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_plan_pin_preview(date) TO authenticated, service_role;
