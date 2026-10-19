-- PRD-144 P1-2: amend_dispatch_after_pickup, the one writer for changing a line that is already in the van
-- (picked_up, not delivered, not returned, not cancelled). operator_admin / superadmin only.
--   p_new_shelf_code  moves the line to another shelf of the same machine: shelf_id and pod_product_id are
--                     rewritten, and the boonz product must map (Active) to the pod on that shelf
--                     (WEIMI identity first, slot_lifecycle second).
--   p_new_qty         a LOWER quantity only (Refill / Add New): the difference goes back to the warehouse
--                     on the same reservation row return_dispatch_line would use (consumer_stock ->
--                     warehouse_stock), so warehouse conservation holds.
--   p_void            return_dispatch_line for the packed units, then include=false and quantity 0.
-- p_actor is recorded only and must be the caller (or NULL): the role check uses auth.uid().
-- Every call writes refill_dispatching_edit_log (there is no refill_dispatching_audit table; the edit log
-- is the per-line audit). protect_packed_dispatch_row gains one named exemption: amend_dispatch_after_pickup
-- may change shelf_id and pod_product_id on a packed line. boonz_product_id, machine_id and dispatch_date
-- stay locked for it.

CREATE OR REPLACE FUNCTION public.amend_dispatch_after_pickup(p_dispatch_id uuid, p_new_shelf_code text DEFAULT NULL::text, p_new_qty numeric DEFAULT NULL::numeric, p_void boolean DEFAULT false, p_reason text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role        text;
  v_reason      text := NULLIF(trim(COALESCE(p_reason, '')), '');
  d             public.refill_dispatching%ROWTYPE;
  v_before      jsonb;
  v_after       jsonb;
  v_code        text;
  v_shelf_id    uuid;
  v_new_pod     uuid;
  v_w           record;
  v_cur         numeric;
  v_diff        numeric;
  v_eff_expiry  date;
  v_consumer    public.warehouse_inventory%ROWTYPE;
  v_ret         jsonb;
  v_bp_name     text;
  v_did         text[] := '{}';
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin') THEN
    RAISE EXCEPTION 'amend_dispatch_after_pickup: operator_admin only (role %)', COALESCE(v_role, 'none');
  END IF;
  IF p_actor IS NOT NULL AND p_actor <> auth.uid() THEN
    RAISE EXCEPTION 'amend_dispatch_after_pickup: p_actor must be the signed-in user';
  END IF;
  IF v_reason IS NULL OR length(v_reason) < 5 THEN
    RAISE EXCEPTION 'amend_dispatch_after_pickup: a reason (5+ characters) is required';
  END IF;
  IF COALESCE(p_void, false) AND (p_new_shelf_code IS NOT NULL OR p_new_qty IS NOT NULL) THEN
    RAISE EXCEPTION 'amend_dispatch_after_pickup: void cannot be combined with a shelf or quantity change';
  END IF;
  IF NOT COALESCE(p_void, false) AND p_new_shelf_code IS NULL AND p_new_qty IS NULL THEN
    RAISE EXCEPTION 'amend_dispatch_after_pickup: nothing to change (give a new shelf, a new quantity, or void)';
  END IF;

  SELECT * INTO d FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'amend_dispatch_after_pickup: dispatch % not found', p_dispatch_id; END IF;
  IF NOT COALESCE(d.picked_up, false) OR d.delivered_at IS NOT NULL OR COALESCE(d.item_added, false)
     OR COALESCE(d.returned, false) OR COALESCE(d.cancelled, false) OR NOT COALESCE(d.include, true) THEN
    RAISE EXCEPTION 'amend_dispatch_after_pickup: dispatch % must be picked up and not yet delivered, returned or cancelled', p_dispatch_id;
  END IF;
  IF (COALESCE(p_void, false) OR p_new_qty IS NOT NULL)
     AND (d.action NOT IN ('Refill', 'Add New', 'Add') OR COALESCE(d.is_m2m, false)) THEN
    RAISE EXCEPTION 'amend_dispatch_after_pickup: quantity and void apply to warehouse Refill / Add New lines only (this is % %)',
      d.action, CASE WHEN d.is_m2m THEN 'M2M' ELSE '' END;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'amend_dispatch_after_pickup', true);
  PERFORM set_config('app.mutation_reason', format('amend_dispatch_after_pickup %s: %s', p_dispatch_id, v_reason), true);

  v_before := jsonb_build_object('shelf_id', d.shelf_id, 'pod_product_id', d.pod_product_id, 'quantity', d.quantity,
    'filled_quantity', d.filled_quantity, 'include', d.include);

  IF COALESCE(p_void, false) THEN
    v_ret := public.return_dispatch_line(p_dispatch_id, format('Voided after pickup: %s', v_reason), auth.uid(), NULL);
    IF v_ret->>'status' IS DISTINCT FROM 'returned' THEN
      RAISE EXCEPTION 'amend_dispatch_after_pickup: return of the packed units refused: %', COALESCE(v_ret->>'message', v_ret::text);
    END IF;
    PERFORM set_config('app.via_rpc', 'true', true);
    PERFORM set_config('app.rpc_name', 'amend_dispatch_after_pickup', true);
    UPDATE public.refill_dispatching
       SET include = false, quantity = 0, original_quantity = COALESCE(original_quantity, d.quantity),
           last_edited_by = auth.uid(), last_edited_by_role = v_role, last_edited_at = now(),
           edit_count = COALESCE(edit_count, 0) + 1
     WHERE dispatch_id = p_dispatch_id;
    v_did := array_append(v_did, 'void');
  END IF;

  IF p_new_shelf_code IS NOT NULL THEN
    v_code := upper(regexp_replace(trim(p_new_shelf_code), '^([A-Za-z])([0-9])$', '\1' || '0' || '\2'));
    SELECT shelf_id INTO v_shelf_id FROM public.shelf_configurations
     WHERE machine_id = d.machine_id AND shelf_code = v_code;
    IF v_shelf_id IS NULL THEN
      RAISE EXCEPTION 'amend_dispatch_after_pickup: shelf % not found on this machine', v_code;
    END IF;
    IF v_shelf_id = d.shelf_id THEN
      RAISE EXCEPTION 'amend_dispatch_after_pickup: the line is already on shelf %', v_code;
    END IF;
    SELECT * INTO v_w FROM public.weimi_lane_now(d.machine_id, v_code);
    IF v_w.pod_product_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM public.product_mapping pm
          WHERE pm.pod_product_id = v_w.pod_product_id AND pm.boonz_product_id = d.boonz_product_id
            AND pm.status = 'Active' AND (pm.machine_id = d.machine_id OR pm.machine_id IS NULL)) THEN
      v_new_pod := v_w.pod_product_id;
    ELSE
      SELECT sl.pod_product_id INTO v_new_pod FROM public.slot_lifecycle sl
       WHERE sl.shelf_id = v_shelf_id AND sl.is_current AND NOT sl.archived
         AND EXISTS (SELECT 1 FROM public.product_mapping pm
                      WHERE pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = d.boonz_product_id
                        AND pm.status = 'Active' AND (pm.machine_id = d.machine_id OR pm.machine_id IS NULL))
       ORDER BY sl.rotated_in_at DESC NULLS LAST LIMIT 1;
    END IF;
    IF v_new_pod IS NULL THEN
      SELECT boonz_product_name INTO v_bp_name FROM public.boonz_products WHERE product_id = d.boonz_product_id;
      RAISE EXCEPTION 'amend_dispatch_after_pickup: % is not mapped to the product on shelf % (WEIMI shows %); fix the mapping first',
        COALESCE(v_bp_name, d.boonz_product_id::text), v_code, COALESCE(v_w.product_name, 'no row');
    END IF;
    UPDATE public.refill_dispatching
       SET shelf_id = v_shelf_id, pod_product_id = v_new_pod, original_shelf_id = COALESCE(original_shelf_id, d.shelf_id),
           last_edited_by = auth.uid(), last_edited_by_role = v_role, last_edited_at = now(),
           edit_count = COALESCE(edit_count, 0) + 1
     WHERE dispatch_id = p_dispatch_id;
    v_did := array_append(v_did, 'shelf');
  END IF;

  IF p_new_qty IS NOT NULL THEN
    v_cur := COALESCE(d.filled_quantity, d.quantity);
    IF p_new_qty <= 0 THEN
      RAISE EXCEPTION 'amend_dispatch_after_pickup: for 0 use void';
    END IF;
    IF p_new_qty >= v_cur THEN
      RAISE EXCEPTION 'amend_dispatch_after_pickup: the new quantity (%) must be lower than the % in the van; more units need a new packed line', p_new_qty, v_cur;
    END IF;
    v_diff := v_cur - p_new_qty;
    -- Same reservation row return_dispatch_line credits: the pinned batch, else the machine's reservation.
    PERFORM set_config('app.provenance_reason', 'dispatch_return', true);
    PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
    IF d.from_wh_inventory_id IS NOT NULL THEN
      SELECT expiration_date INTO v_eff_expiry FROM public.warehouse_inventory WHERE wh_inventory_id = d.from_wh_inventory_id;
      SELECT * INTO v_consumer FROM public.warehouse_inventory WHERE wh_inventory_id = d.from_wh_inventory_id FOR UPDATE;
      IF NOT FOUND OR COALESCE(v_consumer.consumer_stock, 0) <= 0 THEN v_consumer := NULL; END IF;
    ELSE
      v_eff_expiry := d.expiry_date;
    END IF;
    IF v_consumer.wh_inventory_id IS NULL THEN
      SELECT * INTO v_consumer FROM public.warehouse_inventory
       WHERE boonz_product_id = d.boonz_product_id AND COALESCE(consumer_stock, 0) > 0
         AND (reserved_for_machine_id = d.machine_id OR reserved_for_machine_id IS NULL)
         AND (expiration_date = v_eff_expiry OR v_eff_expiry IS NULL)
       ORDER BY (reserved_for_machine_id = d.machine_id) DESC, consumer_stock DESC LIMIT 1 FOR UPDATE;
    END IF;
    IF v_consumer.wh_inventory_id IS NULL OR COALESCE(v_consumer.consumer_stock, 0) < v_diff THEN
      RAISE EXCEPTION 'amend_dispatch_after_pickup: no packed reservation holds the % unit(s) to return; nothing changed', v_diff;
    END IF;
    UPDATE public.warehouse_inventory
       SET consumer_stock = consumer_stock - v_diff,
           warehouse_stock = COALESCE(warehouse_stock, 0) + v_diff,
           reserved_for_machine_id = CASE WHEN consumer_stock - v_diff <= 0 THEN NULL ELSE reserved_for_machine_id END,
           reserved_at = CASE WHEN consumer_stock - v_diff <= 0 THEN NULL ELSE reserved_at END
     WHERE wh_inventory_id = v_consumer.wh_inventory_id;
    UPDATE public.refill_dispatching
       SET quantity = p_new_qty, filled_quantity = p_new_qty, original_quantity = COALESCE(original_quantity, d.quantity),
           last_edited_by = auth.uid(), last_edited_by_role = v_role, last_edited_at = now(),
           edit_count = COALESCE(edit_count, 0) + 1
     WHERE dispatch_id = p_dispatch_id;
    v_did := array_append(v_did, 'qty');
  END IF;

  SELECT jsonb_build_object('shelf_id', r.shelf_id, 'pod_product_id', r.pod_product_id, 'quantity', r.quantity,
           'filled_quantity', r.filled_quantity, 'include', r.include, 'returned', r.returned)
    INTO v_after FROM public.refill_dispatching r WHERE r.dispatch_id = p_dispatch_id;
  INSERT INTO public.refill_dispatching_edit_log (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason)
  VALUES (p_dispatch_id, auth.uid(), v_role, CASE WHEN v_did = ARRAY['shelf'] THEN 'shelf' ELSE 'qty' END,
          v_before, v_after || jsonb_build_object('amend', to_jsonb(v_did), 'returned_to_wh', COALESCE(v_diff, 0),
            'wh_inventory_id', v_consumer.wh_inventory_id),
          format('amend_dispatch_after_pickup: %s', v_reason));

  RETURN jsonb_build_object('status', 'ok', 'dispatch_id', p_dispatch_id, 'changed', to_jsonb(v_did),
    'before', v_before, 'after', v_after, 'returned_to_warehouse', COALESCE(v_diff, 0),
    'credited_wh_inventory_id', v_consumer.wh_inventory_id, 'void_return', v_ret);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.amend_dispatch_after_pickup(uuid, text, numeric, boolean, text, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.amend_dispatch_after_pickup(uuid, text, numeric, boolean, text, uuid) TO authenticated;

DO $patch$
DECLARE
  v_def text; n int; i int; pairs text[][];
BEGIN
  v_def := pg_get_functiondef('public.protect_packed_dispatch_row()'::regprocedure);
  pairs := ARRAY[
    ARRAY['      IF NEW.pod_product_id IS DISTINCT FROM OLD.pod_product_id THEN',
          '      IF NEW.pod_product_id IS DISTINCT FROM OLD.pod_product_id' || chr(10)
          || '         AND current_setting(''app.rpc_name'', true) IS DISTINCT FROM ''amend_dispatch_after_pickup'' THEN  -- PRD-144 P1-2'],
    ARRAY['    IF NEW.shelf_id IS DISTINCT FROM OLD.shelf_id THEN',
          '    IF NEW.shelf_id IS DISTINCT FROM OLD.shelf_id' || chr(10)
          || '       AND current_setting(''app.rpc_name'', true) IS DISTINCT FROM ''amend_dispatch_after_pickup'' THEN  -- PRD-144 P1-2']
  ];
  FOR i IN 1 .. array_length(pairs, 1) LOOP
    n := (length(v_def) - length(replace(v_def, pairs[i][1], ''))) / length(pairs[i][1]);
    IF n <> 1 THEN RAISE EXCEPTION 'prd144_p1_2: protect_packed_dispatch_row anchor % count %', i, n; END IF;
    v_def := replace(v_def, pairs[i][1], pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;