-- PRD-049 Phase C: edit_transfer_qty — atomic both-leg qty edit for M2M transfers.
-- NOT applied in this pass (migration FILE only). Dara design -> Cody review -> CS applies via MCP.
--
-- WHY: edit_dispatch_qty edits a SINGLE refill_dispatching row. An M2M transfer is a
-- pair (Remove leg @ source machine + Add New leg @ dest machine) sharing m2m_transfer_id,
-- both carrying the same quantity. Editing one leg desyncs them. This new writer mutates
-- BOTH legs in one transaction so the pair invariant holds and the guard triggers
-- (block_orphan_internal_transfer, conserve_split_dispatch_quantity, flag_remove_with_transfer_intent)
-- never observe a half-state. It preserves m2m_transfer_id/is_m2m/source_origin so
-- block_orphan stays quiet.
--
-- Articles: 1 (sole atomic transfer-qty path), 4 (DEFINER: role gate via user_profiles,
-- app.via_rpc/app.rpc_name, input validation, FOR UPDATE), 8 (per-leg audit to
-- refill_dispatching_edit_log + generic write_audit_log trigger via app.via_rpc), 12, 14.
-- edit_kind reuses 'qty' (the log CHECK is IN ('qty','shelf','product','source','add','remove');
-- the transfer context lives in before_state/after_state jsonb) — no constraint widening.

CREATE OR REPLACE FUNCTION public.edit_transfer_qty(
  p_dispatch_id uuid,
  p_new_qty     numeric,
  p_edit_role   text,
  p_reason      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_role        text;
  v_transfer_id uuid;
  v_n           int := 0;
  v_target_seen boolean := false;
  v_legs        jsonb := '[]'::jsonb;
  r             public.refill_dispatching%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'edit_transfer_qty', true);

  -- Caller role gate (skip when service-role / no auth.uid()), mirrors edit_dispatch_qty.
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NOT NULL
     AND v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'forbidden: edit_transfer_qty requires warehouse / operator_admin / superadmin / manager';
  END IF;

  IF p_new_qty IS NULL OR p_new_qty <= 0 THEN
    RAISE EXCEPTION 'invalid p_new_qty: a transfer must move > 0 units (use remove_dispatch_row to cancel a transfer)';
  END IF;
  IF p_edit_role NOT IN ('driver','warehouse_manager','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'invalid p_edit_role';
  END IF;

  -- Resolve the transfer id from the target row.
  SELECT m2m_transfer_id INTO v_transfer_id
  FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'dispatch % not found', p_dispatch_id;
  END IF;
  IF v_transfer_id IS NULL THEN
    RAISE EXCEPTION 'dispatch % is not an M2M transfer (no m2m_transfer_id) — use edit_dispatch_qty', p_dispatch_id;
  END IF;

  -- Pass 1: lock the WHOLE pair in one deterministic statement (dispatch_id order ->
  -- no lock-order inversion vs a concurrent edit). Count legs, assert target membership,
  -- and refuse if any leg is already physically progressed.
  FOR r IN
    SELECT * FROM public.refill_dispatching
    WHERE m2m_transfer_id = v_transfer_id
    ORDER BY dispatch_id
    FOR UPDATE
  LOOP
    v_n := v_n + 1;
    IF r.dispatch_id = p_dispatch_id THEN v_target_seen := true; END IF;
    IF COALESCE(r.item_added,false) OR COALESCE(r.packed,false) OR COALESCE(r.picked_up,false) THEN
      RAISE EXCEPTION 'transfer leg % is already packed/picked_up/received — qty edit blocked', r.dispatch_id;
    END IF;
  END LOOP;

  IF v_n <> 2 THEN
    RAISE EXCEPTION 'M2M transfer % has % leg(s), expected exactly 2 — orphaned/corrupt; run repair_orphan_internal_transfer',
      v_transfer_id, v_n;
  END IF;
  IF NOT v_target_seen THEN
    RAISE EXCEPTION 'dispatch % is not part of transfer %', p_dispatch_id, v_transfer_id;
  END IF;

  -- Pass 2: apply the new qty to BOTH legs (rows already locked) + audit each leg.
  FOR r IN
    SELECT * FROM public.refill_dispatching
    WHERE m2m_transfer_id = v_transfer_id
    ORDER BY dispatch_id
  LOOP
    UPDATE public.refill_dispatching
    SET quantity            = p_new_qty,
        original_quantity   = COALESCE(original_quantity, r.quantity),
        edit_count          = edit_count + 1,
        last_edited_by      = auth.uid(),
        last_edited_by_role = p_edit_role,
        last_edited_at      = now()
    WHERE dispatch_id = r.dispatch_id;

    INSERT INTO public.refill_dispatching_edit_log
      (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
    VALUES
      (r.dispatch_id, auth.uid(), p_edit_role, 'qty',
       jsonb_build_object('quantity', r.quantity, 'm2m_transfer_id', v_transfer_id,
                          'leg', r.action, 'edit_via', 'edit_transfer_qty'),
       jsonb_build_object('quantity', p_new_qty,  'm2m_transfer_id', v_transfer_id,
                          'leg', r.action, 'edit_via', 'edit_transfer_qty'),
       p_reason, NULL);

    v_legs := v_legs || jsonb_build_object(
      'dispatch_id', r.dispatch_id, 'action', r.action, 'machine_id', r.machine_id,
      'before', r.quantity, 'after', p_new_qty);
  END LOOP;

  RETURN jsonb_build_object(
    'm2m_transfer_id', v_transfer_id,
    'new_qty',         p_new_qty,
    'legs',            v_legs);
END
$function$;

COMMENT ON FUNCTION public.edit_transfer_qty(uuid, numeric, text, text) IS
  'PRD-049 Phase C: atomic both-leg quantity edit for an M2M transfer pair (shared m2m_transfer_id). Refuses if either leg is packed/picked_up/item_added. Use edit_dispatch_qty for non-transfer rows.';

GRANT EXECUTE ON FUNCTION public.edit_transfer_qty(uuid, numeric, text, text) TO authenticated;
