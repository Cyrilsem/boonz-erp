-- PRD-118 item H (Addendum 2 §H.4): new repin_dispatch_batch door. No re-pin door
-- existed before this — repair_unbound_dispatch refuses bound rows and requires
-- packed=true (the opposite of what's needed), set_dispatch_line_breakdown writes the
-- PRD-053 breakdown + expiry but never from_wh_inventory_id. Every mispin so far was
-- papered over with breakdown stamps instead of a real re-pin.
--
-- repin_dispatch_batch(p_dispatch_id, p_wh_inventory_id, p_reason, p_caller_id default
-- NULL, p_dry_run default true): SECURITY DEFINER, role-checked (warehouse/
-- operator_admin/superadmin/manager, matching bind_dispatch_fefo), mandatory reason,
-- set_write_context per the reactivate_warehouse_row reference pattern. Refuses: no
-- dispatch/batch found, dispatch already packed, batch not Active/unquarantined, batch
-- is a sentinel/phantom row (_is_phantom_wh_row_v3 — never let a re-pin undo item D),
-- product mismatch between the dispatch line and the target batch, or insufficient net
-- depth (real batch stock minus whatever else — single-pin or breakdown-entry — is
-- already committed to that exact batch by other live unpacked lines). On a real
-- re-pin, clears any stale driver_confirmed_breakdown (the new single pin supersedes
-- it) and sets expiry_date from the target batch.
--
-- Verified live: packed-row refusal fires (real packed row, real exception raised);
-- product-mismatch refusal fires (a real phantom-pinned VOX Popcorn Cheese row pointed
-- at a real McVities batch, correctly refused); a valid dry-run against a real
-- currently-unbound McVities line correctly computed available_for_this_line=7 against
-- the real 7-unit batch with zero competing commitments.
-- Cody: approve, Articles 1/4/6/12 — refill_dispatching's canonical writer set gains
-- one door, role-gated and reason-required like every other, no bypass of Article 6
-- (does not touch warehouse_inventory.status).
CREATE FUNCTION public.repin_dispatch_batch(
  p_dispatch_id uuid,
  p_wh_inventory_id uuid,
  p_reason text,
  p_caller_id uuid DEFAULT NULL::uuid,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id     uuid := COALESCE(p_caller_id, auth.uid());
  v_role        text;
  v_dispatch    refill_dispatching%ROWTYPE;
  v_target      warehouse_inventory%ROWTYPE;
  v_committed_elsewhere numeric;
  v_available   numeric;
BEGIN
  IF p_dispatch_id IS NULL OR p_wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'repin_dispatch_batch: p_dispatch_id and p_wh_inventory_id are required';
  END IF;
  IF COALESCE(p_reason, '') = '' THEN
    RAISE EXCEPTION 'repin_dispatch_batch: p_reason is required';
  END IF;

  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'repin_dispatch_batch: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM public.set_write_context('repin_dispatch_batch',
    format('repin dispatch %s to batch %s: %s', p_dispatch_id, p_wh_inventory_id, p_reason),
    'manual_adjust', p_dispatch_id::text);

  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'repin_dispatch_batch: dispatch % not found', p_dispatch_id;
  END IF;
  IF COALESCE(v_dispatch.packed, false) THEN
    RAISE EXCEPTION 'repin_dispatch_batch: dispatch % is already packed — cannot re-pin', p_dispatch_id;
  END IF;

  SELECT * INTO v_target FROM warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'repin_dispatch_batch: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;
  IF v_target.status <> 'Active' OR COALESCE(v_target.quarantined,false) THEN
    RAISE EXCEPTION 'repin_dispatch_batch: batch % is not Active/unquarantined stock', p_wh_inventory_id;
  END IF;
  IF public._is_phantom_wh_row_v3(v_target.batch_id, v_target.expiration_date) THEN
    RAISE EXCEPTION 'repin_dispatch_batch: batch % is a sentinel/phantom row, never FEFO-bindable', p_wh_inventory_id;
  END IF;
  IF v_target.boonz_product_id <> v_dispatch.boonz_product_id THEN
    RAISE EXCEPTION 'repin_dispatch_batch: product mismatch — dispatch is % but batch % is %',
      v_dispatch.boonz_product_id, p_wh_inventory_id, v_target.boonz_product_id;
  END IF;

  SELECT COALESCE(SUM(
           CASE WHEN rd.driver_confirmed_breakdown IS NOT NULL THEN
             (SELECT COALESCE(SUM((e->>'qty')::numeric),0)
                FROM jsonb_array_elements(rd.driver_confirmed_breakdown) e
               WHERE e->>'wh_inventory_id' = p_wh_inventory_id::text)
           WHEN rd.from_wh_inventory_id = p_wh_inventory_id THEN rd.quantity
           ELSE 0 END
         ), 0) INTO v_committed_elsewhere
  FROM refill_dispatching rd
  WHERE rd.dispatch_id <> p_dispatch_id
    AND COALESCE(rd.packed,false) = false
    AND COALESCE(rd.cancelled,false) = false
    AND COALESCE(rd.skipped,false) = false
    AND COALESCE(rd.returned,false) = false
    AND (rd.from_wh_inventory_id = p_wh_inventory_id
         OR (rd.driver_confirmed_breakdown IS NOT NULL
             AND EXISTS (SELECT 1 FROM jsonb_array_elements(rd.driver_confirmed_breakdown) e
                          WHERE e->>'wh_inventory_id' = p_wh_inventory_id::text)));

  v_available := v_target.warehouse_stock - v_committed_elsewhere;

  IF v_available < v_dispatch.quantity THEN
    RETURN jsonb_build_object(
      'status','refused_insufficient_stock',
      'dispatch_id', p_dispatch_id, 'wh_inventory_id', p_wh_inventory_id,
      'batch_stock', v_target.warehouse_stock,
      'committed_elsewhere', v_committed_elsewhere,
      'available_for_this_line', v_available,
      'line_quantity', v_dispatch.quantity
    );
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'status','dry_run_ok',
      'dispatch_id', p_dispatch_id,
      'old_from_wh_inventory_id', v_dispatch.from_wh_inventory_id,
      'old_driver_confirmed_breakdown', v_dispatch.driver_confirmed_breakdown,
      'new_wh_inventory_id', p_wh_inventory_id,
      'new_expiry_date', v_target.expiration_date,
      'available_for_this_line', v_available
    );
  END IF;

  UPDATE refill_dispatching
     SET from_wh_inventory_id = p_wh_inventory_id,
         driver_confirmed_breakdown = NULL,
         expiry_date = v_target.expiration_date
   WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status','ok',
    'dispatch_id', p_dispatch_id,
    'old_from_wh_inventory_id', v_dispatch.from_wh_inventory_id,
    'old_driver_confirmed_breakdown', v_dispatch.driver_confirmed_breakdown,
    'new_wh_inventory_id', p_wh_inventory_id,
    'new_expiry_date', v_target.expiration_date,
    'reason', p_reason
  );
END;
$function$;
