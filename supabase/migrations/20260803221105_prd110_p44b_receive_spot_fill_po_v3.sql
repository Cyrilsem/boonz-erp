-- PRD-110 P4.4b Migration C — receive_spot_fill_po_v3 (phase 2: closing the chain).
--
-- Per docs/prds/PRD-110-P4.4b-DARA-post-facto-fill-design.md §4/§6 (binding).
-- Phase 1 (20260803213141) put the units on the shelf and left them FINANCIALLY
-- UNRECEIVED. Phase 2 closes the money on purchase_orders alone.
--
-- ⛔ D-E (§1, decided on EXECUTED evidence): the spot units never touch
--    warehouse_inventory. Netting them in-and-out drives
--    tg_propose_inactivate_on_zero_stock, which UPDATEs warehouse_inventory.status
--    — Article 6 manager-only — on EVERY fill, and mints an auto-confirmed
--    proposal row. Measured live leg 102: proposals 1148 -> 1149, status Inactive.
--    ⛔ Do not "repair" the missing WH batch. It is intended (§8, Cody's condition).
--
-- ⛔ THE HIGHEST-RISK DEFECT IN THIS UNIT IS A PHASE-2 DOUBLE-ADD (§6). Phase 1
--    already put m on the shelf; phase 2 must NOT re-add it. Composition is
--    therefore moved, never increased: the expiry propagation is a RE-BUCKET.
--    Phase 1 recorded the units in the NULL expiry bucket (it had no receipt yet);
--    phase 2 moves -m out of NULL and +m into the receipt bucket via two
--    'correction' events. Net zero, so "composition is NOT touched" and
--    "propagate the receipt expiry" are both honoured.
--    ⛔ 'correction' is the ONLY kind whose sign CHECK admits both directions —
--    verified live: inventory_events_sign_by_kind pins load/venue_fill/
--    spot_buy_receive > 0 and return/write_off/derived_decrement/
--    expired_sold_incident < 0, and falls through to ELSE true for 'correction'.

-- ---------------------------------------------------------------------------
-- 1. Admit the phase-2 procurement event type.
--
-- Same argument Migration B (part 2) made for 'post_facto_fill_recorded', and it
-- applies with equal force here: reusing 'goods_received' would make a post-facto
-- fill receipt INDISTINGUISHABLE from a warehouse receive in the procurement log,
-- and the two differ in the one way that matters — this one creates no
-- warehouse_inventory batch at all. Any consumer reconciling 'goods_received'
-- against warehouse batches would read this as a missing batch rather than as D-E.
--
-- Widening a CHECK is additive: every existing row already satisfies the new
-- predicate, and no row that was legal becomes illegal.
-- ---------------------------------------------------------------------------
ALTER TABLE public.procurement_events
  DROP CONSTRAINT procurement_events_event_type_check;

ALTER TABLE public.procurement_events
  ADD CONSTRAINT procurement_events_event_type_check
  CHECK (event_type = ANY (ARRAY[
    'po_created','po_line_edited','lines_appended',
    'task_assigned','task_acknowledged','task_collected','task_cancelled',
    'task_pending','task_reopened',
    'goods_received','line_not_purchased',
    'spot_purchase_created','spot_purchase_task_autoclosed',
    'post_facto_fill_recorded',
    -- PRD-110 P4.4b Migration C 2026-08-04: the receipt that closes a post-facto
    -- fill. Distinct from 'goods_received' precisely because D-E creates no
    -- warehouse batch.
    'post_facto_fill_received']));

-- ---------------------------------------------------------------------------
-- 2. receive_spot_fill_po_v3 — phase 2.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_spot_fill_po_v3(
  p_po_id       text,
  p_lines       jsonb,
  p_received_by uuid    DEFAULT NULL,
  p_dry_run     boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_prev_via   text;
  v_prev_rpc   text;
  v_prev_prov  text;
  v_caller     uuid;
  v_role       text;
  v_today      date := CURRENT_DATE;
  v_line       jsonb;
  v_idx        int := 0;
  v_sf_id      uuid;
  v_sf         public.spot_fill_v3%ROWTYPE;
  v_exp        date;
  v_price      numeric;
  v_po_line_id uuid;
  v_cand       int;
  v_line_total numeric;
  v_ev_out     jsonb;
  v_ev_in      jsonb;
  v_received   jsonb := '[]'::jsonb;
  v_skipped    jsonb := '[]'::jsonb;
  v_warnings   text[] := '{}';
  v_n_recv     int := 0;
  v_total      numeric := 0;
  v_result     jsonb;
BEGIN
  -- Article 4 (PRD-016B / S-160): the app.* GUCs leak across statements. Capture
  -- the inbound values now and RESTORE them on every exit path.
  v_prev_via  := current_setting('app.via_rpc', true);
  v_prev_rpc  := current_setting('app.rpc_name', true);
  v_prev_prov := current_setting('app.provenance_reason', true);

  BEGIN
    ------------------------------------------------------------------ 1. gate
    v_caller := (SELECT auth.uid());
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;
    -- Design §4: "warehouse/manager on phase 2". Mirrors the incumbent
    -- receive_purchase_order exactly — this is a RECEIPT, not a machine action,
    -- so it deliberately does NOT admit field_staff the way phase 1 does.
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'receive_spot_fill_po_v3: role % not authorized (warehouse+ only)', COALESCE(v_role,'none');
    END IF;

    -------------------------------------------------------------- 2. validate
    IF p_po_id IS NULL OR btrim(p_po_id) = '' THEN
      RAISE EXCEPTION 'receive_spot_fill_po_v3: p_po_id is required';
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
      RAISE EXCEPTION 'receive_spot_fill_po_v3: p_lines must be a non-empty array of {spot_fill_id, expiry_date, price_per_unit_aed}';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_id = p_po_id) THEN
      RAISE EXCEPTION 'receive_spot_fill_po_v3: po_id % not found', p_po_id;
    END IF;

    ---------------------------------------------------------------- 3. lines
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_idx := v_idx + 1;

      -- Article 4: record_inventory_event_v3 clobbers app.rpc_name and does not
      -- restore it, so a second iteration would inherit ITS name. Re-assert OUR
      -- identity at the top of EVERY iteration, before any protected write.
      PERFORM set_config('app.via_rpc',            'true', true);
      PERFORM set_config('app.rpc_name',           'receive_spot_fill_po_v3', true);
      PERFORM set_config('app.provenance_reason',  'post_facto_fill_receive', true);

      v_sf_id := NULLIF(v_line->>'spot_fill_id','')::uuid;
      IF v_sf_id IS NULL THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line %: spot_fill_id is required', v_idx;
      END IF;

      SELECT * INTO v_sf FROM public.spot_fill_v3 WHERE spot_fill_id = v_sf_id FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line %: spot_fill_id % not found', v_idx, v_sf_id;
      END IF;
      IF v_sf.po_id IS DISTINCT FROM p_po_id THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line %: spot_fill % belongs to PO %, not %', v_idx, v_sf_id, COALESCE(v_sf.po_id,'<null>'), p_po_id;
      END IF;
      IF v_sf.status = 'void' THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line %: spot_fill % is void and cannot be received', v_idx, v_sf_id;
      END IF;

      -- IDEMPOTENCY. Running phase 2 twice must not re-stamp the PO and must not
      -- re-bucket composition a second time. ⛔ This is the guard that separates
      -- this feature from a stock-inflation bug (§6). Skipped, never raised: a
      -- retry after a partial failure is an ordinary operator action.
      IF v_sf.status = 'received' THEN
        v_skipped := v_skipped || jsonb_build_object(
          'spot_fill_id', v_sf_id, 'reason', 'already_received',
          'received_at', v_sf.received_at, 'expiry_date', v_sf.expiry_date);
        CONTINUE;
      END IF;

      IF v_sf.shelf_id IS NULL THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line %: spot_fill % has no shelf_id, so the receipt expiry has nowhere to land in shelf_composition', v_idx, v_sf_id;
      END IF;

      -- Receipt expiry. The incumbent receive_purchase_order refuses a received
      -- batch with no expiry (BUG-007/009) and spot_fill_received_pair enforces
      -- the same at the table. Refuse HERE too, with a message that names the
      -- field, so the operator is never told only that a CHECK failed.
      v_exp := NULLIF(v_line->>'expiry_date','')::date;
      IF v_exp IS NULL THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line % (spot_fill %): expiry_date is required — read it off the receipt. NULL-expiry stock on a shelf is forbidden (BUG-007/009).', v_idx, v_sf_id;
      END IF;
      -- ⛔ P0.4: 2099-12-31 is the sentinel shape. Defaulting or passing it here
      -- would make spot goods immortal in FEFO (§5).
      IF v_exp = DATE '2099-12-31' THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line % (spot_fill %): 2099-12-31 is the P0.4 sentinel, not a receipt expiry. Capture the real date.', v_idx, v_sf_id;
      END IF;
      IF v_exp < v_today THEN
        v_warnings := array_append(v_warnings,
          format('spot_fill %s received with an ALREADY-EXPIRED receipt date %s — the units are on the shelf and now sit in an expired bucket',
                 v_sf_id, v_exp));
      END IF;

      v_price := COALESCE(NULLIF(v_line->>'price_per_unit_aed','')::numeric, v_sf.unit_price_aed);

      ------------------------------------------------- 3a. stamp the PO line
      -- purchase_orders is LINE-grained (PK po_line_id). Phase 1 added exactly one
      -- line per spot_fill row, same product, ordered_qty = the spot qty — but the
      -- PO may also carry unrelated lines when _resolve_open_walkin_po_v3 ATTACHED
      -- to an existing open walk-in PO. Match on the triple and prefer the exact
      -- qty; `received_date IS NULL` is what makes a second run find nothing.
      --
      -- ⛔ THE not_purchased CLAUSE IS LOAD-BEARING, NOT DEFENSIVE PADDING.
      --    cancel_po_line sets purchase_outcome='not_purchased' and does NOT stamp
      --    received_date, so a cancelled line stays received_date IS NULL forever.
      --    Measured live 2026-08-04: 13 such rows exist right now. Without this
      --    clause a spot receipt could land on a CANCELLED line and flip it back to
      --    'received' — resurrecting a line an operator deliberately killed.
      --    Same predicate _resolve_open_walkin_po_v3 uses to find an open PO.
      SELECT count(*) INTO v_cand
        FROM public.purchase_orders
       WHERE po_id = p_po_id AND boonz_product_id = v_sf.boonz_product_id
         AND received_date IS NULL
         AND COALESCE(purchase_outcome,'') <> 'not_purchased';
      IF v_cand = 0 THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line % (spot_fill %): no unreceived PO line for product % on PO %. Refusing to receive a spot fill with no financial line — that would lose the money side silently (LAW 5).',
          v_idx, v_sf_id, v_sf.boonz_product_id, p_po_id;
      END IF;
      IF v_cand > 1 THEN
        v_warnings := array_append(v_warnings,
          format('PO %s has %s open lines for product %s; preferred one with ordered_qty = %s, else the lowest po_line_id — the match is deterministic but not provably the line phase 1 created',
                 p_po_id, v_cand, v_sf.boonz_product_id, v_sf.qty));
      END IF;

      SELECT po_line_id INTO v_po_line_id
        FROM public.purchase_orders
       WHERE po_id = p_po_id AND boonz_product_id = v_sf.boonz_product_id
         AND received_date IS NULL
         AND COALESCE(purchase_outcome,'') <> 'not_purchased'
       ORDER BY (ordered_qty = v_sf.qty) DESC, po_line_id
       LIMIT 1;

      -- RETURNING the stamped values back rather than re-deriving them: the price
      -- actually written may be the LINE's pre-existing price when neither the
      -- receipt nor the spot_fill carried one, and a payload that reports a total
      -- the ledger does not hold is the quiet kind of wrong.
      UPDATE public.purchase_orders
         SET received_date      = v_today,
             received_qty       = v_sf.qty,
             purchase_outcome   = 'received',
             price_per_unit_aed = COALESCE(v_price, price_per_unit_aed),
             total_price_aed    = CASE
               WHEN v_price IS NOT NULL             THEN v_sf.qty * v_price
               WHEN price_per_unit_aed IS NOT NULL  THEN v_sf.qty * price_per_unit_aed
               ELSE NULL END,
             expiry_date        = v_exp
       WHERE po_line_id = v_po_line_id
      RETURNING price_per_unit_aed, total_price_aed INTO v_price, v_line_total;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'receive_spot_fill_po_v3: line %: failed to stamp po_line_id %', v_idx, v_po_line_id;
      END IF;

      -- ⛔ NO warehouse_inventory INSERT HERE. That is D-E, and it is the whole
      --    constitutional point of this design (§1, Article 6). The incumbent
      --    receive_purchase_order inserts a batch at exactly this point; this
      --    function deliberately does not, because the goods are on a shelf.

      ------------------------------------------------ 3b. close the spot fill
      UPDATE public.spot_fill_v3
         SET status         = 'received',
             received_at    = now(),
             received_by    = COALESCE(p_received_by, v_caller),
             expiry_date    = v_exp,
             unit_price_aed = COALESCE(v_price, unit_price_aed),
             po_id          = p_po_id
       WHERE spot_fill_id = v_sf_id;

      ------------------------------- 3c. propagate the expiry — a RE-BUCKET
      -- ⛔ NOT an add. Phase 1 booked the units into the NULL expiry bucket
      --    (record_inventory_event_v3 keys shelf_composition on
      --    (shelf_id, boonz_product_id, expiry_bucket) NULLS NOT DISTINCT, so NULL
      --    is a real addressable bucket, verified live). Move them into the
      --    receipt bucket: -qty out of NULL, +qty into v_exp. The two deltas sum
      --    to zero, so total composition on the shelf is UNCHANGED — which is what
      --    §6 step 4 means by "composition is NOT touched".
      SELECT public.record_inventory_event_v3(
               v_sf.shelf_id, v_sf.boonz_product_id, -v_sf.qty, 'correction', NULL,
               format('spot_fill_recv:%s', v_sf_id),
               format('P4.4b phase 2: moving %s unit(s) OUT of the NULL expiry bucket now that PO %s receipt gives a real date', v_sf.qty, p_po_id))
        INTO v_ev_out;

      SELECT public.record_inventory_event_v3(
               v_sf.shelf_id, v_sf.boonz_product_id, v_sf.qty, 'correction', v_exp,
               format('spot_fill_recv:%s', v_sf_id),
               format('P4.4b phase 2: moving %s unit(s) INTO expiry bucket %s from PO %s receipt (net zero with the paired correction — FEFO and the expiry engine now see a real date)', v_sf.qty, v_exp, p_po_id))
        INTO v_ev_in;

      -- The out-leg clamps at zero and raises an anomaly if the NULL bucket no
      -- longer holds the units (something else consumed them between the phases).
      -- Surfacing it beats a silently smaller shelf.
      IF COALESCE((v_ev_out->>'clamped')::boolean, false) THEN
        v_warnings := array_append(v_warnings,
          format('spot_fill %s: the NULL expiry bucket on shelf %s held less than %s unit(s) — the out-leg clamped at 0 and raised anomaly %s, so the re-bucket was NOT net-zero',
                 v_sf_id, v_sf.shelf_id, v_sf.qty, COALESCE(v_ev_out->>'anomaly_id','<none>')));
      END IF;

      v_n_recv := v_n_recv + 1;
      v_total  := v_total + COALESCE(v_line_total, 0);
      v_received := v_received || jsonb_build_object(
        'spot_fill_id', v_sf_id, 'po_line_id', v_po_line_id,
        'boonz_product_id', v_sf.boonz_product_id, 'shelf_id', v_sf.shelf_id,
        'qty', v_sf.qty, 'expiry_date', v_exp, 'price_per_unit_aed', v_price,
        'rebucket', jsonb_build_object(
          'out_event_id', v_ev_out->>'event_id', 'out_bucket', 'null',
          'out_est_qty_after', v_ev_out->'est_qty_after',
          'in_event_id',  v_ev_in->>'event_id',  'in_bucket', v_exp,
          'in_est_qty_after', v_ev_in->'est_qty_after',
          'net_delta', 0));
    END LOOP;

    ------------------------------------------------------- 4. procurement log
    -- Only when something was ACTUALLY received. A pure re-run stamps nothing and
    -- therefore logs nothing — "no second PO stamp" (§7 seq 34-37).
    IF v_n_recv > 0 THEN
      PERFORM set_config('app.via_rpc',           'true', true);
      PERFORM set_config('app.rpc_name',          'receive_spot_fill_po_v3', true);
      PERFORM set_config('app.provenance_reason', 'post_facto_fill_receive', true);

      INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
      VALUES (p_po_id, 'post_facto_fill_received', v_caller,
        jsonb_build_object(
          'lines_received', v_n_recv, 'lines_skipped', jsonb_array_length(v_skipped),
          'received', v_received, 'skipped', v_skipped,
          'total_price_aed', v_total, 'received_by', COALESCE(p_received_by, v_caller),
          'warehouse_batches_created', 0,
          'note', 'D-E: no warehouse_inventory batch — these goods went counter -> driver -> shelf and never entered a warehouse',
          'warnings', to_jsonb(v_warnings)));
    END IF;

    v_result := jsonb_build_object(
      'ok', true,
      'po_id', p_po_id,
      'received_date', v_today,
      'lines_received', v_n_recv,
      'lines_skipped', jsonb_array_length(v_skipped),
      'received', v_received,
      'skipped', v_skipped,
      'total_price_aed', v_total,
      'warehouse_rows_created', 0,
      'composition_net_delta', 0,
      'design_note', 'D-E: the spot units never touch warehouse_inventory. The expiry propagation is a RE-BUCKET (-qty from the NULL bucket, +qty into the receipt bucket), so composition totals are unchanged — phase 1 already put these units on the shelf.',
      'warnings', to_jsonb(v_warnings),
      'dry_run', p_dry_run, 'committed', true);

    IF p_dry_run THEN
      RAISE EXCEPTION 'PRD110_P44B_DRY_RUN';
    END IF;

  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.via_rpc',           COALESCE(v_prev_via,''),  true);
    PERFORM set_config('app.rpc_name',          COALESCE(v_prev_rpc,''),  true);
    PERFORM set_config('app.provenance_reason', COALESCE(v_prev_prov,''), true);

    IF SQLERRM = 'PRD110_P44B_DRY_RUN' THEN
      RETURN v_result || jsonb_build_object(
        'dry_run', true, 'committed', false,
        'deferred_constraints_unchecked', true,
        'note', 'S-133: a rolled-back dry run does NOT check DEFERRED constraints');
    END IF;
    RAISE;
  END;

  -- Article 4: restore on the success path too.
  PERFORM set_config('app.via_rpc',           COALESCE(v_prev_via,''),  true);
  PERFORM set_config('app.rpc_name',          COALESCE(v_prev_rpc,''),  true);
  PERFORM set_config('app.provenance_reason', COALESCE(v_prev_prov,''), true);

  RETURN v_result;
END;
$fn$;

-- S-140/S-178: Supabase default privileges arm every new public object at birth,
-- and a GRANT does not reduce an existing ACL — so REVOKE first, then GRANT the
-- one intended role set, then read proacl back and assert the WHOLE string.
REVOKE ALL ON FUNCTION public.receive_spot_fill_po_v3(text, jsonb, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.receive_spot_fill_po_v3(text, jsonb, uuid, boolean) FROM anon;
REVOKE ALL ON FUNCTION public.receive_spot_fill_po_v3(text, jsonb, uuid, boolean) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.receive_spot_fill_po_v3(text, jsonb, uuid, boolean) TO authenticated;
