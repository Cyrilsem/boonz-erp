-- PRD-113 A9 — restore receive_dispatch_line byte-for-byte, and enforce the invariant by
--                COMPOSITION instead of by editing it.
--
-- ⛔ A7 EDITED receive_dispatch_line. Golden fixture 26 seq 14 pins `left(md5(prosrc),8)` of
-- that function to `28195f57`, with this description:
--
--     "the incumbent receive_dispatch_line is BYTE-FOR-BYTE UNCHANGED (md5 28195f57).
--      The whole design rests on composing it, not editing it - Cody condition 1 is void
--      the moment this moves."
--
-- That is PRD-110's ratified Cody condition for the spot-buy design
-- (receive_dispatch_line_sourced_v3 composes this function rather than replacing it). It is
-- not mine to waive, and re-baselining another unit's pin to make my own sweep green would be
-- precisely the wrong move. A7's function edit is therefore REVERTED here, verbatim.
--
-- The invariant does NOT go away with it. It moves to where it always belonged: a table-level
-- guard on the credit EVENT rather than on one function that happens to cause it.
--
--   BEFORE UPDATE ON refill_dispatching
--   WHEN (NEW.item_added = true AND OLD.item_added IS DISTINCT FROM true AND NEW.action = 'Remove')
--
-- This is strictly BETTER than the A7 edit, not a concession:
--   • it covers every caller of receive_dispatch_line, present and future, plus a direct
--     PostgREST call, which an in-function guard on one writer never could;
--   • it survives receive_dispatch_line being rewritten by a later PRD;
--   • it composes rather than edits, which is the very principle fixture 26 protects.
--
-- SCOPE, deliberately narrow. The trigger fires only on the item_added credit event for a
-- Remove leg. It does NOT police `returned = true`: return_dispatch_line already refuses an
-- in-machine move in A8, and it does so with a structured refusal object rather than a RAISE,
-- so bulk callers (eod_auto_release_unpicked, release_stale_unpacked_dispatches) keep
-- working. A RAISE on `returned` would have turned a nightly cron into a hard failure the
-- first time it met one of these legs.
--
-- A7's OTHER change - the skip in receive_all_dispatches_for_machine - stays. That function
-- carries no pin, and the skip is what keeps the "Mark All" bulk action working instead of
-- dying on the first move leg.
--
-- Article 12: forward-only. ADDITIVE ONLY.

CREATE OR REPLACE FUNCTION public.receive_dispatch_line(p_dispatch_id uuid, p_filled_quantity numeric, p_received_by uuid DEFAULT NULL::uuid, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_override boolean DEFAULT false, p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_planned numeric; v_return_delta numeric; v_overfill numeric;
  v_consumer_row warehouse_inventory%ROWTYPE;
  v_wh_row warehouse_inventory%ROWTYPE;
  v_pod_id uuid; v_consumer_drawn numeric := 0; v_path text;
  v_target_wh uuid; v_pod_archived int := 0;
  v_breakdown_total numeric := 0;
  v_entry jsonb; v_entry_qty numeric; v_entry_expiry date; v_entry_wh_id uuid;
  v_existing_row warehouse_inventory%ROWTYPE;
  v_credit_summary jsonb := '[]'::jsonb;
  v_effective_expiry date;
  v_prior_active_merged int := 0;
  v_supply text;
  v_is_fill boolean;
  v_gate text;
  v_overfill_debits jsonb := '[]'::jsonb;
  v_fefo record;
  v_need numeric;
  v_take numeric;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'receive_dispatch_line', true);
  PERFORM set_config('app.provenance_reason', 'dispatch_receive', true);
  PERFORM set_config('app.source_event_id', p_dispatch_id::text, true);
  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.item_added = true THEN RAISE EXCEPTION 'Dispatch % already received', p_dispatch_id; END IF;
  IF p_filled_quantity < 0 THEN RAISE EXCEPTION 'filled_quantity cannot be negative'; END IF;
  v_planned := v_dispatch.quantity;
  v_return_delta := GREATEST(v_planned - p_filled_quantity, 0);
  v_overfill := GREATEST(p_filled_quantity - v_planned, 0);
  v_path := 'b2_fallback';
  v_target_wh := COALESCE(
    v_dispatch.from_warehouse_id,
    (SELECT primary_warehouse_id FROM public.machines WHERE machine_id = v_dispatch.machine_id));
  IF v_target_wh IS NULL THEN
    RAISE EXCEPTION 'receive_dispatch_line: cannot resolve credit warehouse for dispatch % (from_warehouse_id NULL and machine % has no primary_warehouse_id). Refusing to silently credit WH_CENTRAL.', p_dispatch_id, v_dispatch.machine_id;
  END IF;
  IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
    SELECT expiration_date INTO v_effective_expiry FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id;
  ELSE
    v_effective_expiry := v_dispatch.expiry_date;
  END IF;
  PERFORM set_config('app.mutation_reason', format('B3 receive: dispatch %s — filled %s / planned %s by %s (breakdown=%s, effective_expiry=%s)', p_dispatch_id, p_filled_quantity, v_planned, COALESCE(p_received_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
  v_is_fill := v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false);
  v_gate := COALESCE(refill_qa.flag('rc07_receive_gate'), 'off');
  IF v_is_fill AND v_gate = 'on'
     AND NOT (COALESCE(v_dispatch.packed, false) AND COALESCE(v_dispatch.picked_up, false)) THEN
    IF p_override IS TRUE AND COALESCE(NULLIF(btrim(p_override_reason), ''), '') <> '' THEN
      PERFORM set_config('app.receive_override_reason', p_override_reason, true);
      PERFORM set_config('app.mutation_reason',
        format('B4 receive OVERRIDE: dispatch %s force-received unpacked (packed=%s picked_up=%s) reason: %s',
               p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false), p_override_reason), true);
    ELSE
      RAISE EXCEPTION 'receive_dispatch_line: dispatch % is not in a receivable state (packed=%, picked_up=%). A fill line must be PACKED and PICKED UP before receive. Pass p_override:=true with p_override_reason to force-receive (audited).',
        p_dispatch_id, COALESCE(v_dispatch.packed,false), COALESCE(v_dispatch.picked_up,false);
    END IF;
  END IF;
  IF v_dispatch.action IN ('Refill','Add New','Add') THEN
   IF NOT COALESCE(v_dispatch.is_m2m, false) THEN
    IF v_dispatch.from_wh_inventory_id IS NOT NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE wh_inventory_id = v_dispatch.from_wh_inventory_id FOR UPDATE;
      IF FOUND AND COALESCE(v_consumer_row.consumer_stock, 0) > 0 THEN v_path := 'b3_consumer_pinned'; ELSE v_consumer_row := NULL; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NULL THEN
      SELECT * INTO v_consumer_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND COALESCE(consumer_stock, 0) > 0 AND (reserved_for_machine_id = v_dispatch.machine_id OR reserved_for_machine_id IS NULL) AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (reserved_for_machine_id = v_dispatch.machine_id) DESC, consumer_stock DESC, reserved_at ASC LIMIT 1 FOR UPDATE;
      IF FOUND THEN v_path := 'b3_consumer_legacy'; END IF;
    END IF;
    IF v_consumer_row.wh_inventory_id IS NOT NULL THEN
      v_consumer_drawn := LEAST(p_filled_quantity, v_consumer_row.consumer_stock);
      UPDATE warehouse_inventory SET consumer_stock = GREATEST(COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta), 0), warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta, reserved_for_machine_id = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_for_machine_id END, reserved_at = CASE WHEN COALESCE(consumer_stock, 0) - (v_consumer_drawn + v_return_delta) <= 0 THEN NULL ELSE reserved_at END WHERE wh_inventory_id = v_consumer_row.wh_inventory_id;
    ELSE
      IF v_return_delta > 0 THEN
        SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY (expiration_date = v_effective_expiry) DESC NULLS LAST, created_at DESC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_wh_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND (expiration_date = v_effective_expiry OR v_effective_expiry IS NULL) ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_return_delta WHERE wh_inventory_id = v_wh_row.wh_inventory_id;
          ELSE
            PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_return_delta, v_effective_expiry, 'Active', format('RETURN-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
          END IF;
        END IF;
      END IF;
    END IF;
    IF v_overfill > 0 THEN
      v_need := v_overfill;
      FOR v_fefo IN
        SELECT f.wh_inventory_id, f.warehouse_stock, f.batch_id, f.expiration_date
        FROM public.wh_fefo_for_line(
               v_dispatch.machine_id, v_dispatch.boonz_product_id,
               COALESCE(v_dispatch.dispatch_date, CURRENT_DATE),
               v_overfill, ARRAY[v_target_wh]) f
        ORDER BY f.pick_rank
      LOOP
        EXIT WHEN v_need <= 0;
        v_take := LEAST(v_need, GREATEST(COALESCE(v_fefo.warehouse_stock,0), 0));
        IF v_take <= 0 THEN CONTINUE; END IF;
        UPDATE warehouse_inventory
           SET warehouse_stock = COALESCE(warehouse_stock, 0) - v_take
         WHERE wh_inventory_id = v_fefo.wh_inventory_id;
        v_overfill_debits := v_overfill_debits || jsonb_build_object(
          'wh_inventory_id', v_fefo.wh_inventory_id, 'batch_id', v_fefo.batch_id,
          'expiry', v_fefo.expiration_date, 'qty', v_take);
        v_need := v_need - v_take;
      END LOOP;
      IF v_need > 0 THEN
        RAISE EXCEPTION 'receive_dispatch_line: overfill of % unit(s) for boonz_product=% cannot be debited — warehouse % is short by % unit(s) across all pickable FEFO batches. Refusing to silently debit an arbitrary/zero row.',
          v_overfill, v_dispatch.boonz_product_id, v_target_wh, v_need;
      END IF;
    END IF;
   ELSE
     v_path := 'add_m2m_no_wh_draw';
   END IF;
    IF p_filled_quantity > 0 THEN
      WITH archived AS (UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text), snapshot_at = now() WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active' RETURNING current_stock, expiration_date), merge_stats AS (SELECT COALESCE(SUM(current_stock), 0)::numeric AS prior_qty, COUNT(*)::int AS prior_n, MIN(expiration_date) AS oldest_expiry FROM archived)
      INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at) SELECT v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE, p_filled_quantity + ms.prior_qty, p_filled_quantity + ms.prior_qty, LEAST(v_effective_expiry, COALESCE(ms.oldest_expiry, v_effective_expiry)), CASE WHEN ms.prior_n > 0 THEN format('MERGED-DISPATCH-%s', v_dispatch.dispatch_date) ELSE format('DISPATCH-%s', v_dispatch.dispatch_date) END, 'Active', now(), now() FROM merge_stats ms RETURNING pod_inventory_id INTO v_pod_id;
      SELECT prior_n INTO v_prior_active_merged FROM (SELECT COUNT(*)::int AS prior_n FROM pod_inventory WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Inactive' AND removal_reason = format('merged_into_dispatch_%s_%s', v_dispatch.dispatch_date, p_dispatch_id::text)) AS s;
    END IF;
  ELSIF v_dispatch.action = 'Remove' THEN
    v_path := 'remove_single_expiry';
    SELECT source_of_supply INTO v_supply FROM public.product_mapping
     WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
       AND (machine_id = v_dispatch.machine_id OR is_global_default)
     ORDER BY (machine_id = v_dispatch.machine_id) DESC, is_global_default ASC LIMIT 1;
    IF COALESCE(v_dispatch.is_m2m, false) THEN
      v_path := 'remove_m2m_no_wh_credit';
    ELSIF v_supply = 'venue_team' THEN
      v_path := 'remove_venue_team_no_wh_credit';
      INSERT INTO public.vox_return_log
        (dispatch_id, machine_id, boonz_product_id, qty, expiry_date, source_of_supply, received_by, reason)
      VALUES
        (p_dispatch_id, v_dispatch.machine_id, v_dispatch.boonz_product_id, p_filled_quantity,
         v_effective_expiry, v_supply, p_received_by,
         format('VOX venue_team REMOVE receipt; WH credit skipped (dispatch %s)', p_dispatch_id));
    ELSIF p_filled_quantity > 0 THEN
      IF p_batch_breakdown IS NOT NULL AND jsonb_typeof(p_batch_breakdown) = 'array' THEN
        v_path := 'remove_breakdown';
        SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total FROM jsonb_array_elements(p_batch_breakdown) e;
        IF v_breakdown_total <> p_filled_quantity THEN RAISE EXCEPTION 'Breakdown total (%) must equal filled_quantity (%)', v_breakdown_total, p_filled_quantity; END IF;
        FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown) LOOP
          v_entry_qty := (v_entry->>'qty')::numeric;
          IF v_entry_qty <= 0 THEN CONTINUE; END IF;
          v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;
          v_entry_wh_id := NULLIF(v_entry->>'wh_inventory_id', '')::uuid;
          IF v_entry_wh_id IS NOT NULL THEN
            SELECT * INTO v_existing_row FROM warehouse_inventory WHERE wh_inventory_id = v_entry_wh_id FOR UPDATE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Breakdown row id % not found', v_entry_wh_id; END IF;
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty, status = CASE WHEN status = 'Inactive' THEN 'Active' ELSE status END WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_existing_row.expiration_date, 'qty', v_entry_qty);
            CONTINUE;
          END IF;
          IF v_entry_expiry IS NULL THEN RAISE EXCEPTION 'Breakdown entry must include expiry or wh_inventory_id (got %)', v_entry; END IF;
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'existing');
          ELSE
            PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
            INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, v_entry_qty, v_entry_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh) RETURNING wh_inventory_id INTO v_entry_wh_id;
            PERFORM set_config('app.provenance_reason','dispatch_receive', true);
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_entry_wh_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'inserted');
          END IF;
        END LOOP;
      ELSIF v_effective_expiry IS NOT NULL THEN
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_effective_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          PERFORM set_config('app.provenance_reason','dispatch_return_unverified', true);
          INSERT INTO warehouse_inventory (boonz_product_id, warehouse_stock, expiration_date, status, batch_id, snapshot_date, warehouse_id) VALUES (v_dispatch.boonz_product_id, p_filled_quantity, v_effective_expiry, 'Active', format('REMOVE-RECEIVE-%s', v_dispatch.dispatch_date), CURRENT_DATE, v_target_wh);
          PERFORM set_config('app.provenance_reason','dispatch_receive', true);
        END IF;
      ELSE
        v_path := 'remove_fefo_fallback';
        SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date IS NOT NULL ORDER BY expiration_date ASC LIMIT 1 FOR UPDATE;
        IF FOUND THEN
          UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
        ELSE
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + p_filled_quantity WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
          ELSE
            RAISE EXCEPTION 'Cannot receive REMOVE dispatch %: effective_expiry is NULL and no Active warehouse_inventory row exists for boonz_product=%, warehouse=%. Pass p_batch_breakdown with explicit expiry.', p_dispatch_id, v_dispatch.boonz_product_id, v_target_wh;
          END IF;
        END IF;
      END IF;
    END IF;
    UPDATE pod_inventory SET status = 'Inactive', removal_reason = format('removed_via_dispatch_%s', p_dispatch_id) WHERE machine_id = v_dispatch.machine_id AND boonz_product_id = v_dispatch.boonz_product_id AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL) AND status = 'Active';
    GET DIAGNOSTICS v_pod_archived = ROW_COUNT;
  END IF;
  UPDATE refill_dispatching
     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,
         pack_outcome = CASE
           WHEN v_dispatch.action IN ('Refill','Add New','Add') AND NOT COALESCE(v_dispatch.is_m2m, false)
             THEN (CASE WHEN p_filled_quantity < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
           ELSE pack_outcome
         END
   WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'filled_quantity', p_filled_quantity, 'planned_quantity', v_planned, 'return_delta', v_return_delta, 'overfill', v_overfill, 'pod_inventory_id', v_pod_id, 'pod_archived', v_pod_archived, 'prior_active_merged', v_prior_active_merged, 'consumer_drained', v_consumer_drawn, 'path', v_path, 'effective_expiry', v_effective_expiry, 'received_by', p_received_by, 'credit_summary', v_credit_summary, 'overfill_debits', v_overfill_debits, 'wh_credit_skipped', CASE WHEN COALESCE(v_dispatch.is_m2m,false) THEN 'm2m' WHEN v_supply = 'venue_team' THEN 'venue_team' ELSE NULL END, 'status', 'received');
END;
$function$;


CREATE OR REPLACE FUNCTION public.tg_block_internal_move_credit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF COALESCE(public.is_internal_move_dispatch(NEW.dispatch_id), false) THEN
    RAISE EXCEPTION 'refill_dispatching: dispatch % is an INTERNAL MOVE and cannot be received/credited. These units moved to another shelf of the SAME machine (%) and never reached the warehouse; crediting them would create phantom warehouse stock. If this really is a warehouse return, call clear_internal_move_flag(%, <reason>) first.',
      NEW.dispatch_id, NEW.machine_id, NEW.dispatch_id
      USING HINT = 'PRD-113. This guard is on the credit EVENT, so it holds for every writer - wh_approve_remove_receipt, approve_stuck_remove, receive_dispatch_line and anything added later.';
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.tg_block_internal_move_credit() IS
  'PRD-113 A9. Table-level floor under the in-machine-move rule: a Remove leg the canonical '
  'predicate identifies as an in-machine move can never flip item_added = true, whatever '
  'writer tries. Exists as a trigger rather than an edit to receive_dispatch_line because '
  'golden fixture 26 seq 14 pins that function byte-for-byte (PRD-110 Cody condition: compose, '
  'do not edit) - and because a guard on the event covers callers a guard on one function '
  'cannot.';

DROP TRIGGER IF EXISTS trg_block_internal_move_credit ON public.refill_dispatching;
CREATE TRIGGER trg_block_internal_move_credit
BEFORE UPDATE ON public.refill_dispatching
FOR EACH ROW
WHEN (NEW.item_added = true
      AND COALESCE(OLD.item_added, false) = false
      AND NEW.action = 'Remove'
      AND COALESCE(NEW.is_m2m, false) = false)
EXECUTE FUNCTION public.tg_block_internal_move_credit();
