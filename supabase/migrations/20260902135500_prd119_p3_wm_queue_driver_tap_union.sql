-- PRD-119 P3 §4.1: v_wm_confirmations gains a second source — driver expiry-check
-- REMOVE taps (open disposition_events rows, state=removed_at_machine, source=
-- driver_expiry_check, not yet superseded). These have no dispatch line at all; the
-- goods physically left the shelf at the tap, and this is the WM's first sight of them.
--
-- The view's key column generalizes from dispatch_id to line_id (event_id for
-- tap-sourced rows, dispatch_id for dispatch-sourced rows) — DROP + CREATE rather than
-- CREATE OR REPLACE since the new leading column can't be appended cleanly; confirmed
-- no other view/function holds a hard pg_depend dependency on the old shape.
--
-- wm_confirm_line matches on line_id and branches its close-out write on source:
-- dispatch_return stamps refill_dispatching.wh_approved_at (unchanged); driver_
-- expiry_check chains the original removed_at_machine row via superseded_by_event to
-- the new state row it just wrote — disposition_events stays append-only (the UPDATE
-- runs as the DEFINER function owner, not as `authenticated`, so the S-308 REVOKE on
-- that table is never bypassed by an FE caller).
--
-- Verified end-to-end on real data: driver tap creates an open queue line tagged
-- source=driver_expiry_check; WM confirms it (warehouse credit + disposition write +
-- queue close); a second confirm attempt on the same line is correctly refused
-- (idempotent); a real dispatch-return line confirmed cleanly through the unchanged
-- branch (regression check).
--
-- Cody: approve, Articles 1/7/12/16 — append-only preserved via DEFINER-only UPDATE,
-- single canonical queue object, no orphaned dependents from the DROP+CREATE.
DROP VIEW IF EXISTS public.v_wm_confirmations;
CREATE VIEW public.v_wm_confirmations AS
WITH dubai AS (SELECT (now() AT TIME ZONE 'Asia/Dubai'::text)::date AS today),
dispatch_candidates AS (
  SELECT rd.dispatch_id AS line_id, 'dispatch_return'::text AS source,
    rd.machine_id, rd.shelf_id, rd.boonz_product_id, rd.pod_product_id,
    COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity) AS qty,
    NULLIF(rd.expiry_date, '2099-12-31'::date) AS expiry_date,
    rd.from_wh_inventory_id, rd.dispatch_id, rd.dispatch_date,
    COALESCE(rd.driver_confirmed_at, rd.driver_outcome_at, rd.last_edited_at, rd.created_at) AS left_machine_at
  FROM public.refill_dispatching rd
  WHERE rd.action = 'Remove' AND rd.picked_up = true AND rd.wh_approved_at IS NULL
    AND COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity, 0) > 0
    AND COALESCE(rd.returned, false) = false AND COALESCE(rd.item_added, false) = false
    AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.skipped, false) = false
    AND rd.boonz_product_id IS NOT NULL
    AND NOT COALESCE(public.is_internal_move_dispatch(rd.dispatch_id), false)
    AND NOT (COALESCE(rd.is_m2m, false) AND rd.m2m_transfer_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.refill_dispatching paired WHERE paired.m2m_transfer_id = rd.m2m_transfer_id
        AND paired.dispatch_id <> rd.dispatch_id AND paired.action IN ('Refill','Add','Add New')))
),
tap_candidates AS (
  SELECT de.event_id AS line_id, 'driver_expiry_check'::text AS source,
    de.machine_id, de.shelf_id, de.boonz_product_id, NULL::uuid AS pod_product_id,
    de.qty, NULLIF(de.expiration_date, '2099-12-31'::date) AS expiry_date,
    NULL::uuid AS from_wh_inventory_id, NULL::uuid AS dispatch_id, de.created_at::date AS dispatch_date,
    de.created_at AS left_machine_at
  FROM public.disposition_events de
  WHERE de.source = 'driver_expiry_check' AND de.state = 'removed_at_machine' AND de.superseded_by_event IS NULL
),
candidates AS ( SELECT * FROM dispatch_candidates UNION ALL SELECT * FROM tap_candidates ),
proposal AS (
  SELECT c.*,
    CASE WHEN c.expiry_date IS NULL OR c.expiry_date <= (SELECT today FROM dubai) THEN true ELSE false END AS expired_or_undated,
    best.target_machine_id, best.daily_rate
  FROM candidates c
  LEFT JOIN LATERAL (
    SELECT sl.machine_id AS target_machine_id, (sl.velocity_30d / 30.0) AS daily_rate
    FROM public.slot_lifecycle sl
    JOIN public.product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = c.boonz_product_id AND pm.status = 'Active'
    WHERE sl.machine_id <> c.machine_id AND sl.is_current = true AND sl.archived = false
      AND c.expiry_date IS NOT NULL AND c.expiry_date > (SELECT today FROM dubai)
      AND (sl.velocity_30d / 30.0) >= (c.qty / GREATEST((c.expiry_date - (SELECT today FROM dubai)) - 2, 1))
    ORDER BY sl.velocity_30d DESC LIMIT 1
  ) best ON true
)
SELECT
  p.line_id, p.source, p.dispatch_id, p.machine_id, m.official_name AS machine_name, p.shelf_id, sc.shelf_code,
  p.boonz_product_id, bp.boonz_product_name, p.pod_product_id,
  p.qty, p.expiry_date, p.from_wh_inventory_id, p.dispatch_date, p.left_machine_at,
  CASE WHEN p.expired_or_undated THEN 'waste' WHEN p.target_machine_id IS NOT NULL THEN 'redeploy' ELSE 'waste' END AS proposed_outcome,
  p.target_machine_id AS proposed_target_machine_id, tm.official_name AS proposed_target_machine_name,
  CASE WHEN p.target_machine_id IS NOT NULL THEN p.expiry_date - 2 ELSE NULL END AS proposed_waste_by,
  (EXTRACT(EPOCH FROM (now() - COALESCE(p.left_machine_at, now()))) / 3600.0) AS age_hours
FROM proposal p
JOIN public.machines m ON m.machine_id = p.machine_id
LEFT JOIN public.shelf_configurations sc ON sc.shelf_id = p.shelf_id
LEFT JOIN public.boonz_products bp ON bp.product_id = p.boonz_product_id
LEFT JOIN public.machines tm ON tm.machine_id = p.target_machine_id;

DO $guard$ BEGIN
  IF (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p WHERE p.proname='wm_confirm_line' AND p.pronamespace='public'::regnamespace) <> '8920d75c363f408f7aa20581ded66a0b' THEN
    RAISE EXCEPTION 'wm_confirm_line drifted, refusing blind replace';
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION public.wm_confirm_line(
  p_line_id uuid, p_qty numeric, p_expiry date, p_outcome text,
  p_target_machine_id uuid DEFAULT NULL::uuid, p_disposal_code text DEFAULT NULL::text,
  p_reason text DEFAULT NULL::text, p_caller uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_role text; v_line record; v_target_wh uuid; v_existing warehouse_inventory%ROWTYPE;
  v_wh_inventory_id uuid; v_credited_mode text; v_state text; v_waste_by date;
  v_value_aed numeric; v_event_id uuid;
BEGIN
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN RAISE EXCEPTION 'forbidden: wm_confirm_line requires warehouse, operator_admin, superadmin, or manager'; END IF;
  IF p_line_id IS NULL THEN RAISE EXCEPTION 'wm_confirm_line: p_line_id is required'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'wm_confirm_line: p_qty must be > 0'; END IF;
  IF p_outcome NOT IN ('restocked','redeploy_pending','waste') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_outcome must be restocked | redeploy_pending | waste (got %)', p_outcome; END IF;
  IF p_expiry IS NOT NULL AND p_expiry = '2099-12-31'::date THEN
    RAISE EXCEPTION 'wm_confirm_line: p_expiry cannot be the 2099-12-31 sentinel — supply the real batch date or NULL'; END IF;
  IF p_outcome = 'waste' AND COALESCE(p_disposal_code,'') = '' THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code is required when p_outcome=waste'; END IF;
  IF p_disposal_code IS NOT NULL AND p_disposal_code NOT IN ('Waste','Returning to supplier','Returned to supplier') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_disposal_code must be Waste|Returning to supplier|Returned to supplier (got %)', p_disposal_code; END IF;
  IF p_outcome = 'redeploy_pending' AND (p_target_machine_id IS NULL OR p_expiry IS NULL) THEN
    RAISE EXCEPTION 'wm_confirm_line: redeploy_pending requires p_target_machine_id and p_expiry'; END IF;
  IF COALESCE(p_reason,'') = '' THEN RAISE EXCEPTION 'wm_confirm_line: p_reason is required'; END IF;

  SELECT * INTO v_line FROM public.v_wm_confirmations WHERE line_id = p_line_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'wm_confirm_line: % is not an open Warehouse Confirmations line', p_line_id; END IF;

  v_target_wh := (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_line.machine_id);
  IF v_target_wh IS NULL THEN RAISE EXCEPTION 'wm_confirm_line: machine % has no primary_warehouse_id', v_line.machine_id; END IF;
  SELECT avg_cost INTO v_value_aed FROM public.boonz_products WHERE product_id = v_line.boonz_product_id;
  v_value_aed := v_value_aed * p_qty;
  v_state := p_outcome;
  v_waste_by := CASE WHEN p_outcome = 'redeploy_pending' THEN p_expiry - 2 ELSE NULL END;

  IF p_dry_run THEN
    RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source, 'machine_id', v_line.machine_id,
      'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
      'target_warehouse_id', v_target_wh, 'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed);
  END IF;

  PERFORM public.set_write_context('wm_confirm_line',
    format('wm_confirm_line line=%s source=%s qty=%s expiry=%s outcome=%s by=%s: %s',
      p_line_id, v_line.source, p_qty, p_expiry, p_outcome, COALESCE(v_user_id::text,'system'), p_reason),
    CASE WHEN p_outcome = 'waste' THEN 'expiry_writeoff' ELSE 'dispatch_return' END, p_line_id::text);

  SELECT * INTO v_existing FROM public.warehouse_inventory
   WHERE boonz_product_id = v_line.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active'
     AND ((expiration_date = p_expiry) OR (expiration_date IS NULL AND p_expiry IS NULL))
   ORDER BY created_at ASC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    v_credited_mode := 'topped_up'; v_wh_inventory_id := v_existing.wh_inventory_id;
    UPDATE public.warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock,0) + p_qty,
      reserved_for_machine_id = CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE reserved_for_machine_id END
     WHERE wh_inventory_id = v_wh_inventory_id;
  ELSE
    v_credited_mode := 'inserted';
    INSERT INTO public.warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id, reserved_for_machine_id)
    VALUES (v_line.boonz_product_id, p_qty, p_expiry, 'Active', format('WM-CONFIRM-%s', p_line_id), CURRENT_DATE, v_target_wh,
      CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END)
    RETURNING wh_inventory_id INTO v_wh_inventory_id;
  END IF;

  IF p_outcome = 'waste' THEN PERFORM public.warehouse_expire_writeoff(v_wh_inventory_id, p_reason, v_user_id, p_disposal_code); END IF;

  INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state,
     disposal_code, target_machine_id, waste_by, value_aed, reason, dispatch_id, wh_inventory_id)
  VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, p_expiry, p_qty, v_state,
     CASE WHEN p_outcome = 'waste' THEN p_disposal_code ELSE NULL END,
     CASE WHEN p_outcome = 'redeploy_pending' THEN p_target_machine_id ELSE NULL END,
     v_waste_by, v_value_aed, p_reason, v_line.dispatch_id, v_wh_inventory_id)
  RETURNING event_id INTO v_event_id;

  IF v_line.source = 'dispatch_return' THEN
    UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id WHERE dispatch_id = p_line_id;
  ELSE
    UPDATE public.disposition_events SET superseded_by_event = v_event_id WHERE event_id = p_line_id;
  END IF;

  RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source, 'event_id', v_event_id,
    'wh_inventory_id', v_wh_inventory_id, 'credited_mode', v_credited_mode,
    'qty', p_qty, 'expiry', p_expiry, 'outcome', p_outcome,
    'target_machine_id', p_target_machine_id, 'waste_by', v_waste_by, 'value_aed', v_value_aed);
END $function$;
