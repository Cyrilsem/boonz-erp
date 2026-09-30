-- PRD-137 F7, drafted 2026-09-30 daytime, NOT YET APPLIED. New RPC confirm_m2m_delivery: driver
-- sets the ACTUAL qty delivered per M2M leg (source removed, dest received), instead of the
-- system assuming the planned qty always arrived intact.
--
-- Investigation finding (this run, daytime): receive_dispatch_line already has everything needed
-- except the shortfall-to-WH-return step. Confirmed by reading its body: for an M2M leg
-- (is_m2m=true) it still runs the FULL pod_inventory update (increments the dest shelf's
-- current_stock on the Add New leg, deactivates the source shelf's row on the Remove leg) --
-- it only skips warehouse_inventory credit/debit, which is correct because M2M by definition
-- never touches the warehouse. So calling receive_dispatch_line on BOTH legs with their real
-- actual quantities already correctly updates pod_inventory at both ends. The one thing neither
-- leg's call can do on its own is notice a MISMATCH between the two real quantities (fewer units
-- arrived than left) and do something about it -- that is this RPC's whole job.
--
-- Design: reject dest_actual > source_actual outright (physically impossible -- you cannot
-- receive more than what left). For dest_actual < source_actual, credit warehouse_inventory for
-- exactly the shortfall as a disclosed direct write (real product went missing between two
-- machines -- it isn't sellable at either shelf, so it becomes a WH-visible discrepancy, not
-- silently lost inventory). Open design call, not resolved by the spec text itself (the spec says
-- "WH return line", not "writeoff"): attribute the shortfall credit to the SOURCE machine's
-- primary warehouse, since that is the warehouse a physical audit would actually check against.
--
-- FE: zero existing UI (the pickup page shows M2M qty as static read-only text) -- net-new driver
-- flow, held for a follow-up per the same reasoning as A8/F5's held items.
--
-- Rollback: supabase/rollback/20260930181231_prd137_f7_confirm_m2m_delivery_rollback.sql (DROP FUNCTION,
-- this is a net-new function with nothing to restore).
CREATE OR REPLACE FUNCTION public.confirm_m2m_delivery(
  p_transfer_id uuid,
  p_source_actual_qty numeric,
  p_dest_actual_qty numeric,
  p_caller_id uuid DEFAULT NULL::uuid,
  p_reason text DEFAULT NULL::text
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id       uuid := COALESCE(p_caller_id, auth.uid());
  v_role          text;
  v_source_leg    refill_dispatching%ROWTYPE;
  v_dest_leg      refill_dispatching%ROWTYPE;
  v_shortfall     numeric;
  v_target_wh     uuid;
  v_wh_row        warehouse_inventory%ROWTYPE;
  v_receive_source jsonb;
  v_receive_dest   jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'confirm_m2m_delivery', true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_user_id IS NOT NULL AND v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: confirm_m2m_delivery requires field_staff / warehouse / operator_admin / superadmin / manager';
  END IF;

  IF p_transfer_id IS NULL THEN
    RAISE EXCEPTION 'confirm_m2m_delivery: p_transfer_id is required';
  END IF;
  IF p_source_actual_qty IS NULL OR p_source_actual_qty < 0 OR p_dest_actual_qty IS NULL OR p_dest_actual_qty < 0 THEN
    RAISE EXCEPTION 'confirm_m2m_delivery: p_source_actual_qty and p_dest_actual_qty must both be >= 0';
  END IF;
  IF p_dest_actual_qty > p_source_actual_qty THEN
    RAISE EXCEPTION 'confirm_m2m_delivery: p_dest_actual_qty (%) cannot exceed p_source_actual_qty (%) -- more units cannot arrive than left the source',
      p_dest_actual_qty, p_source_actual_qty;
  END IF;

  SELECT * INTO v_source_leg FROM public.refill_dispatching
   WHERE m2m_transfer_id = p_transfer_id AND action = 'Remove' AND COALESCE(is_m2m, false) = true
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'confirm_m2m_delivery: no Remove leg found for m2m_transfer_id %', p_transfer_id;
  END IF;

  SELECT * INTO v_dest_leg FROM public.refill_dispatching
   WHERE m2m_transfer_id = p_transfer_id AND action IN ('Add New','Add','Refill') AND COALESCE(is_m2m, false) = true
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'confirm_m2m_delivery: no Add-side leg found for m2m_transfer_id %', p_transfer_id;
  END IF;

  IF v_source_leg.item_added THEN
    RAISE EXCEPTION 'confirm_m2m_delivery: source leg % already received', v_source_leg.dispatch_id;
  END IF;
  IF v_dest_leg.item_added THEN
    RAISE EXCEPTION 'confirm_m2m_delivery: dest leg % already received', v_dest_leg.dispatch_id;
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('confirm_m2m_delivery transfer=%s source_actual=%s dest_actual=%s by=%s: %s',
      p_transfer_id, p_source_actual_qty, p_dest_actual_qty, COALESCE(v_user_id::text,'system'), p_reason), true);

  -- Both legs are is_m2m=true, so receive_dispatch_line's WH credit/debit branches are already
  -- skipped for each -- only pod_inventory moves (source deactivated, dest incremented), which is
  -- exactly right: M2M never touches the warehouse on its own.
  v_receive_source := public.receive_dispatch_line(v_source_leg.dispatch_id, p_source_actual_qty, v_user_id);
  v_receive_dest := public.receive_dispatch_line(v_dest_leg.dispatch_id, p_dest_actual_qty, v_user_id);

  v_shortfall := p_source_actual_qty - p_dest_actual_qty;
  IF v_shortfall > 0 THEN
    v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_source_leg.machine_id);
    IF v_target_wh IS NULL THEN
      RAISE EXCEPTION 'confirm_m2m_delivery: source machine % has no primary_warehouse_id, cannot credit the % unit shortfall',
        v_source_leg.machine_id, v_shortfall;
    END IF;

    PERFORM set_config('app.provenance_reason', 'm2m_return', true);
    SELECT * INTO v_wh_row FROM public.warehouse_inventory
     WHERE boonz_product_id = v_source_leg.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active'
       AND ((expiration_date = v_source_leg.expiry_date) OR (expiration_date IS NULL AND v_source_leg.expiry_date IS NULL))
     ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
    IF FOUND THEN
      UPDATE public.warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_shortfall
       WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
    ELSE
      -- warehouse_inventory.batch_id has its own vocabulary CHECK constraint
      -- (enforce_warehouse_batch_id_vocabulary) -- TRANSFER- is the allowed prefix for this.
      INSERT INTO public.warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id)
      VALUES (v_source_leg.boonz_product_id, v_shortfall, v_source_leg.expiry_date, 'Active',
        format('TRANSFER-SHORTFALL-%s', v_source_leg.dispatch_date), CURRENT_DATE, v_target_wh);
    END IF;
    PERFORM set_config('app.provenance_reason', 'm2m_return', true);

    INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason, dispatch_id)
    VALUES (v_user_id, 'm2m', v_source_leg.machine_id, v_source_leg.shelf_id, v_source_leg.boonz_product_id, v_source_leg.expiry_date,
      v_shortfall, 'restocked', COALESCE(p_reason, format('M2M shortfall: %s left %s, only %s arrived at destination', p_source_actual_qty, v_source_leg.machine_id, p_dest_actual_qty)),
      v_source_leg.dispatch_id);
  END IF;

  RETURN jsonb_build_object(
    'status', 'ok', 'transfer_id', p_transfer_id,
    'source_dispatch_id', v_source_leg.dispatch_id, 'dest_dispatch_id', v_dest_leg.dispatch_id,
    'source_actual_qty', p_source_actual_qty, 'dest_actual_qty', p_dest_actual_qty,
    'shortfall', v_shortfall, 'shortfall_credited_to_warehouse_id', CASE WHEN v_shortfall > 0 THEN v_target_wh ELSE NULL END,
    'receive_source', v_receive_source, 'receive_dest', v_receive_dest
  );
END;
$function$;
