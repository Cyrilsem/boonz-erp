-- PRD-119b T1: audited repair RPC for the E1 Remove legs, plus the actual
-- repair of the one still-open leg found live.
--
-- Of the 5 dispatch rows matching E1's named examples (VOXMCC-1005 A15 x2,
-- VOXMCC-1011 A15 x1, VOXMCC-1011 A11 x2), 4 had already flipped to
-- skipped=true by the time this migration ran (superseded by later daily
-- plan re-pushes) -- the RPC deliberately refuses skipped/cancelled/
-- returned rows, so repairing their historical record would be purely
-- cosmetic; left as-is, noted in the build report.
--
-- The one remaining open leg (VOXMCC-1005 A15, dispatch db862e0f,
-- 2026-09-05) is `packed=true` -- the standing `protect_packed_dispatch_row`
-- trigger refuses to let ANY writer change shelf_id/machine_id/
-- dispatch_date on a packed row (Article 6-adjacent protection, not
-- PRD-specific). This RPC is packed-aware: on a packed row it corrects only
-- `expiry_date` and `pod_lot_id` (the fields that matter for
-- disposition/waste tracking) and leaves `shelf_id` exactly as already
-- packed; on an unpacked row it also corrects `shelf_id`.
--
-- Verified in a rolled-back dry run before the real call: before
-- shelf=A15/expiry=2027-12-03/pod_lot_id=NULL, after
-- shelf=A15 (kept, packed)/expiry=2026-09-06/pod_lot_id=<the real A16 lot>.
-- Applied for real: identical result, `refill_dispatching_edit_log` row
-- written (edit_kind='shelf', the closest of the existing allowed values).
--
-- Cody: approve, Articles 1, 4 (operator_admin/superadmin/manager only,
-- mandatory reason >=10 chars, audit log), 12.
CREATE OR REPLACE FUNCTION public.repair_remove_leg_shelf_lot(
  p_dispatch_id uuid,
  p_reason text,
  p_caller uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := COALESCE(p_caller, auth.uid());
  v_role text;
  v_row refill_dispatching%ROWTYPE;
  v_lot record;
  v_before jsonb;
  v_shelf_locked boolean;
BEGIN
  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','repair_remove_leg_shelf_lot', true);

  IF v_caller IS NOT NULL THEN
    SELECT role INTO v_role FROM user_profiles WHERE id = v_caller;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'repair_remove_leg_shelf_lot: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'repair_remove_leg_shelf_lot: p_dispatch_id required'; END IF;
  IF length(COALESCE(p_reason,'')) < 10 THEN RAISE EXCEPTION 'repair_remove_leg_shelf_lot: p_reason must be at least 10 characters'; END IF;

  SELECT * INTO v_row FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'repair_remove_leg_shelf_lot: dispatch % not found', p_dispatch_id; END IF;
  IF v_row.action <> 'Remove' THEN RAISE EXCEPTION 'repair_remove_leg_shelf_lot: dispatch % is not a Remove leg (action=%)', p_dispatch_id, v_row.action; END IF;
  IF COALESCE(v_row.cancelled,false) OR COALESCE(v_row.skipped,false) OR COALESCE(v_row.returned,false) THEN
    RAISE EXCEPTION 'repair_remove_leg_shelf_lot: dispatch % is cancelled/skipped/returned', p_dispatch_id;
  END IF;
  v_shelf_locked := COALESCE(v_row.packed, false);

  SELECT pil.pod_inventory_id, pil.shelf_id, pil.expiration_date
    INTO v_lot
  FROM v_pod_inventory_latest pil
  WHERE pil.machine_id = v_row.machine_id
    AND pil.boonz_product_id = v_row.boonz_product_id
    AND pil.status = 'Active'
    AND COALESCE(pil.current_stock,0) > 0
  ORDER BY pil.expiration_date ASC NULLS LAST
  LIMIT 1;

  IF v_lot.pod_inventory_id IS NULL THEN
    RAISE EXCEPTION 'repair_remove_leg_shelf_lot: no Active pod lot found for dispatch % (machine=%, product=%) - nothing to repair against', p_dispatch_id, v_row.machine_id, v_row.boonz_product_id;
  END IF;

  v_before := jsonb_build_object('shelf_id', v_row.shelf_id, 'expiry_date', v_row.expiry_date, 'pod_lot_id', v_row.pod_lot_id, 'comment', v_row.comment, 'packed', v_row.packed);

  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','dispatch_id',p_dispatch_id, 'shelf_locked_by_pack', v_shelf_locked,
      'before', v_before,
      'after', jsonb_build_object('shelf_id', CASE WHEN v_shelf_locked THEN v_row.shelf_id ELSE v_lot.shelf_id END,
        'expiry_date', v_lot.expiration_date, 'pod_lot_id', v_lot.pod_inventory_id));
  END IF;

  UPDATE refill_dispatching
     SET shelf_id = CASE WHEN v_shelf_locked THEN shelf_id ELSE v_lot.shelf_id END,
         expiry_date = v_lot.expiration_date,
         pod_lot_id = v_lot.pod_inventory_id,
         comment = COALESCE(NULLIF(btrim(comment),''), '') ||
           CASE WHEN COALESCE(btrim(comment),'') = '' THEN '' ELSE E'\n' END ||
           format('[REPAIRED %s: re-pointed to shelf lot exp=%s%s, reason: %s]', now()::date, v_lot.expiration_date,
             CASE WHEN v_shelf_locked THEN ' (shelf kept as-packed, lot lives elsewhere)' ELSE '' END, p_reason),
         edit_count = COALESCE(edit_count,0) + 1,
         last_edited_by = v_caller,
         last_edited_by_role = 'operator_admin',
         last_edited_at = now()
   WHERE dispatch_id = p_dispatch_id;

  INSERT INTO refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, v_caller, 'operator_admin', 'shelf', v_before,
     jsonb_build_object('shelf_id', CASE WHEN v_shelf_locked THEN v_row.shelf_id ELSE v_lot.shelf_id END,
       'expiry_date', v_lot.expiration_date, 'pod_lot_id', v_lot.pod_inventory_id),
     p_reason, NULL);

  RETURN jsonb_build_object('status','repaired','dispatch_id',p_dispatch_id, 'shelf_locked_by_pack', v_shelf_locked,
    'before', v_before,
    'after', jsonb_build_object('shelf_id', CASE WHEN v_shelf_locked THEN v_row.shelf_id ELSE v_lot.shelf_id END,
      'expiry_date', v_lot.expiration_date, 'pod_lot_id', v_lot.pod_inventory_id));
END;
$function$;
