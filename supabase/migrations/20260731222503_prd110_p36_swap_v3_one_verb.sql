-- PRD-110 P3.6 — swap_v3: the one-verb swap (BUILD-SPEC line 94, charter E3).
--
-- A swap is TWO legs on one shelf, recorded as ONE act:
--   drop(outgoing pod)  +  add(incoming pod, qty)
-- Both HARD locked: a human swap is a decision, not a suggestion the engine may
-- relitigate on the next re-run. Both carry one shared swap_group marker so the
-- pair reads as a single act in the ledger.
--
-- ⭐ It writes through record_plan_edit_v3 rather than INSERTing: one writer for
--    the edit ledger, so the supersede chain, the base_qty capture and the
--    append-only trigger all keep their single owner.
-- ⛔ It does NOT re-check guardrail_products: preflight_refill_plan already owns
--    that rule and a second copy is exactly the D-35 defect.
-- ⛔ Shelf identity resolves through v_shelf_state (shelf_id), never shelf_code.

CREATE OR REPLACE FUNCTION public.swap_v3(
  p_plan_date            date,
  p_machine_id           uuid,
  p_shelf_id             uuid,
  p_new_pod_product_id   uuid,
  p_reason               text,
  p_qty                  integer DEFAULT NULL,
  p_cross_machine_source uuid    DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id     uuid;
  v_shelf_mach  uuid;
  v_pod_out     uuid;
  v_pod_out_nm  text;
  v_new_nm      text;
  v_cap         int;
  v_qty         int;
  v_group       uuid := gen_random_uuid();
  v_dup_shelf   uuid;
  v_dup_src     text;
  v_donor_stock int;
  v_reason      text;
  v_drop        jsonb;
  v_add         jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',    true);
  PERFORM set_config('app.rpc_name', 'swap_v3', true);

  -- Role gate, identical in shape to record_plan_edit_v3 / stitch_v3.
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'swap_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL
     OR p_new_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'swap_v3: plan_date, machine_id, shelf_id and new_pod_product_id are all required';
  END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'swap_v3: reason must be at least 10 characters (got %)',
      COALESCE(char_length(btrim(p_reason)), 0);
  END IF;
  IF p_qty IS NOT NULL AND p_qty < 1 THEN
    RAISE EXCEPTION 'swap_v3: qty must be >= 1 when given (got %)', p_qty;
  END IF;

  ----------------------------------------------------------------------------
  -- (1) The shelf, and the machine it ACTUALLY belongs to.
  ----------------------------------------------------------------------------
  SELECT vs.machine_id, vs.pod_product_id, vs.pod_name, vs.max_stock
    INTO v_shelf_mach, v_pod_out, v_pod_out_nm, v_cap
    FROM public.v_shelf_state vs
   WHERE vs.shelf_id = p_shelf_id
   LIMIT 1;

  IF v_shelf_mach IS NULL THEN
    RAISE EXCEPTION 'swap_v3: shelf % resolves to no machine in v_shelf_state', p_shelf_id;
  END IF;
  IF v_shelf_mach <> p_machine_id THEN
    RAISE EXCEPTION 'swap_v3: shelf % belongs to machine %, not the machine % you named',
      p_shelf_id, v_shelf_mach, p_machine_id;
  END IF;

  SELECT pp.pod_product_name INTO v_new_nm
    FROM public.pod_products pp WHERE pp.pod_product_id = p_new_pod_product_id;
  IF v_new_nm IS NULL THEN
    RAISE EXCEPTION 'swap_v3: pod_product % does not exist', p_new_pod_product_id;
  END IF;

  IF v_pod_out IS NOT NULL AND v_pod_out = p_new_pod_product_id THEN
    RAISE EXCEPTION 'swap_v3: pod % is already the pod on shelf % - that is not a swap',
      v_new_nm, p_shelf_id;
  END IF;

  ----------------------------------------------------------------------------
  -- (2) THE IN-MACHINE DUPLICATE GUARD (CS rule, 2026-07-31).
  --     A pod may not land on two shelves of one machine. "Already there" means
  --     either physically assorted OR carried by a pending add edit for this
  --     same plan_date -- a duplicate minted by two edits is still the bug.
  --     An assorted pod that an active drop edit is removing does NOT count:
  --     it is on its way out, which is what makes swap chains legal.
  ----------------------------------------------------------------------------
  SELECT vs.shelf_id INTO v_dup_shelf
    FROM public.v_shelf_state vs
   WHERE vs.machine_id = p_machine_id
     AND vs.shelf_id <> p_shelf_id
     AND vs.pod_product_id = p_new_pod_product_id
     AND NOT EXISTS (
       SELECT 1 FROM public.v_plan_edits_active_v3 x
        WHERE x.plan_date = p_plan_date
          AND x.shelf_id = vs.shelf_id
          AND x.pod_product_id = p_new_pod_product_id
          AND x.kind = 'drop')
   LIMIT 1;
  IF v_dup_shelf IS NOT NULL THEN v_dup_src := 'assorted'; END IF;

  IF v_dup_shelf IS NULL THEN
    SELECT x.shelf_id INTO v_dup_shelf
      FROM public.v_plan_edits_active_v3 x
     WHERE x.plan_date = p_plan_date
       AND x.machine_id = p_machine_id
       AND x.shelf_id <> p_shelf_id
       AND x.pod_product_id = p_new_pod_product_id
       AND x.kind IN ('add','set_qty')
     LIMIT 1;
    IF v_dup_shelf IS NOT NULL THEN v_dup_src := 'pending edit'; END IF;
  END IF;

  IF v_dup_shelf IS NOT NULL THEN
    RAISE EXCEPTION 'swap_v3: pod % is already on shelf % of machine % (%) - swapping it in here would duplicate it within the machine',
      v_new_nm, v_dup_shelf, p_machine_id, v_dup_src;
  END IF;

  ----------------------------------------------------------------------------
  -- (3) Quantity. Default is fill-to-capacity, which is what a human means by
  --     "put this on the shelf" when they do not name a number.
  ----------------------------------------------------------------------------
  v_qty := COALESCE(p_qty, NULLIF(v_cap, 0));
  IF v_qty IS NULL OR v_qty < 1 THEN
    RAISE EXCEPTION 'swap_v3: shelf % has no positive capacity and no qty was given', p_shelf_id;
  END IF;

  ----------------------------------------------------------------------------
  -- (4) Cross-machine source, when named, must genuinely hold the pod.
  ----------------------------------------------------------------------------
  IF p_cross_machine_source IS NOT NULL THEN
    IF p_cross_machine_source = p_machine_id THEN
      RAISE EXCEPTION 'swap_v3: cross_machine_source % is the destination machine itself',
        p_cross_machine_source;
    END IF;
    SELECT COALESCE(max(vs.current_stock), -1) INTO v_donor_stock
      FROM public.v_shelf_state vs
     WHERE vs.machine_id = p_cross_machine_source
       AND vs.pod_product_id = p_new_pod_product_id;
    IF v_donor_stock < 0 THEN
      RAISE EXCEPTION 'swap_v3: donor machine % does not carry pod %',
        p_cross_machine_source, v_new_nm;
    END IF;
    IF v_donor_stock < 1 THEN
      RAISE EXCEPTION 'swap_v3: donor machine % carries pod % but holds no stock',
        p_cross_machine_source, v_new_nm;
    END IF;
  END IF;

  ----------------------------------------------------------------------------
  -- (5) THE LEGS. One group, both hard, recorded through the canonical writer.
  --     ⛔ drop FIRST: the shelf is vacated before it is refilled, so no reader
  --        of the ledger ever sees two pods claiming one shelf.
  ----------------------------------------------------------------------------
  v_reason := btrim(p_reason) || ' [swap_group:' || v_group::text || ']';

  IF v_pod_out IS NOT NULL THEN
    v_drop := public.record_plan_edit_v3(
      p_plan_date, p_shelf_id, v_pod_out, 'drop', NULL, 'hard',
      v_reason || ' [leg:drop out=' || COALESCE(v_pod_out_nm,'?') || ']');
  END IF;

  v_add := public.record_plan_edit_v3(
    p_plan_date, p_shelf_id, p_new_pod_product_id, 'add', v_qty, 'hard',
    v_reason || ' [leg:add in=' || v_new_nm || ']'
      || CASE WHEN p_cross_machine_source IS NOT NULL
              THEN ' [source_machine:' || p_cross_machine_source::text || ']'
              ELSE ' [source:warehouse]' END);

  RETURN jsonb_build_object(
    'status','ok',
    'swap_group_id', v_group,
    'plan_date', p_plan_date,
    'machine_id', p_machine_id,
    'shelf_id', p_shelf_id,
    'pod_out', v_pod_out,
    'pod_out_name', v_pod_out_nm,
    'pod_in', p_new_pod_product_id,
    'pod_in_name', v_new_nm,
    'qty', v_qty,
    'qty_defaulted_to_capacity', (p_qty IS NULL),
    'source_machine_id', p_cross_machine_source,
    'source', CASE WHEN p_cross_machine_source IS NOT NULL THEN 'cross_machine' ELSE 'warehouse' END,
    'donor_stock', v_donor_stock,
    'legs', CASE WHEN v_drop IS NULL
                 THEN jsonb_build_array(v_add)
                 ELSE jsonb_build_array(v_drop, v_add) END);
END
$function$;

REVOKE ALL ON FUNCTION public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid) TO authenticated, service_role;
