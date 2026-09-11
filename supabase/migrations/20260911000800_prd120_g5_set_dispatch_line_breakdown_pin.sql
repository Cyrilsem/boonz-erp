-- PRD-120 follow-up G5: set_dispatch_line_breakdown must set the primary pin.
--
-- Bug: set_dispatch_line_breakdown writes driver_confirmed_breakdown and the earliest
-- expiry_date, but never touches from_wh_inventory_id. The pack screen reads that column
-- as "the pin"; a correctly per-expiry-split line reads as unpinned/out-of-stock even
-- though it has real stock, just split across dates.
--
-- Second, deeper finding: check_dispatch_batch_overcommit (PRD-118 H4) ALREADY has a
-- branch that reads driver_confirmed_breakdown per-entry, expecting each entry to carry
-- its own `wh_inventory_id` -- `SELECT (e->>'wh_inventory_id')::uuid ... FROM
-- jsonb_array_elements(rd.driver_confirmed_breakdown) e` -- and correctly EXCLUDES the
-- row's own from_wh_inventory_id from the no-breakdown branch once a breakdown exists.
-- But set_dispatch_line_breakdown (and its only caller, ExpiryBreakdownDialog.tsx) never
-- populated that field on any entry -- so every split line's committed quantity has been
-- invisible to the overcommit assertion since PRD-118 H4 shipped, not just unpinned on
-- the pack screen. No change is needed to check_dispatch_batch_overcommit itself; it
-- already "reads the breakdown when present and the pin otherwise" exactly as asked --
-- the writer just never filled in the field the reader was built to expect.
--
-- Fix: for each breakdown entry with a real expiry date, resolve a matching, serving-
-- warehouse, Active, non-quarantined, non-reserved-elsewhere warehouse_inventory row by
-- EXACT expiration_date match (this records what the driver physically read off a real
-- shelf batch, not a FEFO estimate -- an unmatched date is left unresolved rather than
-- guessed) and attach it into that entry as wh_inventory_id. The row's own
-- from_wh_inventory_id is set to the earliest-expiry entry's resolved batch (only when a
-- real batch was found; never regressed to NULL if nothing resolves).
--
-- Cody: approve. Articles 1 (still the sole breakdown writer, no new write path), 4
-- (role/reason guards unchanged), 12 (forward-only CREATE OR REPLACE, md5-guarded).
--
-- Verified in a rolled-back transaction: a fixture line split across two real batches
-- (different expiry dates) resolves from_wh_inventory_id to the earlier-expiry batch,
-- and check_dispatch_batch_overcommit's existing breakdown branch now correctly attributes
-- each entry's qty to its own real batch instead of a NULL key it could never join.

DO $mig$ DECLARE v_def text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.proname='set_dispatch_line_breakdown' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '08ad83137b587b2985908b7df4cfb12a' THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown drifted (md5 %), refusing blind replace', md5(v_def);
  END IF;
END $mig$;

CREATE OR REPLACE FUNCTION public.set_dispatch_line_breakdown(p_dispatch_id uuid, p_batch_breakdown jsonb, p_edit_role text DEFAULT NULL::text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_role      text;
  v_dispatch  refill_dispatching%ROWTYPE;
  v_total     numeric := 0;
  v_entry     jsonb;
  v_qty       numeric;
  v_expiry    date;
  v_n         int := 0;
  v_earliest  date := NULL;
  v_primary_wh    uuid;
  v_secondary_wh  uuid;
  v_resolved_wh   uuid;
  v_new_breakdown jsonb := '[]'::jsonb;
  v_earliest_wh   uuid := NULL;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'set_dispatch_line_breakdown', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'set_dispatch_line_breakdown: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_dispatch_id IS NULL OR p_batch_breakdown IS NULL OR jsonb_typeof(p_batch_breakdown) <> 'array' THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: p_dispatch_id and a JSON array p_batch_breakdown are required';
  END IF;
  IF jsonb_array_length(p_batch_breakdown) = 0 THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: p_batch_breakdown is empty';
  END IF;

  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: dispatch % not found', p_dispatch_id;
  END IF;
  IF COALESCE(v_dispatch.item_added,false) OR COALESCE(v_dispatch.dispatched,false) THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: dispatch % already dispatched/received — breakdown is locked', p_dispatch_id;
  END IF;

  SELECT m.primary_warehouse_id, m.secondary_warehouse_id
    INTO v_primary_wh, v_secondary_wh
  FROM public.machines m WHERE m.machine_id = v_dispatch.machine_id;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown)
  LOOP
    v_qty := (v_entry->>'qty')::numeric;
    IF v_qty IS NULL OR v_qty < 0 THEN
      RAISE EXCEPTION 'set_dispatch_line_breakdown: each entry needs qty >= 0 (got %)', v_entry;
    END IF;
    v_total := v_total + v_qty;
    v_n := v_n + 1;

    v_expiry := NULLIF(v_entry->>'expiry','')::date;
    v_resolved_wh := NULL;
    IF v_expiry IS NOT NULL THEN
      SELECT wi.wh_inventory_id INTO v_resolved_wh
      FROM public.warehouse_inventory wi
      WHERE wi.boonz_product_id = v_dispatch.boonz_product_id
        AND wi.status = 'Active'
        AND NOT COALESCE(wi.quarantined,false)
        AND NOT COALESCE(wi.manually_quarantined,false)
        AND wi.warehouse_id = ANY (ARRAY[v_primary_wh, v_secondary_wh])
        AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = v_dispatch.machine_id)
        AND wi.expiration_date = v_expiry
      ORDER BY wi.created_at ASC LIMIT 1;

      IF v_earliest IS NULL OR v_expiry < v_earliest THEN
        v_earliest := v_expiry;
        v_earliest_wh := v_resolved_wh;
      END IF;
    END IF;

    v_new_breakdown := v_new_breakdown || jsonb_build_array(v_entry || jsonb_build_object('wh_inventory_id', v_resolved_wh));
  END LOOP;

  IF v_total <> v_dispatch.quantity THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: breakdown total (%) must equal the line total (%) — the total is immutable, only the expiry distribution may change',
      v_total, v_dispatch.quantity;
  END IF;

  PERFORM set_config('app.mutation_reason',
    COALESCE(p_reason, format('PRD-053 driver per-expiry breakdown on dispatch %s (%s entries, total %s)', p_dispatch_id, v_n, v_total)),
    true);

  UPDATE refill_dispatching
     SET driver_confirmed_breakdown = v_new_breakdown,
         expiry_date          = COALESCE(v_earliest, expiry_date),
         from_wh_inventory_id = COALESCE(v_earliest_wh, from_wh_inventory_id),
         last_edited_by       = v_uid,
         last_edited_by_role  = COALESCE(p_edit_role, v_role),
         last_edited_at       = now(),
         edit_count           = COALESCE(edit_count, 0) + 1
   WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status','ok',
    'dispatch_id', p_dispatch_id,
    'line_total', v_dispatch.quantity,
    'breakdown_total', v_total,
    'entries', v_n,
    'earliest_expiry', v_earliest,
    'earliest_wh_inventory_id', v_earliest_wh,
    'breakdown', v_new_breakdown
  );
END;
$function$;
