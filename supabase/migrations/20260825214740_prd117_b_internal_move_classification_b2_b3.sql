-- PRD-117 item B (T1.1): same-machine transfers are unclassifiable and sometimes
-- unapprovable. Ships B2 + B3 ONLY tonight; B1 explicitly HELD (see below).
--
-- B1 HELD: add_dispatch_row's proposed fix (only set is_m2m=true for a genuinely
-- different source machine) is blocked by a pre-existing CHECK constraint,
-- m2m_consistency, which requires source_kind IN ('m2m','truck_transfer') to
-- imply is_m2m = true, unconditionally. The mistagging is therefore structural
-- (schema-mandated), not a writer bug - B1 needs a constraint redesign, folded
-- into PRD-116 item K2's source_kind cleanup as a Tier 3 / Dara design item.
--
-- B2, corrected from the original PRD-117 spec after live verification: the naive
-- `source_kind='m2m' AND source_machine_id=machine_id` signal is UNINFORMATIVE
-- for any row created by convert_removes_to_m2m_transfer, genuine or not - that
-- writer sets source_machine_id to the Remove leg's OWN machine on both legs by
-- construction (PRD-116 item K2), so the check is trivially true for every m2m
-- Remove leg, not just same-machine ones. Verified live 2026-08-25: of 69 open
-- Remove-side rows matching the naive signal, 55 are genuine same-machine bugs
-- and 10 (corrected after fixing a JOIN fan-out double-count that had it at 14)
-- are genuine cross-machine redirects, same shape as the already-settled
-- canonical fixture dispatch 194d55ad (JET->OMDBB Vitamin Well, 24 Aug). The
-- only reliable signal is the PAIRED leg's machine, found via m2m_transfer_id.
-- New branch: same-machine AND (no pairing exists at all - the original
-- add_dispatch_row-shaped bug, currently zero rows - OR the paired Add leg is
-- on the SAME machine) -> true. Paired Add leg on a DIFFERENT machine -> falls
-- through to the unchanged is_m2m branch -> false, correctly routing genuine
-- redirects to approve_m2m_transfer instead of blocking them.
--
-- B3: wh_approve_remove_receipt and wh_approve_remove_receipt_multivariant
-- reordered so is_internal_move_dispatch is checked BEFORE the is_m2m raise -
-- without this, B2 is invisible to both writers (they'd raise the M2M message
-- for a genuine same-machine mistag before ever calling the classifier).
--
-- Known limitation, recorded not fixed (theoretical today, zero affected rows):
-- a driver-split child of a genuine cross-machine redirect Remove leg
-- (insert_driver_remove_line, PRD-116b) would inherit source_kind='m2m' +
-- source_machine_id=machine_id with m2m_transfer_id NULL - insert_driver_remove_line
-- does not copy transfer ids from its parent - and would classify TRUE
-- incorrectly under this fix, same as the genuine no-pairing case. Today this
-- population is empty: conversion to m2m (convert_removes_to_m2m_transfer)
-- happens after driver confirm, and driver splits happen at confirm time, so
-- the two never currently coincide. Belongs in the item-B/K2 Tier 3 design.
--
-- Verified live 2026-08-25 in rolled-back transactions, five cases plus the
-- original assertions:
--   194d55ad (settled genuine cross-machine)      -> false (correct, unchanged)
--   93ee43ad (open genuine cross-machine)          -> false (correct)
--   03a16aa9 (open genuine same-machine, Remove)   -> true  (correct)
--   ca5276ef (open genuine same-machine, Add-side) -> false (correct: action<>'Remove'
--                                                     branch is unchanged and fires first)
--   hypothetical NULL-transfer_id same-machine row -> true by direct code
--     inspection of the new branch's OR clause (no live row exists to test)
--   5 known mistagged Remove rows (original PRD-117 sample)          -> all true
--   wh_approve_remove_receipt on a genuine same-machine row          -> raises INTERNAL MOVE
--   wh_approve_remove_receipt on a genuine cross-machine row         -> raises the M2M
--     message (routes to approve_m2m_transfer), NOT internal move
-- Re-verified against LIVE prod (not just rolled-back) immediately after apply.
--
-- Index check: idx_dispatch_m2m_transfer / idx_rd_internal_move_pair (partial,
-- WHERE is_m2m=true) already exist and are used by the query plan (confirmed via
-- EXPLAIN ANALYZE on v_pending_wh_remove_confirmations, 118ms baseline, index
-- scans not seq scans). Two near-duplicate indexes exist
-- (idx_dispatch_m2m_transfer and idx_rd_m2m_transfer, identical definitions) -
-- redundant but harmless, noted as a Tier 3 housekeeping item, not fixed here.
--
-- Cody: Approve, B2+B3 only. Articles 1, 4, 8, 12, 16 - no schema change, no new
-- write path, read-only classifier + existing-writer guard reorder only.
-- Applied to prod via MCP 2026-08-25.

CREATE OR REPLACE FUNCTION public.is_internal_move_dispatch(p_dispatch_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    -- Cody condition 5. A human has ruled this leg a genuine warehouse return. That ruling
    -- outranks every heuristic below and is never re-litigated.
    WHEN rd.internal_move_cleared_at IS NOT NULL THEN false
    -- Already stamped: the writers' answer wins, and CS can stamp by hand.
    WHEN COALESCE(rd.is_internal_move, false) THEN true
    -- Only a Remove leg can be an in-machine move.
    WHEN rd.action <> 'Remove' THEN false
    -- PRD-117 B2: source_machine_id = machine_id is trivially true for EVERY m2m
    -- Remove leg (convert_removes_to_m2m_transfer sets it that way on both legs
    -- by construction), genuine cross-machine redirect or not. The only reliable
    -- ground truth is the PAIRED leg's machine: no pairing at all, or the paired
    -- Add leg lands on this same machine, means the units never left it.
    WHEN rd.source_kind = 'm2m' AND rd.source_machine_id = rd.machine_id AND (
      rd.m2m_transfer_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.refill_dispatching paired
        WHERE paired.m2m_transfer_id = rd.m2m_transfer_id
          AND paired.dispatch_id <> rd.dispatch_id
          AND paired.action IN ('Refill', 'Add', 'Add New')
          AND paired.machine_id = rd.machine_id
      )
    ) THEN true
    -- is_m2m is the DIFFERENT-machine transfer. It has its own approval path
    -- (approve_m2m_transfer) and its own guard; never claim it here.
    WHEN COALESCE(rd.is_m2m, false) THEN false
    -- The MC-2004 shape: the removed product reappears as an Add New on ANOTHER shelf of
    -- the SAME machine in the SAME plan. Those units are moving, not returning.
    ELSE EXISTS (
      SELECT 1
      FROM public.refill_dispatching add_leg
      WHERE add_leg.machine_id       = rd.machine_id
        AND add_leg.dispatch_date    = rd.dispatch_date
        AND add_leg.action           IN ('Add New', 'Add')
        AND add_leg.shelf_id IS DISTINCT FROM rd.shelf_id
        AND COALESCE(add_leg.cancelled, false) = false
        AND COALESCE(add_leg.skipped,   false) = false
        AND COALESCE(add_leg.include,   true)  = true
        AND (
              -- same flavour lands on another shelf
              add_leg.boonz_product_id = rd.boonz_product_id
              -- PRD-113b: multi-flavour shelf move. Flavours differ, but the POD product
              -- moved shelves and the destination leg is itself an in-machine move with no
              -- warehouse source, so these units never reached the warehouse either.
              OR (
                    add_leg.pod_product_id IS NOT NULL
                AND rd.pod_product_id      IS NOT NULL
                AND add_leg.pod_product_id  = rd.pod_product_id
                AND add_leg.from_warehouse_id IS NULL
                AND add_leg.source_kind = 'm2m'
                AND add_leg.source_machine_id = add_leg.machine_id
              )
            )
    )
  END
  FROM public.refill_dispatching rd
  WHERE rd.dispatch_id = p_dispatch_id
    AND rd.boonz_product_id IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.wh_approve_remove_receipt(p_dispatch_id uuid, p_actual_qty numeric DEFAULT NULL::numeric, p_batch_breakdown jsonb DEFAULT NULL::jsonb, p_approved_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'WH manager verified physical receipt'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_dispatch refill_dispatching%ROWTYPE;
  v_final_qty numeric;
  v_final_breakdown jsonb;
  v_receive_result jsonb;
BEGIN
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dispatch % not found', p_dispatch_id; END IF;
  IF v_dispatch.action <> 'Remove' THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt only for action=Remove (got %)', v_dispatch.action;
  END IF;
  -- PRD-113 hard guard, now FIRST (PRD-117 B3): an in-machine move must never be
  -- credited to the warehouse. is_internal_move_dispatch is now the authoritative
  -- same-machine-aware check (PRD-117 B2); the M2M guard below only fires for a
  -- genuine cross-machine transfer.
  IF COALESCE(public.is_internal_move_dispatch(p_dispatch_id), false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt: dispatch % is an INTERNAL MOVE - nothing to credit. These units moved to another shelf of the SAME machine (%) and never reached the warehouse; approving would create phantom warehouse stock. If this really is a warehouse return, call clear_internal_move_flag(%, <reason>) first - it is the only sanctioned way to re-open this credit, it requires a 10+ character reason, and it is durable.',
      p_dispatch_id, v_dispatch.machine_id, p_dispatch_id;
  END IF;
  IF COALESCE(v_dispatch.is_m2m, false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt: dispatch % is an M2M transfer leg - approve via approve_m2m_transfer(%) (no warehouse credit; stock moves to the destination machine).',
      p_dispatch_id, COALESCE(v_dispatch.m2m_transfer_id::text, 'NULL m2m_transfer_id - needs pairing backfill first');
  END IF;
  IF v_dispatch.item_added THEN
    RAISE EXCEPTION 'Dispatch % already approved (item_added=true at %)',
      p_dispatch_id, v_dispatch.wh_approved_at;
  END IF;
  IF v_dispatch.returned THEN
    RAISE EXCEPTION 'Dispatch already marked returned';
  END IF;

  v_final_qty := COALESCE(p_actual_qty, v_dispatch.driver_confirmed_qty);
  v_final_breakdown := COALESCE(p_batch_breakdown, v_dispatch.driver_confirmed_breakdown);
  IF v_final_qty IS NULL THEN
    RAISE EXCEPTION 'No qty available - driver did not confirm and p_actual_qty was NULL. Use approve_stuck_remove for orphans.';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'wh_approve_remove_receipt', true);
  PERFORM set_config('app.mutation_reason',
    format('wh_approve_remove_receipt by %s: %s units verified (driver said %s, WH says %s) - %s',
      COALESCE(p_approved_by::text, 'wh_manager'),
      v_final_qty,
      COALESCE(v_dispatch.driver_confirmed_qty::text, 'none'),
      v_final_qty,
      p_reason), true);

  UPDATE refill_dispatching SET
    wh_approved_at = now(),
    wh_approved_by = p_approved_by
  WHERE dispatch_id = p_dispatch_id;

  v_receive_result := receive_dispatch_line(p_dispatch_id, v_final_qty, p_approved_by, v_final_breakdown);

  RETURN jsonb_build_object(
    'status', 'wh_approved',
    'dispatch_id', p_dispatch_id,
    'driver_said_qty', v_dispatch.driver_confirmed_qty,
    'wh_verified_qty', v_final_qty,
    'discrepancy', v_final_qty - COALESCE(v_dispatch.driver_confirmed_qty, v_final_qty),
    'approved_by', p_approved_by,
    'reason', p_reason,
    'receive_result', v_receive_result
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.wh_approve_remove_receipt_multivariant(p_parent_dispatch_id uuid, p_variant_breakdown jsonb, p_approved_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'WH manager verified per-variant physical receipt'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_parent refill_dispatching%ROWTYPE;
  v_entry jsonb;
  v_entry_bpid uuid;
  v_entry_qty numeric;
  v_entry_expiry date;
  v_breakdown_total numeric := 0;
  v_child_id uuid;
  v_child_ids uuid[] := ARRAY[]::uuid[];
  v_child_results jsonb := '[]'::jsonb;
  v_receive_result jsonb;
  v_final_qty numeric;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'wh_approve_remove_receipt_multivariant', true);

  SELECT * INTO v_parent FROM refill_dispatching
  WHERE dispatch_id = p_parent_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent dispatch % not found', p_parent_dispatch_id;
  END IF;
  IF v_parent.action <> 'Remove' THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt_multivariant requires action=Remove (got %)', v_parent.action;
  END IF;
  -- PRD-113 hard guard, now FIRST (PRD-117 B3, same reorder as the singular RPC).
  IF COALESCE(public.is_internal_move_dispatch(p_parent_dispatch_id), false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt_multivariant: dispatch % is an INTERNAL MOVE - nothing to credit. These units moved to another shelf of the SAME machine (%) and never reached the warehouse; approving would create phantom warehouse stock. If this really is a warehouse return, call clear_internal_move_flag(%, <reason>) first - it is the only sanctioned way to re-open this credit, it requires a 10+ character reason, and it is durable.',
      p_parent_dispatch_id, v_parent.machine_id, p_parent_dispatch_id;
  END IF;
  -- PRD-070 hard guard: an M2M transfer leg must NEVER go through the warehouse-return path.
  IF COALESCE(v_parent.is_m2m, false) THEN
    RAISE EXCEPTION 'wh_approve_remove_receipt_multivariant: dispatch % is an M2M transfer leg - approve via approve_m2m_transfer(%) (no warehouse credit; stock moves to the destination machine).',
      p_parent_dispatch_id, COALESCE(v_parent.m2m_transfer_id::text, 'NULL m2m_transfer_id - needs pairing backfill first');
  END IF;
  IF v_parent.item_added THEN
    RAISE EXCEPTION 'Parent dispatch % already approved at %', p_parent_dispatch_id, v_parent.wh_approved_at;
  END IF;
  IF v_parent.returned THEN
    RAISE EXCEPTION 'Parent dispatch % already returned', p_parent_dispatch_id;
  END IF;

  IF p_variant_breakdown IS NULL OR jsonb_typeof(p_variant_breakdown) <> 'array' THEN
    RAISE EXCEPTION 'p_variant_breakdown must be a JSONB array of {boonz_product_id, qty, expiry}';
  END IF;
  SELECT COALESCE(SUM((e->>'qty')::numeric), 0) INTO v_breakdown_total
  FROM jsonb_array_elements(p_variant_breakdown) e;

  v_final_qty := COALESCE(v_parent.driver_confirmed_qty, ABS(v_parent.quantity));
  IF v_breakdown_total <> v_final_qty THEN
    RAISE EXCEPTION 'Variant breakdown total (%) must equal driver_confirmed_qty / parent.quantity (%)',
      v_breakdown_total, v_final_qty;
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('Multi-variant remove approval on dispatch %s: %s variants, total %s units (driver said %s) - %s',
      p_parent_dispatch_id,
      jsonb_array_length(p_variant_breakdown),
      v_breakdown_total,
      COALESCE(v_parent.driver_confirmed_qty::text, 'null'),
      p_reason),
    true);

  UPDATE refill_dispatching SET
    wh_approved_at = now(),
    wh_approved_by = p_approved_by
  WHERE dispatch_id = p_parent_dispatch_id;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_variant_breakdown)
  LOOP
    v_entry_bpid := NULLIF(v_entry->>'boonz_product_id', '')::uuid;
    v_entry_qty  := (v_entry->>'qty')::numeric;
    v_entry_expiry := NULLIF(v_entry->>'expiry', '')::date;

    IF v_entry_bpid IS NULL THEN
      RAISE EXCEPTION 'Variant entry missing boonz_product_id: %', v_entry;
    END IF;
    IF v_entry_qty <= 0 THEN CONTINUE; END IF;

    IF NOT EXISTS (SELECT 1 FROM boonz_products WHERE product_id = v_entry_bpid) THEN
      RAISE EXCEPTION 'Variant boonz_product_id % does not exist', v_entry_bpid;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM product_mapping
      WHERE pod_product_id = v_parent.pod_product_id
        AND boonz_product_id = v_entry_bpid
        AND status = 'Active'
    ) THEN
      RAISE EXCEPTION 'Variant boonz_product_id % is not mapped to parent pod_product_id %',
        v_entry_bpid, v_parent.pod_product_id;
    END IF;

    -- NOTE (PRD-113): these child rows are born wh_approved_at = now(), so
    -- tg_mark_internal_move_pair leaves them alone by construction — its UPDATE arm only
    -- touches legs with wh_approved_at IS NULL. A settled credit is never relabelled.
    INSERT INTO refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id,
       dispatch_date, action, quantity, filled_quantity, include,
       packed, picked_up, dispatched, returned, item_added,
       expiry_date, from_warehouse_id,
       wh_approved_at, wh_approved_by, comment)
    VALUES
      (v_parent.machine_id, v_parent.shelf_id, v_parent.pod_product_id, v_entry_bpid,
       v_parent.dispatch_date, 'Remove', v_entry_qty, 0, true,
       false, false, false, false, false,
       v_entry_expiry, v_parent.from_warehouse_id,
       now(), p_approved_by,
       format('[multi-variant child of %s] %s', p_parent_dispatch_id, p_reason))
    RETURNING dispatch_id INTO v_child_id;

    v_child_ids := array_append(v_child_ids, v_child_id);

    v_receive_result := receive_dispatch_line(
      v_child_id,
      v_entry_qty,
      p_approved_by,
      CASE
        WHEN v_entry_expiry IS NOT NULL
        THEN jsonb_build_array(jsonb_build_object('expiry', v_entry_expiry, 'qty', v_entry_qty))
        ELSE NULL
      END
    );

    v_child_results := v_child_results || jsonb_build_object(
      'child_dispatch_id',  v_child_id,
      'boonz_product_id',   v_entry_bpid,
      'qty',                v_entry_qty,
      'expiry',             v_entry_expiry,
      'receive_path',       v_receive_result->>'path'
    );
  END LOOP;

  UPDATE refill_dispatching SET
    returned       = true,
    item_added     = false,
    packed         = true,
    picked_up      = true,
    dispatched     = true,
    return_reason  = format('split_into_%s_variants_see_children',
                            COALESCE(array_length(v_child_ids, 1), 0))
  WHERE dispatch_id = p_parent_dispatch_id;

  RETURN jsonb_build_object(
    'status',              'wh_approved_multivariant',
    'parent_dispatch_id',  p_parent_dispatch_id,
    'driver_said_qty',     v_parent.driver_confirmed_qty,
    'wh_verified_qty',     v_final_qty,
    'variant_count',       COALESCE(array_length(v_child_ids, 1), 0),
    'child_dispatch_ids',  v_child_ids,
    'children',            v_child_results,
    'approved_by',         p_approved_by,
    'reason',              p_reason
  );
END;
$function$;
