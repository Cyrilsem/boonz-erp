-- PRD-098 return-approval workflow (Cody PASS, revisions applied: role set incl 'manager', append-only policies).
-- Backend only; NO refill-engine edit. Only mutation = provenance flip (approve) + drain+canonical
-- inactivate (reject). Gate-compliant (app.via_rpc/rpc_name/provenance). Forward-only.
-- NOTE: reject_return here is the ORIGINAL; superseded by prd098_reject_return_guard_already_inactive.

-- (1) append-only audit (Article 7)
CREATE TABLE IF NOT EXISTS public.return_approval_log (
  log_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wh_inventory_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('approve','reject')),
  approver_id uuid,
  approver_role text,
  note text,
  before_row jsonb,
  after_row jsonb,
  created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.return_approval_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ral_select ON public.return_approval_log;
DROP POLICY IF EXISTS ral_no_update ON public.return_approval_log;
DROP POLICY IF EXISTS ral_no_delete ON public.return_approval_log;
CREATE POLICY ral_select ON public.return_approval_log FOR SELECT TO authenticated USING (true);
CREATE POLICY ral_no_update ON public.return_approval_log FOR UPDATE USING (false);
CREATE POLICY ral_no_delete ON public.return_approval_log FOR DELETE USING (false);
GRANT SELECT ON public.return_approval_log TO authenticated, service_role;
CREATE INDEX IF NOT EXISTS idx_ral_wh ON public.return_approval_log (wh_inventory_id, created_at DESC);

-- (2) WS-1 pending view + WS-4 legacy view
CREATE OR REPLACE VIEW public.v_pending_return_approvals AS
SELECT wi.wh_inventory_id, wi.warehouse_id, wi.boonz_product_id, bp.boonz_product_name AS product_name,
       wi.warehouse_stock AS qty, wi.expiration_date,
       (wi.expiration_date - (now() AT TIME ZONE 'Asia/Dubai')::date) AS days_to_expiry,
       wi.batch_id, wi.source_event_id AS origin_dispatch_id, wi.reserved_for_machine_id AS origin_machine_id,
       wi.created_at, ((now() AT TIME ZONE 'Asia/Dubai')::date - wi.created_at::date) AS age_days
FROM public.warehouse_inventory wi
LEFT JOIN public.boonz_products bp ON bp.product_id = wi.boonz_product_id
WHERE wi.provenance_reason = 'dispatch_return_unverified' AND wi.warehouse_stock > 0;
GRANT SELECT ON public.v_pending_return_approvals TO authenticated, service_role;

CREATE OR REPLACE VIEW public.v_pending_legacy_quarantine AS
SELECT wi.wh_inventory_id, wi.warehouse_id, wi.boonz_product_id, bp.boonz_product_name AS product_name,
       wi.warehouse_stock AS qty, wi.expiration_date,
       (wi.expiration_date - (now() AT TIME ZONE 'Asia/Dubai')::date) AS days_to_expiry,
       (wi.expiration_date IS NOT NULL AND wi.expiration_date >= (now() AT TIME ZONE 'Asia/Dubai')::date) AS recoverable,
       wi.batch_id, wi.created_at
FROM public.warehouse_inventory wi
LEFT JOIN public.boonz_products bp ON bp.product_id = wi.boonz_product_id
WHERE wi.provenance_reason = 'unknown_pre_migration' AND wi.warehouse_stock > 0;
GRANT SELECT ON public.v_pending_legacy_quarantine TO authenticated, service_role;

-- (3) approve_return
CREATE OR REPLACE FUNCTION public.approve_return(p_wh_inventory_id uuid, p_approver_id uuid, p_note text,
                                                 p_corrected_expiry date DEFAULT NULL, p_corrected_qty numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_role text; v_uid uuid; v_before jsonb; v_after jsonb; v_row warehouse_inventory%ROWTYPE;
BEGIN
  v_uid := COALESCE(p_approver_id, auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'approve_return: forbidden for role % (inventory-manager only)', COALESCE(v_role,'unknown'); END IF;
  IF COALESCE(p_note,'') = '' OR length(trim(p_note)) < 4 THEN RAISE EXCEPTION 'approve_return: p_note required (min 4 chars)'; END IF;
  SELECT * INTO v_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'approve_return: wh_inventory_id % not found', p_wh_inventory_id; END IF;
  IF v_row.provenance_reason <> 'dispatch_return_unverified' AND v_row.provenance_reason <> 'unknown_pre_migration' THEN
    RAISE EXCEPTION 'approve_return: row provenance % is not a pending quarantine', v_row.provenance_reason; END IF;
  v_before := to_jsonb(v_row);
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','approve_return',true);
  PERFORM set_config('app.provenance_reason','dispatch_return',true);
  PERFORM set_config('app.mutation_reason', format('approve_return by %s: %s', v_uid, p_note), true);
  UPDATE public.warehouse_inventory
     SET provenance_reason = 'dispatch_return',
         expiration_date = COALESCE(p_corrected_expiry, expiration_date),
         warehouse_stock = COALESCE(p_corrected_qty, warehouse_stock)
   WHERE wh_inventory_id = p_wh_inventory_id;
  SELECT to_jsonb(w.*) INTO v_after FROM public.warehouse_inventory w WHERE wh_inventory_id = p_wh_inventory_id;
  INSERT INTO public.return_approval_log(wh_inventory_id, action, approver_id, approver_role, note, before_row, after_row)
  VALUES (p_wh_inventory_id, 'approve', v_uid, v_role, p_note, v_before, v_after);
  RETURN jsonb_build_object('status','approved','wh_inventory_id',p_wh_inventory_id,'now_pickable',true,
                            'corrected_expiry',p_corrected_expiry,'corrected_qty',p_corrected_qty);
END $fn$;
GRANT EXECUTE ON FUNCTION public.approve_return(uuid,uuid,text,date,numeric) TO authenticated, service_role;

-- (4) reject_return (ORIGINAL - superseded by the guard migration)
CREATE OR REPLACE FUNCTION public.reject_return(p_wh_inventory_id uuid, p_approver_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_role text; v_uid uuid; v_before jsonb; v_after jsonb; v_row warehouse_inventory%ROWTYPE; v_inact jsonb;
BEGIN
  v_uid := COALESCE(p_approver_id, auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'reject_return: forbidden for role % (inventory-manager only)', COALESCE(v_role,'unknown'); END IF;
  IF COALESCE(p_reason,'') = '' OR length(trim(p_reason)) < 4 THEN RAISE EXCEPTION 'reject_return: p_reason required (min 4 chars)'; END IF;
  SELECT * INTO v_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'reject_return: wh_inventory_id % not found', p_wh_inventory_id; END IF;
  v_before := to_jsonb(v_row);
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','reject_return',true);
  PERFORM set_config('app.mutation_reason', format('reject_return by %s: %s', v_uid, p_reason), true);
  UPDATE public.warehouse_inventory SET warehouse_stock = 0, disposal_reason = 'Waste' WHERE wh_inventory_id = p_wh_inventory_id;
  v_inact := public.inactivate_warehouse_row(p_wh_inventory_id, 'reject_return: '||p_reason, v_uid);
  SELECT to_jsonb(w.*) INTO v_after FROM public.warehouse_inventory w WHERE wh_inventory_id = p_wh_inventory_id;
  INSERT INTO public.return_approval_log(wh_inventory_id, action, approver_id, approver_role, note, before_row, after_row)
  VALUES (p_wh_inventory_id, 'reject', v_uid, v_role, p_reason, v_before, v_after);
  RETURN jsonb_build_object('status','rejected','wh_inventory_id',p_wh_inventory_id,'written_off',true,'inactivate',v_inact);
END $fn$;
GRANT EXECUTE ON FUNCTION public.reject_return(uuid,uuid,text) TO authenticated, service_role;

-- (5) WS-5 cron alert fn
CREATE OR REPLACE FUNCTION public.cron_pending_return_alert(p_days integer DEFAULT 3)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $fn$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM public.v_pending_return_approvals WHERE age_days >= p_days;
  IF v_n > 0 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('prd098_pending_return_backlog', CASE WHEN v_n >= 20 THEN 'warn' ELSE 'info' END,
            jsonb_build_object('pending_over_days', p_days, 'count', v_n, 'checked_at', now()));
  END IF;
  RETURN jsonb_build_object('pending_over_days', p_days, 'count', v_n);
END $fn$;
GRANT EXECUTE ON FUNCTION public.cron_pending_return_alert(integer) TO authenticated, service_role;

COMMENT ON FUNCTION public.approve_return(uuid,uuid,text,date,numeric) IS 'PRD-098: inventory-manager approves a quarantined return -> provenance_reason=dispatch_return (quarantined generated-flips false => pickable). Sanctioned warehouse_stock/expiration writer for the corrected-at-approval case. Audited.';
COMMENT ON FUNCTION public.reject_return(uuid,uuid,text) IS 'PRD-098: inventory-manager rejects a quarantined return -> drain warehouse_stock=0 + canonical inactivate_warehouse_row. Audited.';
