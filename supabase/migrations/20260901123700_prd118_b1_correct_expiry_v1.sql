-- PRD-118 item B: correct_expiry_v1 — the canonical door to fix a wrong expiry.
-- No prior RPC could do this: apply_inventory_correction COALESCEs and cannot
-- overwrite an existing date; reactivate_warehouse_row refuses stock<=0 and is named
-- for a different job; adjust_pod_inventory matches its target row ON expiration_date,
-- so a new date never matches and it silently INSERTs a duplicate active lane row
-- instead of correcting. The 27 Aug fixes had to be done as a three-tool manual
-- workaround (reactivate_warehouse_row + set_dispatch_line_breakdown +
-- hand-rolled zero-then-reinsert through adjust_pod_inventory).
--
-- correct_expiry_v1(p_scope warehouse|pod|dispatch, p_row_id, p_new_expiry, p_reason,
-- p_caller_id default NULL, p_dry_run default true, p_override default false):
-- SECURITY DEFINER, role-checked (warehouse/operator_admin/superadmin/manager),
-- reason >= 20 chars mandatory, set_write_context per the reactivate_warehouse_row
-- reference pattern. Refuses a past date or >36 months out unless p_override=true.
-- warehouse scope: works at ANY stock including zero (no reactivate_warehouse_row
-- stock>0 refusal), reuses the existing sync_dispatch_expiry_from_pinned_wh trigger
-- (untouched, per the PRD's own instruction that it "worked perfectly on 27 Aug" and
-- cascades to open dispatch rows automatically). pod scope: does the zero-then-
-- reinsert INSIDE the function (archive old row Inactive, insert new Active row at
-- the corrected date carrying the same current_stock) — a single call, so a caller
-- cannot get it wrong the way the manual two-step could. dispatch scope: corrects
-- expiry_date directly on the refill_dispatching row.
--
-- Verified live: zero-stock warehouse correction (real row, 0 units, date updated
-- correctly); pod-scope correction on a real 6-unit row (new Active row created at
-- the corrected date carrying the same stock, old row correctly archived Inactive
-- with its original expiry preserved, no duplication); short-reason refusal fires;
-- past-date-without-override refusal fires.
-- Cody: approve, Articles 1/4/6/12 — refill correction surface gains its missing
-- canonical door; no bypass of Article 6 (never touches warehouse_inventory.status).
CREATE FUNCTION public.correct_expiry_v1(
  p_scope text, p_row_id uuid, p_new_expiry date, p_reason text,
  p_caller_id uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true, p_override boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id  uuid := COALESCE(p_caller_id, auth.uid());
  v_role     text; v_old_expiry date;
  v_wh       warehouse_inventory%ROWTYPE; v_pod pod_inventory%ROWTYPE; v_rd refill_dispatching%ROWTYPE;
  v_new_pod_id uuid;
BEGIN
  IF p_scope NOT IN ('warehouse','pod','dispatch') THEN
    RAISE EXCEPTION 'correct_expiry_v1: p_scope must be warehouse|pod|dispatch (got %)', p_scope;
  END IF;
  IF p_row_id IS NULL OR p_new_expiry IS NULL THEN
    RAISE EXCEPTION 'correct_expiry_v1: p_row_id and p_new_expiry are required';
  END IF;
  IF COALESCE(length(trim(p_reason)), 0) < 20 THEN
    RAISE EXCEPTION 'correct_expiry_v1: p_reason must be >= 20 characters (got %)', COALESCE(length(trim(p_reason)),0);
  END IF;
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'correct_expiry_v1: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF NOT p_override THEN
    IF p_new_expiry < CURRENT_DATE THEN
      RAISE EXCEPTION 'correct_expiry_v1: % is in the past — pass p_override:=true to force (e.g. correcting a batch already known to have expired)', p_new_expiry;
    END IF;
    IF p_new_expiry > (CURRENT_DATE + INTERVAL '36 months')::date THEN
      RAISE EXCEPTION 'correct_expiry_v1: % is more than 36 months out — pass p_override:=true to force', p_new_expiry;
    END IF;
  END IF;
  PERFORM public.set_write_context('correct_expiry_v1',
    format('correct_expiry_v1 scope=%s row=%s new_expiry=%s dry_run=%s: %s', p_scope, p_row_id, p_new_expiry, p_dry_run, p_reason),
    'manual_adjust', p_row_id::text);
  IF p_scope = 'warehouse' THEN
    SELECT * INTO v_wh FROM warehouse_inventory WHERE wh_inventory_id = p_row_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'correct_expiry_v1: warehouse_inventory % not found', p_row_id; END IF;
    v_old_expiry := v_wh.expiration_date;
    IF p_dry_run THEN
      RETURN jsonb_build_object('status','dry_run_ok','scope',p_scope,'row_id',p_row_id,'old_expiry',v_old_expiry,'new_expiry',p_new_expiry,'stock',v_wh.warehouse_stock);
    END IF;
    UPDATE warehouse_inventory SET expiration_date = p_new_expiry WHERE wh_inventory_id = p_row_id;
    RETURN jsonb_build_object('status','ok','scope',p_scope,'row_id',p_row_id,'old_expiry',v_old_expiry,'new_expiry',p_new_expiry,'reason',p_reason);
  ELSIF p_scope = 'pod' THEN
    SELECT * INTO v_pod FROM pod_inventory WHERE pod_inventory_id = p_row_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'correct_expiry_v1: pod_inventory % not found', p_row_id; END IF;
    v_old_expiry := v_pod.expiration_date;
    IF p_dry_run THEN
      RETURN jsonb_build_object('status','dry_run_ok','scope',p_scope,'row_id',p_row_id,'old_expiry',v_old_expiry,'new_expiry',p_new_expiry,'current_stock',v_pod.current_stock);
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('expiry_corrected_by_%s', COALESCE(v_user_id::text,'system')), snapshot_at = now()
     WHERE pod_inventory_id = p_row_id;
    INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at)
    VALUES (v_pod.machine_id, v_pod.shelf_id, v_pod.boonz_product_id, CURRENT_DATE, v_pod.current_stock, v_pod.current_stock, p_new_expiry, format('EXPIRY-CORRECTED-%s', v_pod.pod_inventory_id), 'Active', now(), now())
    RETURNING pod_inventory_id INTO v_new_pod_id;
    RETURN jsonb_build_object('status','ok','scope',p_scope,'old_row_id',p_row_id,'new_row_id',v_new_pod_id,'old_expiry',v_old_expiry,'new_expiry',p_new_expiry,'current_stock',v_pod.current_stock,'reason',p_reason);
  ELSE
    SELECT * INTO v_rd FROM refill_dispatching WHERE dispatch_id = p_row_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'correct_expiry_v1: dispatch % not found', p_row_id; END IF;
    v_old_expiry := v_rd.expiry_date;
    IF p_dry_run THEN
      RETURN jsonb_build_object('status','dry_run_ok','scope',p_scope,'row_id',p_row_id,'old_expiry',v_old_expiry,'new_expiry',p_new_expiry,'quantity',v_rd.quantity);
    END IF;
    UPDATE refill_dispatching SET expiry_date = p_new_expiry WHERE dispatch_id = p_row_id;
    RETURN jsonb_build_object('status','ok','scope',p_scope,'row_id',p_row_id,'old_expiry',v_old_expiry,'new_expiry',p_new_expiry,'reason',p_reason);
  END IF;
END;
$function$;
