-- PRD-114 §3.3 - day-close acknowledge learns the fourth outcome set.
--
-- This is the ONLY place in PRD-114 where pod_inventory is written, and it fires
-- only on CS's click. It adds no new write path: it calls
-- backfill_archive_pod_inventory_row, the existing manual write-off / archival
-- writer, which zeroes the batch and sets removal_reason.
--
--   Remove  -> archived, removal_reason 'expired_writeoff'
--   Sold    -> archived, removal_reason 'sold_through_<event_date>'
--   Exists  -> no stock write, verified_at stamped in the payload
--   Skip    -> no stock write, the row simply closes
--
-- Warehouse stock is untouched in all four: a batch that expired on a shelf
-- never comes back to WH, and a batch that sold was already revenue.
--
-- The substitution branch below is carried over BYTE-FOR-BYTE from PRD-112.
--
-- ROLE NOTE (Cody C-2): backfill_archive_pod_inventory_row is gated on
-- superadmin / operator_admin, while acknowledge admits 'manager' as well. Rather
-- than widen the archival gate or let a manager silently no-op a stock write,
-- a manager acknowledging a stock-moving expiry_check is refused BY NAME.

CREATE OR REPLACE FUNCTION public.acknowledge_day_close_event(p_event_id uuid, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller     uuid := (SELECT auth.uid());
  v_role       text;
  v_ev         public.day_close_events%ROWTYPE;
  v_row        public.refill_dispatching%ROWTYPE;
  v_machine    text;
  v_shelf_code text;
  v_prior      numeric := 0;
  v_target     numeric;
  v_pod_action text;
  v_pod_result jsonb := NULL;
  -- PRD-114
  v_outcome    text;
  v_pod_id     uuid;
  v_pod        public.pod_inventory%ROWTYPE;
  v_reason     text;
  v_extra      jsonb := '{}'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'acknowledge_day_close_event', true);

  IF p_event_id IS NULL THEN
    RAISE EXCEPTION 'acknowledge_day_close_event: p_event_id required';
  END IF;
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'acknowledge_day_close_event: anonymous caller refused';
  END IF;
  SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'acknowledge_day_close_event: role % not authorized (CS closes the day)', COALESCE(v_role,'none');
  END IF;

  SELECT * INTO v_ev FROM public.day_close_events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'acknowledge_day_close_event: event % not found', p_event_id;
  END IF;

  -- Idempotent: a second click is a no-op, not a second stock write.
  IF v_ev.acknowledged_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true, 'event_id', p_event_id, 'already_acknowledged', true,
      'acknowledged_at', v_ev.acknowledged_at, 'acknowledged_by', v_ev.acknowledged_by,
      'pod_action', v_ev.payload->>'pod_action');
  END IF;

  v_pod_action := 'not_applicable';

  IF v_ev.kind = 'substitution' AND v_ev.dispatch_id IS NOT NULL THEN
    SELECT * INTO v_row FROM public.refill_dispatching
     WHERE dispatch_id = v_ev.dispatch_id FOR UPDATE;

    SELECT m.official_name INTO v_machine FROM public.machines m WHERE m.machine_id = v_ev.machine_id;
    SELECT sc.shelf_code  INTO v_shelf_code FROM public.shelf_configurations sc WHERE sc.shelf_id = v_row.shelf_id;

    IF COALESCE(v_row.item_added, false) THEN
      -- receive_dispatch_line already merged these units under the NEW product.
      v_pod_action := 'already_credited_by_receive';
    ELSIF COALESCE(v_row.filled_quantity, 0) <= 0 THEN
      v_pod_action := 'no_qty_to_credit';
    ELSIF v_shelf_code IS NULL THEN
      v_pod_action := 'skipped_no_shelf_code';
    ELSE
      -- Article 16 note: v_live_shelf_stock is WEIMI-telemetry derived and keyed on
      -- pod_product_id; adjust_pod_inventory writes an absolute at ledger grain.
      -- This is a ledger read for a ledger write, as receive_dispatch_line does for
      -- its own prior_qty merge. Never displayed as a stock figure.
      SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_prior
      FROM public.pod_inventory pi
      WHERE pi.machine_id       = v_row.machine_id
        AND pi.shelf_id         = v_row.shelf_id
        AND pi.boonz_product_id = v_row.boonz_product_id
        AND pi.status           = 'Active';

      v_target := v_prior + v_row.filled_quantity;

      v_pod_result := public.adjust_pod_inventory(
        v_machine,
        v_ev.event_date,
        jsonb_build_array(jsonb_build_object(
          'boonz_product_id', v_row.boonz_product_id,
          'new_qty',          v_target,
          'shelf_code',       v_shelf_code,
          'expiration_date',  v_row.expiry_date)),
        format('PRD-112 day-close acknowledge of substitution %s: %s -> %s (+%s units)',
               p_event_id,
               COALESCE(v_ev.payload->>'old_boonz_product_name','?'),
               COALESCE(v_ev.payload->>'new_boonz_product_name','?'),
               v_row.filled_quantity));
      v_pod_action := 'adjusted';

      -- adjust_pod_inventory overwrote app.rpc_name with its own name. Re-assert ours
      -- so the canonical-writer guard is satisfied by THIS writer (S-160 family).
      PERFORM set_config('app.via_rpc',  'true', true);
      PERFORM set_config('app.rpc_name', 'acknowledge_day_close_event', true);
    END IF;

    IF COALESCE(v_row.needs_review, false) THEN
      UPDATE public.refill_dispatching
         SET needs_review = false,
             review_status = 'accepted',
             reviewed_by   = v_caller,
             reviewed_at   = now()
       WHERE dispatch_id = v_ev.dispatch_id;
    END IF;

  ELSIF v_ev.kind = 'expiry_check' THEN
    -- PRD-114 §3.3. Per row, via EXISTING canonical paths only.
    v_outcome := lower(COALESCE(v_ev.payload->>'outcome',''));
    v_pod_id  := NULLIF(v_ev.payload->>'pod_inventory_id','')::uuid;

    IF v_outcome IN ('remove','sold') THEN
      IF v_pod_id IS NULL THEN
        v_pod_action := 'no_pod_inventory_id_in_payload';
      ELSE
        -- The archival writer admits superadmin / operator_admin only. Refuse by
        -- name rather than escalate the caller or silently drop the write.
        IF v_role NOT IN ('operator_admin','superadmin') THEN
          RAISE EXCEPTION 'acknowledge_day_close_event: role % cannot acknowledge a stock-moving expiry_check (% needs operator_admin or superadmin, the backfill_archive_pod_inventory_row gate)',
            v_role, v_outcome;
        END IF;

        SELECT * INTO v_pod FROM public.pod_inventory
         WHERE pod_inventory_id = v_pod_id FOR UPDATE;

        IF NOT FOUND THEN
          v_pod_action := 'pod_row_missing';
        ELSIF v_pod.status = 'Inactive' THEN
          -- Someone already wrote this batch off (the manual flow, or the sweep).
          -- Re-archiving would overwrite a truer removal_reason with ours.
          v_pod_action := 'already_archived';
        ELSE
          v_reason := CASE WHEN v_outcome = 'remove'
                           THEN 'expired_writeoff'
                           ELSE 'sold_through_' || v_ev.event_date::text END;
          v_pod_result := public.backfill_archive_pod_inventory_row(
            v_pod_id, v_reason, NULL, v_caller);
          v_pod_action := CASE WHEN v_outcome = 'remove'
                               THEN 'expired_writeoff' ELSE 'sold_through' END;
          -- backfill_archive overwrote app.rpc_name with its own. Re-assert ours.
          PERFORM set_config('app.via_rpc',  'true', true);
          PERFORM set_config('app.rpc_name', 'acknowledge_day_close_event', true);
        END IF;
      END IF;

    ELSIF v_outcome = 'exists' THEN
      -- The driver looked and the batch is there. A fact, not a stock movement.
      v_pod_action := 'verified_no_write';
      v_extra := jsonb_build_object('verified_at', now(), 'verified_by', v_caller);

    ELSIF v_outcome = 'skip' THEN
      v_pod_action := 'skipped_no_write';

    ELSE
      v_pod_action := 'unknown_outcome';
    END IF;
  END IF;

  UPDATE public.day_close_events
     SET acknowledged_at = now(),
         acknowledged_by = v_caller,
         payload = payload || v_extra || jsonb_build_object(
           'pod_action',        v_pod_action,
           'pod_result',        v_pod_result,
           'acknowledge_note',  p_note)
   WHERE id = p_event_id;

  RETURN jsonb_build_object(
    'ok', true, 'event_id', p_event_id, 'already_acknowledged', false,
    'kind', v_ev.kind, 'pod_action', v_pod_action, 'pod_result', v_pod_result);
END
$function$;

COMMENT ON FUNCTION public.acknowledge_day_close_event(uuid, text) IS
  'PRD-112 §3.3 + PRD-114 §3.3. CS closes one day-close event. substitution credits pod_inventory via adjust_pod_inventory; expiry_check Remove/Sold archives the batch via backfill_archive_pod_inventory_row (removal_reason expired_writeoff / sold_through_<date>); Exists/Skip write no stock. Idempotent: a second acknowledge writes nothing.';
