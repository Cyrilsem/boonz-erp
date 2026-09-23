-- PRD-130 F3 remainder: receive_dispatch_line must not touch the warehouse ledger for an
-- intra-machine move, and protect_packed_dispatch_row root-cause check.
--
-- NOT APPLIED YET. Touches receive_dispatch_line -- under the window rule, only runs after
-- 22:00 Dubai. This file was never written when PRD-130 first shipped (01, 02, 05, 06, 08, 09,
-- 10 all applied that morning); F3's remaining requirement on receive_dispatch_line specifically
-- needed the after-22:00 window and was deferred. Drafted now, CS confirmed 2026-09-23 (Dubai
-- 08:00) to add it to tonight's batch.
--
-- Root cause confirmed against live code before writing anything (per the standing rule):
-- receive_dispatch_line's current body checks ONLY `COALESCE(v_dispatch.is_m2m, false)` to skip
-- the warehouse draw/credit -- in three places: the rc07 fill-gate exemption, the Refill/Add New
-- consumer/warehouse-draw branch, and the Remove warehouse-credit branch. It has NO awareness of
-- source_kind='intra_machine' at all. add_intra_machine_move (PRD-130 F5) creates both its Remove
-- and Add New legs WITHOUT setting is_m2m (column default is false, confirmed live), only
-- source_kind='intra_machine'. Because no intra_machine dispatch could even be INSERTed until
-- prd130_11 fixed refill_dispatching_source_kind_chk earlier today, this gap has not yet caused a
-- live incident -- but the first intra-machine move ever received today would have drawn from or
-- credited the warehouse ledger for what is purely a shelf-to-shelf move within one machine.
--
-- SECOND finding, from testing the first draft of this fix in a rolled-back transaction (per the
-- standing rule): a live PRD-113 guard, `tg_block_internal_move_credit` (calling
-- `is_internal_move_dispatch`), unconditionally blocks any `action='Remove'` row from ever
-- reaching `item_added=true` when its heuristic detects a same-machine Remove+AddNew pair on the
-- same dispatch_date/boonz_product_id, regardless of source_kind -- it does not know about
-- `source_kind='intra_machine'` at all, but its general-purpose "MC-2004 shape" branch (Remove +
-- same-product Add New on another shelf of the same machine, same date) matches an intra_machine
-- pair anyway. This means an intra-machine Remove leg can NEVER be receive_dispatch_line'd to
-- item_added=true through any fix inside receive_dispatch_line itself -- that guard fires first,
-- on every writer, by design ("This guard is on the credit EVENT, so it holds for every writer").
-- Confirmed the guard's WHEN clause is scoped to `new.action = 'Remove'` only, so it never touches
-- an Add New row -- meaning receiving the Add New leg is unaffected and always was going to work.
--
-- This changes the fix's shape: rather than trying to make BOTH intra-machine legs independently
-- receivable (the M2M cross-machine pattern), only the Add New leg is ever received. It already
-- credits its own to-shelf pod_inventory correctly once the warehouse-touch is skipped (unchanged,
-- unconditional logic already in the function). The one thing genuinely missing: F5's own text
-- says "the Remove leg moves the pod lot from the from-shelf to the to-shelf... The Add New leg's
-- item_added=true is what triggers it" -- since the Remove leg can never independently trigger its
-- own from-shelf archive (blocked, and per add_intra_machine_move it is created already
-- packed=true/dispatched=true/picked_up=true/item_added=false, a permanent shadow record), the
-- Add New leg's own receive must ALSO archive the paired Remove leg's from-shelf pod_inventory row
-- (found via the shared m2m_transfer_id), not just credit its own to-shelf. Added as a new,
-- source_kind='intra_machine'-scoped block in the Refill/Add New branch, after the existing
-- to-shelf credit logic; nothing else in the function changes shape.
--
-- Fix, final shape: every place that currently checks is_m2m to skip the warehouse touch also
-- checks source_kind IN ('m2m','truck_transfer','intra_machine') -- exactly the set F3's own text
-- names (this still matters for the fill-gate exemption and, defensively, for the Remove branch's
-- own v_path labeling even though that branch's item_added UPDATE can never actually complete for
-- an intra_machine row). Plus the new from-shelf archive block described above, Add New branch only.
--
-- Smoke test (rolled back, 2026-09-23): synthetic intra_machine pair on WAVEMAKER-1006-4100-O1,
-- Remove leg on A01, Add New leg on A03, shared m2m_transfer_id. Called receive_dispatch_line ONLY
-- on the Add New leg's dispatch_id (per the design above -- the Remove leg is never called).
-- Result: no exception (confirming the PRD-113 guard correctly leaves Add New legs alone), A03
-- pod_inventory credited to current_stock=1/status=Active, A01 pod_inventory correctly archived to
-- status=Inactive. Green.
--
-- protect_packed_dispatch_row root-cause check: F3's text also asks this trigger to "exempt rows
-- with pack_outcome='no_pack_needed' from the packed lock for the specific columns quantity,
-- expiry_date, skipped and cancelled". Read the live trigger body before writing anything: it
-- currently locks only boonz_product_id, pod_product_id, machine_id, shelf_id, and dispatch_date
-- on a packed=true row -- it does NOT lock quantity, expiry_date, skipped, or cancelled at all,
-- for any row, packed or not. The root cause as literally stated does not hold: there is nothing
-- to exempt because nothing currently blocks those four columns. No change made to this
-- function, per the standing instruction not to invent a fix for a root cause that does not hold.

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
  v_no_wh_touch boolean;
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
  -- PRD-130 F3: no_wh_touch covers m2m, truck_transfer, and intra_machine -- any leg whose
  -- pairing (same machine or a different one) handles the other side, so this side must never
  -- touch the warehouse ledger.
  v_no_wh_touch := COALESCE(v_dispatch.is_m2m, false)
                    OR v_dispatch.source_kind IN ('m2m','truck_transfer','intra_machine');
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
    PERFORM public.log_expiry_entry_suspect('receive_dispatch_line', v_dispatch.dispatch_date,
      v_effective_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
        'boonz_product_id', v_dispatch.boonz_product_id, 'action', v_dispatch.action));
  END IF;
  PERFORM set_config('app.mutation_reason', format('B3 receive: dispatch %s — filled %s / planned %s by %s (breakdown=%s, effective_expiry=%s)', p_dispatch_id, p_filled_quantity, v_planned, COALESCE(p_received_by::text, 'system'), p_batch_breakdown IS NOT NULL, v_effective_expiry), true);
  v_is_fill := v_dispatch.action IN ('Refill','Add New','Add') AND NOT v_no_wh_touch;
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
   IF NOT v_no_wh_touch THEN
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
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
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
     v_path := CASE WHEN v_dispatch.source_kind = 'intra_machine' THEN 'add_intra_no_wh_draw' ELSE 'add_m2m_no_wh_draw' END;
   END IF;
    IF p_filled_quantity > 0 THEN
      UPDATE pod_inventory
         SET current_stock = current_stock + p_filled_quantity,
             estimated_remaining = current_stock + p_filled_quantity,
             snapshot_at = now()
       WHERE machine_id = v_dispatch.machine_id AND shelf_id = v_dispatch.shelf_id
         AND boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
         AND ((expiration_date = v_effective_expiry) OR (expiration_date IS NULL AND v_effective_expiry IS NULL))
       RETURNING pod_inventory_id INTO v_pod_id;
      IF NOT FOUND THEN
        INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date,
          current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at)
        VALUES (v_dispatch.machine_id, v_dispatch.shelf_id, v_dispatch.boonz_product_id, CURRENT_DATE,
          p_filled_quantity, p_filled_quantity, v_effective_expiry,
          format('DISPATCH-%s', v_dispatch.dispatch_date), 'Active', now(), now())
        RETURNING pod_inventory_id INTO v_pod_id;
      END IF;
      v_prior_active_merged := 0;
    END IF;
    -- PRD-130 F5/F3: an intra-machine Add New leg's own receive must also archive the paired
    -- Remove leg's from-shelf pod lot -- that leg can never independently reach item_added=true
    -- (blocked by the PRD-113 internal-move-credit guard, by design), so this is the only place
    -- the from-shelf side of the move can happen.
    IF v_dispatch.source_kind = 'intra_machine' AND v_dispatch.m2m_transfer_id IS NOT NULL THEN
      UPDATE pod_inventory
         SET status = 'Inactive',
             removal_reason = format('intra_machine_move_via_dispatch_%s', p_dispatch_id)
       WHERE machine_id = v_dispatch.machine_id
         AND boonz_product_id = v_dispatch.boonz_product_id
         AND status = 'Active'
         AND shelf_id = (
           SELECT rd2.shelf_id FROM refill_dispatching rd2
           WHERE rd2.m2m_transfer_id = v_dispatch.m2m_transfer_id
             AND rd2.action = 'Remove'
             AND rd2.dispatch_id <> p_dispatch_id
           LIMIT 1
         );
    END IF;
  ELSIF v_dispatch.action = 'Remove' THEN
    v_path := 'remove_single_expiry';
    SELECT source_of_supply INTO v_supply FROM public.product_mapping
     WHERE boonz_product_id = v_dispatch.boonz_product_id AND status = 'Active'
       AND (machine_id = v_dispatch.machine_id OR is_global_default)
     ORDER BY (machine_id = v_dispatch.machine_id) DESC, is_global_default ASC LIMIT 1;
    IF v_no_wh_touch THEN
      v_path := CASE WHEN v_dispatch.source_kind = 'intra_machine' THEN 'remove_intra_no_wh_credit' ELSE 'remove_m2m_no_wh_credit' END;
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
          PERFORM public.log_expiry_entry_suspect('receive_dispatch_line_breakdown', v_dispatch.dispatch_date,
            v_entry_expiry, jsonb_build_object('dispatch_id', p_dispatch_id, 'machine_id', v_dispatch.machine_id,
              'boonz_product_id', v_dispatch.boonz_product_id));
          SELECT * INTO v_existing_row FROM warehouse_inventory WHERE boonz_product_id = v_dispatch.boonz_product_id AND warehouse_id = v_target_wh AND status = 'Active' AND expiration_date = v_entry_expiry ORDER BY created_at ASC LIMIT 1 FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory SET warehouse_stock = COALESCE(warehouse_stock, 0) + v_entry_qty WHERE wh_inventory_id = v_existing_row.wh_inventory_id;
            v_credit_summary := v_credit_summary || jsonb_build_object('wh_inventory_id', v_existing_row.wh_inventory_id, 'expiry', v_entry_expiry, 'qty', v_entry_qty, 'mode', 'existing');
          ELSE
            PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
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
          PERFORM set_config('app.provenance_reason', CASE WHEN v_dispatch.wh_approved_at IS NOT NULL THEN 'dispatch_receive' ELSE 'dispatch_return_unverified' END, true);
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
         remainder_credited = true,
         pack_outcome = CASE
           WHEN v_dispatch.action IN ('Refill','Add New','Add') AND NOT v_no_wh_touch
             THEN (CASE WHEN p_filled_quantity < v_planned THEN 'partial' ELSE 'packed' END)::public.pack_outcome_enum
           ELSE pack_outcome
         END
   WHERE dispatch_id = p_dispatch_id;
  RETURN jsonb_build_object('dispatch_id', p_dispatch_id, 'action', v_dispatch.action, 'filled_quantity', p_filled_quantity, 'planned_quantity', v_planned, 'return_delta', v_return_delta, 'overfill', v_overfill, 'pod_inventory_id', v_pod_id, 'pod_archived', v_pod_archived, 'prior_active_merged', v_prior_active_merged, 'consumer_drained', v_consumer_drawn, 'path', v_path, 'effective_expiry', v_effective_expiry, 'received_by', p_received_by, 'credit_summary', v_credit_summary, 'overfill_debits', v_overfill_debits, 'wh_credit_skipped', CASE WHEN COALESCE(v_dispatch.is_m2m,false) THEN 'm2m' WHEN v_dispatch.source_kind = 'intra_machine' THEN 'intra_machine' WHEN v_dispatch.source_kind = 'truck_transfer' THEN 'truck_transfer' WHEN v_supply = 'venue_team' THEN 'venue_team' ELSE NULL END, 'status', 'received');
END;
$function$;
