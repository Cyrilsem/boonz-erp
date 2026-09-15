-- ONE-LOOP-2 Block C addition (PRD-124 #11): expiry capture at pick.
--
-- set_wh_batch_expiry(wh_inventory_id, expiration_date, reason, caller,
-- dry_run) writes a batch's expiration_date exactly once, only when it is
-- currently NULL -- a non-null date is changed through adjust_warehouse_stock
-- elsewhere, never here. Allowed roles: warehouse, field_staff, manager,
-- operator_admin, superadmin (this is captured by whoever is physically
-- looking at the batch -- a driver at the machine, warehouse staff on
-- receipt -- not manager-only like warehouse_inventory.status, Article 6).
--
-- No blocking canonical-writer allowlist exists for warehouse_inventory the
-- way enforce_canonical_dispatch_write gates refill_dispatching --
-- detect_silent_warehouse_inventory_write only watches one specific
-- Inactive->Active reactivation pattern and does not block anything.
-- app.via_rpc/app.rpc_name are still set, per Article 4, and the new
-- wh_batch_expiry_audit_log table is the audit trail this write needs,
-- since the generic auto_audit_warehouse_inventory trigger only fires on
-- warehouse_stock/consumer_stock changes, never on expiration_date alone.
--
-- enforce_warehouse_expiry_sanity (existing trigger) provides the real hard
-- ceiling: created_at + 3 years, tighter in most cases than this RPC's own
-- 5-year check for a batch created recently. Both checks run; the trigger's
-- is not touched or loosened.
CREATE TABLE IF NOT EXISTS public.wh_batch_expiry_audit_log (
  audit_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wh_inventory_id      uuid NOT NULL,
  old_expiration_date  date,
  new_expiration_date  date NOT NULL,
  changed_by           uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reason               text NOT NULL,
  changed_at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.wh_batch_expiry_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wh_batch_expiry_audit_select ON public.wh_batch_expiry_audit_log;
CREATE POLICY wh_batch_expiry_audit_select ON public.wh_batch_expiry_audit_log
  FOR SELECT TO authenticated USING (true);

-- S-308: a new table in public is born writable by authenticated. Revoke
-- the write verbs explicitly; only this SECURITY DEFINER RPC writes here.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.wh_batch_expiry_audit_log FROM authenticated;
GRANT SELECT ON public.wh_batch_expiry_audit_log TO authenticated;

CREATE OR REPLACE FUNCTION public.set_wh_batch_expiry(
  p_wh_inventory_id uuid,
  p_expiration_date date,
  p_reason text,
  p_caller uuid DEFAULT auth.uid(),
  p_dry_run boolean DEFAULT true
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_row public.warehouse_inventory%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'set_wh_batch_expiry', true);

  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','field_staff','manager','operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'forbidden: set_wh_batch_expiry requires warehouse, field_staff, manager, operator_admin, or superadmin';
  END IF;

  IF p_wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'set_wh_batch_expiry: p_wh_inventory_id is required';
  END IF;
  IF p_expiration_date IS NULL THEN
    RAISE EXCEPTION 'set_wh_batch_expiry: p_expiration_date is required';
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'set_wh_batch_expiry: p_reason is required';
  END IF;
  IF p_expiration_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'set_wh_batch_expiry: expiration_date % is before today', p_expiration_date;
  END IF;
  IF p_expiration_date > CURRENT_DATE + interval '5 years' THEN
    RAISE EXCEPTION 'set_wh_batch_expiry: expiration_date % is more than 5 years out', p_expiration_date;
  END IF;

  SELECT * INTO v_row FROM public.warehouse_inventory
   WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_wh_batch_expiry: no such wh_inventory_id %', p_wh_inventory_id;
  END IF;
  IF v_row.expiration_date IS NOT NULL THEN
    RAISE EXCEPTION 'set_wh_batch_expiry: batch % already has expiration_date % -- use adjust_warehouse_stock to change an existing date, not this RPC', p_wh_inventory_id, v_row.expiration_date;
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'status', 'dry_run_ok',
      'wh_inventory_id', p_wh_inventory_id,
      'would_set_expiration_date', p_expiration_date,
      'batch', to_jsonb(v_row)
    );
  END IF;

  UPDATE public.warehouse_inventory
     SET expiration_date = p_expiration_date
   WHERE wh_inventory_id = p_wh_inventory_id;

  INSERT INTO public.wh_batch_expiry_audit_log
    (wh_inventory_id, old_expiration_date, new_expiration_date, changed_by, reason)
  VALUES
    (p_wh_inventory_id, NULL, p_expiration_date, v_user_id, trim(p_reason));

  SELECT * INTO v_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'wh_inventory_id', p_wh_inventory_id,
    'batch', to_jsonb(v_row)
  );
END;
$function$;

-- Nightly alert, 21:30 UTC: every Active, non-quarantined batch with stock
-- and no expiration_date. Zero rows means no alert.
CREATE OR REPLACE FUNCTION public.cron_wh_batch_no_expiry_alert()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n integer;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'wh_inventory_id', wi.wh_inventory_id,
           'warehouse_id',    wi.warehouse_id,
           'boonz_product_id', wi.boonz_product_id,
           'batch_id',        wi.batch_id,
           'units',           wi.warehouse_stock
         )), '[]'::jsonb), COUNT(*)
    INTO v_rows, v_n
    FROM public.warehouse_inventory wi
   WHERE wi.status = 'Active'
     AND COALESCE(wi.quarantined, false) = false
     AND COALESCE(wi.warehouse_stock, 0) > 0
     AND wi.expiration_date IS NULL;

  IF v_n > 0 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('wh_batch_no_expiry', 'warning', jsonb_build_object(
      'title', format('%s Active warehouse batch(es) with no expiry set', v_n),
      'count', v_n, 'rows', v_rows, 'detected_at', now()));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'batches_missing_expiry', v_n);
END;
$function$;

SELECT cron.schedule('wh_batch_no_expiry_alert', '30 21 * * *',
  $cron$SELECT public.cron_wh_batch_no_expiry_alert();$cron$);
