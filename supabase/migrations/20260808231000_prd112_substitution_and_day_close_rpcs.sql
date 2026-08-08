-- PRD-112 unit 2c — the two RPCs and the day-close read surface
--
--   driver_substitute_dispatch_line  (SECURITY DEFINER, writes refill_dispatching)
--   acknowledge_day_close_event      (SECURITY DEFINER, writes pod_inventory via
--                                     adjust_pod_inventory, and closes the review)
--   v_day_close_events               (read view for the panel)
--   day_close_checks(date)           (the five red/green close checks)
--
-- Incident this exists for: 2026-08-08, VOXMCC-1005. Plan said Fade Fit Dark
-- Choc / Hazelnut / PB / Salted Caramel; the venue only had Coconut. The driver
-- had no self-service path - add-row hit the duplicate guard, the packed-row
-- guard blocked the edit, and resolution needed CS mid-route.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. driver_substitute_dispatch_line
-- ═══════════════════════════════════════════════════════════════════════════
-- The driver is never blocked at the machine. This function accepts what he
-- actually put in the shelf and flags anything it could not verify, rather than
-- refusing and sending him back to the office. It raises for MALFORMED INPUT
-- ONLY (PRD §3.1.5): a missing argument, a product that does not exist, a
-- non-positive fill, a line that is not his to substitute, or a day that is
-- already closed. It never raises because stock is missing or unmapped - those
-- become needs_review + a day-close event.

CREATE OR REPLACE FUNCTION public.driver_substitute_dispatch_line(
  p_dispatch_id          uuid,
  p_new_boonz_product_id uuid,
  p_filled_qty           numeric,
  p_reason               text,
  p_actor                uuid,
  p_source_tag           text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller       uuid := (SELECT auth.uid());
  v_role         text;
  v_edit_role    text;
  v_actor        uuid;
  v_row          public.refill_dispatching%ROWTYPE;
  v_today        date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_old_name     text;
  v_new_name     text;
  v_new_pod      uuid;
  v_new_pod_name text;
  v_machine_name text;
  v_shelf_code   text;
  v_supply       text;
  v_wh_id        uuid;
  v_needs_review boolean := false;
  v_review_rsn   text    := NULL;
  v_new_wh_inv   uuid    := NULL;
  v_new_expiry   date    := NULL;
  v_venue_line   boolean := false;
  v_pack_outcome public.pack_outcome_enum;
  v_before       jsonb;
  v_after        jsonb;
  v_event_id     uuid;
  v_gap_event_id uuid := NULL;
  v_comment      text;
  v_rpo_synced   int := 0;
  v_driver_name  text;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'driver_substitute_dispatch_line', true);

  -- ── Malformed input ───────────────────────────────────────────────────────
  IF p_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: p_dispatch_id required';
  END IF;
  IF p_new_boonz_product_id IS NULL THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: p_new_boonz_product_id required';
  END IF;
  IF p_filled_qty IS NULL OR p_filled_qty <= 0 THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: p_filled_qty must be > 0 (a zero fill is the not-filled flow, not a substitution)';
  END IF;
  IF p_source_tag IS NOT NULL AND p_source_tag NOT IN ('venue','wh','spot') THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: p_source_tag must be venue | wh | spot (got %)', p_source_tag;
  END IF;

  -- Anonymous is refused BY NAME. Written as its own statement rather than as
  -- "auth.uid() IS NOT NULL AND <role check>", which short-circuits to false for
  -- anon and skips the gate entirely (the D-41 / D-42 defect class).
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: anonymous caller refused';
  END IF;
  SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: role % not authorized', COALESCE(v_role,'none');
  END IF;

  -- p_actor is a RECORDED hint, never an authorization claim. A driver is always
  -- stamped as himself; only CS-class roles may attribute the fill to someone else.
  IF p_actor IS NOT NULL AND p_actor <> v_caller AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    v_actor := v_caller;
  ELSE
    v_actor := COALESCE(p_actor, v_caller);
  END IF;
  v_edit_role := CASE WHEN v_role = 'field_staff' THEN 'driver'
                      WHEN v_role = 'warehouse'   THEN 'warehouse_manager'
                      ELSE v_role END;

  SELECT * INTO v_row FROM public.refill_dispatching
   WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: dispatch % not found', p_dispatch_id;
  END IF;

  -- A closed day is settled history. Today and pack-ahead (PRD-111 shipped a
  -- Today/Tomorrow toggle on /field, so a driver legitimately holds tomorrow's
  -- lines) are both live; anything before today is not his to rewrite.
  IF v_row.dispatch_date < v_today THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: dispatch % is dated % and today (Dubai) is % - a closed day cannot be substituted',
      p_dispatch_id, v_row.dispatch_date, v_today;
  END IF;
  IF COALESCE(v_row.cancelled, false) OR COALESCE(v_row.skipped, false) OR COALESCE(v_row.returned, false) THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: dispatch % is cancelled/skipped/returned - nothing to substitute', p_dispatch_id;
  END IF;
  IF COALESCE(v_row.action,'') NOT IN ('Refill','Add New') THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: action % is not substitutable (Refill / Add New only)', COALESCE(v_row.action,'<null>');
  END IF;
  IF v_row.boonz_product_id = p_new_boonz_product_id THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: new product is the product already on the line - use the qty confirm, not a substitution';
  END IF;

  SELECT bp.boonz_product_name INTO v_new_name
    FROM public.boonz_products bp WHERE bp.product_id = p_new_boonz_product_id;
  IF v_new_name IS NULL THEN
    RAISE EXCEPTION 'driver_substitute_dispatch_line: boonz product % not found', p_new_boonz_product_id;
  END IF;
  SELECT bp.boonz_product_name INTO v_old_name
    FROM public.boonz_products bp WHERE bp.product_id = v_row.boonz_product_id;

  -- Snapshotted, not joined at read time: user_profiles RLS is own-row only.
  SELECT up.full_name INTO v_driver_name FROM public.user_profiles up WHERE up.id = v_actor;

  SELECT m.official_name INTO v_machine_name
    FROM public.machines m WHERE m.machine_id = v_row.machine_id;
  SELECT sc.shelf_code INTO v_shelf_code
    FROM public.shelf_configurations sc WHERE sc.shelf_id = v_row.shelf_id;

  -- ── pod resolution ────────────────────────────────────────────────────────
  -- Same cascade as edit_dispatch_product (FIX D2): the shelf's CURRENT binding
  -- wins when it carries the new SKU, then per-machine mapping, then the global
  -- default. Keeps pod_product_id from drifting away from boonz_product_id.
  SELECT sl.pod_product_id INTO v_new_pod
  FROM public.slot_lifecycle sl
  WHERE sl.machine_id = v_row.machine_id
    AND sl.shelf_id   = v_row.shelf_id
    AND sl.is_current = true
    AND sl.archived   = false
    AND EXISTS (
      SELECT 1 FROM public.product_mapping pm2
      WHERE pm2.pod_product_id   = sl.pod_product_id
        AND pm2.boonz_product_id = p_new_boonz_product_id
        AND pm2.status = 'Active')
  ORDER BY sl.rotated_in_at DESC NULLS LAST
  LIMIT 1;

  IF v_new_pod IS NULL THEN
    SELECT pm.pod_product_id INTO v_new_pod
    FROM public.product_mapping pm
    WHERE pm.boonz_product_id = p_new_boonz_product_id
      AND pm.status = 'Active'
      AND (pm.machine_id = v_row.machine_id OR pm.machine_id IS NULL)
    ORDER BY (pm.machine_id = v_row.machine_id) DESC NULLS LAST, pm.is_global_default DESC
    LIMIT 1;
  END IF;

  IF v_new_pod IS NULL THEN
    -- Flavor freedom over correctness theatre: an unmapped product is still what
    -- physically went in the shelf. Keep the shelf's existing pod so the row stays
    -- internally consistent, and make CS look at it tonight.
    v_new_pod      := v_row.pod_product_id;
    v_needs_review := true;
    v_review_rsn   := 'substitution_unmapped_product';
  END IF;
  SELECT pp.pod_product_name INTO v_new_pod_name
    FROM public.pod_products pp WHERE pp.pod_product_id = v_new_pod;

  -- ── source binding (PRD §3.1.2) ───────────────────────────────────────────
  SELECT pm.source_of_supply INTO v_supply
  FROM public.product_mapping pm
  WHERE pm.boonz_product_id = p_new_boonz_product_id
    AND pm.status = 'Active'
    AND (pm.machine_id = v_row.machine_id OR pm.machine_id IS NULL)
  ORDER BY (pm.machine_id = v_row.machine_id) DESC NULLS LAST, pm.is_global_default DESC
  LIMIT 1;

  v_venue_line := (v_row.source_origin = 'vox_at_venue'::public.source_origin_enum)
                  OR v_supply = 'venue_team'
                  OR p_source_tag = 'venue';

  IF v_venue_line THEN
    -- Venue-sourced: the venue's own stock, so there is no warehouse to debit.
    -- Bind the VOX_SOURCED sentinel batch when one exists for the new flavor.
    SELECT wi.wh_inventory_id, wi.expiration_date
      INTO v_new_wh_inv, v_new_expiry
    FROM public.warehouse_inventory wi
    WHERE wi.boonz_product_id = p_new_boonz_product_id
      AND wi.wh_location = 'VOX_SOURCED'
      AND wi.status = 'Active'
    ORDER BY wi.expiration_date ASC NULLS LAST
    LIMIT 1;
  ELSE
    -- Boonz-sourced: FEFO over the line's own warehouse. expiration_date ASC
    -- NULLS LAST is the house FIFO rule.
    v_wh_id := COALESCE(v_row.from_warehouse_id, v_row.source_warehouse_id);
    SELECT wi.wh_inventory_id, wi.expiration_date
      INTO v_new_wh_inv, v_new_expiry
    FROM public.warehouse_inventory wi
    WHERE wi.boonz_product_id = p_new_boonz_product_id
      AND wi.status = 'Active'
      AND COALESCE(wi.quarantined, false) = false
      AND (v_wh_id IS NULL OR wi.warehouse_id = v_wh_id)
      AND COALESCE(wi.warehouse_stock, 0) >= p_filled_qty
    ORDER BY wi.expiration_date ASC NULLS LAST, wi.created_at ASC
    LIMIT 1;
  END IF;

  IF v_new_wh_inv IS NULL THEN
    -- Never a hard block. A spot buy is a KNOWN reason the batch is missing; an
    -- unexplained miss is the one CS has to chase. Both land in Day Close.
    v_needs_review := true;
    v_review_rsn   := COALESCE(v_review_rsn,
                        CASE WHEN p_source_tag = 'spot'
                             THEN 'substitution_spot_buy'
                             ELSE 'substitution_stock_unverified' END);
  END IF;

  -- tg_enforce_not_filled_zero silently re-zeroes filled_quantity while
  -- pack_outcome sits at 'not_filled'. The driver just told us he filled
  -- something, so the outcome moves with the fact rather than the fact being
  -- erased to match a stale outcome.
  v_pack_outcome := v_row.pack_outcome;
  IF v_pack_outcome = 'not_filled'::public.pack_outcome_enum THEN
    v_pack_outcome := CASE WHEN p_filled_qty >= COALESCE(v_row.quantity, 0)
                           THEN 'packed'::public.pack_outcome_enum
                           ELSE 'partial'::public.pack_outcome_enum END;
  END IF;

  v_comment := format('SUBSTITUTED by driver: %s -> %s (%s)',
                      COALESCE(v_old_name, '?'), v_new_name,
                      COALESCE(NULLIF(btrim(COALESCE(p_reason,'')), ''), 'no reason given'));

  v_before := jsonb_build_object(
    'boonz_product_id',     v_row.boonz_product_id,
    'boonz_product_name',   v_old_name,
    'pod_product_id',       v_row.pod_product_id,
    'filled_quantity',      v_row.filled_quantity,
    'from_wh_inventory_id', v_row.from_wh_inventory_id,
    'pack_outcome',         v_row.pack_outcome,
    'packed',               v_row.packed,
    'picked_up',            v_row.picked_up);

  UPDATE public.refill_dispatching
     SET boonz_product_id          = p_new_boonz_product_id,
         pod_product_id            = v_new_pod,
         filled_quantity           = p_filled_qty,
         pack_outcome              = v_pack_outcome,
         driver_confirmed_qty      = p_filled_qty,
         driver_confirmed_at       = now(),
         driver_confirmed_by       = v_actor,
         -- PRD §4.4: settlement reads what was PLANNED from here, so the first
         -- substitution wins and later ones never overwrite the plan's product.
         original_boonz_product_id = COALESCE(original_boonz_product_id, v_row.boonz_product_id),
         from_wh_inventory_id      = v_new_wh_inv,
         expiry_date               = COALESCE(v_new_expiry, expiry_date),
         needs_review              = COALESCE(needs_review, false) OR v_needs_review,
         review_reason             = CASE WHEN v_needs_review THEN v_review_rsn ELSE review_reason END,
         review_status             = CASE WHEN v_needs_review THEN 'pending' ELSE review_status END,
         comment                   = CASE WHEN COALESCE(btrim(comment),'') = ''
                                          THEN v_comment
                                          ELSE comment || E'\n' || v_comment END,
         edit_count                = COALESCE(edit_count, 0) + 1,
         last_edited_by            = v_caller,
         last_edited_by_role       = v_edit_role,
         last_edited_at            = now()
   WHERE dispatch_id = p_dispatch_id;

  v_after := jsonb_build_object(
    'boonz_product_id',     p_new_boonz_product_id,
    'boonz_product_name',   v_new_name,
    'pod_product_id',       v_new_pod,
    'filled_quantity',      p_filled_qty,
    'from_wh_inventory_id', v_new_wh_inv,
    'pack_outcome',         v_pack_outcome,
    'needs_review',         v_needs_review,
    'review_reason',        v_review_rsn);

  -- PRD §4.2: add_dispatch_row leaves rpo orphans, and the FE boards read rpo.
  -- Keep the linked plan row pointing at the same product the dispatch row does.
  UPDATE public.refill_plan_output
     SET boonz_product_id   = p_new_boonz_product_id,
         boonz_product_name = v_new_name,
         pod_product_id     = v_new_pod,
         pod_product_name   = COALESCE(v_new_pod_name, pod_product_name)
   WHERE dispatch_id = p_dispatch_id;
  GET DIAGNOSTICS v_rpo_synced = ROW_COUNT;

  INSERT INTO public.refill_dispatching_edit_log
    (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
  VALUES
    (p_dispatch_id, v_caller, v_edit_role, 'product', v_before, v_after,
     COALESCE(p_reason, 'driver substitution'), NULL);

  -- ── Day-close note ────────────────────────────────────────────────────────
  INSERT INTO public.day_close_events
    (event_date, machine_id, dispatch_id, kind, payload, created_by)
  VALUES
    (v_row.dispatch_date, v_row.machine_id, p_dispatch_id, 'substitution',
     jsonb_build_object(
       'machine_name',        v_machine_name,
       'shelf_code',          v_shelf_code,
       'shelf_id',            v_row.shelf_id,
       'old_boonz_product_id',   v_row.boonz_product_id,
       'old_boonz_product_name', v_old_name,
       'new_boonz_product_id',   p_new_boonz_product_id,
       'new_boonz_product_name', v_new_name,
       'planned_qty',         v_row.quantity,
       'filled_qty',          p_filled_qty,
       'reason',              p_reason,
       'source_tag',          p_source_tag,
       'venue_line',          v_venue_line,
       'driver',              v_actor,
       'driver_name',         v_driver_name,
       'needs_review',        v_needs_review,
       'review_reason',       v_review_rsn,
       'was_packed',          v_row.packed,
       'was_picked_up',       v_row.picked_up,
       -- The warehouse debit is NOT rebalanced here. On a packed Boonz-sourced
       -- line the WH was already debited against the OLD product's batch at pack
       -- time; those units are physically on the truck and close through the
       -- returns flow, not through this RPC. Recorded explicitly so the stranded
       -- debit is something CS can SEE at day close rather than has to know about.
       'wh_debit_rebalanced',      false,
       'prior_from_wh_inventory_id', v_row.from_wh_inventory_id,
       'new_from_wh_inventory_id',   v_new_wh_inv,
       'rpo_rows_synced',     v_rpo_synced),
     v_caller)
  RETURNING id INTO v_event_id;

  -- A gap CS has to act on gets its own row so the Gaps list is not a filter over
  -- the Changes list.
  IF v_needs_review AND v_review_rsn IN ('substitution_spot_buy','substitution_stock_unverified') THEN
    INSERT INTO public.day_close_events
      (event_date, machine_id, dispatch_id, kind, payload, created_by)
    VALUES
      (v_row.dispatch_date, v_row.machine_id, p_dispatch_id,
       CASE WHEN v_review_rsn = 'substitution_spot_buy' THEN 'spot_buy' ELSE 'stock_unverified' END,
       jsonb_build_object(
         'machine_name',           v_machine_name,
         'shelf_code',             v_shelf_code,
         'new_boonz_product_name', v_new_name,
         'filled_qty',             p_filled_qty,
         'review_reason',          v_review_rsn,
         'substitution_event_id',  v_event_id),
       v_caller)
    RETURNING id INTO v_gap_event_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',              true,
    'dispatch_id',     p_dispatch_id,
    'machine_name',    v_machine_name,
    'shelf_code',      v_shelf_code,
    'before',          v_before,
    'after',           v_after,
    'day_close_event_id', v_event_id,
    'gap_event_id',    v_gap_event_id,
    'rpo_rows_synced', v_rpo_synced,
    'comment',         v_comment);
END
$function$;

COMMENT ON FUNCTION public.driver_substitute_dispatch_line(uuid, uuid, numeric, text, uuid, text) IS
  'PRD-112 §3.1. The driver''s at-machine product substitution. Sanctioned single '
  'writer through the packed-row guard: it re-labels a line, never deletes one. '
  'Raises on malformed input only - missing stock or an unmapped product become '
  'needs_review plus a day_close_events row, so the driver is never blocked.';

REVOKE ALL ON FUNCTION public.driver_substitute_dispatch_line(uuid, uuid, numeric, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_substitute_dispatch_line(uuid, uuid, numeric, text, uuid, text) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. acknowledge_day_close_event
-- ═══════════════════════════════════════════════════════════════════════════
-- PRD §3.3.4: nothing auto-writes stock. Machine stock truth for a substituted
-- line moves here, when CS clicks acknowledge, and only then.
--
-- The double-credit trap: receive_dispatch_line already merges filled_quantity
-- into pod_inventory for the line's CURRENT boonz_product_id. Substitution
-- rewrites that column before the receive runs, so a received line has already
-- been credited to the NEW product and must not be credited again. The pod write
-- therefore fires only for a substituted line the receive never closed.

CREATE OR REPLACE FUNCTION public.acknowledge_day_close_event(
  p_event_id uuid,
  p_note     text
) RETURNS jsonb
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

  -- Idempotent (acceptance 3): a second click is a no-op, not a second stock write.
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
      -- adjust_pod_inventory sets an ABSOLUTE new_qty, so the merge is done here:
      -- whatever is live on that shelf for that product, plus what the driver filled.
      --
      -- Article 16 note: the registry claims "any pod_inventory-based stock count"
      -- for v_live_shelf_stock, which cannot serve this call - it is WEIMI-telemetry
      -- derived and keyed on pod_product_id, while adjust_pod_inventory writes an
      -- absolute at (machine, shelf, boonz_product, expiry) LEDGER grain. Sourcing a
      -- ledger write from telemetry would inject drift into the ledger. This is a
      -- ledger read for a ledger write, exactly as receive_dispatch_line does for its
      -- own prior_qty merge. It is never displayed as a stock figure.
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

      -- adjust_pod_inventory overwrote app.rpc_name with its own name. Re-assert
      -- ours before touching refill_dispatching, so the canonical-writer guard is
      -- satisfied by THIS writer and not by a leaked GUC (S-160 family).
      PERFORM set_config('app.via_rpc',  'true', true);
      PERFORM set_config('app.rpc_name', 'acknowledge_day_close_event', true);
    END IF;

    -- CS looked at it, so the line's review is closed with it.
    IF COALESCE(v_row.needs_review, false) THEN
      UPDATE public.refill_dispatching
         SET needs_review = false,
             review_status = 'accepted',
             reviewed_by   = v_caller,
             reviewed_at   = now()
       WHERE dispatch_id = v_ev.dispatch_id;
    END IF;
  END IF;

  UPDATE public.day_close_events
     SET acknowledged_at = now(),
         acknowledged_by = v_caller,
         payload = payload || jsonb_build_object(
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
  'PRD-112 §3.3.4. CS closes one day-close event. For a substitution whose receive '
  'never ran, this is where machine stock truth moves, via adjust_pod_inventory. '
  'Idempotent: a second acknowledge writes no stock.';

REVOKE ALL ON FUNCTION public.acknowledge_day_close_event(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.acknowledge_day_close_event(uuid, text) TO authenticated;

-- ── Acknowledge-all for a date ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.acknowledge_day_close(
  p_event_date date,
  p_note       text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller uuid := (SELECT auth.uid());
  v_role   text;
  v_id     uuid;
  v_n      int := 0;
  v_res    jsonb := '[]'::jsonb;
BEGIN
  -- Article 4: this function delegates every write, but an unlabelled DEFINER is
  -- one refactor away from being a bypass. It labels itself with its OWN name -
  -- borrowing the delegate's name would be a guard satisfied for the wrong reason,
  -- which is the defect this codebase calls the S-160 family. Each per-event call
  -- re-asserts the delegate's own name before it writes.
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'acknowledge_day_close', true);

  IF p_event_date IS NULL THEN
    RAISE EXCEPTION 'acknowledge_day_close: p_event_date required';
  END IF;
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'acknowledge_day_close: anonymous caller refused';
  END IF;
  SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'acknowledge_day_close: role % not authorized (CS closes the day)', COALESCE(v_role,'none');
  END IF;

  FOR v_id IN
    SELECT id FROM public.day_close_events
     WHERE event_date = p_event_date AND acknowledged_at IS NULL
     ORDER BY created_at
  LOOP
    v_res := v_res || public.acknowledge_day_close_event(v_id, p_note);
    v_n := v_n + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'event_date', p_event_date,
                            'acknowledged_n', v_n, 'results', v_res);
END
$function$;

REVOKE ALL ON FUNCTION public.acknowledge_day_close(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.acknowledge_day_close(date, text) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Read surface for the panel
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.v_day_close_events
WITH (security_invoker = true) AS
SELECT
  e.id,
  e.event_date,
  e.kind,
  e.machine_id,
  COALESCE(e.payload->>'machine_name', m.official_name) AS machine_name,
  e.dispatch_id,
  e.payload->>'shelf_code'              AS shelf_code,
  e.payload->>'old_boonz_product_name'  AS old_product,
  e.payload->>'new_boonz_product_name'  AS new_product,
  NULLIF(e.payload->>'planned_qty','')::numeric AS planned_qty,
  NULLIF(e.payload->>'filled_qty','')::numeric  AS filled_qty,
  e.payload->>'reason'                  AS reason,
  e.payload->>'source_tag'              AS source_tag,
  e.payload->>'review_reason'           AS review_reason,
  (e.payload->>'needs_review')::boolean AS needs_review,
  e.payload->>'pod_action'              AS pod_action,
  e.created_by,
  -- Name is snapshotted into the payload by the writer, NOT joined from
  -- user_profiles: that table's RLS is own-row only, so a join here would render
  -- every driver's name as NULL for the CS reading the panel.
  e.payload->>'driver_name'             AS created_by_name,
  e.created_at,
  e.acknowledged_at,
  e.acknowledged_by,
  (e.acknowledged_at IS NOT NULL)       AS acknowledged,
  e.payload
FROM public.day_close_events e
LEFT JOIN public.machines m ON m.machine_id = e.machine_id;

REVOKE ALL ON public.v_day_close_events FROM PUBLIC, anon;
GRANT SELECT ON public.v_day_close_events TO authenticated;

-- The five close checks (PRD §3.3.3), computed live. Each returns a count and a
-- boolean; the panel colours on the boolean. A check that can never be red is a
-- check that is not doing anything, so each one counts a real, reachable state.
CREATE OR REPLACE FUNCTION public.day_close_checks(p_date date)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH lines AS (
    SELECT * FROM public.refill_dispatching
     WHERE dispatch_date = p_date
       AND COALESCE(include, true)
       AND COALESCE(cancelled, false) = false
       AND COALESCE(skipped,   false) = false
  ),
  unreceived AS (
    SELECT count(DISTINCT machine_id)::int AS n
    FROM lines WHERE picked_up = true AND COALESCE(item_added, false) = false
  ),
  not_picked AS (
    SELECT count(*)::int AS n
    FROM lines WHERE packed = true AND COALESCE(picked_up, false) = false
  ),
  review AS (
    SELECT count(*)::int AS n
    FROM lines WHERE COALESCE(needs_review, false) AND review_status IN ('none','pending')
  ),
  returns AS (
    SELECT count(*)::int AS n FROM public.v_pending_return_approvals
  ),
  pod_pending AS (
    SELECT count(*)::int AS n
    FROM public.day_close_events
    WHERE event_date = p_date AND kind = 'substitution' AND acknowledged_at IS NULL
  )
  SELECT jsonb_build_object(
    'event_date', p_date,
    'checks', jsonb_build_array(
      jsonb_build_object('key','all_dispatched_machines_received',
        'label','All dispatched machines received',
        'count', unreceived.n, 'ok', unreceived.n = 0),
      jsonb_build_object('key','all_packed_lines_picked_up',
        'label','All packed lines picked up',
        'count', not_picked.n, 'ok', not_picked.n = 0),
      jsonb_build_object('key','no_open_needs_review',
        'label','No rows awaiting review',
        'count', review.n, 'ok', review.n = 0),
      jsonb_build_object('key','no_returns_pending_receive',
        'label','No returns pending manager receive',
        'count', returns.n, 'ok', returns.n = 0),
      jsonb_build_object('key','no_pod_adjustments_pending',
        'label','No pod_inventory adjustments pending',
        'count', pod_pending.n, 'ok', pod_pending.n = 0)))
  FROM unreceived, not_picked, review, returns, pod_pending;
$function$;

REVOKE ALL ON FUNCTION public.day_close_checks(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.day_close_checks(date) TO authenticated;
