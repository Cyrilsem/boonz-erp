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

CREATE OR REPLACE FUNCTION public.propose_decommission_plan(p_pod_product_id uuid, p_target_completion_date date, p_max_residual_units integer DEFAULT 0, p_machine_scope uuid[] DEFAULT NULL::uuid[], p_rationale text DEFAULT NULL::text, p_min_pearson numeric DEFAULT 0.30)
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
  v_tags_with_sub  integer;
  v_tags_m2w       integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'propose_decommission_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id AND role = 'operator_admin'
  ) THEN RAISE EXCEPTION 'lacks role'; END IF;

  IF p_pod_product_id IS NULL THEN RAISE EXCEPTION 'p_pod_product_id required'; END IF;
  IF p_target_completion_date IS NULL OR p_target_completion_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'p_target_completion_date must be in the future';
  END IF;
  IF p_max_residual_units IS NULL OR p_max_residual_units < 0 THEN
    RAISE EXCEPTION 'p_max_residual_units must be >= 0';
  END IF;
  IF p_machine_scope IS NOT NULL AND array_length(p_machine_scope, 1) = 0 THEN
    p_machine_scope := NULL;
  END IF;

  SELECT pp.pod_product_name INTO v_pod_name
  FROM public.pod_products pp WHERE pp.pod_product_id = p_pod_product_id;
  IF v_pod_name IS NULL THEN RAISE EXCEPTION 'pod_product % not found', p_pod_product_id; END IF;

  -- Target qty: live pod_inventory across all variants
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
  WHERE pil.status = 'Active' AND pil.current_stock > 0
    AND (p_machine_scope IS NULL OR pil.machine_id = ANY(p_machine_scope));

  IF v_target_qty = 0 THEN
    RAISE EXCEPTION 'no deployed units in scope for "%s"', v_pod_name;
  END IF;
  IF p_max_residual_units >= v_target_qty THEN
    RAISE EXCEPTION 'p_max_residual_units (%) must be < target_qty (%)', p_max_residual_units, v_target_qty;
  END IF;

  -- Dedup
  SELECT si.intent_id INTO v_existing_id
  FROM public.strategic_intents si
  WHERE si.intent_type = 'decommission'
    AND si.status IN ('queued','in_progress')
    AND si.scope_pod_product_id = p_pod_product_id
    AND ((p_machine_scope IS NULL AND si.scope_machine_ids IS NULL)
      OR (p_machine_scope IS NOT NULL AND si.scope_machine_ids IS NOT NULL
          AND p_machine_scope::uuid[] @> si.scope_machine_ids
          AND si.scope_machine_ids @> p_machine_scope::uuid[]))
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object('status','duplicate',
      'message', format('Active decommission for "%s" exists', v_pod_name),
      'existing_intent_id', v_existing_id);
  END IF;

  -- Insert intent
  INSERT INTO public.strategic_intents(
    intent_type, scope_pod_product_id, scope_boonz_product_id,
    scope_machine_ids, target_completion_date, target_qty,
    acceptance_criteria, operator_rationale, status,
    progress, created_by_engine, created_by
  )
  VALUES (
    'decommission', p_pod_product_id, NULL, p_machine_scope,
    p_target_completion_date, v_target_qty,
    jsonb_build_object(
      'pod_product_name', v_pod_name,
      'max_residual_units', p_max_residual_units,
      'machines_in_scope_at_creation', v_machine_count,
      'min_pearson_for_substitute', p_min_pearson,
      'engine_version', 'decommission_v2_with_tags'),
    COALESCE(p_rationale, 'Decommission requested by operator'),
    'queued', '{}'::jsonb, 'PRODUCT_OPT', v_user_id
  )
  RETURNING intent_id INTO v_intent_id;

  -- Materialize per-machine tags with Pearson-pre-decided substitutes
  WITH fleet_v AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric(8,3) AS avg_v30
    FROM public.slot_lifecycle sl
    WHERE sl.archived = false AND sl.is_current = true
    GROUP BY sl.pod_product_id
  ),
  donor_slots AS (
    -- One row per (machine, shelf) that has the pod
    SELECT DISTINCT sl.machine_id, sl.shelf_id, sl.signal,
           m.location_type
    FROM public.slot_lifecycle sl
    JOIN public.v_pod_inventory_latest pil
      ON pil.machine_id = sl.machine_id AND pil.shelf_id = sl.shelf_id AND pil.status='Active'
    JOIN (SELECT DISTINCT pod_product_id, boonz_product_id
            FROM public.product_mapping
           WHERE status='Active' AND pod_product_id = p_pod_product_id) pm
      ON pm.boonz_product_id = pil.boonz_product_id
    JOIN public.machines m ON m.machine_id = sl.machine_id
    WHERE sl.pod_product_id = p_pod_product_id
      AND sl.archived = false AND sl.is_current = true
      AND (p_machine_scope IS NULL OR sl.machine_id = ANY(p_machine_scope))
  ),
  per_machine_donor AS (
    -- Reduce to one (machine, pod) tag — pick the most "DEAD" shelf to surface signal
    SELECT machine_id, location_type,
           MIN(CASE signal WHEN 'DEAD — SWAP NOW' THEN 1 WHEN 'ROTATE OUT' THEN 2
                           WHEN 'WIND DOWN' THEN 3 ELSE 4 END) AS worst_signal_rank,
           string_agg(DISTINCT signal, ', ') AS signals
    FROM donor_slots
    GROUP BY machine_id, location_type
  ),
  sub_candidates AS (
    SELECT pmd.machine_id, pmd.location_type, pmd.signals,
           sub.pod_product_id AS pod_in,
           sub.product_category AS sub_cat,
           fv.avg_v30 AS sub_v30,
           per_m.pearson AS p_machine,
           per_l.pearson AS p_loc,
           ROW_NUMBER() OVER (
             PARTITION BY pmd.machine_id
             ORDER BY
               CASE WHEN per_m.pearson IS NOT NULL THEN 0
                    WHEN per_l.pearson IS NOT NULL THEN 1
                    ELSE 2 END,
               COALESCE(per_m.pearson, per_l.pearson, 0) DESC,
               fv.avg_v30 DESC NULLS LAST,
               sub.pod_product_id
           ) AS rnk
    FROM per_machine_donor pmd
    JOIN public.pod_products sub ON sub.pod_product_id <> p_pod_product_id
    JOIN public.v_warehouse_pod_rollup wpr
      ON wpr.pod_product_id = sub.pod_product_id AND wpr.total_stock > 0
    JOIN fleet_v fv ON fv.pod_product_id = sub.pod_product_id
    -- Guardrails
    LEFT JOIN public.v_pod_inventory_latest pil_check
      ON pil_check.machine_id = pmd.machine_id
     AND pil_check.boonz_product_id IN (SELECT boonz_product_id FROM public.product_mapping
                                         WHERE pod_product_id = sub.pod_product_id AND status='Active')
     AND pil_check.status='Active'
    LEFT JOIN public.strategic_intents si_check
      ON si_check.scope_pod_product_id = sub.pod_product_id
     AND si_check.intent_type = 'decommission'
     AND si_check.status IN ('queued','in_progress')
    -- Pearson sources
    LEFT JOIN public.correlation_pod_per_machine per_m
      ON per_m.machine_id = pmd.machine_id
     AND ((per_m.pod_product_a = p_pod_product_id AND per_m.pod_product_b = sub.pod_product_id)
       OR (per_m.pod_product_b = p_pod_product_id AND per_m.pod_product_a = sub.pod_product_id))
     AND per_m.pearson >= p_min_pearson
    LEFT JOIN public.correlation_pod_per_loc_type per_l
      ON per_l.location_type = pmd.location_type
     AND ((per_l.pod_product_a = p_pod_product_id AND per_l.pod_product_b = sub.pod_product_id)
       OR (per_l.pod_product_b = p_pod_product_id AND per_l.pod_product_a = sub.pod_product_id))
     AND per_l.pearson >= p_min_pearson
    JOIN public.pod_products out_pp ON out_pp.pod_product_id = p_pod_product_id
    WHERE pil_check.machine_id IS NULL
      AND si_check.intent_id IS NULL
      AND (per_m.pearson IS NOT NULL OR per_l.pearson IS NOT NULL OR sub.product_category = out_pp.product_category)
  ),
  best_sub AS (SELECT * FROM sub_candidates WHERE rnk = 1),
  tag_rows AS (
    SELECT
      pmd.machine_id, pmd.signals,
      bs.pod_in, bs.p_machine, bs.p_loc, bs.sub_v30,
      CASE WHEN bs.pod_in IS NOT NULL THEN 'swap_out_with_substitute' ELSE 'swap_out_m2w' END AS directive,
      CASE pmd.worst_signal_rank
        WHEN 1 THEN 2  -- DEAD → priority 2
        WHEN 2 THEN 3
        WHEN 3 THEN 4
        ELSE 5
      END AS prio
    FROM per_machine_donor pmd
    LEFT JOIN best_sub bs ON bs.machine_id = pmd.machine_id
  )
  INSERT INTO public.strategic_machine_tags(
    strategic_intent_id, machine_id, pod_product_id,
    action_directive, substitute_pod_product_id, expected_qty, priority,
    status, proposed_by_engine, reasoning
  )
  SELECT
    v_intent_id, tr.machine_id, p_pod_product_id,
    tr.directive, tr.pod_in,
    NULL,
    tr.prio,
    'proposed', 'PRODUCT_OPT',
    jsonb_build_object(
      'donor_signals', tr.signals,
      'substitute_source',
        CASE WHEN tr.p_machine IS NOT NULL THEN 'pearson_per_machine'
             WHEN tr.p_loc IS NOT NULL     THEN 'pearson_per_loc'
             WHEN tr.pod_in IS NOT NULL    THEN 'category_fallback'
             ELSE NULL END,
      'pearson_per_machine', tr.p_machine,
      'pearson_per_loc', tr.p_loc,
      'sub_fleet_v30', tr.sub_v30,
      'reason', 'decommission')
  FROM tag_rows tr;

  SELECT COUNT(*) FILTER (WHERE action_directive='swap_out_with_substitute'),
         COUNT(*) FILTER (WHERE action_directive='swap_out_m2w')
  INTO v_tags_with_sub, v_tags_m2w
  FROM public.strategic_machine_tags
  WHERE strategic_intent_id = v_intent_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'intent_id', v_intent_id,
    'pod_product_name', v_pod_name,
    'target_qty', v_target_qty,
    'machine_count_in_scope', v_machine_count,
    'tags_proposed', v_tags_with_sub + v_tags_m2w,
    'tags_with_substitute', v_tags_with_sub,
    'tags_m2w', v_tags_m2w,
    'target_completion_date', p_target_completion_date,
    'next_step', 'Review tags + approve_strategic_machine_tags(intent_id)'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.propose_rebalance_plan(p_pod_product_id uuid, p_min_donor_stock integer DEFAULT 3, p_min_donor_v_ratio numeric DEFAULT 0.30, p_rationale text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id        uuid;
  v_pod_name       text;
  v_intent_id      uuid;
  v_donor_count    integer;
  v_total_drainable integer;
  v_wh_now         integer;
  v_recipients_n   integer;
  v_existing_id    uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'propose_rebalance_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id AND role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'propose_rebalance_plan: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_pod_product_id required';
  END IF;

  SELECT pod_product_name INTO v_pod_name
  FROM public.pod_products WHERE pod_product_id = p_pod_product_id;
  IF v_pod_name IS NULL THEN
    RAISE EXCEPTION 'pod_product % not found', p_pod_product_id;
  END IF;

  -- Dedup: refuse if active rebalance for same pod already exists
  SELECT intent_id INTO v_existing_id
  FROM public.strategic_intents
  WHERE intent_type = 'rebalance'
    AND status IN ('queued','in_progress')
    AND scope_pod_product_id = p_pod_product_id
  LIMIT 1;
  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status','duplicate',
      'message', format('Active rebalance intent for pod "%s" already exists', v_pod_name),
      'existing_intent_id', v_existing_id);
  END IF;

  -- Find donor slots and current WH stock
  WITH fleet_v AS (
    SELECT AVG(velocity_30d) AS fleet_v30
    FROM public.slot_lifecycle
    WHERE pod_product_id = p_pod_product_id AND archived=false AND is_current=true
  ),
  donor_slots AS (
    SELECT sl.machine_id, sl.shelf_id,
           SUM(pil.current_stock)::int AS slot_stock,
           sl.velocity_30d, sl.signal
    FROM public.slot_lifecycle sl
    JOIN public.v_pod_inventory_latest pil
      ON pil.machine_id = sl.machine_id AND pil.shelf_id = sl.shelf_id AND pil.status='Active'
    JOIN (SELECT DISTINCT pod_product_id, boonz_product_id
            FROM public.product_mapping
           WHERE status='Active' AND pod_product_id = p_pod_product_id) pm
      ON pm.boonz_product_id = pil.boonz_product_id
    JOIN fleet_v ON true
    WHERE sl.pod_product_id = p_pod_product_id
      AND sl.archived=false AND sl.is_current=true
      AND sl.signal IN ('DEAD — SWAP NOW','WIND DOWN','ROTATE OUT')
      AND (fleet_v.fleet_v30 = 0
        OR sl.velocity_30d / NULLIF(fleet_v.fleet_v30, 0) <= p_min_donor_v_ratio)
    GROUP BY sl.machine_id, sl.shelf_id, sl.velocity_30d, sl.signal
    HAVING SUM(pil.current_stock) >= p_min_donor_stock
  )
  SELECT COUNT(*), COALESCE(SUM(slot_stock), 0)
  INTO v_donor_count, v_total_drainable
  FROM donor_slots;

  IF v_donor_count = 0 THEN
    RAISE EXCEPTION 'propose_rebalance_plan: no donor slots qualify for pod "%" (need ≥%s units on DEAD/WIND DOWN/ROTATE OUT slots with velocity ≤ %s × fleet avg)',
      v_pod_name, p_min_donor_stock, p_min_donor_v_ratio;
  END IF;

  SELECT COALESCE(total_stock, 0) INTO v_wh_now
  FROM public.v_warehouse_pod_rollup WHERE pod_product_id = p_pod_product_id;

  -- Count recipients (slots needing this pod with positive velocity and low stock)
  SELECT COUNT(*) INTO v_recipients_n
  FROM public.slot_lifecycle sl
  WHERE sl.pod_product_id = p_pod_product_id
    AND sl.archived=false AND sl.is_current=true
    AND sl.signal IN ('STAR','DOUBLE DOWN','KEEP GROWING','KEEP');

  -- Insert intent
  INSERT INTO public.strategic_intents(
    intent_type, scope_pod_product_id, scope_boonz_product_id,
    scope_machine_ids, target_completion_date, target_qty,
    acceptance_criteria, operator_rationale, status,
    progress, created_by_engine, created_by
  )
  VALUES (
    'rebalance',
    p_pod_product_id,
    NULL,
    NULL,
    (CURRENT_DATE + interval '21 days')::date,
    v_total_drainable,
    jsonb_build_object(
      'pod_product_name', v_pod_name,
      'donor_slots_count', v_donor_count,
      'drainable_units', v_total_drainable,
      'wh_stock_at_propose', v_wh_now,
      'recipient_slots_count', v_recipients_n,
      'suppress_procurement_alert', true,
      'min_donor_stock', p_min_donor_stock,
      'min_donor_v_ratio', p_min_donor_v_ratio,
      'engine_version', 'rebalance_v1_donor_side'
    ),
    COALESCE(p_rationale,
      format('Rebalance %s: drain %s units from %s low-velocity slots; WH has %s, %s recipient slots need refill',
             v_pod_name, v_total_drainable, v_donor_count, v_wh_now, v_recipients_n)),
    'queued',
    '{}'::jsonb,
    'PRODUCT_OPT',
    v_user_id
  )
  RETURNING intent_id INTO v_intent_id;

  -- Write one tag per donor machine
  WITH fleet_v AS (
    SELECT AVG(velocity_30d) AS fleet_v30
    FROM public.slot_lifecycle
    WHERE pod_product_id = p_pod_product_id AND archived=false AND is_current=true
  ),
  donor_slots AS (
    SELECT sl.machine_id, sl.shelf_id,
           SUM(pil.current_stock)::int AS slot_stock,
           sl.velocity_30d, sl.signal
    FROM public.slot_lifecycle sl
    JOIN public.v_pod_inventory_latest pil
      ON pil.machine_id = sl.machine_id AND pil.shelf_id = sl.shelf_id AND pil.status='Active'
    JOIN (SELECT DISTINCT pod_product_id, boonz_product_id
            FROM public.product_mapping
           WHERE status='Active' AND pod_product_id = p_pod_product_id) pm
      ON pm.boonz_product_id = pil.boonz_product_id
    JOIN fleet_v ON true
    WHERE sl.pod_product_id = p_pod_product_id
      AND sl.archived=false AND sl.is_current=true
      AND sl.signal IN ('DEAD — SWAP NOW','WIND DOWN','ROTATE OUT')
      AND (fleet_v.fleet_v30 = 0
        OR sl.velocity_30d / NULLIF(fleet_v.fleet_v30, 0) <= p_min_donor_v_ratio)
    GROUP BY sl.machine_id, sl.shelf_id, sl.velocity_30d, sl.signal
    HAVING SUM(pil.current_stock) >= p_min_donor_stock
  )
  INSERT INTO public.strategic_machine_tags(
    strategic_intent_id, machine_id, pod_product_id,
    action_directive, expected_qty, priority,
    status, proposed_by_engine,
    reasoning
  )
  SELECT
    v_intent_id, ds.machine_id, p_pod_product_id,
    'swap_out_m2w',
    ds.slot_stock,
    CASE ds.signal
      WHEN 'DEAD — SWAP NOW' THEN 2
      WHEN 'ROTATE OUT'      THEN 3
      WHEN 'WIND DOWN'       THEN 4
      ELSE 5
    END,
    'proposed', 'PRODUCT_OPT',
    jsonb_build_object('signal_at_propose', ds.signal,
                       'velocity_30d', ds.velocity_30d,
                       'stock_to_drain', ds.slot_stock,
                       'reason', 'rebalance_donor')
  FROM donor_slots ds;

  RETURN jsonb_build_object(
    'status', 'ok',
    'intent_id', v_intent_id,
    'intent_type', 'rebalance',
    'pod_product_name', v_pod_name,
    'donor_machines', v_donor_count,
    'drainable_units', v_total_drainable,
    'wh_stock_now', v_wh_now,
    'recipient_slots', v_recipients_n,
    'tags_proposed', v_donor_count,
    'next_step', 'review tags via SELECT * FROM strategic_machine_tags WHERE strategic_intent_id = '||v_intent_id||', then approve_strategic_machine_tags(intent_id)'
  );
END;
$function$;
