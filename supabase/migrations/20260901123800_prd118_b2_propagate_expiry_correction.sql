-- PRD-118 item B companion: propagate_expiry_correction(p_wh_inventory_id,
-- p_dry_run default true). When a warehouse batch's date is corrected, units already
-- delivered from it still carry the old date in the field (on 27 Aug this was found
-- by hand: Zero Peach, 5 units across ALJLT/VML-1003/OMDBB).
--
-- Derives the superseded date from the Article-8 audit trail (write_audit_log stores
-- full old/new row images on every via_rpc write) rather than requiring a separate
-- p_old_expiry input — reads the most recent logged expiration_date change on the
-- exact warehouse row, so it can never be stale or mistyped by a caller. Lists every
-- Active pod_inventory row for the same product matching that old value. Dry-run by
-- default per the PRD's own explicit caution — matching on the old date alone can
-- catch legitimate rows from a different delivery, so a human confirms the list
-- before any write. The real pass calls correct_expiry_v1('pod', ...) once per
-- matching row — the canonical door, never a raw UPDATE.
--
-- Verified live end-to-end: corrected a real Kit-Kat warehouse batch (2027-01-31 ->
-- 2027-03-15), then ran propagate_expiry_correction in dry-run against that same
-- wh_inventory_id — it correctly derived old_expiry=2027-01-31 with no input, and
-- found exactly 21 matching Active field rows, matching the population confirmed by
-- a manual query beforehand.
-- Cody: approve, Articles 1/4/12 — read-only discovery + a loop of already-canonical
-- correct_expiry_v1 calls, no new raw write path on pod_inventory.
CREATE OR REPLACE FUNCTION public.propagate_expiry_correction(
  p_wh_inventory_id uuid, p_dry_run boolean DEFAULT true, p_caller_id uuid DEFAULT NULL::uuid, p_override boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role text; v_wh warehouse_inventory%ROWTYPE; v_old_expiry date; v_new_expiry date;
  v_matches jsonb; v_n int; r RECORD; v_corrected jsonb := '[]'::jsonb; v_corrected_n int := 0;
BEGIN
  IF p_wh_inventory_id IS NULL THEN RAISE EXCEPTION 'propagate_expiry_correction: p_wh_inventory_id is required'; END IF;
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'propagate_expiry_correction: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  SELECT * INTO v_wh FROM warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'propagate_expiry_correction: warehouse_inventory % not found', p_wh_inventory_id; END IF;
  v_new_expiry := v_wh.expiration_date;
  SELECT (payload->'old'->>'expiration_date')::date INTO v_old_expiry
  FROM write_audit_log
  WHERE table_name = 'warehouse_inventory' AND row_pk = p_wh_inventory_id::text AND operation = 'UPDATE'
    AND (payload->'old'->>'expiration_date') IS DISTINCT FROM (payload->'new'->>'expiration_date')
  ORDER BY occurred_at DESC LIMIT 1;
  IF v_old_expiry IS NULL THEN
    RETURN jsonb_build_object('status','no_correction_found','wh_inventory_id',p_wh_inventory_id,'current_expiry',v_new_expiry);
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('pod_inventory_id', pi.pod_inventory_id, 'machine_id', pi.machine_id,
           'shelf_id', pi.shelf_id, 'current_stock', pi.current_stock, 'expiration_date', pi.expiration_date)), '[]'::jsonb),
         COUNT(*)
    INTO v_matches, v_n
  FROM pod_inventory pi
  WHERE pi.boonz_product_id = v_wh.boonz_product_id AND pi.status = 'Active' AND pi.expiration_date = v_old_expiry;
  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','wh_inventory_id',p_wh_inventory_id,'boonz_product_id',v_wh.boonz_product_id,
      'old_expiry',v_old_expiry,'new_expiry',v_new_expiry,'matching_rows',v_n,'rows',v_matches);
  END IF;
  FOR r IN
    SELECT pi.pod_inventory_id FROM pod_inventory pi
    WHERE pi.boonz_product_id = v_wh.boonz_product_id AND pi.status = 'Active' AND pi.expiration_date = v_old_expiry
  LOOP
    PERFORM public.correct_expiry_v1('pod', r.pod_inventory_id, v_new_expiry,
      format('propagate_expiry_correction from warehouse batch %s (was %s, corrected to %s)', p_wh_inventory_id, v_old_expiry, v_new_expiry),
      v_user_id, false, p_override);
    v_corrected := v_corrected || jsonb_build_object('pod_inventory_id', r.pod_inventory_id);
    v_corrected_n := v_corrected_n + 1;
  END LOOP;
  RETURN jsonb_build_object('status','ok','wh_inventory_id',p_wh_inventory_id,'boonz_product_id',v_wh.boonz_product_id,
    'old_expiry',v_old_expiry,'new_expiry',v_new_expiry,'rows_corrected',v_corrected_n,'corrected',v_corrected);
END;
$function$;
