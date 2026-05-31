-- PRD-015 Phase C / C3 — add 'warehouse' to the role tier of the pod_refill_plan edit RPCs.
-- Tier-only widening (operator_admin/superadmin -> +warehouse); NO logic change; locked-row
-- guards intact. Bodies are VERBATIM copies of the live pg_get_functiondef (2026-05-31) with
-- the single role-array change. stop_pod_refill_row is a thin wrapper delegating to
-- edit_pod_refill_row, so it inherits the widened gate (no change needed).
-- find_substitutes_for_shelf already allows warehouse.
-- REVIEW: diff each body against live before apply; only delta is +'warehouse' in the role ANY().
-- NOT YET APPLIED.

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
BEGIN
  -- Article 4: role validation (service-role bypass when auth.uid() NULL)
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: edit_pod_refill_row requires operator_admin, superadmin, or warehouse';
  END IF;

  -- Article 4: input validation
  IF p_new_qty IS NULL OR p_new_qty < 0 THEN
    RAISE EXCEPTION 'invalid qty: % (must be >= 0)', p_new_qty;
  END IF;
  IF p_action NOT IN ('REFILL','ADD_NEW','REMOVE','M2W','NOTHING') THEN
    RAISE EXCEPTION 'invalid action key: %', p_action;
  END IF;

  -- Article 4: GUCs for audit trigger
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'edit_pod_refill_row', true);

  -- 1) Find the row
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

  -- 2) Lock check: any linked boonz row past pending blocks the edit
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

  -- 3) Snapshot before
  v_before := jsonb_build_object(
    'qty', v_row.qty,
    'action', v_row.action,
    'pod_product_id', v_row.pod_product_id,
    'reasoning', v_row.reasoning
  );

  v_edit_type := CASE WHEN p_new_qty = 0 THEN 'stop' ELSE 'qty' END;

  -- 4) Apply
  UPDATE public.pod_refill_plan
  SET qty        = p_new_qty,
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

  -- 5) Audit
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

CREATE OR REPLACE FUNCTION public.restitch_after_edits(p_plan_date date, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_edited_count   int;
  v_locked_count   int;
  v_last_stitch    timestamptz;
  v_will_change    jsonb;
  v_stitch_result  jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: restitch_after_edits requires operator_admin, superadmin, or warehouse';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'restitch_after_edits', true);

  -- Use generated_at as the stitch timestamp (refill_plan_output has no created_at)
  SELECT MAX(generated_at) INTO v_last_stitch
  FROM public.refill_plan_output
  WHERE plan_date = p_plan_date
    AND COALESCE(tier, 'phase_f_stitch') = 'phase_f_stitch';

  SELECT COUNT(*) INTO v_edited_count
  FROM public.pod_refill_plan
  WHERE plan_date = p_plan_date
    AND status = 'approved'
    AND edited_at IS NOT NULL
    AND edited_at > COALESCE(v_last_stitch, '1970-01-01'::timestamptz);

  IF v_edited_count = 0 THEN
    RETURN jsonb_build_object('status', 'no_edits_to_apply', 'edited_rows', 0);
  END IF;

  SELECT COUNT(*) INTO v_locked_count
  FROM public.refill_plan_output
  WHERE plan_date = p_plan_date
    AND COALESCE(tier, 'phase_f_stitch') = 'phase_f_stitch'
    AND operator_status != 'pending';

  WITH edited_pods AS (
    SELECT prp.plan_date, prp.machine_id, prp.shelf_id,
           prp.pod_product_id, prp.action, prp.qty
    FROM public.pod_refill_plan prp
    WHERE prp.plan_date = p_plan_date
      AND prp.status = 'approved'
      AND prp.edited_at IS NOT NULL
      AND prp.edited_at > COALESCE(v_last_stitch, '1970-01-01'::timestamptz)
  )
  SELECT jsonb_agg(jsonb_build_object(
    'machine_name', m.official_name,
    'shelf_code',   sc.shelf_code,
    'pod_product',  pp.pod_product_name,
    'action',       ep.action,
    'new_pod_qty',  ep.qty,
    'old_boonz_qty', rpo.quantity,
    'boonz_locked', CASE WHEN rpo.operator_status IS NULL THEN false
                         WHEN rpo.operator_status = 'pending' THEN false
                         ELSE true END
  )) INTO v_will_change
  FROM edited_pods ep
  JOIN public.machines m              ON m.machine_id = ep.machine_id
  JOIN public.shelf_configurations sc ON sc.shelf_id = ep.shelf_id
  LEFT JOIN public.pod_products pp    ON pp.pod_product_id = ep.pod_product_id
  LEFT JOIN public.refill_plan_output rpo
    ON rpo.plan_date    = p_plan_date
   AND rpo.machine_name = m.official_name
   AND rpo.shelf_code   = sc.shelf_code;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'status',                    'dry_run',
      'edited_pod_rows',           v_edited_count,
      'locked_boonz_rows_skipped', v_locked_count,
      'will_change',               COALESCE(v_will_change, '[]'::jsonb)
    );
  END IF;

  SELECT public.stitch_pod_to_boonz(p_plan_date, false) INTO v_stitch_result;

  RETURN jsonb_build_object(
    'status',                    'committed',
    'edited_pod_rows',           v_edited_count,
    'locked_boonz_rows_skipped', v_locked_count,
    'stitch_result',             v_stitch_result
  );
END $function$;

-- stop_pod_refill_row: thin wrapper -> edit_pod_refill_row. No own role gate; inherits the
-- widened tier above. No change required (documented for completeness).
