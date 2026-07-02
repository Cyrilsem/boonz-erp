-- PRD-071 WS-C3: approve_m2m_transfer v2 - normalize returned/date at approval.
--
-- Convert-path anomaly (PRD-052 convert_removes_to_m2m_transfer): dest legs can be
-- created returned=true and/or past-dated, which blocks the pick list. CS decision
-- (2026-07-02): fix at the APPROVE path - guard, not rewrite; convert stays untouched.
-- v1 already cleared returned on dest legs inside the receive loop; v2 adds an
-- explicit, counted normalize pass (returned=false on not-yet-received dest legs)
-- BEFORE receiving, so the transfer is consistent even if a leg loop exits early.
-- dispatch_date is intentionally NOT normalized: protect_packed_dispatch_row
-- (PRD-028-era immutability, no GUC bypass) hard-blocks date changes on packed
-- rows, and the historical date is the truthful physical-transfer date; once
-- approved the legs are received (item_added) and leave the pick list anyway.
--
-- Constitution: Articles 1, 3, 4, 6 (WH conservation self-assert kept), 8, 12
-- (idempotent: normalize is a no-op on clean transfers; re-approve returns
-- already_done). Amendment 003. Dara-designed, Cody-reviewed (PRD-071 log).
-- Forward-only. engine_add_pod / engine_swap_pod untouched. swaps_enabled untouched.

CREATE OR REPLACE FUNCTION public.approve_m2m_transfer(p_transfer_id uuid, p_caller_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_wh_before numeric; v_wh_after numeric;
  v_src_qty numeric; v_dst_qty numeric;
  v_dest_done int := 0; v_src_done int := 0;
  v_normalized int := 0;
  r record;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'approve_m2m_transfer: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM 1 FROM public.refill_dispatching WHERE m2m_transfer_id = p_transfer_id AND is_m2m FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approve_m2m_transfer: no is_m2m legs for transfer %', p_transfer_id;
  END IF;

  SELECT COALESCE(SUM(quantity) FILTER (WHERE action = 'Remove'),0),
         COALESCE(SUM(quantity) FILTER (WHERE action IN ('Refill','Add','Add New')),0)
    INTO v_src_qty, v_dst_qty
  FROM public.refill_dispatching WHERE m2m_transfer_id = p_transfer_id AND is_m2m;
  IF v_src_qty <> v_dst_qty THEN
    RAISE EXCEPTION 'approve_m2m_transfer: pair qty mismatch (source=% dest=%) for transfer %', v_src_qty, v_dst_qty, p_transfer_id;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.refill_dispatching
                 WHERE m2m_transfer_id = p_transfer_id AND is_m2m
                   AND COALESCE(item_added,false) = false) THEN
    RETURN jsonb_build_object('status','already_done','transfer_id',p_transfer_id,'note','all legs already received');
  END IF;

  SELECT COALESCE(SUM(warehouse_stock),0) INTO v_wh_before FROM public.warehouse_inventory;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','approve_m2m_transfer', true);
  PERFORM set_config('app.via_trigger','true', true);
  PERFORM set_config('app.mutation_reason', format('M2M approve transfer=%s by=%s (no WH credit)', p_transfer_id, v_user_id), true);

  -- PRD-071 WS-C3: normalize stale convert-created legs at approval (guard, not
  -- rewrite; convert untouched). returned=true dest legs block the pick list;
  -- approve is the choke point. dispatch_date stays historical (packed-row
  -- immutability + truthful physical date).
  UPDATE public.refill_dispatching
     SET returned = false
   WHERE m2m_transfer_id = p_transfer_id AND is_m2m
     AND action IN ('Refill','Add','Add New')
     AND COALESCE(item_added,false) = false
     AND returned;
  GET DIAGNOSTICS v_normalized = ROW_COUNT;

  FOR r IN SELECT dispatch_id, quantity FROM public.refill_dispatching
           WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action = 'Remove'
             AND COALESCE(item_added,false) = false
  LOOP
    PERFORM public.receive_dispatch_line(r.dispatch_id, r.quantity, v_user_id, NULL);
    v_src_done := v_src_done + 1;
  END LOOP;

  FOR r IN SELECT dispatch_id, quantity, m2m_partner_id FROM public.refill_dispatching
           WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action IN ('Refill','Add','Add New')
             AND COALESCE(item_added,false) = false
  LOOP
    UPDATE public.refill_dispatching d
       SET expiry_date = COALESCE(d.expiry_date, s.expiry_date),
           returned = false
      FROM public.refill_dispatching s
     WHERE d.dispatch_id = r.dispatch_id AND s.dispatch_id = r.m2m_partner_id;
    PERFORM public.receive_dispatch_line(r.dispatch_id, r.quantity, v_user_id, NULL);
    v_dest_done := v_dest_done + 1;
  END LOOP;

  UPDATE public.refill_dispatching
     SET wh_approved_at = COALESCE(wh_approved_at, now()), wh_approved_by = COALESCE(wh_approved_by, v_user_id),
         m2m_approved_at = COALESCE(m2m_approved_at, now())
   WHERE m2m_transfer_id = p_transfer_id AND is_m2m;

  SELECT COALESCE(SUM(warehouse_stock),0) INTO v_wh_after FROM public.warehouse_inventory;
  IF v_wh_after <> v_wh_before THEN
    RAISE EXCEPTION 'approve_m2m_transfer: WH CONSERVATION VIOLATED (before=% after=%) - M2M must never credit warehouse', v_wh_before, v_wh_after;
  END IF;

  RETURN jsonb_build_object('status','approved','transfer_id',p_transfer_id,
                            'source_legs_received',v_src_done,'dest_legs_received',v_dest_done,
                            'legs_normalized', v_normalized,
                            'wh_delta', v_wh_after - v_wh_before, 'pair_qty', v_src_qty,
                            'rpc_version','v2_prd071_wsc3_normalize_on_approve');
END;
$function$;

COMMENT ON FUNCTION public.approve_m2m_transfer(uuid, uuid) IS
'v2_prd071_wsc3_normalize_on_approve (PRD-071 WS-C3). Canonical atomic+idempotent M2M approve: normalizes stale convert-created legs (returned=true dest legs) before receiving both legs with ZERO warehouse credit; WH conservation self-asserted. Roles: warehouse/operator_admin/superadmin/manager. Articles 1,3,4,6,8,12; Amendment 003.';
