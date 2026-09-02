-- PRD-118 item G3: set_wh_quarantine — the canonical door to place a manual hold on
-- a warehouse batch. Under the revised G2 design (independent manually_quarantined
-- column, not a widened GENERATED quarantined column), this function's job is to
-- set manually_quarantined=true — NOT provenance_reason='manual_quarantine' as the
-- original spec text said before the redesign; that value is now vestigial and this
-- function does not touch provenance_reason at all.
--
-- Mirrors release_wh_quarantine's exact role gate (warehouse/operator_admin/
-- superadmin). p_reason mandatory >= 10 chars. Refuses status<>'Active' or
-- warehouse_stock=0 before the dry-run branch, so a dry run previews the same
-- refusal a real call would hit. p_dry_run defaults true. Real writes go through
-- set_write_context (app.via_rpc/app.rpc_name) so the generic Article-8 audit
-- trigger fires automatically — no manual write_audit_log call needed.
--
-- Cody: approve, Articles 1/4/6/8/12 — canonical door for the new hold flag, pairs
-- with release_wh_quarantine (already extended in G2a to clear it); never touches
-- warehouse_inventory.status (Article 6 untouched).
CREATE FUNCTION public.set_wh_quarantine(
  p_wh_inventory_id uuid, p_reason text, p_caller_id uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_row public.warehouse_inventory%ROWTYPE;
BEGIN
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY(ARRAY['warehouse','operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'forbidden: set_wh_quarantine requires warehouse, operator_admin, or superadmin';
  END IF;

  IF p_wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'set_wh_quarantine: p_wh_inventory_id is required';
  END IF;
  IF COALESCE(p_reason, '') = '' OR length(p_reason) < 10 THEN
    RAISE EXCEPTION 'set_wh_quarantine: p_reason is required (>= 10 chars; why this batch is being held)';
  END IF;

  SELECT * INTO v_row FROM public.warehouse_inventory
  WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_wh_quarantine: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  IF v_row.status <> 'Active' THEN
    RAISE EXCEPTION 'set_wh_quarantine: row % is not Active (status=%) — nothing to quarantine', p_wh_inventory_id, v_row.status;
  END IF;
  IF COALESCE(v_row.warehouse_stock, 0) = 0 THEN
    RAISE EXCEPTION 'set_wh_quarantine: row % has zero warehouse_stock — nothing to quarantine', p_wh_inventory_id;
  END IF;

  IF v_row.manually_quarantined OR v_row.quarantined THEN
    RETURN jsonb_build_object(
      'status', 'noop', 'wh_inventory_id', p_wh_inventory_id,
      'message', 'row is already quarantined (manual or provenance-derived)',
      'manually_quarantined', v_row.manually_quarantined,
      'quarantined', v_row.quarantined);
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'status', 'dry_run_ok', 'wh_inventory_id', p_wh_inventory_id,
      'boonz_product_id', v_row.boonz_product_id, 'warehouse_stock', v_row.warehouse_stock,
      'expiration_date', v_row.expiration_date, 'reason', p_reason);
  END IF;

  PERFORM public.set_write_context('set_wh_quarantine',
    format('set_wh_quarantine by %s: %s', COALESCE(v_user_id::text,'system'), p_reason),
    'manual_quarantine', p_wh_inventory_id::text);

  UPDATE public.warehouse_inventory
     SET manually_quarantined = true
   WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'status', 'quarantined',
    'wh_inventory_id', p_wh_inventory_id,
    'boonz_product_id', v_row.boonz_product_id,
    'warehouse_stock', v_row.warehouse_stock,
    'expiration_date', v_row.expiration_date,
    'reason', p_reason,
    'caller', v_user_id,
    'note', 'excluded from v_wh_pickable and every direct-reader RPC patched in G2a; release via release_wh_quarantine');
END $function$;
