-- PRD-137 F11, drafted 2026-09-30 daytime, NOT YET APPLIED. Migration 2 of 3: write_refill_plan
-- gets V7, the write-time half of G11 (rejects a Refill/Add New line whose boonz_product is not
-- in its machine's Active machine-scoped product_mapping set, using the shared
-- g11_check_machine_mapping helper from migration 1 of 3 -- apply that one first). Logs every
-- override to monitoring_alerts at write time (the earliest point a "[sub]"-commented line is
-- seen). Touches a dispatch/plan function -- apply only inside the 22:00-06:00 Dubai window, then
-- rename to match whatever version apply_migration actually records.
--
-- Rollback: supabase/rollback/DRAFT_prd137_f11_write_refill_plan_g11_rollback.sql
CREATE OR REPLACE FUNCTION public.write_refill_plan(p_plan_date date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  line           jsonb;
  v_count        int := 0;
  v_machine_names text[];
  v_user_id      uuid;
  v_errors       jsonb := '[]'::jsonb;
  v_line_idx     int := 0;
  v_action       text;
  v_shelf        text;
  v_machine      text;
  v_product      text;
  v_qty          int;
  v_seen_keys    text[] := '{}';
  v_dup_key      text;
  v_valid_actions text[] := ARRAY['Refill','Add New','Remove','Machine To Warehouse'];
  v_stale_pending int := 0;
  v_validation    jsonb;
  -- PRD-137 F11 (V7, G11 machine-scoped mapping gate)
  v_g11_machine_id      uuid;
  v_g11_pod_product_id  uuid;
  v_g11_boonz_product_id uuid;
  v_g11_comment         text;
  v_g11                 record;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'write_refill_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'write_refill_plan: caller % lacks required role', v_user_id;
  END IF;

  IF p_plan_date IS NULL OR p_plan_date < CURRENT_DATE THEN
    RETURN jsonb_build_object('status','error','reason','p_plan_date must be today or future','plan_date',p_plan_date);
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RETURN jsonb_build_object('status','error','reason','p_lines is empty or null');
  END IF;

  FOR line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_line_idx := v_line_idx + 1;
    v_action   := line->>'action';
    v_shelf    := line->>'shelf_code';
    v_machine  := line->>'machine_name';
    v_product  := line->>'boonz_product_name';
    v_qty      := (line->>'quantity')::int;

    IF v_action IS NULL OR NOT (v_action = ANY(v_valid_actions)) THEN
      v_errors := v_errors || jsonb_build_object(
        'line',v_line_idx,'check','V1_action_case',
        'message',format('Invalid action "%s". Must be one of: Refill, Add New, Remove, Machine To Warehouse', v_action),
        'machine',v_machine,'product',v_product);
    END IF;

    IF v_qty IS NULL OR v_qty <= 0 THEN
      v_errors := v_errors || jsonb_build_object(
        'line',v_line_idx,'check','V2_quantity',
        'message',format('Quantity must be > 0, got %s', v_qty),
        'machine',v_machine,'product',v_product);
    END IF;

    IF v_action != 'Machine To Warehouse' THEN
      IF v_shelf IS NULL OR v_shelf !~ '^[A-Z]\d{2}$' THEN
        v_errors := v_errors || jsonb_build_object(
          'line',v_line_idx,'check','V3_shelf_code',
          'message',format('Invalid shelf_code "%s". Must match [A-Z][0-9][0-9] (e.g. A01, B12)', v_shelf),
          'machine',v_machine,'product',v_product);
      END IF;
    END IF;

    IF v_machine IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.machines WHERE official_name = v_machine
    ) THEN
      v_errors := v_errors || jsonb_build_object(
        'line',v_line_idx,'check','V4_machine_name',
        'message',format('Unknown machine_name "%s"', v_machine),
        'product',v_product);
    END IF;

    IF v_product IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.boonz_products WHERE boonz_product_name = v_product
    ) THEN
      v_errors := v_errors || jsonb_build_object(
        'line',v_line_idx,'check','V5_product_name',
        'message',format('Unknown boonz_product_name "%s"', v_product),
        'machine',v_machine);
    END IF;

    IF v_action != 'Machine To Warehouse' THEN
      v_dup_key := v_machine || '::' || v_shelf || '::' || v_product;
      IF v_dup_key = ANY(v_seen_keys) THEN
        v_errors := v_errors || jsonb_build_object(
          'line',v_line_idx,'check','V6_duplicate',
          'message',format('Duplicate row for %s / %s / %s in same batch', v_machine, v_shelf, v_product));
      ELSE
        v_seen_keys := array_append(v_seen_keys, v_dup_key);
      END IF;
    END IF;

    -- PRD-137 F11 V7: machine-scoped mapping gate. Only meaningful once machine/product/pod
    -- all resolve (V4/V5 already flagged unresolved names; skip here to avoid a confusing
    -- second error stacked on an already-reported one).
    IF v_action IN ('Refill','Add New') THEN
      v_g11_comment := line->>'comment';
      SELECT m.machine_id INTO v_g11_machine_id FROM public.machines m WHERE m.official_name = v_machine;
      SELECT bp.product_id INTO v_g11_boonz_product_id FROM public.boonz_products bp WHERE bp.boonz_product_name = v_product;
      SELECT pp.pod_product_id INTO v_g11_pod_product_id FROM public.pod_products pp
        WHERE lower(trim(pp.pod_product_name)) = lower(trim(line->>'pod_product_name'));

      IF v_g11_machine_id IS NOT NULL AND v_g11_boonz_product_id IS NOT NULL AND v_g11_pod_product_id IS NOT NULL THEN
        SELECT * INTO v_g11 FROM public.g11_check_machine_mapping(
          v_g11_machine_id, v_g11_pod_product_id, v_g11_boonz_product_id, v_g11_comment);

        IF v_g11.is_violation THEN
          v_errors := v_errors || jsonb_build_object(
            'line',v_line_idx,'check','G11_not_in_machine_mapping',
            'message','G11 not in machine mapping',
            'machine',v_machine,'product',v_product);
        ELSIF v_g11.is_override THEN
          INSERT INTO public.monitoring_alerts(source,severity,payload)
          VALUES ('g11_mapping_override','warning', jsonb_build_object(
            'title', format('G11 override: %s / %s / %s not in machine mapping, comment starts [sub], zero WH_CENTRAL pickable stock on mapped set', p_plan_date, v_machine, v_product),
            'plan_date', p_plan_date, 'line', v_line_idx, 'machine', v_machine, 'shelf_code', v_shelf,
            'product', v_product, 'mapped_ids', to_jsonb(v_g11.mapped_ids), 'comment', v_g11_comment,
            'detected_at', now()
          ));
        END IF;
      END IF;
    END IF;
  END LOOP;

  IF jsonb_array_length(v_errors) > 0 THEN
    RETURN jsonb_build_object(
      'status','validation_error',
      'plan_date',p_plan_date,
      'lines_submitted',v_line_idx,
      'errors_found',jsonb_array_length(v_errors),
      'errors',v_errors
    );
  END IF;

  SELECT ARRAY(
    SELECT DISTINCT r->>'machine_name'
    FROM jsonb_array_elements(p_lines) r
    WHERE r->>'machine_name' IS NOT NULL
  ) INTO v_machine_names;

  DELETE FROM refill_plan_output t
  WHERE t.plan_date = p_plan_date
    AND t.operator_status = 'pending'
    AND t.machine_name = ANY(v_machine_names)
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_lines) r
      WHERE r->>'machine_name' = t.machine_name
        AND (
          (
            NULLIF(r->>'shelf_code','') IS NOT NULL
            AND NULLIF(t.shelf_code,'') IS NOT NULL
            AND regexp_replace(r->>'shelf_code', '^([A-Z])([0-9])$', '\1' || '0' || '\2')
              = regexp_replace(t.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2')
          )
          OR
          (
            upper(r->>'action') = 'MACHINE TO WAREHOUSE'
            AND NULLIF(r->>'shelf_code','') IS NULL
            AND upper(t.action) = 'MACHINE TO WAREHOUSE'
            AND NULLIF(t.shelf_code,'') IS NULL
          )
        )
    );

  SELECT count(*) INTO v_stale_pending
  FROM refill_plan_output
  WHERE plan_date = p_plan_date
    AND operator_status = 'pending'
    AND machine_name = ANY(v_machine_names);

  IF v_stale_pending > 0 THEN
    INSERT INTO public.monitoring_alerts(source,severity,payload)
    VALUES ('write_refill_plan','warning', jsonb_build_object(
      'title', format('write_refill_plan %s: %s pending row(s) had NO replacement line in payload and were PRESERVED (was: silent delete)', p_plan_date, v_stale_pending),
      'plan_date', p_plan_date,
      'machines', to_jsonb(v_machine_names),
      'detected_at', now()
    ));
  END IF;

  v_line_idx := 0;
  FOR line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    INSERT INTO refill_plan_output (
      plan_date, machine_name, machine_priority, shelf_code,
      pod_product_name, boonz_product_name, action, quantity,
      current_stock, max_stock, smart_target, tier, global_score,
      fill_pct, comment, operator_status,
      machine_id, shelf_id, pod_product_id, boonz_product_id,
      source_origin, from_machine_id
    ) VALUES (
      p_plan_date,
      line->>'machine_name',
      COALESCE((line->>'machine_priority')::int, 0),
      line->>'shelf_code',
      line->>'pod_product_name',
      line->>'boonz_product_name',
      COALESCE(line->>'action', 'Refill'),
      (line->>'quantity')::int,
      (line->>'current_stock')::int,
      (line->>'max_stock')::int,
      (line->>'smart_target')::int,
      line->>'tier',
      (line->>'global_score')::numeric,
      (line->>'fill_pct')::numeric,
      line->>'comment',
      'pending',
      (SELECT m.machine_id FROM public.machines m WHERE m.official_name = line->>'machine_name' LIMIT 1),
      (SELECT sc.shelf_id FROM public.shelf_configurations sc
        JOIN public.machines m2 ON m2.machine_id = sc.machine_id AND m2.official_name = line->>'machine_name'
        WHERE sc.shelf_code = regexp_replace(line->>'shelf_code', '^([A-Z])([0-9])$', '\1' || '0' || '\2')
        LIMIT 1),
      (SELECT pp.pod_product_id FROM public.pod_products pp
        WHERE lower(trim(pp.pod_product_name)) = lower(trim(line->>'pod_product_name')) LIMIT 1),
      (SELECT bp.product_id FROM public.boonz_products bp
        WHERE lower(trim(bp.boonz_product_name)) = lower(trim(line->>'boonz_product_name')) LIMIT 1),
      COALESCE(NULLIF(line->>'source_origin','')::public.source_origin_enum, 'warehouse'::public.source_origin_enum),
      NULLIF(line->>'from_machine_id','')::uuid
    );
    v_count := v_count + 1;
  END LOOP;

  v_validation := public.validate_refill_plan(p_plan_date, v_machine_names, 'plan_output');

  RETURN jsonb_build_object(
    'status', 'ok',
    'plan_date', p_plan_date,
    'lines_written', v_count,
    'machines_affected', v_machine_names,
    'preflight_version', 'g11_id_keyed',
    'validation', v_validation
  ) || jsonb_build_object('stale_pending_preserved', v_stale_pending);
END;
$function$;
