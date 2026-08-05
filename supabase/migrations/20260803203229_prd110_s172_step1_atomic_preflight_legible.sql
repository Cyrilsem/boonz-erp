CREATE OR REPLACE FUNCTION public.commit_refill_plan_atomic(p_plan_date date, p_machine_names text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user        uuid;
  v_lock_ctx    text;
  v_ids         uuid[];
  v_stitch      jsonb;
  v_appr        jsonb;
  v_lines_built integer;
  v_output_rows integer;
  v_dispatch_rows integer;
  v_no_dispatch text[];
  v_soft        jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'commit_refill_plan_atomic', true);

  v_user := auth.uid();
  IF v_user IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user AND up.role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: caller % lacks operator_admin/manager role', v_user;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: p_plan_date required';
  END IF;
  IF p_machine_names IS NULL OR array_length(p_machine_names, 1) IS NULL THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: p_machine_names must be a non-empty array';
  END IF;

  SELECT context INTO v_lock_ctx FROM public.refill_plan_lock WHERE plan_date = p_plan_date FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.refill_plan_lock (plan_date, locked_by, locked_at, context)
    VALUES (p_plan_date, v_user, now(), 'commit');
  ELSIF v_lock_ctx <> 'commit' THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: plan % is locked by context "%"; commit refused (PRD-019 D1).', p_plan_date, v_lock_ctx;
  END IF;
  PERFORM set_config('app.refill_lock_context', 'commit', false);

  SELECT array_agg(m.machine_id) INTO v_ids
  FROM public.machines m WHERE m.official_name = ANY (p_machine_names);
  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: none of the named machines resolve to a machine_id';
  END IF;

  PERFORM public.approve_pod_refill_plan(p_plan_date, p_machine_names);

  v_stitch := public.stitch_pod_to_boonz(p_plan_date, false);

  -- ══ PRD-110 S-172 STEP 1: MAKE THE PRE-FLIGHT REFUSAL LEGIBLE ═══════════
  -- stitch_pod_to_boonz returns a rich {status:'preflight_failed', ...} payload
  -- when preflight_enforcement='block' and the plan FAILs. Without this branch
  -- that payload has no write_result key, so the generic guard below reported
  -- only "write_result=null" and discarded the invariant id, the offending
  -- shelf and the fix path. The teeth were real; the recovery was not.
  -- Unreachable while the flag is 'warn' (stitch never returns preflight_failed).
  IF COALESCE(v_stitch->>'status', '') = 'preflight_failed' THEN
    RAISE EXCEPTION '%', format(
      'commit_refill_plan_atomic: PRE-FLIGHT REFUSED this commit (PRD-109 gate, preflight_enforcement=block). '
      '%s invariant violation(s): %s. Nothing was written; the entire commit is rolled back. '
      'First violation [%s] machine=%s shelf=%s: expected %s, found %s. FIX: %s '
      'Full detail: SELECT * FROM public.preflight_refill_plan(%s). '
      'NOTE: an audited single-use override (p_force plus a reason of at least 10 characters) exists on '
      'public.stitch_pod_to_boonz but is NOT reachable from this commit path yet (PRD-110 S-172 step 2); '
      'fix the violation above and re-commit.',
      COALESCE(v_stitch->>'violation_count', '?'),
      COALESCE((SELECT string_agg(DISTINCT vv->>'invariant_id', ', ')
                  FROM jsonb_array_elements(COALESCE(v_stitch->'violations', '[]'::jsonb)) vv), 'none'),
      COALESCE(v_stitch->'violations'->0->>'invariant_id', '?'),
      COALESCE(v_stitch->'violations'->0->>'machine',      '?'),
      COALESCE(v_stitch->'violations'->0->>'shelf_code',   '?'),
      COALESCE(v_stitch->'violations'->0->>'expected',     '?'),
      COALESCE(v_stitch->'violations'->0->>'found',        '?'),
      COALESCE(v_stitch->'violations'->0->>'fix_path',     '(no fix path supplied)'),
      quote_literal(p_plan_date::text));
  END IF;

  v_lines_built := COALESCE((v_stitch->>'lines_built')::int, 0);
  IF COALESCE(v_stitch->'write_result'->>'status', '') <> 'ok' THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: stitch write_result=% — rolling back (PRD-019 E2).', COALESCE(v_stitch->'write_result'->>'status', 'null');
  END IF;

  v_appr := public.approve_refill_plan(p_plan_date, p_machine_names);
  IF COALESCE(v_appr->>'status', '') <> 'ok' THEN
    RAISE EXCEPTION 'commit_refill_plan_atomic: approve_refill_plan failed (%) — rolling back.', COALESCE(v_appr->>'error', v_appr::text);
  END IF;

  SELECT COUNT(*) INTO v_output_rows
  FROM public.refill_plan_output
  WHERE plan_date = p_plan_date AND machine_name = ANY (p_machine_names)
    AND operator_status = 'approved';

  SELECT COUNT(*) INTO v_dispatch_rows
  FROM public.refill_dispatching
  WHERE dispatch_date = p_plan_date AND machine_id = ANY (v_ids) AND include = true;

  IF v_lines_built = 0 OR v_output_rows = 0 OR v_dispatch_rows = 0 THEN
    RAISE EXCEPTION
      'commit_refill_plan_atomic: empty commit (lines_built=%, output_rows=%, dispatch_rows=%) — rolling back (PRD-019 E2).',
      v_lines_built, v_output_rows, v_dispatch_rows;
  END IF;

  SELECT array_agg(name) INTO v_no_dispatch
  FROM unnest(p_machine_names) AS name
  WHERE NOT EXISTS (
    SELECT 1 FROM public.refill_dispatching d
    JOIN public.machines m ON m.machine_id = d.machine_id
    WHERE d.dispatch_date = p_plan_date AND m.official_name = name AND d.include = true);

  IF v_no_dispatch IS NOT NULL THEN
    SELECT jsonb_agg(jsonb_build_object('machine', name, 'note', 'committed_no_actionable_lines'))
      INTO v_soft FROM unnest(v_no_dispatch) AS name;
  END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'plan_date', p_plan_date,
    'machines', array_length(v_ids, 1),
    'output_rows', v_output_rows,
    'dispatch_rows', v_dispatch_rows,
    'lines_built', v_lines_built,
    'soft_flags', v_soft
  );
END;
$function$
;
