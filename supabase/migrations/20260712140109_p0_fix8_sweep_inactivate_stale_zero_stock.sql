-- P0 FIX8 (2026-07-12): one-shot + reusable sweep for STALE zero-stock Active
-- warehouse_inventory rows that propose_inactivate_on_zero_stock (AFTER UPDATE
-- trigger, fires only on non-zero->zero transitions) never caught. Mirrors the
-- trigger's sanctioned auto-confirm proposal pattern exactly (Amendment 002
-- precedent: zero-stock inactivation is auto-confirmed). Narrow concern under
-- Amendment 005. These stale rows are the feedstock of phantom FEFO batch picks
-- (incident 2026-07-12: Dubai Popcorn 2027-03-15 batch @ 0u forced into picker).
CREATE OR REPLACE FUNCTION public.sweep_inactivate_stale_zero_stock(p_reason text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE
  v_role text;
  v_swept int := 0;
  v_rows jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'sweep_inactivate_stale_zero_stock: role % not permitted', COALESCE(v_role,'(none)');
  END IF;

  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','sweep_inactivate_stale_zero_stock',true);

  WITH stale AS (
    SELECT wi.wh_inventory_id, wi.status AS current_status
    FROM public.warehouse_inventory wi
    WHERE wi.status = 'Active'
      AND COALESCE(wi.warehouse_stock,0) = 0
      AND COALESCE(wi.consumer_stock,0) = 0
      AND NOT EXISTS (
        SELECT 1 FROM public.warehouse_inventory_status_proposal p
        WHERE p.wh_inventory_id = wi.wh_inventory_id
          AND p.status IN ('pending','confirmed')
          AND p.proposed_status = 'Inactive'
          AND p.decided_at > wi.updated_at
      )
    FOR UPDATE OF wi
  ), ins AS (
    INSERT INTO public.warehouse_inventory_status_proposal (
      wh_inventory_id, current_status, proposed_status, reason,
      proposer_kind, proposer_name, status, decided_at, decision_note
    )
    SELECT s.wh_inventory_id, s.current_status, 'Inactive',
           COALESCE(p_reason, 'Stale zero-stock sweep: warehouse_stock and consumer_stock are zero but row stayed Active (missed by transition-only trigger). Propose Inactive.'),
           'rpc', 'sweep_inactivate_stale_zero_stock', 'confirmed', now(),
           'Auto-confirmed: zero-stock inactivation does not require manual approval'
    FROM stale s
    RETURNING wh_inventory_id
  ), upd AS (
    UPDATE public.warehouse_inventory wi
       SET status = 'Inactive'
      FROM ins
     WHERE wi.wh_inventory_id = ins.wh_inventory_id
    RETURNING wi.wh_inventory_id
  )
  SELECT count(*), COALESCE(jsonb_agg(wh_inventory_id),'[]'::jsonb)
    INTO v_swept, v_rows FROM upd;

  IF v_swept > 0 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('zero_stock_sweep','warning', jsonb_build_object(
      'title', format('sweep_inactivate_stale_zero_stock: %s stale Active zero-stock rows inactivated', v_swept),
      'rows', v_rows, 'swept_at', now()));
  END IF;

  RETURN jsonb_build_object('status','ok','swept', v_swept, 'wh_inventory_ids', v_rows);
END; $fn$;

REVOKE EXECUTE ON FUNCTION public.sweep_inactivate_stale_zero_stock(text) FROM anon;