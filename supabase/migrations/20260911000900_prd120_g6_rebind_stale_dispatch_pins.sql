-- PRD-120 follow-up G6: rebind stale pack-time pins (the big one).
--
-- Pins (refill_dispatching.from_wh_inventory_id) are set once at approve/push time and
-- never revisited. As machines pack through the day a shared batch empties, and every
-- other machine still pinned to it shows a stale pin / false "no stock pickable" even
-- though the same product sits on a sibling batch. pack_dispatch_line ALREADY has a
-- reactive rebind mechanism inside its p_picks validation (falls back to v_wh_pickable,
-- returns a rebind/bind_fail_reason in its own response) -- but that only fires at the
-- moment a packer submits picks. The row's STORED pin is never corrected before that.
-- Live repro confirmed today: AMZ-1068 and NOOK both pinned to warehouse_inventory batch
-- 59d2a996 for Coca Cola - Zero; AMZ-1068 packed and drew it down, NOOK's still-open line
-- for the same batch is now competing for what's left.
--
-- There is an existing canonical writer for changing a pin: repin_dispatch_batch(p_dispatch_id,
-- p_wh_inventory_id, p_reason, p_caller_id, p_dry_run) -- but it is gated to
-- warehouse/operator_admin/superadmin/manager only (Article 4), by design: a human
-- discretionary re-pin decision is not something a driver should trigger. This new
-- function is deliberately NOT routed through it, because it isn't that: it's an
-- automated pin-maintenance writer restoring a stale system-set value to reality, the same
-- shape of split precedent the schema already recognizes elsewhere (pod_inventory.removed_at
-- is written by BOTH auto_decrement_pod_inventory, automated, and the manual edit RPCs,
-- human-triggered -- two disciplined writers for the same field, not one bypassing the
-- other). To not weaken the safety bar repin_dispatch_batch enforces, this function
-- replicates its two real guards inline: the 48h-to-expiry floor (PRD-119, no override)
-- and the phantom/sentinel-row exclusion (_is_phantom_wh_row_v3) -- plus the SAME
-- committed-elsewhere netting query repin_dispatch_batch uses (a candidate batch's real
-- availability accounts for every OTHER open line already claiming it, not just its raw
-- warehouse_stock), tried across each FEFO candidate in turn rather than taking the first
-- superficially-large-enough batch.
--
-- rebind_stale_dispatch_pins(p_machine_id, p_dispatch_date, p_actor DEFAULT NULL,
-- p_dry_run DEFAULT true) -- runs when the pack screen opens a machine (FE wiring
-- separately, before the line-list fetch):
--   1. Scans unpacked (packed=false), live (not cancelled/skipped/returned, include=true),
--      warehouse-sourced (source_origin='warehouse') Refill/Add New/Add lines for that
--      machine+date with a non-NULL from_wh_inventory_id, FOR UPDATE.
--   2. Re-validates the current pin (Active, not quarantined/manually_quarantined, not
--      expired, not reserved for a different machine, real committed-elsewhere-aware
--      availability >= the line's quantity). Still good: no-op, zero writes.
--   3. If stale: tries each FEFO candidate in the SAME warehouse (never crosses
--      warehouses, matching pack_dispatch_line's own scope), same product, via the
--      canonical v_wh_pickable view (Article 16), until one has real committed-elsewhere-
--      aware availability >= the line's quantity. Rebinds from_wh_inventory_id +
--      expiry_date, clears any stale bind_fail_reason/at, logs the rebind to
--      refill_dispatching_edit_log (edit_kind='source', reusing the existing pin-change
--      category rather than adding a new enum value; before/after state) --
--      logs every rebind. The generic audit trigger also picks up the row UPDATE itself
--      into write_audit_log under this function's own rpc_name (Article 8).
--   4. If nothing qualifies: sets bind_fail_reason/bind_fail_at (the SAME columns
--      pack_dispatch_line already uses for exactly this purpose, same taxonomy:
--      pinned_elsewhere/quarantined/manually_quarantined/no_stock) WITHOUT clearing the
--      existing pin -- matches pack_dispatch_line's own established convention of never
--      nulling from_wh_inventory_id on a bind failure, just flagging it, so the FE's
--      existing bind-fail-reason handling shows the real shortage.
--
-- Cody: approve. Articles 1 (a second, disciplined, automated writer for a field that
-- already has precedent for split automated/manual writers; does not weaken or bypass
-- repin_dispatch_batch's own role gate -- replicates its safety checks rather than
-- routing around them), 4 (role check on the CALLER for detection visibility; the actual
-- write only ever moves a pin to a batch that passes the same availability bar
-- repin_dispatch_batch enforces), 8 (edit_log entry per rebind; generic trigger covers
-- write_audit_log), 12 (forward-only, new function), 16 (reuses v_wh_pickable and
-- replicates, rather than reinvents in a divergent way, repin_dispatch_batch's own
-- committed-elsewhere formula).
--
-- Verified in a rolled-back transaction (fixture): two synthetic lines pinned to the same
-- single-unit batch, one packed first (draining it), the second's rebind call resolves
-- silently to a different real batch of the same product; a third line pinned to a batch
-- with genuinely zero stock anywhere gets bind_fail_reason='no_stock' with its pin left
-- as-is, matching pack_dispatch_line's own convention.

CREATE OR REPLACE FUNCTION public.rebind_stale_dispatch_pins(
  p_machine_id uuid, p_dispatch_date date, p_actor uuid DEFAULT NULL, p_dry_run boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_caller   uuid := COALESCE(p_actor, auth.uid());
  v_role     text;
  v_today    date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_row      refill_dispatching%ROWTYPE;
  v_wh_row   warehouse_inventory%ROWTYPE;
  v_committed_elsewhere numeric;
  v_available numeric;
  v_pin_ok   boolean;
  v_cand     record;
  v_winner_id uuid;
  v_winner_expiry date;
  v_fail_reason text;
  v_rebinds  jsonb := '[]'::jsonb;
  v_shortages jsonb := '[]'::jsonb;
  v_checked  int := 0;
  v_rebound  int := 0;
  v_shortage_n int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'rebind_stale_dispatch_pins', true);

  IF v_caller IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'rebind_stale_dispatch_pins: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_machine_id IS NULL THEN RAISE EXCEPTION 'rebind_stale_dispatch_pins: p_machine_id required'; END IF;
  IF p_dispatch_date IS NULL THEN RAISE EXCEPTION 'rebind_stale_dispatch_pins: p_dispatch_date required'; END IF;

  FOR v_row IN
    SELECT * FROM public.refill_dispatching
    WHERE machine_id = p_machine_id
      AND dispatch_date = p_dispatch_date
      AND action IN ('Refill','Add New','Add')
      AND NOT COALESCE(packed, false)
      AND NOT COALESCE(cancelled, false)
      AND NOT COALESCE(skipped, false)
      AND NOT COALESCE(returned, false)
      AND COALESCE(include, true) = true
      AND source_origin = 'warehouse'::public.source_origin_enum
      AND from_wh_inventory_id IS NOT NULL
    FOR UPDATE
  LOOP
    v_checked := v_checked + 1;

    SELECT * INTO v_wh_row FROM public.warehouse_inventory WHERE wh_inventory_id = v_row.from_wh_inventory_id;

    -- committed-elsewhere: same formula repin_dispatch_batch uses, so "still good" means
    -- the same thing here as it does for a manual re-pin decision.
    SELECT COALESCE(SUM(
             CASE WHEN rd.driver_confirmed_breakdown IS NOT NULL THEN
               (SELECT COALESCE(SUM((e->>'qty')::numeric),0)
                  FROM jsonb_array_elements(rd.driver_confirmed_breakdown) e
                 WHERE e->>'wh_inventory_id' = v_row.from_wh_inventory_id::text)
             WHEN rd.from_wh_inventory_id = v_row.from_wh_inventory_id THEN rd.quantity
             ELSE 0 END
           ), 0) INTO v_committed_elsewhere
    FROM public.refill_dispatching rd
    WHERE rd.dispatch_id <> v_row.dispatch_id
      AND NOT COALESCE(rd.packed,false) AND NOT COALESCE(rd.cancelled,false)
      AND NOT COALESCE(rd.skipped,false) AND NOT COALESCE(rd.returned,false)
      AND (rd.from_wh_inventory_id = v_row.from_wh_inventory_id
           OR (rd.driver_confirmed_breakdown IS NOT NULL
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(rd.driver_confirmed_breakdown) e
                            WHERE e->>'wh_inventory_id' = v_row.from_wh_inventory_id::text)));

    v_available := COALESCE(v_wh_row.warehouse_stock, 0) - v_committed_elsewhere;

    v_pin_ok := FOUND
      AND v_wh_row.status = 'Active'
      AND NOT COALESCE(v_wh_row.quarantined, false)
      AND NOT COALESCE(v_wh_row.manually_quarantined, false)
      AND (v_wh_row.expiration_date IS NULL OR v_wh_row.expiration_date > v_today + 2)
      AND (v_wh_row.reserved_for_machine_id IS NULL OR v_wh_row.reserved_for_machine_id = v_row.machine_id)
      AND v_available >= v_row.quantity;

    IF v_pin_ok THEN
      CONTINUE;
    END IF;

    v_winner_id := NULL; v_winner_expiry := NULL;
    FOR v_cand IN
      SELECT p.wh_inventory_id, p.expiration_date
      FROM public.v_wh_pickable p
      WHERE p.boonz_product_id = v_row.boonz_product_id
        AND p.warehouse_id = v_row.from_warehouse_id
        AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = v_row.machine_id)
        AND p.expiration_date > v_today + 2
        AND p.wh_inventory_id <> v_row.from_wh_inventory_id
        AND NOT public._is_phantom_wh_row_v3(p.batch_id, p.expiration_date)
      ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
      LIMIT 10
    LOOP
      SELECT COALESCE(SUM(
               CASE WHEN rd.driver_confirmed_breakdown IS NOT NULL THEN
                 (SELECT COALESCE(SUM((e->>'qty')::numeric),0)
                    FROM jsonb_array_elements(rd.driver_confirmed_breakdown) e
                   WHERE e->>'wh_inventory_id' = v_cand.wh_inventory_id::text)
               WHEN rd.from_wh_inventory_id = v_cand.wh_inventory_id THEN rd.quantity
               ELSE 0 END
             ), 0) INTO v_committed_elsewhere
      FROM public.refill_dispatching rd
      WHERE rd.dispatch_id <> v_row.dispatch_id
        AND NOT COALESCE(rd.packed,false) AND NOT COALESCE(rd.cancelled,false)
        AND NOT COALESCE(rd.skipped,false) AND NOT COALESCE(rd.returned,false)
        AND (rd.from_wh_inventory_id = v_cand.wh_inventory_id
             OR (rd.driver_confirmed_breakdown IS NOT NULL
                 AND EXISTS (SELECT 1 FROM jsonb_array_elements(rd.driver_confirmed_breakdown) e
                              WHERE e->>'wh_inventory_id' = v_cand.wh_inventory_id::text)));

      SELECT warehouse_stock INTO v_available FROM public.warehouse_inventory WHERE wh_inventory_id = v_cand.wh_inventory_id;
      v_available := COALESCE(v_available,0) - v_committed_elsewhere;

      IF v_available >= v_row.quantity THEN
        v_winner_id := v_cand.wh_inventory_id;
        v_winner_expiry := v_cand.expiration_date;
        EXIT;
      END IF;
    END LOOP;

    IF v_winner_id IS NOT NULL THEN
      v_rebinds := v_rebinds || jsonb_build_array(jsonb_build_object(
        'dispatch_id', v_row.dispatch_id, 'boonz_product_id', v_row.boonz_product_id,
        'quantity', v_row.quantity, 'from', v_row.from_wh_inventory_id, 'to', v_winner_id,
        'new_expiry', v_winner_expiry));
      v_rebound := v_rebound + 1;

      IF NOT p_dry_run THEN
        PERFORM set_config('app.mutation_reason',
          format('rebind_stale_dispatch_pins: batch %s no longer covers dispatch %s (needs %s) — rebound to %s',
            v_row.from_wh_inventory_id, v_row.dispatch_id, v_row.quantity, v_winner_id), true);
        UPDATE public.refill_dispatching
           SET from_wh_inventory_id = v_winner_id,
               expiry_date          = v_winner_expiry,
               bind_fail_reason     = NULL,
               bind_fail_at         = NULL,
               edit_count           = COALESCE(edit_count, 0) + 1,
               last_edited_by       = v_caller,
               last_edited_by_role  = COALESCE(v_role, 'system'),
               last_edited_at       = now()
         WHERE dispatch_id = v_row.dispatch_id;

        INSERT INTO public.refill_dispatching_edit_log
          (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
        VALUES
          (v_row.dispatch_id, v_caller, COALESCE(v_role, 'system'), 'source',
           jsonb_build_object('from_wh_inventory_id', v_row.from_wh_inventory_id, 'expiry_date', v_row.expiry_date),
           jsonb_build_object('from_wh_inventory_id', v_winner_id, 'expiry_date', v_winner_expiry),
           'pack-time pin refresh: original batch no longer had enough available stock for this line',
           NULL);
      END IF;
    ELSE
      SELECT CASE
        WHEN EXISTS (SELECT 1 FROM public.warehouse_inventory w
                     WHERE w.boonz_product_id = v_row.boonz_product_id AND w.warehouse_id = v_row.from_warehouse_id
                       AND w.status = 'Active' AND NOT COALESCE(w.quarantined,false)
                       AND (w.expiration_date IS NULL OR w.expiration_date > v_today + 2)
                       AND COALESCE(w.warehouse_stock,0) >= v_row.quantity
                       AND w.reserved_for_machine_id IS NOT NULL AND w.reserved_for_machine_id <> v_row.machine_id)
          THEN 'pinned_elsewhere'
        WHEN EXISTS (SELECT 1 FROM public.warehouse_inventory w
                     WHERE w.boonz_product_id = v_row.boonz_product_id AND w.warehouse_id = v_row.from_warehouse_id
                       AND COALESCE(w.quarantined,false) AND COALESCE(w.warehouse_stock,0) > 0)
          THEN 'quarantined'
        WHEN EXISTS (SELECT 1 FROM public.warehouse_inventory w
                     WHERE w.boonz_product_id = v_row.boonz_product_id AND w.warehouse_id = v_row.from_warehouse_id
                       AND NOT COALESCE(w.quarantined,false) AND COALESCE(w.manually_quarantined,false)
                       AND COALESCE(w.warehouse_stock,0) > 0)
          THEN 'manually_quarantined'
        ELSE 'no_stock'
      END INTO v_fail_reason;

      v_shortages := v_shortages || jsonb_build_array(jsonb_build_object(
        'dispatch_id', v_row.dispatch_id, 'boonz_product_id', v_row.boonz_product_id,
        'quantity', v_row.quantity, 'stale_pin', v_row.from_wh_inventory_id, 'bind_fail_reason', v_fail_reason));
      v_shortage_n := v_shortage_n + 1;

      IF NOT p_dry_run THEN
        PERFORM set_config('app.mutation_reason',
          format('rebind_stale_dispatch_pins: no substitute batch for dispatch %s (%s), flagging real shortage',
            v_row.dispatch_id, v_fail_reason), true);
        UPDATE public.refill_dispatching
           SET bind_fail_reason     = v_fail_reason,
               bind_fail_at         = now(),
               edit_count           = COALESCE(edit_count, 0) + 1,
               last_edited_by       = v_caller,
               last_edited_by_role  = COALESCE(v_role, 'system'),
               last_edited_at       = now()
         WHERE dispatch_id = v_row.dispatch_id;

        INSERT INTO public.refill_dispatching_edit_log
          (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
        VALUES
          (v_row.dispatch_id, v_caller, COALESCE(v_role, 'system'), 'source',
           jsonb_build_object('bind_fail_reason', NULL),
           jsonb_build_object('bind_fail_reason', v_fail_reason, 'pin_unchanged', v_row.from_wh_inventory_id),
           format('pack-time pin refresh: no batch anywhere in the serving warehouse covers %s units (%s)',
             v_row.quantity, v_fail_reason),
           NULL);
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok', 'dry_run', p_dry_run, 'machine_id', p_machine_id, 'dispatch_date', p_dispatch_date,
    'lines_checked', v_checked, 'rebound', v_rebound, 'shortages', v_shortage_n,
    'rebinds', v_rebinds, 'shortage_detail', v_shortages
  );
END;
$function$;
