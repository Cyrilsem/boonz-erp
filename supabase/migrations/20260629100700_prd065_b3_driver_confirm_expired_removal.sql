-- PRD-065 B3 — driver-confirm closeout for a queued stock-bearing expired row.
-- HELD (writes pod_inventory + pod_inventory_edits). Apply on CS green light.
-- Dara: the sweep (B2) queues a stock-bearing expired pod row as a PENDING 'expired' edit. When the
-- driver confirms physical removal, write the pod row off (Inactive, 0, removal_reason) and approve the
-- edit. Expired = loss: NO warehouse credit. Bounded capability: only operates on a row already flagged
-- expired (a pending 'expired' edit linked to it) AND actually Active+past-expiry -- a driver cannot
-- write off arbitrary stock. Field-callable (drivers) + manager-class. Mirrors the
-- backfill_archive_pod_inventory_row pod write, but backfill is superadmin/operator_admin-gated so B3
-- carries its own bounded write. Idempotent: no-op if the edit is resolved or the pod row is Inactive.

CREATE OR REPLACE FUNCTION public.driver_confirm_expired_removal(
  p_edit_id   uuid,
  p_caller_id uuid,
  p_note      text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_edit    public.pod_inventory_edits%ROWTYPE;
  v_pod     public.pod_inventory%ROWTYPE;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'driver_confirm_expired_removal: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'driver_confirm_expired_removal: edit % not found', p_edit_id;
  END IF;
  IF v_edit.edit_type <> 'expired' THEN
    RAISE EXCEPTION 'driver_confirm_expired_removal: edit % is type % (expects expired)', p_edit_id, v_edit.edit_type;
  END IF;
  IF v_edit.status <> 'pending' THEN
    RETURN jsonb_build_object('status','already_done','edit_id',p_edit_id,'edit_status',v_edit.status);
  END IF;
  IF v_edit.pod_inventory_id IS NULL THEN
    RAISE EXCEPTION 'driver_confirm_expired_removal: edit % has no linked pod_inventory_id', p_edit_id;
  END IF;

  SELECT * INTO v_pod FROM public.pod_inventory WHERE pod_inventory_id = v_edit.pod_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    -- pod row gone; just resolve the edit
    UPDATE public.pod_inventory_edits SET status='approved', reviewed_by=v_user_id, reviewed_at=now() WHERE edit_id=p_edit_id;
    RETURN jsonb_build_object('status','already_done','edit_id',p_edit_id,'note','linked pod row missing; edit closed');
  END IF;

  IF COALESCE(v_pod.status,'') = 'Inactive' THEN
    UPDATE public.pod_inventory_edits SET status='approved', reviewed_by=v_user_id, reviewed_at=now() WHERE edit_id=p_edit_id;
    RETURN jsonb_build_object('status','already_done','edit_id',p_edit_id,'note','pod row already Inactive; edit closed');
  END IF;

  -- safety: only confirm removal of an actually-expired row
  IF v_pod.expiration_date IS NULL OR v_pod.expiration_date >= (now() AT TIME ZONE 'Asia/Dubai')::date THEN
    RAISE EXCEPTION 'driver_confirm_expired_removal: pod row % is not past expiry (%); refusing', v_pod.pod_inventory_id, v_pod.expiration_date;
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_confirm_expired_removal', true);
  PERFORM set_config('app.mutation_reason',
    format('B3 expired removal pod=%s edit=%s by=%s', v_pod.pod_inventory_id, p_edit_id, v_user_id), true);

  -- write-off (loss, NO warehouse credit)
  UPDATE public.pod_inventory
  SET current_stock = 0, estimated_remaining = 0, status = 'Inactive',
      removal_reason = format('expired_driver_confirmed_via_edit_%s', p_edit_id), last_decremented_at = now()
  WHERE pod_inventory_id = v_pod.pod_inventory_id;

  UPDATE public.pod_inventory_edits
  SET status='approved', reviewed_by=v_user_id, reviewed_at=now(),
      notes = COALESCE(notes,'') || COALESCE(' | '||p_note,'')
  WHERE edit_id = p_edit_id;

  RETURN jsonb_build_object('status','written_off','edit_id',p_edit_id,'pod_inventory_id',v_pod.pod_inventory_id,
                            'units_written_off',COALESCE(v_pod.current_stock,0),'wh_credit',false);
END;
$$;

REVOKE ALL ON FUNCTION public.driver_confirm_expired_removal(uuid,uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.driver_confirm_expired_removal(uuid,uuid,text) TO authenticated, service_role;

-- DOWN:
-- DROP FUNCTION IF EXISTS public.driver_confirm_expired_removal(uuid,uuid,text);
