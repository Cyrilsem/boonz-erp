-- PROGRAM-2026-05-26 Phase 2 RPC infrastructure.
-- Cody-approved 2026-05-30. Articles satisfied: 1, 4, 5, 6, 8, 12, 14.
-- Allow-list on block_orphan_internal_transfer trigger already includes
-- repair_orphan_internal_transfer (pre-wired).
-- Applied to prod 2026-05-30 via MCP. This file is the repo mirror.

-- 1. Schema additions on refill_dispatching for cancel_dispatch_line.
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS cancelled boolean NOT NULL DEFAULT false;
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz NULL;
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS cancelled_by uuid NULL REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS cancellation_reason text NULL;

CREATE INDEX IF NOT EXISTS idx_refill_dispatching_cancelled
  ON public.refill_dispatching (cancelled) WHERE cancelled = true;

-- 2. cancel_dispatch_line(p_dispatch_id, p_reason)
CREATE OR REPLACE FUNCTION public.cancel_dispatch_line(
  p_dispatch_id uuid,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id   uuid := (SELECT auth.uid());
  v_caller    text;
  v_row       public.refill_dispatching%ROWTYPE;
BEGIN
  SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller IS NULL OR v_caller NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'cancel_dispatch_line: forbidden for role %', COALESCE(v_caller,'unknown');
  END IF;

  IF p_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'p_dispatch_id required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cancel_dispatch_line', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_row FROM public.refill_dispatching
   WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel_dispatch_line: dispatch_id % not found', p_dispatch_id;
  END IF;
  IF v_row.cancelled = true THEN
    RAISE EXCEPTION 'cancel_dispatch_line: dispatch_id % already cancelled at %',
      p_dispatch_id, v_row.cancelled_at;
  END IF;
  IF v_row.dispatched IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'cancel_dispatch_line: dispatch_id % is not dispatched (state must be dispatched=true for cancellation; got %)',
      p_dispatch_id, v_row.dispatched;
  END IF;
  IF v_row.from_wh_inventory_id IS NOT NULL THEN
    RAISE EXCEPTION 'cancel_dispatch_line: dispatch_id % already bound to WH inventory %. Use a reverse-cancellation RPC (not yet implemented) to credit back WH stock.',
      p_dispatch_id, v_row.from_wh_inventory_id;
  END IF;

  UPDATE public.refill_dispatching
     SET cancelled = true,
         cancelled_at = now(),
         cancelled_by = v_user_id,
         cancellation_reason = p_reason
   WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'dispatch_id', p_dispatch_id,
    'cancelled_at', now(),
    'cancelled_by', v_user_id,
    'reason', p_reason,
    'machine_id', v_row.machine_id,
    'boonz_product_id', v_row.boonz_product_id,
    'quantity_cancelled', v_row.quantity
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cancel_dispatch_line(uuid, text) TO authenticated;

-- 3. repair_orphan_internal_transfer(p_orphan_dispatch_id, p_destination_machine_id, p_reason)
CREATE OR REPLACE FUNCTION public.repair_orphan_internal_transfer(
  p_orphan_dispatch_id uuid,
  p_destination_machine_id uuid,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_user_id      uuid := (SELECT auth.uid());
  v_caller       text;
  v_orphan       public.refill_dispatching%ROWTYPE;
  v_dest_machine public.machines%ROWTYPE;
  v_transfer_id  uuid := gen_random_uuid();
  v_new_dispatch_id uuid;
BEGIN
  SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller IS NULL OR v_caller NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'repair_orphan_internal_transfer: forbidden for role %', COALESCE(v_caller,'unknown');
  END IF;

  IF p_orphan_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'p_orphan_dispatch_id required';
  END IF;
  IF p_destination_machine_id IS NULL THEN
    RAISE EXCEPTION 'p_destination_machine_id required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'repair_orphan_internal_transfer', true);
  PERFORM set_config('app.provenance_reason', 'm2m_return', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_orphan FROM public.refill_dispatching
   WHERE dispatch_id = p_orphan_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'repair_orphan_internal_transfer: dispatch_id % not found', p_orphan_dispatch_id;
  END IF;
  IF v_orphan.action <> 'Remove' THEN
    RAISE EXCEPTION 'repair_orphan_internal_transfer: dispatch_id % action=% (expected Remove)',
      p_orphan_dispatch_id, v_orphan.action;
  END IF;
  IF v_orphan.source_origin IS DISTINCT FROM 'internal_transfer'::source_origin_enum THEN
    RAISE EXCEPTION 'repair_orphan_internal_transfer: dispatch_id % source_origin=% (expected internal_transfer)',
      p_orphan_dispatch_id, v_orphan.source_origin;
  END IF;
  IF v_orphan.m2m_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'repair_orphan_internal_transfer: dispatch_id % already paired (transfer_id=%)',
      p_orphan_dispatch_id, v_orphan.m2m_transfer_id;
  END IF;

  SELECT * INTO v_dest_machine FROM public.machines
   WHERE machine_id = p_destination_machine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'repair_orphan_internal_transfer: destination machine % not found', p_destination_machine_id;
  END IF;
  IF p_destination_machine_id = v_orphan.machine_id THEN
    RAISE EXCEPTION 'repair_orphan_internal_transfer: destination machine cannot equal source machine %', v_orphan.machine_id;
  END IF;

  -- Update the orphan with a fresh transfer_id so the trigger sees a complete shape.
  UPDATE public.refill_dispatching
     SET m2m_transfer_id = v_transfer_id,
         is_m2m = true
   WHERE dispatch_id = p_orphan_dispatch_id;

  -- Write the paired Add New row at destination.
  INSERT INTO public.refill_dispatching (
    machine_id, shelf_id, pod_product_id, boonz_product_id,
    dispatch_date, action, quantity, include,
    packed, picked_up, dispatched, returned, item_added,
    expiry_date,
    is_m2m, m2m_transfer_id, m2m_partner_id,
    source_origin, source_kind,
    comment
  ) VALUES (
    p_destination_machine_id, NULL, v_orphan.pod_product_id, v_orphan.boonz_product_id,
    v_orphan.dispatch_date, 'Add New', v_orphan.quantity, true,
    true, true, true, false, false,
    v_orphan.expiry_date,
    true, v_transfer_id, p_orphan_dispatch_id,
    'internal_transfer'::source_origin_enum, 'wh',
    format('Repair pair for orphan %s: %s', p_orphan_dispatch_id, p_reason)
  ) RETURNING dispatch_id INTO v_new_dispatch_id;

  -- Backlink the m2m_partner_id on the orphan side.
  UPDATE public.refill_dispatching
     SET m2m_partner_id = v_new_dispatch_id
   WHERE dispatch_id = p_orphan_dispatch_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'transfer_id', v_transfer_id,
    'orphan_dispatch_id', p_orphan_dispatch_id,
    'new_add_new_dispatch_id', v_new_dispatch_id,
    'source_machine_id', v_orphan.machine_id,
    'destination_machine_id', p_destination_machine_id,
    'quantity', v_orphan.quantity,
    'boonz_product_id', v_orphan.boonz_product_id,
    'reason', p_reason
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.repair_orphan_internal_transfer(uuid, uuid, text) TO authenticated;
