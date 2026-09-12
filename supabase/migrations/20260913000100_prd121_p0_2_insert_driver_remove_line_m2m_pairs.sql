-- PRD-121 Phase 2, P0.2: insert_driver_remove_line's three defects, the root cause
-- silently corrupting M2M records since 12 June.
--
-- Confirmed by reading the live function and real production rows (HUAWEI-2003 A11,
-- dispatch_id 7110136b, dated 2026-09-09): a driver splitting a single-flavour M2M
-- "carry" Remove leg into its real per-variant amounts got THREE separate bugs at once:
--
--   1. Copies is_m2m from the parent but never sets m2m_transfer_id/m2m_partner_id --
--      the exact orphan shape (is_m2m=true, m2m_transfer_id NULL) invisible to every
--      pairing/balance check. 82 such rows exist since 12 June.
--   2. Never writes the destination Add New leg -- the carry leaves the source machine
--      and never arrives anywhere.
--   3. Never reduces the parent leg's quantity -- split rows are added ON TOP of the
--      full parent, double-counting the physical removal.
--
-- FIX, M2M branch (parent.is_m2m = true):
--   - resolve the destination machine/shelf from the parent's OWN m2m_partner_id (the
--     existing, correctly-paired Add New leg from push_plan_to_dispatch's original
--     single-flavour plan) -- never guessed, never a new parameter the driver has to
--     supply. If the parent has no partner, RAISE rather than write an orphan.
--   - require the driver-named boonz_product_id to have an Active product_mapping to
--     the destination machine (or a global default) for this pod -- same check
--     correct_packed_m2m_transfer already makes before writing a destination leg.
--   - write ONE matched pair per call (fresh m2m_transfer_id, mutual m2m_partner_id,
--     source_origin='internal_transfer', source_kind='m2m', source_machine_id = the
--     machine the transfer originates from on BOTH legs, from_warehouse_id NULL on
--     both) -- the exact shape correct_packed_m2m_transfer already uses and verified
--     passes m2m_consistency, not swap_between_machines' shape (that function never
--     sets source_kind/source_machine_id at all and is role-gated to
--     operator_admin/superadmin/manager, unreachable for a driver call anyway).
--   - conservation: decrement BOTH the parent AND its existing partner leg by the
--     split quantity (both sides of the original wrong single-flavour pair shrink in
--     lockstep as each real flavour is peeled off) -- this is what makes "source total
--     8, destination total 8" after a 4+4 split hold on BOTH ends, not just the source.
--   - the parent-selection query does NOT reuse the original "most recently created
--     matching row" predicate for this branch (that could accidentally re-match one of
--     THIS function's own prior split calls instead of the true bulk parent once more
--     than one split has happened). It instead requires: is_m2m=true, NOT already
--     item_added (a settled/received leg is never retroactively reduced -- reducing it
--     after the warehouse has already been credited would understate a real receipt,
--     not correct a wrong one), a DIFFERENT boonz_product_id than the one just named
--     (repeating the same variant is a quantity edit, not a split), and enough
--     remaining quantity to cover this call (quantity >= p_quantity) -- ORDER BY
--     quantity DESC so a large bulk leg is preferred over an already-small remainder,
--     mirroring conserve_split_dispatch_quantity's own "quantity >= NEW.quantity"
--     same-SKU conservation check (that trigger explicitly skips is_m2m rows, so it
--     was never going to catch this class; this fix is the same idea for the
--     cross-variant case it was never scoped to cover). No eligible parent -> RAISE,
--     per the task's own doctrine ("if the destination cannot be resolved, RAISE with a
--     clear message. Never write an orphan") applied symmetrically to the source side.
--
-- NOT done here: any repair of the 82 historical orphan rows since 12 June. The task's
-- own AC is explicit that it covers rows "dated today or later"; STOP CONDITIONS forbid
-- rewriting closed days without CS, and several of these have already been through
-- receive_dispatch_line under the wrong (defaulted) product, which is a data
-- reconciliation decision, not a write-path bug fix.
--
-- FIX, non-M2M branch (parent.is_m2m = false, or no parent found): unchanged writer
-- shape, but now also reduces the matched parent's quantity by p_quantity (same
-- "quantity >= p_quantity" guard) -- item 3 applied to the simple case. When no parent
-- is found at all, behaves exactly as before (a genuine beyond-plan addition with no
-- prior line to conserve against).
--
-- Verified triggers on refill_dispatching before writing this: protect_packed_dispatch_row
-- allows quantity edits on a packed row (blocks only product/machine/shelf/date) --
-- confirmed by reading its body, so no correct_packed_m2m_transfer-style zero-and-relog
-- dance is needed for the plain decrements here. enforce_canonical_dispatch_write already
-- allowlists 'insert_driver_remove_line' (both the INSERT and this function's own UPDATEs
-- run under the same app.rpc_name). block_orphan_internal_transfer only fires when
-- m2m_transfer_id IS NULL, which these new rows never are. audit_m2m_dispatch_changes and
-- tg_default_pack_outcome_driver_legs are pure loggers/defaulters, no conflict.
--
-- Cody: approve. Articles 1 (still the sole writer for this action; the destination leg
-- is written here, not by a second path), 4 (role/reason guards unchanged; via_rpc/
-- rpc_name set before every write), 12 (forward-only CREATE OR REPLACE, same signature,
-- md5-guarded), 16 (reuses correct_packed_m2m_transfer's proven-correct M2M row shape
-- rather than a third divergent one; reuses conserve_split_dispatch_quantity's own
-- conservation test rather than inventing a different threshold).

DO $mig$ DECLARE v_def text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='insert_driver_remove_line' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> 'e39dcb02c9074fa249093884bd9a2e5e' THEN
    RAISE EXCEPTION 'insert_driver_remove_line drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

CREATE OR REPLACE FUNCTION public.insert_driver_remove_line(p_machine_id uuid, p_boonz_product_id uuid, p_pod_product_id uuid, p_shelf_id uuid, p_quantity numeric, p_expiry_date date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller_id uuid := auth.uid();
  v_caller_role text;
  v_dispatch_id uuid;
  v_parent refill_dispatching%ROWTYPE;
  v_partner refill_dispatching%ROWTYPE;
  v_new_transfer_id uuid;
  v_new_source_id uuid;
  v_new_dest_id uuid;
  v_dest_pod_ok boolean;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'insert_driver_remove_line: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity required (qty > 0)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'insert_driver_remove_line', true);

  -- PRD-116b: the parent leg this split refines. Matching is deliberately narrow:
  -- same machine, shelf, pod product, today, an included non-cancelled Remove.
  SELECT * INTO v_parent FROM refill_dispatching rd
   WHERE rd.machine_id = p_machine_id
     AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
     AND rd.pod_product_id = p_pod_product_id
     AND rd.dispatch_date = CURRENT_DATE
     AND rd.action = 'Remove' AND rd.include
     AND COALESCE(rd.cancelled, false) = false
   ORDER BY rd.created_at DESC LIMIT 1;

  IF COALESCE(v_parent.is_m2m, false) THEN
    -- PRD-121 P0.2: re-select the real conservation source. The "most recently
    -- created" row above may itself be a prior call's own split leg once more than
    -- one variant has been peeled off this shelf today -- pick the largest still-open,
    -- not-yet-settled, DIFFERENT-variant leg instead.
    SELECT * INTO v_parent FROM refill_dispatching rd
     WHERE rd.machine_id = p_machine_id
       AND (rd.shelf_id = p_shelf_id OR (rd.shelf_id IS NULL AND p_shelf_id IS NULL))
       AND rd.pod_product_id = p_pod_product_id
       AND rd.dispatch_date = CURRENT_DATE
       AND rd.action = 'Remove' AND rd.include
       AND COALESCE(rd.cancelled, false) = false
       AND COALESCE(rd.is_m2m, false) = true
       AND NOT COALESCE(rd.item_added, false)
       AND rd.boonz_product_id IS DISTINCT FROM p_boonz_product_id
       AND COALESCE(rd.quantity, 0) >= p_quantity
     ORDER BY rd.quantity DESC, rd.created_at ASC
     FOR UPDATE
     LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'insert_driver_remove_line: no open M2M parent leg for machine %, shelf %, pod % has >= % units remaining to split off as % -- resolve manually, refusing to write an orphan',
        p_machine_id, p_shelf_id, p_pod_product_id, p_quantity, p_boonz_product_id;
    END IF;

    IF v_parent.m2m_partner_id IS NULL THEN
      RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch % is is_m2m=true but has no m2m_partner_id -- destination cannot be resolved, refusing to write an orphan',
        v_parent.dispatch_id;
    END IF;

    SELECT * INTO v_partner FROM refill_dispatching WHERE dispatch_id = v_parent.m2m_partner_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch %''s partner % not found -- destination cannot be resolved, refusing to write an orphan',
        v_parent.dispatch_id, v_parent.m2m_partner_id;
    END IF;
    IF COALESCE(v_partner.quantity, 0) < p_quantity THEN
      RAISE EXCEPTION 'insert_driver_remove_line: destination leg % only has % units remaining, cannot absorb a % unit split -- the pair is already imbalanced, resolve manually',
        v_partner.dispatch_id, v_partner.quantity, p_quantity;
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM product_mapping pm
      WHERE pm.pod_product_id = p_pod_product_id AND pm.status = 'Active'
        AND pm.boonz_product_id = p_boonz_product_id
        AND (pm.machine_id = v_partner.machine_id OR pm.machine_id IS NULL)
    ) INTO v_dest_pod_ok;
    IF NOT v_dest_pod_ok THEN
      RAISE EXCEPTION 'insert_driver_remove_line: boonz_product % has no Active product_mapping to pod % at destination machine % -- refusing to write an orphan',
        p_boonz_product_id, p_pod_product_id, v_partner.machine_id;
    END IF;

    v_new_transfer_id := gen_random_uuid();
    v_new_source_id := gen_random_uuid();
    v_new_dest_id := gen_random_uuid();

    -- m2m_partner_id is a real FK to refill_dispatching.dispatch_id (a genuine circular
    -- reference between the two legs of a pair) -- insert the source leg with NO partner
    -- yet, insert the dest leg pointing at the now-real source id, then back-fill the
    -- source's partner_id. Same two-step swap_between_machines already uses for exactly
    -- this constraint.
    INSERT INTO refill_dispatching
      (dispatch_id, machine_id, boonz_product_id, pod_product_id, shelf_id,
       dispatch_date, action, quantity, filled_quantity, expiry_date,
       packed, picked_up, dispatched, returned, item_added, include, comment,
       source_origin, source_kind, source_machine_id, is_m2m, m2m_transfer_id,
       from_warehouse_id)
    VALUES
      (v_new_source_id, p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
       CURRENT_DATE, 'Remove', p_quantity, 0, p_expiry_date,
       true, true, true, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id,
       NULL);

    INSERT INTO refill_dispatching
      (dispatch_id, machine_id, boonz_product_id, pod_product_id, shelf_id,
       dispatch_date, action, quantity, filled_quantity, expiry_date,
       packed, picked_up, dispatched, returned, item_added, include, comment,
       source_origin, source_kind, source_machine_id, is_m2m, m2m_transfer_id, m2m_partner_id,
       from_warehouse_id)
    VALUES
      (v_new_dest_id, v_partner.machine_id, p_boonz_product_id, p_pod_product_id, v_partner.shelf_id,
       CURRENT_DATE, 'Add New', p_quantity, 0, p_expiry_date,
       true, false, false, false, false, true,
       format('[DRIVER-INSERT] Multi-variant split: %s', p_reason),
       'internal_transfer'::source_origin_enum, 'm2m', p_machine_id, true, v_new_transfer_id, v_new_source_id,
       NULL)
    RETURNING dispatch_id INTO v_dispatch_id;

    UPDATE refill_dispatching SET m2m_partner_id = v_new_dest_id WHERE dispatch_id = v_new_source_id;

    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_parent.dispatch_id;
    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_partner.dispatch_id;

    RETURN jsonb_build_object('ok', true, 'dispatch_id', v_new_source_id,
      'dest_dispatch_id', v_new_dest_id, 'transfer_id', v_new_transfer_id,
      'machine_id', p_machine_id, 'dest_machine_id', v_partner.machine_id,
      'qty', p_quantity, 'reason', p_reason,
      'inherited_from_parent', v_parent.dispatch_id, 'partner_reduced', v_partner.dispatch_id);
  END IF;

  IF v_parent.dispatch_id IS NOT NULL AND COALESCE(v_parent.quantity, 0) < p_quantity THEN
    RAISE EXCEPTION 'insert_driver_remove_line: parent dispatch % only has % units remaining, cannot absorb a % unit split',
      v_parent.dispatch_id, v_parent.quantity, p_quantity;
  END IF;

  INSERT INTO refill_dispatching
    (machine_id, boonz_product_id, pod_product_id, shelf_id,
     dispatch_date, action, quantity, filled_quantity, expiry_date,
     packed, picked_up, dispatched, returned, item_added, include, comment,
     source_kind, source_machine_id, is_m2m, is_internal_move, from_warehouse_id)
  VALUES
    (p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
     CURRENT_DATE, 'Remove', p_quantity, 0, p_expiry_date,
     true, true, false, false, false, true,
     format('[DRIVER-INSERT] %s', p_reason),
     COALESCE(v_parent.source_kind, 'unknown'), v_parent.source_machine_id,
     COALESCE(v_parent.is_m2m, false), COALESCE(v_parent.is_internal_move, false),
     v_parent.from_warehouse_id)
  RETURNING dispatch_id INTO v_dispatch_id;

  IF v_parent.dispatch_id IS NOT NULL THEN
    UPDATE refill_dispatching SET quantity = quantity - p_quantity WHERE dispatch_id = v_parent.dispatch_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', v_dispatch_id,
    'machine_id', p_machine_id, 'qty', p_quantity, 'reason', p_reason,
    'inherited_from_parent', v_parent.dispatch_id);
END $function$;
