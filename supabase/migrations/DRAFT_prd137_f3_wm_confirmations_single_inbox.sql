-- PRD-137 F3, drafted 2026-09-30 daytime, NOT YET APPLIED. Warehouse Confirmations single inbox.
--
-- Root cause (confirmed against real live rows, e.g. dispatch d9da3b7f-ed5b-4787-a6cf-91dab8e3724e,
-- traced during the 29 Sep incident): v_wm_confirmations only ever looked at action='Remove' rows.
-- A Refill/Add-New line that gets returned (driver never delivered it) is auto-credited to
-- warehouse_inventory by return_dispatch_line with ZERO warehouse review -- it never appears here
-- at all. Every one of these rows sitting live right now (`SELECT * FROM refill_dispatching WHERE
-- action IN ('Refill','Add New') AND returned=true AND wh_approved_at IS NULL` -- 8+ rows as of
-- 2026-09-30 daytime, none reviewed) is exactly this gap.
--
-- Scope built tonight: (1) the Refill/Add-return acknowledge-only branch, (2) the quarantined
-- REMOVE-RETURN batch branch (warehouse_inventory rows with provenance_reason =
-- 'dispatch_return_unverified', already sitting Active with real stock, never surfaced anywhere
-- for review), (3) hide qty <= 0 on every branch. Held for a follow-up, NOT built tonight: "M2M
-- legs that ended in WH" (cancel_m2m_transfer's p_convert_source_to_return path -- needs its own
-- read before touching, out of scope for a "never cut" night with G11/F1b/F4/A7 already ahead of
-- it) and "split by variant" (a real per-line UI/data-model change, same class of risk as the
-- driver-facing writers held under F5/A8 -- not something to improvise under time pressure).
--
-- wm_confirm_line gets two new source branches:
--   'refill_return_ack'  -- acknowledge only. Sets wh_approved_at/wh_approved_by on the dispatch
--                            row. NEVER credits warehouse_inventory again -- return_dispatch_line
--                            already did that at return time; this is purely the missing review
--                            step, not a second credit.
--   'quarantine_batch'   -- the stock is already sitting in warehouse_inventory (this IS that
--                            row); confirming it means WH has physically verified it, so this
--                            releases the quarantine (provenance_reason -> 'manual_adjust', same
--                            transition release_wh_quarantine already uses -- quarantined is a
--                            GENERATED column derived from provenance_reason, PRD-098) and logs a
--                            disposition_event. Also never credits warehouse_inventory again.
--
-- Rollback: supabase/rollback/DRAFT_prd137_f3_wm_confirmations_single_inbox_rollback.sql

CREATE OR REPLACE VIEW public.v_wm_confirmations AS
WITH dubai AS (
  SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today
),
dispatch_candidates AS (
  SELECT rd.dispatch_id AS line_id, 'dispatch_return'::text AS source,
    rd.machine_id, rd.shelf_id, rd.boonz_product_id, rd.pod_product_id,
    COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity) AS qty,
    NULLIF(rd.expiry_date, '2099-12-31'::date) AS expiry_date,
    rd.from_wh_inventory_id, rd.dispatch_id, rd.dispatch_date,
    COALESCE(rd.driver_confirmed_at, rd.driver_outcome_at, rd.last_edited_at, rd.created_at) AS left_machine_at
  FROM refill_dispatching rd
  WHERE rd.action = 'Remove'
    AND rd.picked_up = true
    AND rd.wh_approved_at IS NULL
    AND COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity, 0) > 0
    AND COALESCE(rd.returned, false) = false
    AND COALESCE(rd.item_added, false) = false
    AND COALESCE(rd.cancelled, false) = false
    AND COALESCE(rd.skipped, false) = false
    AND rd.boonz_product_id IS NOT NULL
    AND NOT COALESCE(is_internal_move_dispatch(rd.dispatch_id), false)
    AND NOT (COALESCE(rd.is_m2m, false) AND rd.m2m_transfer_id IS NOT NULL
             AND EXISTS (SELECT 1 FROM refill_dispatching paired
                          WHERE paired.m2m_transfer_id = rd.m2m_transfer_id
                            AND paired.dispatch_id <> rd.dispatch_id
                            AND paired.action = ANY (ARRAY['Refill','Add','Add New'])))
),
-- PRD-137 F3: Refill/Add-New lines that were never delivered and got returned, but never
-- reviewed by warehouse. return_dispatch_line already credited warehouse_inventory at return
-- time -- this branch exists purely so a human sees and acknowledges it happened.
refill_return_ack_candidates AS (
  -- return_dispatch_line's non-Remove branch always fully returns the line (there is no
  -- partial-return path for Refill/Add-New) and its own trailing UPDATE resets
  -- filled_quantity to 0 unconditionally -- so post-return, filled_quantity is never a
  -- reliable "amount actually credited" signal. rd.quantity (the original planned amount)
  -- is what return_dispatch_line actually credited: COALESCE(v_dispatch.filled_quantity,
  -- v_dispatch.quantity) read filled_quantity BEFORE that reset, and it is NULL (not 0)
  -- until a line is actually filled, so it resolved to the full planned quantity.
  SELECT rd.dispatch_id AS line_id, 'refill_return_ack'::text AS source,
    rd.machine_id, rd.shelf_id, rd.boonz_product_id, rd.pod_product_id,
    rd.quantity AS qty,
    NULLIF(rd.expiry_date, '2099-12-31'::date) AS expiry_date,
    rd.from_wh_inventory_id, rd.dispatch_id, rd.dispatch_date,
    COALESCE(rd.last_edited_at, rd.created_at) AS left_machine_at
  FROM refill_dispatching rd
  WHERE rd.action = ANY (ARRAY['Refill','Add','Add New'])
    AND COALESCE(rd.returned, false) = true
    AND rd.wh_approved_at IS NULL
    AND COALESCE(rd.quantity, 0) > 0
    AND COALESCE(rd.cancelled, false) = false
    AND rd.boonz_product_id IS NOT NULL
),
-- PRD-137 F3: quarantined REMOVE-RETURN batches -- already Active + stocked in
-- warehouse_inventory, never surfaced anywhere for a human to verify and release.
quarantine_candidates AS (
  SELECT wi.wh_inventory_id AS line_id, 'quarantine_batch'::text AS source,
    NULL::uuid AS machine_id, NULL::uuid AS shelf_id, wi.boonz_product_id, NULL::uuid AS pod_product_id,
    wi.warehouse_stock AS qty, NULLIF(wi.expiration_date, '2099-12-31'::date) AS expiry_date,
    NULL::uuid AS from_wh_inventory_id, NULL::uuid AS dispatch_id, wi.snapshot_date AS dispatch_date,
    wi.created_at AS left_machine_at
  FROM warehouse_inventory wi
  WHERE wi.provenance_reason = 'dispatch_return_unverified'
    AND wi.quarantined = true
    AND wi.status = 'Active'
    AND COALESCE(wi.warehouse_stock, 0) > 0
),
tap_candidates AS (
  SELECT de.event_id AS line_id, de.source, de.machine_id, de.shelf_id, de.boonz_product_id,
    NULL::uuid AS pod_product_id, de.qty, NULLIF(de.expiration_date, '2099-12-31'::date) AS expiry_date,
    NULL::uuid AS from_wh_inventory_id, NULL::uuid AS dispatch_id, de.created_at::date AS dispatch_date,
    de.created_at AS left_machine_at
  FROM disposition_events de
  WHERE de.source = ANY (ARRAY['driver_expiry_check','reconcile'])
    AND de.state = 'removed_at_machine'
    AND de.superseded_by_event IS NULL
    AND COALESCE(de.qty, 0) > 0
),
candidates AS (
  SELECT * FROM dispatch_candidates
  UNION ALL SELECT * FROM refill_return_ack_candidates
  UNION ALL SELECT * FROM quarantine_candidates
  UNION ALL SELECT * FROM tap_candidates
),
proposal AS (
  SELECT c.*,
    CASE WHEN c.expiry_date IS NULL OR c.expiry_date <= (SELECT today FROM dubai) THEN true ELSE false END AS expired_or_undated,
    best.target_machine_id, best.daily_rate
  FROM candidates c
  LEFT JOIN LATERAL (
    SELECT sl.machine_id AS target_machine_id, sl.velocity_30d / 30.0 AS daily_rate
    FROM slot_lifecycle sl
    JOIN product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = c.boonz_product_id AND pm.status = 'Active'
    WHERE sl.machine_id <> c.machine_id AND sl.is_current = true AND sl.archived = false
      AND c.expiry_date IS NOT NULL AND c.expiry_date > (SELECT today FROM dubai)
      AND (sl.velocity_30d / 30.0) >= (c.qty / GREATEST(c.expiry_date - (SELECT today FROM dubai) - 2, 1)::numeric)
    ORDER BY sl.velocity_30d DESC LIMIT 1
  ) best ON true
)
SELECT p.line_id, p.source, p.dispatch_id, p.machine_id, m.official_name AS machine_name,
  p.shelf_id, sc.shelf_code, p.boonz_product_id, bp.boonz_product_name, p.pod_product_id,
  p.qty, p.expiry_date, p.from_wh_inventory_id, p.dispatch_date, p.left_machine_at,
  CASE WHEN p.expired_or_undated THEN 'waste' WHEN p.target_machine_id IS NOT NULL THEN 'redeploy' ELSE 'waste' END AS proposed_outcome,
  p.target_machine_id AS proposed_target_machine_id, tm.official_name AS proposed_target_machine_name,
  CASE WHEN p.target_machine_id IS NOT NULL THEN p.expiry_date - 2 ELSE NULL END AS proposed_waste_by,
  EXTRACT(epoch FROM now() - COALESCE(p.left_machine_at, now())) / 3600.0 AS age_hours
FROM proposal p
LEFT JOIN machines m ON m.machine_id = p.machine_id
LEFT JOIN shelf_configurations sc ON sc.shelf_id = p.shelf_id
LEFT JOIN boonz_products bp ON bp.product_id = p.boonz_product_id
LEFT JOIN machines tm ON tm.machine_id = p.target_machine_id;

COMMENT ON VIEW public.v_wm_confirmations IS
  'PRD-137 F3: Warehouse Confirmations single inbox. Sources: dispatch_return (confirmed picked-up
   Removes), refill_return_ack (Refill/Add-New returns needing acknowledgment, already credited by
   return_dispatch_line), quarantine_batch (quarantined REMOVE-RETURN warehouse_inventory rows
   needing physical verification), driver_expiry_check/reconcile (disposition_events taps). All
   branches hide qty<=0. machine_id/shelf_id/pod_product_id/dispatch_id are NULL for the
   quarantine_batch source (it has no dispatch row -- line_id is the wh_inventory_id).';

CREATE OR REPLACE FUNCTION public.wm_confirm_line(p_line_id uuid, p_qty numeric, p_expiry date, p_outcome text, p_target_machine_id uuid DEFAULT NULL::uuid, p_disposal_code text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_caller uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  IF p_outcome NOT IN ('restocked','redeploy_pending','waste','acknowledged') THEN
    RAISE EXCEPTION 'wm_confirm_line: p_outcome must be restocked | redeploy_pending | waste | acknowledged (got %)', p_outcome; END IF;
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

  -- PRD-137 F3: acknowledge-only sources. Never credit warehouse_inventory again — the stock
  -- movement already happened (return_dispatch_line for refill_return_ack, or the row already
  -- exists for quarantine_batch). This confirmation step is the missing human review, nothing else.
  IF v_line.source IN ('refill_return_ack', 'quarantine_batch') THEN
    IF p_outcome <> 'acknowledged' THEN
      RAISE EXCEPTION 'wm_confirm_line: source % only accepts p_outcome=acknowledged (got %)', v_line.source, p_outcome;
    END IF;

    IF p_dry_run THEN
      RETURN jsonb_build_object('status', 'dry_run_ok', 'line_id', p_line_id, 'source', v_line.source,
        'boonz_product_id', v_line.boonz_product_id, 'qty', p_qty, 'outcome', 'acknowledged');
    END IF;

    IF v_line.source = 'refill_return_ack' THEN
      PERFORM public.set_write_context('wm_confirm_line',
        format('wm_confirm_line line=%s source=%s qty=%s outcome=acknowledged by=%s: %s',
          p_line_id, v_line.source, p_qty, COALESCE(v_user_id::text,'system'), p_reason),
        'dispatch_return', p_line_id::text);
      UPDATE public.refill_dispatching SET wh_approved_at = now(), wh_approved_by = v_user_id
       WHERE dispatch_id = p_line_id;
    ELSE
      -- quarantine_batch: same transition release_wh_quarantine uses, including its exact
      -- set_config call shape (via_rpc/rpc_name/mutation_reason only, no app.provenance_reason).
      -- A generic warehouse_inventory trigger stamps provenance_reason FROM the
      -- app.provenance_reason GUC when it's set, which would silently override this branch's
      -- own 'manual_adjust' value back to whatever set_write_context's 3rd arg says — confirmed
      -- in testing (using 'dispatch_return' there reverted this UPDATE's value on write).
      -- quarantined is a GENERATED column derived from provenance_reason (PRD-098); flipping
      -- provenance_reason releases it, no separate quarantined write.
      PERFORM set_config('app.via_rpc',  'true', true);
      PERFORM set_config('app.rpc_name', 'wm_confirm_line', true);
      PERFORM set_config('app.mutation_reason',
        format('wm_confirm_line line=%s source=quarantine_batch qty=%s outcome=acknowledged by=%s: %s',
          p_line_id, p_qty, COALESCE(v_user_id::text,'system'), p_reason), true);
      UPDATE public.warehouse_inventory SET provenance_reason = 'manual_adjust'
       WHERE wh_inventory_id = p_line_id;
    END IF;

    -- disposition_events.source and .state both have their own fixed-enum CHECK constraints
    -- that don't know about these two new v_wm_confirmations source names -- reuse
    -- source='return_receipt' and state='restocked' (the stock is already sitting in
    -- warehouse_inventory; acknowledging it is functionally the same terminal state as any
    -- other confirmed restock) and keep the real distinction in reason instead.
    INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason, dispatch_id, wh_inventory_id)
    VALUES (v_user_id, 'return_receipt', v_line.machine_id, v_line.shelf_id, v_line.boonz_product_id, p_expiry, p_qty,
      'restocked', format('[%s] %s', v_line.source, p_reason),
      CASE WHEN v_line.source = 'refill_return_ack' THEN p_line_id ELSE NULL END,
      CASE WHEN v_line.source = 'quarantine_batch' THEN p_line_id ELSE NULL END)
    RETURNING event_id INTO v_event_id;

    RETURN jsonb_build_object('status', 'confirmed', 'line_id', p_line_id, 'source', v_line.source,
      'event_id', v_event_id, 'outcome', 'acknowledged', 'qty', p_qty);
  END IF;

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

-- PRD-137 F3: 48h staleness alert for open Warehouse Confirmations lines, same shape as
-- check_stale_pending_reviews. Read-only check function; wiring a cron job to call it is held for
-- a follow-up (out of scope to add pg_cron changes on top of everything else tonight).
CREATE OR REPLACE FUNCTION public.check_stale_wm_confirmations()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_stale jsonb;
  v_count int;
BEGIN
  SELECT jsonb_agg(jsonb_build_object(
      'line_id', line_id, 'source', source, 'machine_name', machine_name, 'shelf_code', shelf_code,
      'boonz_product_name', boonz_product_name, 'qty', qty, 'age_hours', round(age_hours::numeric, 1)
    ) ORDER BY age_hours DESC),
    count(*)
  INTO v_stale, v_count
  FROM public.v_wm_confirmations
  WHERE age_hours > 48;

  IF v_count > 0 THEN
    INSERT INTO public.monitoring_alerts(source, severity, payload)
    VALUES ('wm_confirmations_stale', 'warning', jsonb_build_object(
      'title', format('%s Warehouse Confirmations line(s) open more than 48h', v_count),
      'count', v_count, 'lines', v_stale, 'detected_at', now()
    ));
  END IF;

  RETURN jsonb_build_object('stale_count', COALESCE(v_count, 0), 'lines', COALESCE(v_stale, '[]'::jsonb));
END;
$function$;
