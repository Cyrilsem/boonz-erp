-- PRD-129R step 02: credit_dispatch_remainder inserted its own inventory_audit_log row after
-- crediting warehouse_stock, while auto_audit_warehouse_inventory() (the AFTER UPDATE trigger on
-- warehouse_inventory) already logs the same UPDATE via app.mutation_reason, which this function
-- sets ("A3 remainder credit dispatch=... remainder=... by=...") before running its own UPDATE.
-- Every remainder credit was writing two inventory_audit_log rows for one stock change.
--
-- Fix: remove the explicit INSERT. The trigger-driven log is kept as-is; nothing about it
-- changes. One row per credit going forward.

CREATE OR REPLACE FUNCTION public.credit_dispatch_remainder(p_dispatch_id uuid, p_caller_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id   uuid := COALESCE(p_caller_id, auth.uid());
  v_d         public.refill_dispatching%ROWTYPE;
  v_remainder numeric;
  v_wh        public.warehouse_inventory%ROWTYPE;
  v_unreserve numeric;
  v_old       numeric;
BEGIN
  SELECT * INTO v_d FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'credit_dispatch_remainder: dispatch % not found', p_dispatch_id;
  END IF;

  IF COALESCE(v_d.remainder_credited,false) THEN
    RETURN jsonb_build_object('status','already_done','dispatch_id',p_dispatch_id,'note','remainder already credited');
  END IF;
  IF COALESCE(v_d.returned,false) THEN
    RETURN jsonb_build_object('status','already_done','dispatch_id',p_dispatch_id,'note','line already returned (whole-line)');
  END IF;
  IF COALESCE(v_d.is_m2m,false) THEN
    RETURN jsonb_build_object('status','skipped','dispatch_id',p_dispatch_id,'note','M2M transfer out of scope (PRD-065)');
  END IF;
  IF v_d.action = 'Remove' THEN
    RETURN jsonb_build_object('status','skipped','dispatch_id',p_dispatch_id,'note','Remove line has no fill remainder');
  END IF;
  IF NOT COALESCE(v_d.item_added,false) THEN
    RETURN jsonb_build_object('status','skipped','dispatch_id',p_dispatch_id,'note','not yet received/closed; nothing to reconcile');
  END IF;

  v_remainder := COALESCE(v_d.quantity,0) - COALESCE(v_d.filled_quantity,0);
  IF v_remainder <= 0 THEN
    UPDATE public.refill_dispatching SET remainder_credited = true WHERE dispatch_id = p_dispatch_id;
    RETURN jsonb_build_object('status','already_done','dispatch_id',p_dispatch_id,'remainder',0,'note','fully filled; no remainder');
  END IF;

  IF v_d.from_wh_inventory_id IS NULL THEN
    RETURN jsonb_build_object('status','unpinned_skip','dispatch_id',p_dispatch_id,'remainder',v_remainder,
                              'note','no from_wh_inventory_id pin; credit manually via adjust/return');
  END IF;

  SELECT * INTO v_wh FROM public.warehouse_inventory WHERE wh_inventory_id = v_d.from_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','unpinned_skip','dispatch_id',p_dispatch_id,'remainder',v_remainder,
                              'note','pinned wh row missing');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'credit_dispatch_remainder', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_partial_remainder', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  PERFORM set_config('app.mutation_reason',
    format('A3 remainder credit dispatch=%s remainder=%s by=%s', p_dispatch_id, v_remainder, v_user_id), true);

  v_old := COALESCE(v_wh.warehouse_stock,0);
  v_unreserve := LEAST(COALESCE(v_wh.consumer_stock,0), v_remainder);
  UPDATE public.warehouse_inventory
  SET warehouse_stock = COALESCE(warehouse_stock,0) + v_remainder,
      consumer_stock  = GREATEST(0, COALESCE(consumer_stock,0) - v_unreserve)
  WHERE wh_inventory_id = v_wh.wh_inventory_id;

  UPDATE public.refill_dispatching SET remainder_credited = true WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('status','credited','dispatch_id',p_dispatch_id,'remainder',v_remainder,
                            'wh_inventory_id',v_wh.wh_inventory_id,'unreserved',v_unreserve);
END;
$function$;
