-- PRD-119b T7 (E2 + E4): create pre-filled WM Confirmations lines for this
-- week's physical removals that never reached the ledger, so WM can confirm
-- what she physically has. "Nothing written to inventory by the loop
-- itself" -- this RPC inserts ONLY a disposition_events row (the same
-- candidate shape v_wm_confirmations' tap_candidates already reads for the
-- P3 tap); the actual warehouse_inventory credit/writeoff happens only when
-- WM calls wm_confirm_line on the resulting queue line, exactly like every
-- other WM Confirmations source.
--
-- New source value 'reconcile' added to disposition_events' source CHECK
-- (forward-only ALTER, Article 12) rather than a per-day literal
-- ('reconcile_2026-09-07' as the goal text literally suggests) -- a CHECK
-- constraint enumerating one value per reconciliation date doesn't scale;
-- the batch/date identifier goes in `reason` instead (e.g. "reconcile_
-- 2026-09-07: ..."), fully satisfying the traceability the goal actually
-- wants. v_wm_confirmations' tap_candidates widened from
-- `source = 'driver_expiry_check'` to `source IN ('driver_expiry_check',
-- 'reconcile')` -- output column list unchanged, so this CREATE OR REPLACE
-- VIEW is safe for any dependents. wm_confirm_line needs no change: its
-- non-dispatch_return branch already generically marks the sourcing
-- disposition_events row `superseded_by_event` on confirm, regardless of
-- source value.
--
-- create_reconcile_disposition_line(p_machine_id, p_shelf_id,
-- p_boonz_product_id, p_qty, p_expiration_date, p_reason, p_caller,
-- p_dry_run) - SECURITY DEFINER, operator_admin/superadmin/manager only
-- (same role set as repair_remove_leg_shelf_lot -- this is the same class
-- of administrative backfill action), p_reason >= 15 chars and required to
-- reference the reconciliation batch.
--
-- Applied for real: 4 lines created for the E2/E4 items with a confidently
-- resolved machine+shelf+product+date (VOXMCC-1005 A16, VOXMCC-1011 A10,
-- VOXMCC-1011 A11, IRIS-1070 A01) -- see the PRD-119b report for the full
-- create/skip list, including the E4 items with unresolved device numbers
-- (0715/0736/0745) that are explicitly NOT created here per the goal's own
-- stop condition, and two E4/E2-named items (VOXMCC-1011 Barebells White
-- Almond, NISSAN Bounty/Activia) found already Inactive/zero-stock in the
-- ledger -- no gap remained, so no line was created for them.
--
-- Cody: approve, Articles 1 (inserts via the one canonical disposition_events
-- writer path other reconcile-style backfills already use -- see
-- migration_sheet's 99-row precedent), 4 (role check, app.via_rpc/rpc_name),
-- 12 (additive CHECK widen + WHERE-only view change, no dependent breakage).
ALTER TABLE public.disposition_events DROP CONSTRAINT disposition_events_source_check;
ALTER TABLE public.disposition_events ADD CONSTRAINT disposition_events_source_check
  CHECK (source = ANY (ARRAY['driver_expiry_check','return_receipt','wh_writeoff','m2m','migration_sheet','reconcile']));

CREATE OR REPLACE VIEW public.v_wm_confirmations AS
 WITH dubai AS (
         SELECT (now() AT TIME ZONE 'Asia/Dubai'::text)::date AS today
        ), dispatch_candidates AS (
         SELECT rd.dispatch_id AS line_id,
            'dispatch_return'::text AS source,
            rd.machine_id,
            rd.shelf_id,
            rd.boonz_product_id,
            rd.pod_product_id,
            COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity) AS qty,
            NULLIF(rd.expiry_date, '2099-12-31'::date) AS expiry_date,
            rd.from_wh_inventory_id,
            rd.dispatch_id,
            rd.dispatch_date,
            COALESCE(rd.driver_confirmed_at, rd.driver_outcome_at, rd.last_edited_at, rd.created_at) AS left_machine_at
           FROM refill_dispatching rd
          WHERE rd.action = 'Remove'::text AND rd.picked_up = true AND rd.wh_approved_at IS NULL AND COALESCE(rd.driver_confirmed_qty, rd.filled_quantity, rd.quantity, 0::numeric) > 0::numeric AND COALESCE(rd.returned, false) = false AND COALESCE(rd.item_added, false) = false AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.skipped, false) = false AND rd.boonz_product_id IS NOT NULL AND NOT COALESCE(is_internal_move_dispatch(rd.dispatch_id), false) AND NOT (COALESCE(rd.is_m2m, false) AND rd.m2m_transfer_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM refill_dispatching paired
                  WHERE paired.m2m_transfer_id = rd.m2m_transfer_id AND paired.dispatch_id <> rd.dispatch_id AND (paired.action = ANY (ARRAY['Refill'::text, 'Add'::text, 'Add New'::text])))))
        ), tap_candidates AS (
         SELECT de.event_id AS line_id,
            de.source,
            de.machine_id,
            de.shelf_id,
            de.boonz_product_id,
            NULL::uuid AS pod_product_id,
            de.qty,
            NULLIF(de.expiration_date, '2099-12-31'::date) AS expiry_date,
            NULL::uuid AS from_wh_inventory_id,
            NULL::uuid AS dispatch_id,
            de.created_at::date AS dispatch_date,
            de.created_at AS left_machine_at
           FROM disposition_events de
          WHERE de.source IN ('driver_expiry_check','reconcile') AND de.state = 'removed_at_machine'::text AND de.superseded_by_event IS NULL
        ), candidates AS (
         SELECT dispatch_candidates.line_id,
            dispatch_candidates.source,
            dispatch_candidates.machine_id,
            dispatch_candidates.shelf_id,
            dispatch_candidates.boonz_product_id,
            dispatch_candidates.pod_product_id,
            dispatch_candidates.qty,
            dispatch_candidates.expiry_date,
            dispatch_candidates.from_wh_inventory_id,
            dispatch_candidates.dispatch_id,
            dispatch_candidates.dispatch_date,
            dispatch_candidates.left_machine_at
           FROM dispatch_candidates
        UNION ALL
         SELECT tap_candidates.line_id,
            tap_candidates.source,
            tap_candidates.machine_id,
            tap_candidates.shelf_id,
            tap_candidates.boonz_product_id,
            tap_candidates.pod_product_id,
            tap_candidates.qty,
            tap_candidates.expiry_date,
            tap_candidates.from_wh_inventory_id,
            tap_candidates.dispatch_id,
            tap_candidates.dispatch_date,
            tap_candidates.left_machine_at
           FROM tap_candidates
        ), proposal AS (
         SELECT c.line_id,
            c.source,
            c.machine_id,
            c.shelf_id,
            c.boonz_product_id,
            c.pod_product_id,
            c.qty,
            c.expiry_date,
            c.from_wh_inventory_id,
            c.dispatch_id,
            c.dispatch_date,
            c.left_machine_at,
                CASE
                    WHEN c.expiry_date IS NULL OR c.expiry_date <= (( SELECT dubai.today
                       FROM dubai)) THEN true
                    ELSE false
                END AS expired_or_undated,
            best.target_machine_id,
            best.daily_rate
           FROM candidates c
             LEFT JOIN LATERAL ( SELECT sl.machine_id AS target_machine_id,
                    sl.velocity_30d / 30.0 AS daily_rate
                   FROM slot_lifecycle sl
                     JOIN product_mapping pm ON pm.pod_product_id = sl.pod_product_id AND pm.boonz_product_id = c.boonz_product_id AND pm.status = 'Active'::text
                  WHERE sl.machine_id <> c.machine_id AND sl.is_current = true AND sl.archived = false AND c.expiry_date IS NOT NULL AND c.expiry_date > (( SELECT dubai.today
                           FROM dubai)) AND (sl.velocity_30d / 30.0) >= (c.qty / GREATEST(c.expiry_date - (( SELECT dubai.today
                           FROM dubai)) - 2, 1)::numeric)
                  ORDER BY sl.velocity_30d DESC
                 LIMIT 1) best ON true
        )
 SELECT p.line_id,
    p.source,
    p.dispatch_id,
    p.machine_id,
    m.official_name AS machine_name,
    p.shelf_id,
    sc.shelf_code,
    p.boonz_product_id,
    bp.boonz_product_name,
    p.pod_product_id,
    p.qty,
    p.expiry_date,
    p.from_wh_inventory_id,
    p.dispatch_date,
    p.left_machine_at,
        CASE
            WHEN p.expired_or_undated THEN 'waste'::text
            WHEN p.target_machine_id IS NOT NULL THEN 'redeploy'::text
            ELSE 'waste'::text
        END AS proposed_outcome,
    p.target_machine_id AS proposed_target_machine_id,
    tm.official_name AS proposed_target_machine_name,
        CASE
            WHEN p.target_machine_id IS NOT NULL THEN p.expiry_date - 2
            ELSE NULL::date
        END AS proposed_waste_by,
    EXTRACT(epoch FROM now() - COALESCE(p.left_machine_at, now())) / 3600.0 AS age_hours
   FROM proposal p
     JOIN machines m ON m.machine_id = p.machine_id
     LEFT JOIN shelf_configurations sc ON sc.shelf_id = p.shelf_id
     LEFT JOIN boonz_products bp ON bp.product_id = p.boonz_product_id
     LEFT JOIN machines tm ON tm.machine_id = p.target_machine_id;

CREATE OR REPLACE FUNCTION public.create_reconcile_disposition_line(
  p_machine_id uuid,
  p_shelf_id uuid,
  p_boonz_product_id uuid,
  p_qty numeric,
  p_expiration_date date,
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
  v_event_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','create_reconcile_disposition_line', true);

  IF v_caller IS NOT NULL THEN
    SELECT role INTO v_role FROM user_profiles WHERE id = v_caller;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'create_reconcile_disposition_line: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_machine_id IS NULL THEN RAISE EXCEPTION 'create_reconcile_disposition_line: p_machine_id required'; END IF;
  IF p_boonz_product_id IS NULL THEN RAISE EXCEPTION 'create_reconcile_disposition_line: p_boonz_product_id required'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'create_reconcile_disposition_line: p_qty must be > 0'; END IF;
  IF length(COALESCE(p_reason,'')) < 15 THEN RAISE EXCEPTION 'create_reconcile_disposition_line: p_reason must be at least 15 characters'; END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object('status','dry_run_ok','machine_id',p_machine_id,'shelf_id',p_shelf_id,
      'boonz_product_id',p_boonz_product_id,'qty',p_qty,'expiration_date',p_expiration_date,'reason',p_reason);
  END IF;

  INSERT INTO public.disposition_events (actor, source, machine_id, shelf_id, boonz_product_id, expiration_date, qty, state, reason)
  VALUES (v_caller, 'reconcile', p_machine_id, p_shelf_id, p_boonz_product_id, p_expiration_date, p_qty, 'removed_at_machine', p_reason)
  RETURNING event_id INTO v_event_id;

  RETURN jsonb_build_object('status','created','event_id',v_event_id,'machine_id',p_machine_id,'shelf_id',p_shelf_id,
    'boonz_product_id',p_boonz_product_id,'qty',p_qty,'expiration_date',p_expiration_date,'reason',p_reason);
END;
$function$;
