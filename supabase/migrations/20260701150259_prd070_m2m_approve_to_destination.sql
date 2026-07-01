-- PRD-070: M2M transfer approval routes stock to the DESTINATION machine pod (same qty + expiry),
-- ZERO warehouse credit, appears in dispatch. APPLIED 2026-07-01 on CS sign-off (schema_migrations
-- version 20260701150259). Dara-designed, Cody approved (Articles 1,3,4,6,12,14). Idempotent. Forward-only.
-- Sibling: prd070_m2m_guard_multivariant (v20260701150432). Dry-run proved WH delta=0, dest pod +11.
--
-- ROOT CAUSE (verified live 2026-07-01): receive_dispatch_line is already WH-neutral for is_m2m rows
-- (Remove->remove_m2m_no_wh_credit, Refill/Add->add_m2m_no_wh_draw). The break is (1) no canonical M2M
-- approve entry point; (2) the WH-return approve path (wh_approve_remove_receipt) does not refuse is_m2m;
-- (3) dest legs created with NULL expiry + dispatched=true so they never surface. This migration adds the
-- canonical approve_m2m_transfer + a hard reject guard + an idempotency stamp. Two companion changes are
-- FLAGGED as scoped follow-ups (NOT folded blind this run): the push/stitch-bridge M2M stamping and the
-- dest-leg dispatch-list visibility (dispatched=false at creation) - see NOTES at end.

-- 1. Idempotency + audit stamp (additive) + approve lookup index -----------------------------------
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS m2m_approved_at timestamptz;
COMMENT ON COLUMN public.refill_dispatching.m2m_approved_at IS
  'PRD-070: when approve_m2m_transfer applied this leg (distinct from wh_approved_at). Idempotency marker.';

CREATE INDEX IF NOT EXISTS idx_rd_m2m_transfer
  ON public.refill_dispatching (m2m_transfer_id) WHERE is_m2m = true;

-- 2. approve_m2m_transfer: the ONE canonical M2M approve. Atomic, idempotent, WH-neutral. -----------
CREATE OR REPLACE FUNCTION public.approve_m2m_transfer(
  p_transfer_id uuid,
  p_caller_id   uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_wh_before numeric; v_wh_after numeric;
  v_src_qty numeric; v_dst_qty numeric;
  v_dest_done int := 0; v_src_done int := 0; v_skipped int := 0;
  r record;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'approve_m2m_transfer: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  -- lock the transfer's legs
  PERFORM 1 FROM public.refill_dispatching WHERE m2m_transfer_id = p_transfer_id AND is_m2m FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approve_m2m_transfer: no is_m2m legs for transfer %', p_transfer_id;
  END IF;

  -- validate pair qty-match (planned quantity, source Remove == dest Refill/Add)
  SELECT COALESCE(SUM(quantity) FILTER (WHERE action = 'Remove'),0),
         COALESCE(SUM(quantity) FILTER (WHERE action IN ('Refill','Add','Add New')),0)
    INTO v_src_qty, v_dst_qty
  FROM public.refill_dispatching WHERE m2m_transfer_id = p_transfer_id AND is_m2m;
  IF v_src_qty <> v_dst_qty THEN
    RAISE EXCEPTION 'approve_m2m_transfer: pair qty mismatch (source=% dest=%) for transfer %', v_src_qty, v_dst_qty, p_transfer_id;
  END IF;

  -- idempotency: fully applied already?
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

  -- SOURCE legs out (archive source pod, no WH). Skip already-received.
  FOR r IN SELECT dispatch_id, quantity FROM public.refill_dispatching
           WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action = 'Remove'
             AND COALESCE(item_added,false) = false
  LOOP
    PERFORM public.receive_dispatch_line(r.dispatch_id, r.quantity, v_user_id, NULL);
    v_src_done := v_src_done + 1;
  END LOOP;

  -- DEST legs in (write dest pod at SAME qty + SAME expiry carried from the paired source, no WH).
  FOR r IN SELECT dispatch_id, quantity, m2m_partner_id FROM public.refill_dispatching
           WHERE m2m_transfer_id = p_transfer_id AND is_m2m AND action IN ('Refill','Add','Add New')
             AND COALESCE(item_added,false) = false
  LOOP
    -- carry expiry from the paired source leg; clear the anomalous returned flag on an addition leg
    UPDATE public.refill_dispatching d
       SET expiry_date = COALESCE(d.expiry_date, s.expiry_date),
           returned = false
      FROM public.refill_dispatching s
     WHERE d.dispatch_id = r.dispatch_id AND s.dispatch_id = r.m2m_partner_id;
    PERFORM public.receive_dispatch_line(r.dispatch_id, r.quantity, v_user_id, NULL);
    v_dest_done := v_dest_done + 1;
  END LOOP;

  -- stamp approval on every leg of the transfer
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
                            'wh_delta', v_wh_after - v_wh_before, 'pair_qty', v_src_qty);
END;
$$;

REVOKE ALL ON FUNCTION public.approve_m2m_transfer(uuid,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_m2m_transfer(uuid,uuid) TO authenticated, service_role;

-- 3. HARD GUARD: wh_approve_remove_receipt REJECTS is_m2m rows (points to approve_m2m_transfer).
--    Faithful CREATE OR REPLACE of the live body with the guard added after the action=Remove check.
CREATE OR REPLACE FUNCTION public.wh_approve_remove_receipt(p_dispatch_id uuid, p_actual_qty numeric DEFAULT NULL::numeric, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_approved_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'WH manager verified physical receipt'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_final_qty numeric;
  v_final_breakdown jsonb;
  v_receive_result jsonb;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.action <> 'Remove' THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt only for action=Remove (got %)', v_dispatch.action;
  END IF;
  -- PRD-070 hard guard: an M2M transfer leg must NEVER go through the warehouse-return path.
  IF COALESCE(v_dispatch.is_m2m, false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt: dispatch % is an M2M transfer leg - approve via approve_m2m_transfer(%) (no warehouse credit; stock moves to the destination machine).',
      p_dispatch_id, COALESCE(v_dispatch.m2m_transfer_id::text, 'NULL m2m_transfer_id - needs pairing backfill first');
  END IF;
  IF v_dispatch.item_added THEN
    RAISE EXCEPTION 'Dispatch % already approved (item_added=true at %)',
      p_dispatch_id, v_dispatch.wh_approved_at;
  END IF;
  IF v_dispatch.returned THEN
    RAISE EXCEPTION 'Dispatch already marked returned';
  END IF;

  v_final_qty := COALESCE(p_actual_qty, v_dispatch.driver_confirmed_qty);
  v_final_breakdown := COALESCE(p_batch_breakdown, v_dispatch.driver_confirmed_breakdown);
  IF v_final_qty IS NULL THEN
    RAISE EXCEPTION 'No qty available - driver did not confirm and p_actual_qty was NULL. Use approve_stuck_remove for orphans.';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'wh_approve_remove_receipt', true);
  PERFORM set_config('app.mutation_reason',
    format('wh_approve_remove_receipt by %s: %s units verified (driver said %s, WH says %s) - %s',
      COALESCE(p_approved_by::text, 'wh_manager'),
      v_final_qty,
      COALESCE(v_dispatch.driver_confirmed_qty::text, 'none'),
      v_final_qty,
      p_reason), true);

  UPDATE refill_dispatching SET
    wh_approved_at = now(),
    wh_approved_by = p_approved_by
  WHERE dispatch_id = p_dispatch_id;

  v_receive_result := receive_dispatch_line(p_dispatch_id, v_final_qty, p_approved_by, v_final_breakdown);

  RETURN jsonb_build_object(
    'status', 'wh_approved',
    'dispatch_id', p_dispatch_id,
    'driver_said_qty', v_dispatch.driver_confirmed_qty,
    'wh_verified_qty', v_final_qty,
    'discrepancy', v_final_qty - COALESCE(v_dispatch.driver_confirmed_qty, v_final_qty),
    'approved_by', p_approved_by,
    'reason', p_reason,
    'receive_result', v_receive_result
  );
END;
$function$;

-- NOTES / FLAGGED COMPANION CHANGES (NOT in this file - scoped follow-ups per Dara D-2/D-3):
--  A. wh_approve_remove_receipt_multivariant (6.3KB): add the identical is_m2m reject guard at its top.
--     Held out of this file to avoid a blind fold of a large writer; ship as a one-line-guard sibling.
--  B. Push/stitch bridge M2M stamping (D-2): when a source_origin='internal_transfer' plan row becomes
--     dispatch legs, stamp is_m2m=true + one shared m2m_transfer_id + source_machine_id/m2m_partner_id on
--     BOTH legs. convert_removes_to_m2m_transfer already does this; mark_internal_transfer is plan-level,
--     so the durable stamp belongs in the push bridge - author against its live body separately.
--  C. Dispatch visibility (D-3): dest M2M leg should be created dispatched=false (convert currently sets
--     true) so it surfaces in v_dispatch_pick_list until received; approve_m2m_transfer's receive sets
--     item_added=true to drop it out. Verify no ripple into other dispatch consumers before applying.
--  D. receive_dispatch_line (15.5KB): already WH-neutral for is_m2m (verified branch trace); NOT rewritten
--     here (redundant guard not worth a 15.5KB blind rewrite). approve_m2m_transfer asserts wh_delta=0.
--  E. Gen-1 orphans: 8 legacy is_m2m Refill legs with m2m_transfer_id=NULL are already item_added=true
--     with no source pairing -> OUT OF SCOPE, skip+log, do NOT fabricate a transfer id.
--
-- DOWN:
--  DROP FUNCTION IF EXISTS public.approve_m2m_transfer(uuid,uuid);
--  -- restore wh_approve_remove_receipt to its pre-PRD-070 body (remove the is_m2m guard block);
--  DROP INDEX IF EXISTS public.idx_rd_m2m_transfer;
--  ALTER TABLE public.refill_dispatching DROP COLUMN IF EXISTS m2m_approved_at;
