-- RD-05: expiry-aware FEFO pick at edit time. NOT YET APPLIED (output-only goal).
--
-- (1) pin column on the pod-level plan row (NULL = let stitch FEFO decide).
-- (2) get_shelf_fefo_options: read-only (INVOKER) batch list by expiry for product × machine's WH(s).
-- (3) edit_/add_pod_refill_row gain an optional p_preferred_wh_inventory_id. SHAPE (Cody/Art.12, the
--     #6 precedent — NO DROP of a core writer): the existing 8-arg signature is replaced IN PLACE
--     with a thin wrapper that delegates to a NEW 9-arg carrying the live body VERBATIM + the pin.
--     The 9-arg has no default on the pin (avoids 8-arg call ambiguity). Diff-gate target: the 9-arg
--     body vs the live 8-arg body differs ONLY by the new param + the one pin assignment.
-- Cody: Articles 4,5,8,12,15 (register get_shelf_fefo_options as a read-only helper).

ALTER TABLE public.pod_refill_plan
  ADD COLUMN IF NOT EXISTS preferred_wh_inventory_id uuid
  REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE SET NULL;
COMMENT ON COLUMN public.pod_refill_plan.preferred_wh_inventory_id IS
  'RD-05: operator-pinned WH batch (by expiry); stitch prefers it over default FEFO; NULL = FEFO.';

-- ── (2) get_shelf_fefo_options — read-only, FEFO-ordered, warehouse_stock>0 ───────────────────
CREATE OR REPLACE FUNCTION public.get_shelf_fefo_options(
  p_machine_id uuid,
  p_boonz_product_id uuid
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
  WITH wh AS (
    SELECT w AS warehouse_id
    FROM public.machines m
    CROSS JOIN LATERAL unnest(ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id]) AS w
    WHERE m.machine_id = p_machine_id AND w IS NOT NULL
  ),
  batches AS (
    SELECT wi.wh_inventory_id, wi.warehouse_id, wi.expiration_date,
           wi.warehouse_stock::int AS warehouse_stock,
           (wi.expiration_date - CURRENT_DATE) AS days_to_expiry,
           ROW_NUMBER() OVER (ORDER BY wi.expiration_date ASC NULLS LAST, wi.wh_inventory_id) AS fefo_rank
    FROM public.warehouse_inventory wi
    JOIN wh ON wh.warehouse_id = wi.warehouse_id
    WHERE wi.boonz_product_id = p_boonz_product_id
      AND wi.status = 'Active' AND wi.quarantined = false AND wi.warehouse_stock > 0
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'wh_inventory_id', wh_inventory_id, 'warehouse_id', warehouse_id,
    'expiration_date', expiration_date, 'warehouse_stock', warehouse_stock,
    'days_to_expiry', days_to_expiry, 'is_fefo_default', (fefo_rank = 1)
  ) ORDER BY fefo_rank), '[]'::jsonb)
  FROM batches;
$function$;
GRANT EXECUTE ON FUNCTION public.get_shelf_fefo_options(uuid,uuid) TO authenticated;

-- ── (3a) edit_pod_refill_row: 9-arg full body (live + pin) + 8-arg wrapper ────────────────────
CREATE OR REPLACE FUNCTION public.edit_pod_refill_row(
  p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text,
  p_new_qty integer, p_reason text, p_conductor_session text, p_preferred_wh_inventory_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_row            public.pod_refill_plan;
  v_before         jsonb;
  v_after          jsonb;
  v_locked_boonz   int;
  v_machine_name   text;
  v_shelf_code     text;
  v_edit_type      text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: edit_pod_refill_row requires operator_admin, superadmin, or warehouse';
  END IF;

  IF p_new_qty IS NULL OR p_new_qty < 0 THEN
    RAISE EXCEPTION 'invalid qty: % (must be >= 0)', p_new_qty;
  END IF;
  IF p_action NOT IN ('REFILL','ADD_NEW','REMOVE','M2W','NOTHING') THEN
    RAISE EXCEPTION 'invalid action key: %', p_action;
  END IF;

  -- RD-05 E5: refuse pinning an already-expired batch.
  IF p_preferred_wh_inventory_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouse_inventory wi
    WHERE wi.wh_inventory_id = p_preferred_wh_inventory_id
      AND wi.expiration_date IS NOT NULL AND wi.expiration_date < p_plan_date
  ) THEN
    RAISE EXCEPTION 'edit_pod_refill_row: pinned batch % expires before plan_date %', p_preferred_wh_inventory_id, p_plan_date;
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'edit_pod_refill_row', true);

  SELECT * INTO v_row
  FROM public.pod_refill_plan
  WHERE plan_date = p_plan_date
    AND machine_id = p_machine_id
    AND shelf_id = p_shelf_id
    AND pod_product_id = p_pod_product_id
    AND action = p_action;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pod_refill_plan row not found for (%, %, %, %, %)',
      p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action;
  END IF;

  SELECT m.official_name, sc.shelf_code
    INTO v_machine_name, v_shelf_code
  FROM public.machines m
  JOIN public.shelf_configurations sc ON sc.shelf_id = p_shelf_id
  WHERE m.machine_id = p_machine_id;

  SELECT COUNT(*) INTO v_locked_boonz
  FROM public.refill_plan_output rpo
  WHERE rpo.plan_date = p_plan_date
    AND rpo.machine_name = v_machine_name
    AND rpo.shelf_code   = v_shelf_code
    AND COALESCE(rpo.tier, 'phase_f_stitch') = 'phase_f_stitch'
    AND rpo.operator_status != 'pending';

  IF v_locked_boonz > 0 THEN
    RAISE EXCEPTION 'cannot edit: % linked refill_plan_output row(s) past pending. Edit only applies to next plan.', v_locked_boonz;
  END IF;

  v_before := jsonb_build_object(
    'qty', v_row.qty,
    'action', v_row.action,
    'pod_product_id', v_row.pod_product_id,
    'reasoning', v_row.reasoning
  );

  v_edit_type := CASE WHEN p_new_qty = 0 THEN 'stop' ELSE 'qty' END;

  UPDATE public.pod_refill_plan
  SET qty        = p_new_qty,
      preferred_wh_inventory_id = COALESCE(p_preferred_wh_inventory_id, preferred_wh_inventory_id),
      edited_at  = now(),
      edited_by  = COALESCE(auth.uid()::text, current_user),
      reasoning  = reasoning || jsonb_build_object(
                     'manual_edit', jsonb_build_object(
                       'at',     now(),
                       'type',   v_edit_type,
                       'reason', p_reason,
                       'old_qty', v_row.qty,
                       'new_qty', p_new_qty
                     )
                   ),
      updated_at = now()
  WHERE plan_date = p_plan_date
    AND machine_id = p_machine_id
    AND shelf_id = p_shelf_id
    AND pod_product_id = p_pod_product_id
    AND action = p_action;

  SELECT jsonb_build_object(
    'qty', qty, 'action', action,
    'pod_product_id', pod_product_id, 'reasoning', reasoning
  ) INTO v_after
  FROM public.pod_refill_plan
  WHERE plan_date = p_plan_date
    AND machine_id = p_machine_id
    AND shelf_id = p_shelf_id
    AND pod_product_id = p_pod_product_id
    AND action = p_action;

  INSERT INTO public.pod_refill_plan_audit
    (plan_date, machine_id, shelf_id, pod_product_id, action,
     edit_type, before_state, after_state, reason, conductor_session)
  VALUES
    (p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action,
     v_edit_type, v_before, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object(
    'plan_date', p_plan_date,
    'machine_id', p_machine_id,
    'shelf_id', p_shelf_id,
    'pod_product_id', p_pod_product_id,
    'action', p_action,
    'edit_type', v_edit_type,
    'before', v_before,
    'after',  v_after,
    'restitch_required', true
  );
END $function$;
GRANT EXECUTE ON FUNCTION public.edit_pod_refill_row(date,uuid,uuid,uuid,text,integer,text,text,uuid) TO authenticated;

-- 8-arg wrapper: in-place replace, delegates to the 9-arg with NULL pin (backward compatible).
CREATE OR REPLACE FUNCTION public.edit_pod_refill_row(
  p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text,
  p_new_qty integer, p_reason text DEFAULT NULL, p_conductor_session text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.edit_pod_refill_row(p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id,
    p_action, p_new_qty, p_reason, p_conductor_session, NULL::uuid);
END $function$;

-- ── (3b) add_pod_refill_row: 9-arg full body (live + pin) + 8-arg wrapper ─────────────────────
CREATE OR REPLACE FUNCTION public.add_pod_refill_row(
  p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text,
  p_qty integer, p_reason text, p_conductor_session text, p_preferred_wh_inventory_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_machine_name text;
  v_shelf_code   text;
  v_locked_boonz int;
  v_after        jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: add_pod_refill_row requires operator_admin, superadmin, or warehouse';
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL
     OR p_pod_product_id IS NULL OR p_action IS NULL THEN
    RAISE EXCEPTION 'add_pod_refill_row: all 5 PK columns required';
  END IF;
  IF p_qty IS NULL OR p_qty < 0 THEN
    RAISE EXCEPTION 'invalid qty: % (must be >= 0)', p_qty;
  END IF;
  IF p_action NOT IN ('REFILL','ADD_NEW','REMOVE','M2W') THEN
    RAISE EXCEPTION 'invalid action key: %', p_action;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.pod_products WHERE pod_product_id = p_pod_product_id) THEN
    RAISE EXCEPTION 'add_pod_refill_row: pod_product_id % does not exist (pick from the product list)', p_pod_product_id;
  END IF;

  -- RD-05 E5: refuse pinning an already-expired batch.
  IF p_preferred_wh_inventory_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.warehouse_inventory wi
    WHERE wi.wh_inventory_id = p_preferred_wh_inventory_id
      AND wi.expiration_date IS NOT NULL AND wi.expiration_date < p_plan_date
  ) THEN
    RAISE EXCEPTION 'add_pod_refill_row: pinned batch % expires before plan_date %', p_preferred_wh_inventory_id, p_plan_date;
  END IF;

  SELECT m.official_name, sc.shelf_code
    INTO v_machine_name, v_shelf_code
  FROM public.machines m
  JOIN public.shelf_configurations sc ON sc.shelf_id = p_shelf_id
  WHERE m.machine_id = p_machine_id;
  IF v_shelf_code IS NULL THEN
    RAISE EXCEPTION 'add_pod_refill_row: shelf % not found on machine %', p_shelf_id, p_machine_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.pod_refill_plan
    WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
      AND pod_product_id=p_pod_product_id AND action=p_action
  ) THEN
    RAISE EXCEPTION 'add_pod_refill_row: row already exists for this 5-tuple; use edit_pod_refill_row or restore_pod_refill_row';
  END IF;

  SELECT COUNT(*) INTO v_locked_boonz
  FROM public.refill_plan_output rpo
  WHERE rpo.plan_date = p_plan_date
    AND rpo.machine_name = v_machine_name
    AND rpo.shelf_code   = v_shelf_code
    AND COALESCE(rpo.tier,'phase_f_stitch') = 'phase_f_stitch'
    AND rpo.operator_status != 'pending';
  IF v_locked_boonz > 0 THEN
    RAISE EXCEPTION 'cannot add: % linked refill_plan_output row(s) past pending on this shelf', v_locked_boonz;
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'add_pod_refill_row', true);

  INSERT INTO public.pod_refill_plan
    (plan_date, machine_id, shelf_id, pod_product_id, action, qty, status,
     source_origin, reasoning, created_at, updated_at, edited_at, edited_by, preferred_wh_inventory_id)
  VALUES
    (p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action, p_qty, 'draft',
     'warehouse',
     jsonb_build_object('manual_add', jsonb_build_object(
        'at', now(), 'reason', p_reason, 'qty', p_qty,
        'by', COALESCE(auth.uid()::text, current_user))),
     now(), now(), now(), COALESCE(auth.uid()::text, current_user), p_preferred_wh_inventory_id);

  SELECT jsonb_build_object('qty',qty,'action',action,'pod_product_id',pod_product_id,
                            'status',status,'source_origin',source_origin)
    INTO v_after
  FROM public.pod_refill_plan
  WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
    AND pod_product_id=p_pod_product_id AND action=p_action;

  INSERT INTO public.pod_refill_plan_audit
    (plan_date, machine_id, shelf_id, pod_product_id, action,
     edit_type, before_state, after_state, reason, conductor_session)
  VALUES
    (p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action,
     'add', '{}'::jsonb, v_after, p_reason, p_conductor_session);

  RETURN jsonb_build_object(
    'plan_date', p_plan_date, 'machine_name', v_machine_name, 'shelf_code', v_shelf_code,
    'pod_product_id', p_pod_product_id, 'action', p_action, 'qty', p_qty,
    'after', v_after, 'restitch_required', true);
END $function$;
GRANT EXECUTE ON FUNCTION public.add_pod_refill_row(date,uuid,uuid,uuid,text,integer,text,text,uuid) TO authenticated;

-- 8-arg wrapper: in-place replace, delegates to the 9-arg with NULL pin (backward compatible).
CREATE OR REPLACE FUNCTION public.add_pod_refill_row(
  p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text,
  p_qty integer, p_reason text DEFAULT NULL, p_conductor_session text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.add_pod_refill_row(p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id,
    p_action, p_qty, p_reason, p_conductor_session, NULL::uuid);
END $function$;
