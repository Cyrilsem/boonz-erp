-- PRD-118 item D fix #4 (the actual per-machine routing fix): push_plan_to_dispatch's
-- Refill/Add-New warehouse candidate was ARRAY[v_line_wh_id] (primary warehouse, or
-- wh_central_id() override for cold items) — the machine's own secondary_warehouse_id
-- was fetched nowhere and never considered. For the 4 VOX machines (whose primary is a
-- consignment warehouse holding only sentinel rows), this meant every Boonz-supplied
-- line only ever searched the consignment warehouse. Fix: fetch secondary_warehouse_id
-- alongside primary at function start; for non-cold lines, pass
-- ARRAY[v_line_wh_id, v_secondary_warehouse_id] to wh_fefo_for_line instead of a
-- single-element array. Cold-chain routing (wh_central_id() override) is deliberately
-- left untouched — a single-candidate array, unwidened — pending a CS decision on
-- whether cold items should also consider a secondary warehouse (flagged for the
-- report, not decided here). This fix depends on prd118_d1 (wh_fefo_for_line sentinel
-- exclusion) having already shipped: widening the candidate array without that filter
-- in place would let a genuine shortfall silently bind against a sentinel row instead
-- of correctly reporting a procurement gap. Verified against md5
-- 8290d51f6c0e5078da2eeb1a2d6afe04.
--
-- Testing note: the underlying mechanism (wh_fefo_for_line correctly excluding
-- sentinels and finding real CENTRAL stock) was proven live twice under prd118_d1/d2
-- with real quantities (7Up-Diet at VOXMCC-1005: total_pickable 1033->34,
-- is_satisfiable true->false for an over-ask). Live full-RPC testing of THIS specific
-- array-widening against real historical undispatched VOX rows hit two consecutive
-- unrelated pre-existing data-integrity blockers on the only two candidate rows found
-- (a conservation_violation stop-ship on VOXMM-1013/2026-08-15, and a WEIMI
-- slot-binding-drift block on VOXMCC-1005/2026-08-14, shelf A16 showing WEIMI="Aquafina"
-- vs planned "Vitamin Well - Zero Lemon" — both pre-existing data debt unrelated to
-- this patch). Given the delegated mechanism is already proven and this patch is a
-- simple array-widening with no new logic of its own, this is treated as sufficient;
-- disclosed in the PRD-118 report rather than claimed as a clean positive-path test.
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p
   WHERE p.proname='push_plan_to_dispatch' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '8290d51f6c0e5078da2eeb1a2d6afe04' THEN
    RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_new := replace(v_def, 'v_primary_warehouse_id uuid;', 'v_primary_warehouse_id uuid;
  v_secondary_warehouse_id uuid;');
  IF v_new = v_def THEN RAISE EXCEPTION 'declare 1 not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def, 'v_line_wh_id           uuid;', 'v_line_wh_id           uuid;
  v_wh_candidates        uuid[];');
  IF v_new = v_def THEN RAISE EXCEPTION 'declare 2 not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
    'SELECT machine_id, primary_warehouse_id INTO v_machine_id, v_primary_warehouse_id
    FROM machines WHERE official_name = p_machine_name;',
    'SELECT machine_id, primary_warehouse_id, secondary_warehouse_id
    INTO v_machine_id, v_primary_warehouse_id, v_secondary_warehouse_id
    FROM machines WHERE official_name = p_machine_name;');
  IF v_new = v_def THEN RAISE EXCEPTION 'select not found'; END IF;
  v_def := v_new;

  v_new := replace(v_def,
$$    v_line_wh_id := CASE WHEN v_storage_temp = 'cold' THEN public.wh_central_id()
                         ELSE v_primary_warehouse_id END;

    IF v_pin_eligible AND v_line_wh_id IS NOT NULL THEN
      SELECT f.wh_inventory_id, f.expiration_date, f.warehouse_id
        INTO v_pinned_wh_id, v_pinned_expiry, v_pinned_route_wh
      FROM public.wh_fefo_for_line(
             v_machine_id, v_boonz_product_id, line.plan_date, line.quantity,
             ARRAY[v_line_wh_id]) f$$,
$$    -- PRD-118 item D fix #4: a non-cold line must also consider the machine's own
    -- secondary_warehouse_id (e.g. WH_CENTRAL for a VOX machine whose primary is a
    -- consignment warehouse), not just primary/cold-override alone. Cold-chain routing
    -- is left untouched on purpose (single-candidate wh_central_id() override) pending
    -- a CS decision on whether cold items should also consider a secondary warehouse.
    v_line_wh_id := CASE WHEN v_storage_temp = 'cold' THEN public.wh_central_id()
                         ELSE v_primary_warehouse_id END;
    v_wh_candidates := CASE WHEN v_storage_temp = 'cold' THEN ARRAY[v_line_wh_id]
                            ELSE ARRAY[v_line_wh_id, v_secondary_warehouse_id] END;

    IF v_pin_eligible AND v_line_wh_id IS NOT NULL THEN
      SELECT f.wh_inventory_id, f.expiration_date, f.warehouse_id
        INTO v_pinned_wh_id, v_pinned_expiry, v_pinned_route_wh
      FROM public.wh_fefo_for_line(
             v_machine_id, v_boonz_product_id, line.plan_date, line.quantity,
             v_wh_candidates) f$$);
  IF v_new = v_def THEN RAISE EXCEPTION 'fefo call block not found'; END IF;
  v_def := v_new;

  EXECUTE v_def;
END $mig$;
