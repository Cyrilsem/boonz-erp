-- PRD-019 A2 (AC-A1) + A3 (AC-A3): capacity clamp on the manual fill RPCs.
-- NOT APPLIED. Author-only; apply after CS sign-off (after A1 view).
-- Both functions are the LIVE body verbatim with a capacity clamp added:
--   * REFILL / ADD_NEW: qty is clamped so it never exceeds the shelf headroom
--     (v_shelf_capacity). When clamped, clamp_reason='capacity_capped' plus the
--     requested qty and the cap are recorded in reasoning and returned. No
--     silent over-fill (R-A1). REMOVE / M2W / NOTHING are removals: not clamped.
--   * ADD_NEW also returns a projected per-flavor split + variant/line count
--     (A3) from product_mapping so the caller can confirm a multi-variant seed.
-- Audit trail (pod_refill_plan_audit) records the EFFECTIVE qty.

-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.add_pod_refill_row(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text, p_qty integer, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_machine_name text;
  v_shelf_code   text;
  v_locked_boonz int;
  v_after        jsonb;
  -- PRD-019 A2/A3 capacity clamp
  v_eff_qty      integer := p_qty;
  v_cap_max      integer;
  v_headroom     integer;
  v_cur          integer;
  v_clamped      boolean := false;
  v_clamp        jsonb   := NULL;
  v_proj         jsonb   := NULL;
  v_variant_n    integer := 0;
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

  -- PRD-019 A2 (AC-A1): clamp additive actions to shelf headroom. No silent over-fill.
  IF p_action IN ('REFILL','ADD_NEW') THEN
    SELECT max_stock, current_stock, headroom
      INTO v_cap_max, v_cur, v_headroom
    FROM public.v_shelf_capacity WHERE shelf_id = p_shelf_id;
    IF v_cap_max IS NOT NULL AND p_qty > COALESCE(v_headroom, 0) THEN
      v_eff_qty := GREATEST(COALESCE(v_headroom, 0), 0);
      v_clamped := true;
      v_clamp := jsonb_build_object(
        'clamp_reason', 'capacity_capped',
        'requested_qty', p_qty,
        'capped_to', v_eff_qty,
        'max_stock', v_cap_max,
        'current_stock', v_cur,
        'headroom', v_headroom);
    END IF;
    -- PRD-019 A3 (AC-A3): for ADD_NEW, surface the multi-variant projection so
    -- the caller can confirm the per-flavor split a fill-to-headroom implies.
    IF p_action = 'ADD_NEW' THEN
      WITH variants AS (
        SELECT DISTINCT ON (pm.boonz_product_id)
               pm.boonz_product_id, bp.boonz_product_name,
               COALESCE(pm.split_pct, 0)::numeric AS split_pct
        FROM public.product_mapping pm
        LEFT JOIN public.boonz_products bp ON bp.product_id = pm.boonz_product_id
        WHERE pm.pod_product_id = p_pod_product_id AND pm.status = 'Active'
          AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL)
        ORDER BY pm.boonz_product_id, (pm.machine_id = p_machine_id) DESC NULLS LAST
      ), tot AS (SELECT NULLIF(SUM(split_pct), 0) AS s FROM variants)
      SELECT COUNT(*),
             COALESCE(jsonb_agg(jsonb_build_object(
               'boonz_product_id', v.boonz_product_id,
               'boonz_product_name', v.boonz_product_name,
               'projected_qty', CASE WHEN tot.s IS NULL THEN NULL
                                     ELSE ROUND(v_eff_qty * v.split_pct / tot.s) END)
               ORDER BY v.boonz_product_name), '[]'::jsonb)
        INTO v_variant_n, v_proj
      FROM variants v CROSS JOIN tot;
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'add_pod_refill_row', true);

  INSERT INTO public.pod_refill_plan
    (plan_date, machine_id, shelf_id, pod_product_id, action, qty, status,
     source_origin, reasoning, created_at, updated_at, edited_at, edited_by)
  VALUES
    (p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action, v_eff_qty, 'draft',
     'warehouse',
     jsonb_build_object('manual_add', jsonb_build_object(
        'at', now(), 'reason', p_reason, 'qty', v_eff_qty, 'requested_qty', p_qty,
        'by', COALESCE(auth.uid()::text, current_user)))
       || CASE WHEN v_clamped THEN jsonb_build_object('capacity_clamp', v_clamp) ELSE '{}'::jsonb END,
     now(), now(), now(), COALESCE(auth.uid()::text, current_user));

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
    'pod_product_id', p_pod_product_id, 'action', p_action,
    'qty', v_eff_qty, 'requested_qty', p_qty,
    'clamp_reason', CASE WHEN v_clamped THEN 'capacity_capped' ELSE NULL END,
    'capacity_clamp', v_clamp,
    'add_new_projection', CASE WHEN p_action = 'ADD_NEW'
      THEN jsonb_build_object('variant_count', v_variant_n, 'projected_line_count', v_variant_n, 'projected_split', v_proj)
      ELSE NULL END,
    'after', v_after, 'restitch_required', true);
END $function$;

-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.edit_pod_refill_row(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text, p_new_qty integer, p_reason text DEFAULT NULL::text, p_conductor_session text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row            public.pod_refill_plan;
  v_before         jsonb;
  v_after          jsonb;
  v_locked_boonz   int;
  v_machine_name   text;
  v_shelf_code     text;
  v_edit_type      text;
  -- PRD-019 A2 capacity clamp
  v_eff_qty        integer := p_new_qty;
  v_cap_max        integer;
  v_headroom       integer;
  v_cur            integer;
  v_clamped        boolean := false;
  v_clamp          jsonb   := NULL;
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

  -- PRD-019 A2 (AC-A1): clamp additive edits to shelf headroom. No silent over-fill.
  IF p_action IN ('REFILL','ADD_NEW') THEN
    SELECT max_stock, current_stock, headroom
      INTO v_cap_max, v_cur, v_headroom
    FROM public.v_shelf_capacity WHERE shelf_id = p_shelf_id;
    IF v_cap_max IS NOT NULL AND p_new_qty > COALESCE(v_headroom, 0) THEN
      v_eff_qty := GREATEST(COALESCE(v_headroom, 0), 0);
      v_clamped := true;
      v_clamp := jsonb_build_object(
        'clamp_reason', 'capacity_capped',
        'requested_qty', p_new_qty,
        'capped_to', v_eff_qty,
        'max_stock', v_cap_max,
        'current_stock', v_cur,
        'headroom', v_headroom);
    END IF;
  END IF;

  v_before := jsonb_build_object(
    'qty', v_row.qty,
    'action', v_row.action,
    'pod_product_id', v_row.pod_product_id,
    'reasoning', v_row.reasoning
  );

  v_edit_type := CASE WHEN v_eff_qty = 0 THEN 'stop' ELSE 'qty' END;

  UPDATE public.pod_refill_plan
  SET qty        = v_eff_qty,
      edited_at  = now(),
      edited_by  = COALESCE(auth.uid()::text, current_user),
      reasoning  = reasoning || jsonb_build_object(
                     'manual_edit', jsonb_build_object(
                       'at',     now(),
                       'type',   v_edit_type,
                       'reason', p_reason,
                       'old_qty', v_row.qty,
                       'new_qty', v_eff_qty,
                       'requested_qty', p_new_qty
                     )
                   )
                   || CASE WHEN v_clamped THEN jsonb_build_object('capacity_clamp', v_clamp) ELSE '{}'::jsonb END,
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
    'qty', v_eff_qty, 'requested_qty', p_new_qty,
    'clamp_reason', CASE WHEN v_clamped THEN 'capacity_capped' ELSE NULL END,
    'capacity_clamp', v_clamp,
    'before', v_before,
    'after',  v_after,
    'restitch_required', true
  );
END $function$;
