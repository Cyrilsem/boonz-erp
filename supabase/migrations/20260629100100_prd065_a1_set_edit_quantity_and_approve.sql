-- PRD-065 A1 (repair RPC) — set_edit_quantity_and_approve.
-- HELD (writes pod_inventory_edits -> pod_inventory via approve). Apply on CS green light.
-- Dara: one-step review-queue repair = what was done by hand for JET Pepsi edit 5d5ab4a7. Sets the
-- missing quantity_update on a still-pending edit, then delegates to the canonical
-- approve_pod_inventory_edit (no duplicate approval logic). SECURITY DEFINER, explicit caller_id,
-- role-gated to the same set approve uses. Idempotent: no-op-ish if already approved/rejected.
-- Article 1/3: the only write is the qty UPDATE (GUC-audited) then the canonical approver.

CREATE OR REPLACE FUNCTION public.set_edit_quantity_and_approve(
  p_edit_id   uuid,
  p_qty       numeric,
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
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'set_edit_quantity_and_approve: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'set_edit_quantity_and_approve: quantity must be > 0 (got %)', p_qty;
  END IF;

  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_edit_quantity_and_approve: edit % not found', p_edit_id;
  END IF;

  -- idempotency: only act on still-pending edits
  IF v_edit.status <> 'pending' THEN
    RETURN jsonb_build_object('status','already_done','edit_id',p_edit_id,'edit_status',v_edit.status,
                              'note','edit is not pending; nothing to set');
  END IF;

  -- set the missing quantity (GUC-audited pod_inventory_edits write)
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'set_edit_quantity_and_approve', true);
  PERFORM set_config('app.mutation_reason',
    format('set_edit_quantity edit=%s qty=%s by=%s', p_edit_id, p_qty, v_user_id), true);

  UPDATE public.pod_inventory_edits SET quantity_update = p_qty WHERE edit_id = p_edit_id;

  -- delegate to the canonical approver (it sets its own GUCs + does the inventory mutation)
  RETURN public.approve_pod_inventory_edit(p_edit_id, v_user_id, COALESCE(p_note, 'qty set + approved via set_edit_quantity_and_approve'));
END;
$$;

REVOKE ALL ON FUNCTION public.set_edit_quantity_and_approve(uuid,numeric,uuid,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_edit_quantity_and_approve(uuid,numeric,uuid,text) TO authenticated, service_role;

-- DOWN:
-- DROP FUNCTION IF EXISTS public.set_edit_quantity_and_approve(uuid,numeric,uuid,text);
