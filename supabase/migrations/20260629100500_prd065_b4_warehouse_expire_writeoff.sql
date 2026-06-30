-- PRD-065 B4 — warehouse_expire_writeoff. Server-callable WH expiry/defective write-off.
-- HELD (writes warehouse_inventory, incl. status -> Article 6). Apply on CS green light.
-- Dara: adjust_warehouse_stock is auth.uid()-gated (FE only) so there is no server path to write off
-- expired/defective WH stock (the Al Ain case). This mirrors adjust_warehouse_stock's guards + audit
-- but takes an EXPLICIT caller_id. Sets warehouse_stock=0, consumer_stock=0, status='Inactive',
-- disposal_reason. Expired = loss (no credit anywhere). Reversible (flip status/stock back).
-- ARTICLE 6 (warehouse_inventory.status is manager-only, propose-then-confirm): this writer does NOT
-- set status. It zeroes warehouse_stock + consumer_stock + disposal_reason (audited). Zeroing the
-- stock on an Active row fires the existing tg_propose_inactivate_on_zero_stock trigger, which raises
-- an inactivation PROPOSAL for the warehouse manager to confirm. So the write-off is server-callable
-- (unblocks Al Ain + the sweep) while the status flip stays manager-confirmed (Cody verdict 2026-06-29).

CREATE OR REPLACE FUNCTION public.warehouse_expire_writeoff(
  p_wh_inventory_id uuid,
  p_reason          text,
  p_caller_id       uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_wh      public.warehouse_inventory%ROWTYPE;
  v_old_ws  numeric;
  v_old_cs  numeric;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'warehouse_expire_writeoff: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'warehouse_expire_writeoff: reason must be >= 10 chars';
  END IF;

  SELECT * INTO v_wh FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'warehouse_expire_writeoff: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  -- idempotency: already zeroed (status flip is the manager's propose-then-confirm step, not ours)
  IF COALESCE(v_wh.warehouse_stock,0) = 0 AND COALESCE(v_wh.consumer_stock,0) = 0 THEN
    RETURN jsonb_build_object('status','already_done','wh_inventory_id',p_wh_inventory_id,
                              'wh_status',v_wh.status,'note','already 0 stock; inactivation is manager propose-then-confirm');
  END IF;

  v_old_ws := COALESCE(v_wh.warehouse_stock,0);
  v_old_cs := COALESCE(v_wh.consumer_stock,0);

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'warehouse_expire_writeoff', true);
  PERFORM set_config('app.provenance_reason', 'expiry_writeoff', true);
  PERFORM set_config('app.source_event_id', p_wh_inventory_id::text, true);
  PERFORM set_config('app.mutation_reason',
    format('warehouse_expire_writeoff wh=%s by=%s reason=%s', p_wh_inventory_id, v_user_id, p_reason), true);

  -- NOTE: no status write (Article 6). Zeroing stock fires tg_propose_inactivate_on_zero_stock,
  -- which raises the inactivation proposal for the warehouse manager to confirm.
  UPDATE public.warehouse_inventory
  SET warehouse_stock = 0, consumer_stock = 0, disposal_reason = p_reason
  WHERE wh_inventory_id = p_wh_inventory_id;

  -- explicit audit rows (one per non-zero field), matching adjust_warehouse_stock's shape
  IF v_old_ws <> 0 THEN
    INSERT INTO public.inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
    VALUES (p_wh_inventory_id, v_wh.boonz_product_id, v_user_id, v_old_ws, 0,
            format('B4 expire/defective write-off: %s [warehouse_stock]', p_reason));
  END IF;
  IF v_old_cs <> 0 THEN
    INSERT INTO public.inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
    VALUES (p_wh_inventory_id, v_wh.boonz_product_id, v_user_id, v_old_cs, 0,
            format('B4 expire/defective write-off: %s [consumer_stock]', p_reason));
  END IF;

  RETURN jsonb_build_object('status','written_off','wh_inventory_id',p_wh_inventory_id,
                            'old_warehouse_stock',v_old_ws,'old_consumer_stock',v_old_cs,'reason',p_reason);
END;
$$;

REVOKE ALL ON FUNCTION public.warehouse_expire_writeoff(uuid,text,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.warehouse_expire_writeoff(uuid,text,uuid) TO authenticated, service_role;

-- DOWN:
-- DROP FUNCTION IF EXISTS public.warehouse_expire_writeoff(uuid,text,uuid);
