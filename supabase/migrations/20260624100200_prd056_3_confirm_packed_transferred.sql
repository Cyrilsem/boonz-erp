-- PRD-056 Phase 2b - confirm_packed_transferred: the transfer-confirm writer.
-- A transfer leg (is_m2m) is confirmed with the ONLY legal outcome for that row: packed_transferred.
-- The writer resolves the M2M pair (source Remove leg + dest Add leg, linked by m2m_partner_id /
-- m2m_transfer_id from convert_removes_to_m2m_transfer) and routes BOTH legs through the single
-- canonical pod_inventory writer receive_dispatch_line (Article 1):
--   - DEST (Add* leg): lands the unit in the destination machine's pod_inventory; WH-neutral via the
--     is_m2m add-skip (PRD-056 Phase 2a). p_batch_breakdown is forwarded for forward-compat.
--   - SOURCE (Remove leg): archives the source machine's pod_inventory via the is_m2m remove-skip; no
--     WH credit, so the transfer never double-counts.
-- Then stamps pack_outcome='packed_transferred' on both legs. Idempotent (second call is a no-op).
-- DEFINER; sets app.via_rpc + app.rpc_name (audit via the generic trigger, Article 8); validates caller
-- role; NEVER writes warehouse_inventory.status (Article 6). Forward-only. Replay-proven before apply.

CREATE OR REPLACE FUNCTION public.confirm_packed_transferred(
  p_dispatch_id uuid,
  p_confirmed_by uuid DEFAULT NULL::uuid,
  p_batch_breakdown jsonb DEFAULT NULL::jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row  refill_dispatching%ROWTYPE;
  v_src  refill_dispatching%ROWTYPE;
  v_dest refill_dispatching%ROWTYPE;
  v_src_res jsonb := NULL; v_dest_res jsonb := NULL;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','confirm_packed_transferred',true);

  IF v_uid IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
     WHERE id = v_uid AND role = ANY(ARRAY['field_staff','warehouse','operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'Unauthorized: confirm_packed_transferred requires field_staff/warehouse/operator role';
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;

  -- Transfer-leg gate: packed_transferred is ONLY valid for an M2M leg. Skip / Not Filled are rejected
  -- here by construction (this RPC is the only writer of packed_transferred; the FE renders no other
  -- action for transfer rows).
  IF COALESCE(v_row.is_m2m, false) <> true THEN
    RAISE EXCEPTION 'Dispatch % is not a transfer leg (is_m2m=false); packed_transferred is only valid for M2M legs', p_dispatch_id;
  END IF;

  -- Resolve the pair: source = the Remove leg, dest = the Add* leg.
  IF v_row.action = 'Remove' THEN
    v_src := v_row;
    SELECT * INTO v_dest FROM public.refill_dispatching WHERE dispatch_id = v_row.m2m_partner_id FOR UPDATE;
  ELSE
    v_dest := v_row;
    SELECT * INTO v_src  FROM public.refill_dispatching WHERE dispatch_id = v_row.m2m_partner_id FOR UPDATE;
  END IF;
  IF v_dest.dispatch_id IS NULL OR v_src.dispatch_id IS NULL THEN
    RAISE EXCEPTION 'Incomplete M2M pairing for dispatch % (transfer_id %, partner %)',
                    p_dispatch_id, v_row.m2m_transfer_id, v_row.m2m_partner_id;
  END IF;

  -- Idempotency: already transferred -> no-op.
  IF COALESCE(v_dest.item_added,false) = true
     AND COALESCE(v_src.item_added,false) = true
     AND v_dest.pack_outcome = 'packed_transferred' THEN
    RETURN jsonb_build_object('status','noop','reason','already packed_transferred',
      'transfer_id', v_row.m2m_transfer_id,
      'source_dispatch_id', v_src.dispatch_id, 'dest_dispatch_id', v_dest.dispatch_id);
  END IF;

  -- DEST leg: land the unit in the destination machine's pod_inventory (canonical writer; WH-neutral).
  IF COALESCE(v_dest.item_added,false) <> true THEN
    v_dest_res := public.receive_dispatch_line(v_dest.dispatch_id, v_dest.quantity, p_confirmed_by, p_batch_breakdown);
  ELSE
    v_dest_res := jsonb_build_object('status','already_received');
  END IF;

  -- SOURCE leg: archive the source machine's pod_inventory (canonical writer; is_m2m skip => no WH credit).
  IF COALESCE(v_src.item_added,false) <> true THEN
    v_src_res := public.receive_dispatch_line(v_src.dispatch_id, v_src.quantity, p_confirmed_by, NULL);
  ELSE
    v_src_res := jsonb_build_object('status','already_received');
  END IF;

  -- Stamp the transfer outcome on both legs.
  UPDATE public.refill_dispatching
     SET pack_outcome = 'packed_transferred'
   WHERE dispatch_id IN (v_src.dispatch_id, v_dest.dispatch_id);

  RETURN jsonb_build_object(
    'status','ok',
    'transfer_id', v_row.m2m_transfer_id,
    'source_dispatch_id', v_src.dispatch_id,
    'dest_dispatch_id',   v_dest.dispatch_id,
    'dest_machine_id',    v_dest.machine_id,
    'source_machine_id',  v_src.machine_id,
    'quantity',           v_dest.quantity,
    'dest_result',        v_dest_res,
    'source_result',      v_src_res
  );
END;
$function$;
