-- Loop 2026-09-25 (CS ADD TO LOOP, R1): insert_driver_remove_line non-M2M parent selection fix.
--
-- DEFERRED, NOT YET APPLIED. insert_driver_remove_line is a field-app dispatch function; this
-- loop's own hard rule restricts migrations touching dispatch/field-app functions to the
-- 22:00-06:00 Dubai window. Drafted and investigated now so it is ready the moment the window
-- opens; STATE.md records this as DEFERRED. Queue order for tonight: R1, R3, R2, R4, R5a, R5c.
--
-- Confirmed not previously fixed: read the live function body via pg_get_functiondef before
-- writing anything. The non-M2M branch selected exactly one candidate parent via
-- "ORDER BY rd.created_at DESC LIMIT 1" with no SUM-across-siblings, no FOR UPDATE row lock beyond
-- the single row, and no p_dispatch_date parameter (hardcoded CURRENT_DATE). Confirmed live on the
-- named evidence: ADDMIND-1007-0000-W0 shelf A16, 2026-09-25, three sibling non-M2M Remove lines
-- on the same shelf+pod (Vitamin Well) -- Zero Lemon qty 8, Zero peach qty 1, Antioxidant qty 0
-- (created last) -- so the old query grabbed the newest (Antioxidant, qty 0) and refused the
-- driver's Care x8 split with "only has 2 units remaining" (the qty visible on that single row
-- plus whatever was already drawn), even though 9 real units (8+1) were available across the
-- other two sibling lines.
--
-- Fix: the non-M2M branch now locks every sibling Remove line on the same machine+shelf+pod+date
-- (FOR UPDATE), excluding is_m2m and excluding any sibling whose boonz_product_id already equals
-- the flavour being added (drawing a new line's stock from an existing line of the SAME flavour
-- would be circular). If the summed remaining quantity across those eligible siblings is less
-- than the requested split, the function refuses with an exception that lists every eligible
-- sibling (boonz product name and its remaining qty), so the caller can see exactly what is
-- plannable instead of a single misleading "2 units remaining" message. Otherwise it draws the
-- split down across siblings largest-remaining-first, never below 0, logging one
-- refill_dispatching_edit_log row per sibling actually drawn from (edit_kind 'variant_split',
-- before/after quantity). The new child line inherits its source_kind/source_machine_id/warehouse
-- routing from the largest sibling actually drawn from, matching today's "inherit from parent"
-- behaviour. The M2M branch is untouched except for using the new p_dispatch_date parameter
-- (default CURRENT_DATE) instead of a hardcoded CURRENT_DATE, so a split can be requested for a
-- named plan_date, not only today.
--
-- edit_dispatch_qty's guard against editing a packed/driver-confirmed line is deliberately left
-- untouched; this fix only changes which sibling(s) fund a NEW inserted line, never edits an
-- existing line's own packed/confirmed state.

-- Widen the edit_kind vocabulary, forward only, same pattern as A1's 'cancel_m2m_transfer' value:
-- new value 'variant_split', same shape as qty/shelf/product/source (before_state and after_state
-- both required).
ALTER TABLE public.refill_dispatching_edit_log
  DROP CONSTRAINT refill_dispatching_edit_log_edit_kind_check;
ALTER TABLE public.refill_dispatching_edit_log
  ADD CONSTRAINT refill_dispatching_edit_log_edit_kind_check
  CHECK (edit_kind = ANY (ARRAY['qty','shelf','product','source','add','remove','decline_swap','cancel_m2m_transfer','variant_split']));

ALTER TABLE public.refill_dispatching_edit_log
  DROP CONSTRAINT refill_dispatching_edit_log_state_coherence;
ALTER TABLE public.refill_dispatching_edit_log
  ADD CONSTRAINT refill_dispatching_edit_log_state_coherence
  CHECK (
    ((edit_kind = 'add') AND (before_state IS NULL) AND (after_state IS NOT NULL))
    OR ((edit_kind = 'remove') AND (before_state IS NOT NULL) AND (after_state IS NULL))
    OR ((edit_kind = ANY (ARRAY['qty','shelf','product','source','decline_swap','cancel_m2m_transfer','variant_split']))
        AND (before_state IS NOT NULL) AND (after_state IS NOT NULL))
  );

CREATE OR REPLACE FUNCTION public.insert_driver_remove_line(
  p_machine_id uuid,
  p_boonz_product_id uuid,
  p_pod_product_id uuid,
  p_shelf_id uuid,
  p_quantity numeric,
  p_expiry_date date,
  p_reason text,
  p_dispatch_date date DEFAULT CURRENT_DATE
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_caller_role text;
  v_dispatch_id uuid;
  v_parent refill_dispatching%ROWTYPE;
  v_partner refill_dispatching%ROWTYPE;
  v_new_transfer_id uuid;
  v_new_source_id uuid;
  v_new_dest_id uuid;
  v_dest_pod_ok boolean;
  v_sibling RECORD;
  v_sibling_total numeric := 0;
  v_siblings_desc text := '';
  v_remaining numeric;
  v_take numeric;
  v_largest_drawn refill_dispatching%ROWTYPE;
  v_draws_made int := 0;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'insert_driver_remove_line: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity required (qty > 0)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'insert_driver_remove_line', true);

  -- M2M detection unchanged: the newest matching Remove line decides whether this is an M2M
  -- split. Only CURRENT_DATE -> p_dispatch_date changed here.
  SELECT * INTO v_parent FROM refill_dispatching rd
   WHERE rd.machine_id = p_machine_id
     AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
     AND rd.pod_product_id = p_pod_product_id
     AND rd.dispatch_date = p_dispatch_date
     AND rd.action = 'Remove' AND rd.include
     AND COALESCE(rd.cancelled, false) = false
   ORDER BY rd.created_at DESC LIMIT 1;

  IF COALESCE(v_parent.is_m2m, false) THEN
    SELECT * INTO v_parent FROM refill_dispatching rd
     WHERE rd.machine_id = p_machine_id
       AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
       AND rd.pod_product_id = p_pod_product_id
       AND rd.dispatch_date = p_dispatch_date
       AND rd.action = 'Remove' AND rd.include
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.is_m2m, false) = true
       AND rd.boonz_product_id IS DISTINCT FROM p_boonz_product_id
       AND COALESCE(rd.quantity, 0) >= p_quantity
     ORDER BY rd.quantity DESC, rd.created_at ASC
     FOR UPDATE
     LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'insert_driver_remove_line: no open M2M parent leg for machine %, shelf %, pod % has >= % units remaining to split off as % - resolve manually, refusing to write an orphan',
        p_machine_id, p_shelf_id, p_pod_product_id, p_quantity, p_boonz_product_id;
    END IF;

    IF v_parent.m2m_partner_id IS NULL THEN
      RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch % is is_m2m=true but has no m2m_partner_id - destination cannot be resolved, refusing to write an orphan',
        v_parent.dispatch_id;
    END IF;

    SELECT * INTO v_partner FROM refill_dispatching WHERE dispatch_id = v_parent.m2m_partner_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch %''s partner % not found - destination cannot be resolved, refusing to write an orphan',
        v_parent.dispatch_id, v_parent.m2m_partner_id;
    END IF;
    IF COALESCE(v_partner.quantity, 0) < p_quantity THEN
      RAISE EXCEPTION 'insert_driver_remove_line: destination leg % only has % units remaining, cannot absorb a % unit split - the pair is already imbalanced, resolve manually',
        v_partner.dispatch_id, v_partner.quantity, p_quantity;
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM product_mapping pm
      WHERE pm.pod_product_id = p_pod_product_id AND pm.status = 'Active'
        AND pm.boonz_product_id = p_boonz_product_id
        AND (pm.machine_id = v_partner.machine_id OR pm.machine_id IS NULL)
    ) INTO v_dest_pod_ok;
    IF NOT v_dest_pod_ok THEN
      RAISE EXCEPTION 'insert_driver_remove_line: boonz_product % has no Active product_mapping to pod % at destination machine % - refusing to write an orphan',
        p_boonz_product_id, p_pod_product_id, v_partner.machine_id;
    END IF;

    v_new_transfer_id := gen_random_uuid();
    v_new_source_id := gen_random_uuid();
    v_new_dest_id := gen_random_uuid();

    INSERT INTO refill_dispatching
      (dispatch_id, machine_id, boonz_product_id, pod_product_id, shelf_id,
       dispatch_date, action, quantity, filled_quantity, expiry_date,
       packed, picked_up, dispatched, returned, item_added, include, comment,
       source_origin, source_kind, source_machine_id, is_m2m, m2m_transfer_id,
       from_warehouse_id)
    VALUES
      (v_new_source_id, p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
       p_dispatch_date, 'Remove', p_quantity, 0, p_expiry_date,
       true, true, true, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id,
       NULL);

    INSERT INTO refill_dispatching
      (dispatch_id, machine_id, boonz_product_id, pod_product_id, shelf_id,
       dispatch_date, action, quantity, filled_quantity, expiry_date,
       packed, picked_up, dispatched, returned, item_added, include, comment,
       source_origin, source_kind, source_machine_id, is_m2m, m2m_transfer_id, m2m_partner_id,
       from_warehouse_id)
    VALUES
      (v_new_dest_id, v_partner.machine_id, p_boonz_product_id, p_pod_product_id, v_partner.shelf_id,
       p_dispatch_date, 'Add New', p_quantity, 0, p_expiry_date,
       true, false, false, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id, v_new_source_id,
       NULL)
    RETURNING dispatch_id INTO v_dispatch_id;

    UPDATE refill_dispatching SET m2m_partner_id = v_new_dest_id WHERE dispatch_id = v_new_source_id;

    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_parent.dispatch_id;
    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_partner.dispatch_id;

    RETURN jsonb_build_object('ok', true, 'dispatch_id', v_new_source_id,
      'dest_dispatch_id', v_new_dest_id, 'transfer_id', v_new_transfer_id,
      'machine_id', p_machine_id, 'dest_machine_id', v_partner.machine_id,
      'qty', p_quantity, 'reason', p_reason,
      'inherited_from_parent', v_parent.dispatch_id, 'partner_reduced', v_partner.dispatch_id);
  END IF;

  -- R1: non-M2M branch. Sum every eligible sibling Remove line (same machine+shelf+pod+date,
  -- non-M2M, not this exact flavour) before deciding anything.
  FOR v_sibling IN
    SELECT * FROM refill_dispatching rd
     WHERE rd.machine_id = p_machine_id
       AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
       AND rd.pod_product_id = p_pod_product_id
       AND rd.dispatch_date = p_dispatch_date
       AND rd.action = 'Remove' AND rd.include
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.is_m2m, false) = false
       AND rd.boonz_product_id IS DISTINCT FROM p_boonz_product_id
     ORDER BY rd.quantity DESC, rd.created_at ASC
     FOR UPDATE
  LOOP
    v_sibling_total := v_sibling_total + COALESCE(v_sibling.quantity, 0);
    v_siblings_desc := v_siblings_desc || format('%s: %s remaining; ',
      (SELECT boonz_product_name FROM boonz_products WHERE product_id = v_sibling.boonz_product_id),
      COALESCE(v_sibling.quantity, 0));
  END LOOP;

  IF v_sibling_total < p_quantity THEN
    RAISE EXCEPTION 'insert_driver_remove_line: only % units remaining across the planned Remove lines on this shelf, cannot absorb a % unit split. Planned: %',
      v_sibling_total, p_quantity, v_siblings_desc;
  END IF;

  v_remaining := p_quantity;
  FOR v_sibling IN
    SELECT * FROM refill_dispatching rd
     WHERE rd.machine_id = p_machine_id
       AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
       AND rd.pod_product_id = p_pod_product_id
       AND rd.dispatch_date = p_dispatch_date
       AND rd.action = 'Remove' AND rd.include
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.is_m2m, false) = false
       AND rd.boonz_product_id IS DISTINCT FROM p_boonz_product_id
     ORDER BY rd.quantity DESC, rd.created_at ASC
     FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    IF COALESCE(v_sibling.quantity, 0) <= 0 THEN CONTINUE; END IF;
    v_take := LEAST(v_sibling.quantity, v_remaining);

    UPDATE refill_dispatching SET quantity = quantity - v_take WHERE dispatch_id = v_sibling.dispatch_id;

    INSERT INTO refill_dispatching_edit_log
      (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
    VALUES
      (v_sibling.dispatch_id, v_caller_id, COALESCE(v_caller_role, 'system'), 'variant_split',
       jsonb_build_object('quantity', v_sibling.quantity),
       jsonb_build_object('quantity', v_sibling.quantity - v_take),
       format('[DRIVER-INSERT variant split] drew %s units for a new %s line: %s', v_take,
         (SELECT boonz_product_name FROM boonz_products WHERE product_id = p_boonz_product_id), p_reason),
       NULL);

    IF v_largest_drawn.dispatch_id IS NULL THEN v_largest_drawn := v_sibling; END IF;
    v_remaining := v_remaining - v_take;
    v_draws_made := v_draws_made + 1;
  END LOOP;

  IF v_remaining > 0 THEN
    RAISE EXCEPTION 'insert_driver_remove_line: could only draw % of the requested % units from sibling lines, resolve manually',
      (p_quantity - v_remaining), p_quantity;
  END IF;

  INSERT INTO refill_dispatching
    (machine_id, boonz_product_id, pod_product_id, shelf_id,
     dispatch_date, action, quantity, filled_quantity, expiry_date,
     packed, picked_up, dispatched, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, is_internal_move, from_warehouse_id, source_warehouse_id)
  VALUES
    (p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
     p_dispatch_date, 'Remove', p_quantity, 0, p_expiry_date,
     true, true, false, false, false, true,
     format('[DRIVER-INSERT] %s', p_reason),
     CASE WHEN COALESCE(v_largest_drawn.source_kind, 'unknown') = 'wh'
               AND COALESCE(v_largest_drawn.source_warehouse_id, v_largest_drawn.from_warehouse_id) IS NULL
          THEN 'unknown' ELSE COALESCE(v_largest_drawn.source_kind, 'unknown') END,
     v_largest_drawn.source_machine_id,
     COALESCE(v_largest_drawn.is_m2m, false), COALESCE(v_largest_drawn.is_internal_move, false),
     v_largest_drawn.from_warehouse_id,
     CASE WHEN COALESCE(v_largest_drawn.source_kind, 'unknown') = 'wh'
          THEN COALESCE(v_largest_drawn.source_warehouse_id, v_largest_drawn.from_warehouse_id) ELSE NULL END)
  RETURNING dispatch_id INTO v_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', v_dispatch_id,
    'machine_id', p_machine_id, 'qty', p_quantity, 'reason', p_reason,
    'drawn_from_siblings', v_draws_made, 'inherited_from', v_largest_drawn.dispatch_id);
END $function$;
