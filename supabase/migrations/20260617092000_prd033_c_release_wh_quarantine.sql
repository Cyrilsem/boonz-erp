-- PRD-033 Phase C (R3): release_wh_quarantine - canonical RPC to release benign quarantine
-- so good, Active, in-date stock becomes pickable, replacing the off-path guarded direct
-- UPDATE used on 2026-06-17.
--
-- warehouse_inventory.quarantined is GENERATED:
--   provenance_reason IS NULL OR provenance_reason IN ('unknown_pre_migration','dispatch_return_unverified')
-- so a row is quarantined only for those two provenance values (or NULL). Setting
-- provenance_reason='manual_adjust' (already in BOTH provenance CHECK constraints, and NOT in
-- the quarantining set) flips quarantined -> false, making the row visible to v_wh_pickable.
-- We use 'manual_adjust' rather than adding a new enum value, so no CHECK constraint change.
--
-- New DEFINER writer of warehouse_inventory (protected). Role-gated warehouse/operator_admin.
-- Sets app.via_rpc + app.rpc_name (the detect_silent_warehouse_inventory_write trigger trusts
-- an in-flight RPC; the generic tg_audit_warehouse_inventory:audit_log_write records it). Does
-- NOT set app.provenance_reason GUC, so set_warehouse_inventory_provenance leaves our explicit
-- SET value intact. No stock/status change (so it never trips the silent-reactivation pattern).
-- Reason >= 10 chars; stamped into app.mutation_reason for the audit, like reactivate_warehouse_row.

CREATE OR REPLACE FUNCTION public.release_wh_quarantine(
  p_wh_inventory_id uuid,
  p_reason          text,
  p_verified_by     uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.warehouse_inventory%ROWTYPE;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['warehouse','operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'forbidden: release_wh_quarantine requires warehouse, operator_admin, or superadmin';
  END IF;

  IF p_wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'release_wh_quarantine: p_wh_inventory_id is required';
  END IF;
  IF COALESCE(p_reason, '') = '' OR length(p_reason) < 10 THEN
    RAISE EXCEPTION 'release_wh_quarantine: p_reason is required (>= 10 chars; what was verified)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'release_wh_quarantine', true);
  PERFORM set_config('app.mutation_reason',
    format('release_wh_quarantine by %s: %s',
      COALESCE(p_verified_by::text, COALESCE(auth.uid()::text, 'system')), p_reason),
    true);

  SELECT * INTO v_row FROM public.warehouse_inventory
  WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'release_wh_quarantine: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  IF NOT v_row.quarantined THEN
    RETURN jsonb_build_object(
      'status', 'noop', 'wh_inventory_id', p_wh_inventory_id,
      'message', 'row is not quarantined',
      'provenance_reason', v_row.provenance_reason);
  END IF;

  -- Release: set a verified, non-quarantining provenance. Stock/status unchanged.
  UPDATE public.warehouse_inventory
     SET provenance_reason = 'manual_adjust'
   WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'status', 'released',
    'wh_inventory_id', p_wh_inventory_id,
    'boonz_product_id', v_row.boonz_product_id,
    'old_provenance_reason', v_row.provenance_reason,
    'new_provenance_reason', 'manual_adjust',
    'now_quarantined', false,
    'wh_status', v_row.status,
    'expiration_date', v_row.expiration_date,
    'verified_by', p_verified_by,
    'reason', p_reason,
    'note', 'pickable only if Active, in-date, stock>0 (governed by v_wh_pickable)');
END $function$;
