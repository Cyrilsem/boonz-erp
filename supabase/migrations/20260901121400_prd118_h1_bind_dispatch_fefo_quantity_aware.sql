-- PRD-118 item H (Addendum 2 §H): bind_dispatch_fefo rebuilt to be quantity-aware.
-- Bugs fixed: (1) no quantity check — picked ORDER BY expiration_date LIMIT 1 with only
-- warehouse_stock > 0, so an 8-unit line could bind to a 1-unit batch; (2) no netting —
-- N rows in one run all pinned the same earliest batch regardless of depth, since real
-- warehouse_stock only moves at pack time so re-running never corrected it.
--
-- Rebuild: a running per-batch tally (temp table, seeded from real stock, sentinel rows
-- excluded via _is_phantom_wh_row_v3 same as item D) decremented as this run allocates.
-- Two-pass per line: Pass 1 checks total available (tally-adjusted) fully covers the
-- line BEFORE touching the tally — a line that can't be fully covered is left
-- completely alone (no partial/abandoned allocation that would unfairly starve a later
-- line in the same run). Pass 2 performs the real allocation, walking batches in FEFO
-- order. A line landing on exactly one batch gets a simple from_wh_inventory_id pin
-- (unchanged shape from before). A line spanning multiple batches gets
-- driver_confirmed_breakdown written (array of {wh_inventory_id, qty, expiry,
-- batch_id} — matches the shape the PRD-118 item I packing-screen fix already reads)
-- plus from_wh_inventory_id set to the earliest batch for backward-compat with any
-- reader that only checks the pin. expiry_date is now also set from the earliest batch
-- used (the old body never touched it).
--
-- Verified against md5 11441077a80fdcd306b84ecb8690c8bf. Proven live against real prod
-- data (McVities Digestive Mini Dark Chocolate, dispatch_date 2026-07-02, CENTRAL):
-- two real unbound lines (qty 8, qty 5) against a real 7-unit earliest batch. Result:
-- the qty-8 line split 2+1+5 across three batches, the qty-5 line single-bound to the
-- exact 5-unit remainder of the first batch after the qty-8 line's share — zero
-- over-commit on any batch (7-unit batch: 2+5=7 exactly; 1-unit batch: 1 exactly).
-- Cody: approve, Articles 1/4/6/12/16 — same protected-entity writer, same role gate,
-- no new write path; still the sole FEFO-binding RPC for already-unbound rows.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='bind_dispatch_fefo' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '11441077a80fdcd306b84ecb8690c8bf' THEN
    RAISE EXCEPTION 'bind_dispatch_fefo drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;
END $mig$;

CREATE OR REPLACE FUNCTION public.bind_dispatch_fefo(p_plan_date date, p_machine_names text[] DEFAULT NULL::text[], p_caller_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id      uuid := COALESCE(p_caller_id, auth.uid());
  v_role         text;
  v_bound_single int := 0;
  v_bound_split  int := 0;
  v_left         int := 0;
  r_line         RECORD;
  r_batch        RECORD;
  v_remaining    numeric;
  v_take         numeric;
  v_breakdown    jsonb;
  v_entries      int;
  v_first_wh     uuid;
  v_earliest_expiry date;
  v_total_avail  numeric;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'bind_dispatch_fefo: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','bind_dispatch_fefo', true);
  PERFORM set_config('app.via_trigger','true', true);
  PERFORM set_config('app.mutation_reason', format('FEFO bind plan_date=%s by=%s', p_plan_date, v_user_id), true);

  CREATE TEMP TABLE _bind_tally ON COMMIT DROP AS
  SELECT wh_inventory_id, warehouse_stock::numeric AS remaining
  FROM warehouse_inventory
  WHERE status='Active' AND NOT COALESCE(quarantined,false)
    AND (expiration_date IS NULL OR expiration_date >= (now() AT TIME ZONE 'Asia/Dubai')::date)
    AND NOT public._is_phantom_wh_row_v3(batch_id, expiration_date);
  CREATE UNIQUE INDEX ON _bind_tally(wh_inventory_id);

  FOR r_line IN
    SELECT rd.dispatch_id, rd.boonz_product_id, rd.machine_id, rd.quantity,
           COALESCE(rd.from_warehouse_id, public.wh_central_id()::uuid) AS wh
    FROM public.refill_dispatching rd
    WHERE rd.dispatch_date = p_plan_date
      AND rd.action IN ('Refill','Add','Add New')
      AND rd.from_wh_inventory_id IS NULL
      AND COALESCE(rd.item_added,false) = false
      AND COALESCE(rd.returned,false)   = false
      AND COALESCE(rd.cancelled,false)  = false
      AND COALESCE(rd.packed,false)     = false
      AND COALESCE(rd.is_m2m,false)     = false
      AND (p_machine_names IS NULL
           OR rd.machine_id IN (SELECT machine_id FROM public.machines WHERE official_name = ANY(p_machine_names)))
    ORDER BY rd.created_at ASC NULLS LAST, rd.dispatch_id
  LOOP
    SELECT COALESCE(SUM(t.remaining), 0) INTO v_total_avail
    FROM warehouse_inventory wi
    JOIN _bind_tally t ON t.wh_inventory_id = wi.wh_inventory_id
    WHERE wi.boonz_product_id = r_line.boonz_product_id
      AND wi.warehouse_id = r_line.wh
      AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = r_line.machine_id)
      AND t.remaining > 0;

    IF v_total_avail < r_line.quantity THEN
      v_left := v_left + 1;
      CONTINUE;
    END IF;

    v_remaining := r_line.quantity;
    v_breakdown := '[]'::jsonb;
    v_entries := 0;
    v_first_wh := NULL;
    v_earliest_expiry := NULL;

    FOR r_batch IN
      SELECT wi.wh_inventory_id, wi.expiration_date, wi.batch_id, t.remaining
      FROM warehouse_inventory wi
      JOIN _bind_tally t ON t.wh_inventory_id = wi.wh_inventory_id
      WHERE wi.boonz_product_id = r_line.boonz_product_id
        AND wi.warehouse_id = r_line.wh
        AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = r_line.machine_id)
        AND t.remaining > 0
      ORDER BY wi.expiration_date ASC NULLS LAST, wi.created_at ASC
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_take := LEAST(r_batch.remaining, v_remaining);
      IF v_first_wh IS NULL THEN v_first_wh := r_batch.wh_inventory_id; END IF;
      IF v_earliest_expiry IS NULL THEN v_earliest_expiry := r_batch.expiration_date; END IF;
      v_breakdown := v_breakdown || jsonb_build_object(
        'wh_inventory_id', r_batch.wh_inventory_id, 'qty', v_take,
        'expiry', r_batch.expiration_date, 'batch_id', r_batch.batch_id);
      v_entries := v_entries + 1;
      UPDATE _bind_tally SET remaining = remaining - v_take WHERE wh_inventory_id = r_batch.wh_inventory_id;
      v_remaining := v_remaining - v_take;
    END LOOP;

    IF v_entries = 1 THEN
      UPDATE public.refill_dispatching
         SET from_wh_inventory_id = v_first_wh,
             expiry_date          = COALESCE(v_earliest_expiry, expiry_date)
       WHERE dispatch_id = r_line.dispatch_id
         AND COALESCE(packed,false) = false
         AND from_wh_inventory_id IS NULL;
      v_bound_single := v_bound_single + 1;
    ELSE
      UPDATE public.refill_dispatching
         SET from_wh_inventory_id      = v_first_wh,
             driver_confirmed_breakdown = v_breakdown,
             expiry_date               = COALESCE(v_earliest_expiry, expiry_date)
       WHERE dispatch_id = r_line.dispatch_id
         AND COALESCE(packed,false) = false
         AND from_wh_inventory_id IS NULL;
      v_bound_split := v_bound_split + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status','ok','plan_date',p_plan_date,
    'bound_single_batch', v_bound_single,
    'bound_split_batch', v_bound_split,
    'still_unbound_insufficient_stock', v_left);
END;
$function$;
