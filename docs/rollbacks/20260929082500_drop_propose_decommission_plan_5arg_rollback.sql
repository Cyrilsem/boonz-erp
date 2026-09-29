-- Rollback for the DROP of propose_decommission_plan's 5-arg overload (2026-09-29). Restores it
-- exactly as it was live immediately before the drop (oid 99543, confirmed byte-identical via a
-- whitespace-stripped comparison against pg_get_functiondef before dropping).
--
-- CAUTION: restoring this recreates the exact ambiguous-overload condition
-- check_ambiguous_function_overloads() exists to catch (this signature is a strict prefix of the
-- 6-arg propose_decommission_plan, which stays live). Only run this if the 6-arg version is being
-- rolled back too, or if CS has decided the two need to coexist again with a different fix
-- (for example renaming one of them) -- do not restore this file on its own.
CREATE OR REPLACE FUNCTION public.propose_decommission_plan(p_pod_product_id uuid, p_target_completion_date date, p_max_residual_units integer DEFAULT 0, p_machine_scope uuid[] DEFAULT NULL::uuid[], p_rationale text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id        uuid;
  v_pod_name       text;
  v_target_qty     integer;
  v_machine_count  integer;
  v_intent_id      uuid;
  v_existing_id    uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'propose_decommission_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id
      AND up.role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'propose_decommission_plan: caller % lacks operator_admin role', v_user_id;
  END IF;

  -- Validate inputs
  IF p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_pod_product_id required';
  END IF;
  IF p_target_completion_date IS NULL OR p_target_completion_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'p_target_completion_date must be in the future, got %', p_target_completion_date;
  END IF;
  IF p_max_residual_units IS NULL OR p_max_residual_units < 0 THEN
    RAISE EXCEPTION 'p_max_residual_units must be >= 0';
  END IF;
  IF p_machine_scope IS NOT NULL AND array_length(p_machine_scope, 1) = 0 THEN
    p_machine_scope := NULL;  -- treat empty array as fleet-wide
  END IF;

  -- Resolve pod_product_id to name (and validate existence)
  SELECT pp.pod_product_name INTO v_pod_name
  FROM public.pod_products pp
  WHERE pp.pod_product_id = p_pod_product_id;
  IF v_pod_name IS NULL THEN
    RAISE EXCEPTION 'pod_product % not found', p_pod_product_id;
  END IF;

  -- Per-element FK validation on machine_scope
  IF p_machine_scope IS NOT NULL THEN
    PERFORM 1 FROM unnest(p_machine_scope) AS m(machine_id)
      WHERE NOT EXISTS (SELECT 1 FROM public.machines mc WHERE mc.machine_id = m.machine_id);
    IF FOUND THEN
      RAISE EXCEPTION 'p_machine_scope contains one or more unknown machine_ids';
    END IF;
  END IF;

  -- Compute target_qty: SUM of currently-deployed units across ALL boonz variants
  -- of this pod_product, scoped to machine list (or fleet).
  -- Uses v_pod_inventory_latest to avoid the legacy stale-snapshot inflation.
  SELECT
    COALESCE(SUM(pil.current_stock), 0)::int,
    COUNT(DISTINCT pil.machine_id)::int
  INTO v_target_qty, v_machine_count
  FROM public.v_pod_inventory_latest pil
  JOIN (SELECT DISTINCT pod_product_id, boonz_product_id
          FROM public.product_mapping
         WHERE status = 'Active'
           AND pod_product_id = p_pod_product_id) pm
    ON pm.boonz_product_id = pil.boonz_product_id
  WHERE pil.status = 'Active'
    AND pil.current_stock > 0
    AND (p_machine_scope IS NULL OR pil.machine_id = ANY(p_machine_scope));

  IF v_target_qty = 0 THEN
    RAISE EXCEPTION 'propose_decommission_plan: pod % has 0 deployed units in scope (no-op intent)', v_pod_name;
  END IF;
  IF p_max_residual_units >= v_target_qty THEN
    RAISE EXCEPTION 'p_max_residual_units (%) must be < target_qty (%); else reconcile auto-completes immediately', p_max_residual_units, v_target_qty;
  END IF;

  -- Idempotency: refuse if there's already an active intent for the same (pod, scope)
  SELECT si.intent_id INTO v_existing_id
  FROM public.strategic_intents si
  WHERE si.intent_type = 'decommission'
    AND si.status IN ('queued','in_progress')
    AND si.scope_pod_product_id = p_pod_product_id
    AND (
      (p_machine_scope IS NULL AND si.scope_machine_ids IS NULL)
      OR (p_machine_scope IS NOT NULL AND si.scope_machine_ids IS NOT NULL
          AND p_machine_scope::uuid[] @> si.scope_machine_ids
          AND si.scope_machine_ids @> p_machine_scope::uuid[])
    )
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'message', format('An active decommission intent for pod "%s" already exists with the same scope', v_pod_name),
      'existing_intent_id', v_existing_id
    );
  END IF;

  -- Insert the intent
  INSERT INTO public.strategic_intents(
    intent_type, scope_pod_product_id, scope_boonz_product_id,
    scope_machine_ids, target_completion_date, target_qty,
    acceptance_criteria, operator_rationale, status,
    progress, created_by_engine, created_by
  ) VALUES (
    'decommission',
    p_pod_product_id,
    NULL,                                              -- pod-scoped, boonz left NULL
    p_machine_scope,
    p_target_completion_date,
    v_target_qty,
    jsonb_build_object(
      'pod_product_name', v_pod_name,
      'max_residual_units', p_max_residual_units,
      'computed_at', now(),
      'engine_version', 'phase_f_e2_reframe',
      'machines_in_scope_at_creation', v_machine_count
    ),
    COALESCE(p_rationale, 'Decommission requested by operator'),
    'queued',
    '{}'::jsonb,
    'PRODUCT_OPT',
    v_user_id
  )
  RETURNING intent_id INTO v_intent_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'intent_id', v_intent_id,
    'pod_product_id', p_pod_product_id,
    'pod_product_name', v_pod_name,
    'target_qty', v_target_qty,
    'machine_scope', CASE WHEN p_machine_scope IS NULL THEN 'fleet'
                          ELSE 'subset (' || array_length(p_machine_scope,1)::text || ')' END,
    'machine_count_in_scope_at_creation', v_machine_count,
    'target_completion_date', p_target_completion_date
  );
END;
$function$;
