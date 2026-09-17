-- PRD-127 Block C bug #1: push_plan_to_dispatch(plan_date, ONE machine) calls
-- bind_dispatch_fefo(plan_date, ARRAY[machine]) once per machine at the end
-- of its own run. bind_dispatch_fefo's CREATE TEMP TABLE _bind_tally is
-- unconditional, so a second machine's call within the same transaction (a
-- multi-machine approve_refill_plan/confirm_and_build push) hits
-- "relation _bind_tally already exists", caught by push_plan_to_dispatch's
-- own EXCEPTION WHEN OTHERS, logging one push_fefo_bind_failure alert per
-- machine (135 alerts on 17 Sep for a 135-row multi-machine plan).
--
-- Made idempotent, not scoped-per-call (D-006): _bind_tally.remaining is a
-- shared, cross-call ledger of physical warehouse stock for the whole
-- transaction -- nothing else decrements warehouse_inventory.warehouse_stock
-- at bind time, only from_wh_inventory_id gets stamped on refill_dispatching.
-- Re-creating the table fresh per machine would let two machines in the same
-- push run double-allocate the same physical batch. This preserves that
-- shared-pool behaviour across calls while eliminating the crash on the
-- second and subsequent calls.

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

  IF to_regclass('pg_temp._bind_tally') IS NULL THEN
    CREATE TEMP TABLE _bind_tally ON COMMIT DROP AS
    SELECT wh_inventory_id, warehouse_stock::numeric AS remaining
    FROM warehouse_inventory
    WHERE status='Active' AND NOT COALESCE(quarantined,false) AND NOT COALESCE(manually_quarantined,false)
      AND (expiration_date IS NULL OR expiration_date >= (now() AT TIME ZONE 'Asia/Dubai')::date)
      AND NOT public._is_phantom_wh_row_v3(batch_id, expiration_date);
    CREATE UNIQUE INDEX ON _bind_tally(wh_inventory_id);
  END IF;

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
