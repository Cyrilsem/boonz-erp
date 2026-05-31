-- PRD-015 Phase D / AC#5 — canonical, reversible pod_inventory shelf reconciliation.
-- p_confirm=false (default): returns the per-row diff, writes NOTHING.
-- p_confirm=true: archives all Active rows on the shelf (status='Inactive',
--   removal_reason='archived_<date>_reconcile_weimi'; NEVER DELETE), then inserts ONE Active
--   row for p_new_pod_product_id (identity-only seed; stock=0, corrected later via add_stock).
-- Refuses if: new product NULL, new product has no global product_mapping (cannot seed a NULL
--   boonz product — Issue-3 gate edge), or the shelf has a linked refill_plan_output past 'pending'.
-- SECURITY DEFINER; Article 4 GUCs; role operator_admin/superadmin (pod_inventory identity is
-- sensitive). pod_inventory audit trigger captures the writes (Article 8). NOT YET APPLIED.

CREATE OR REPLACE FUNCTION public.reconcile_pod_inventory_shelf(
  p_machine_id        uuid,
  p_shelf_id          uuid,
  p_new_pod_product_id uuid,
  p_reason            text,
  p_confirm           boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_new_boonz_id uuid;
  v_machine_name text;
  v_shelf_code   text;
  v_locked       int;
  v_archive      jsonb;
  v_archived_n   int := 0;
  v_new_pod_id   uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'forbidden: reconcile_pod_inventory_shelf requires operator_admin or superadmin';
  END IF;
  IF p_machine_id IS NULL OR p_shelf_id IS NULL OR p_new_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_machine_id, p_shelf_id, p_new_pod_product_id all required (cannot seed a NULL product)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  -- Resolve the new product's canonical boonz_product_id (pod_inventory keys on boonz_product_id).
  SELECT pm.boonz_product_id INTO v_new_boonz_id
  FROM public.product_mapping pm
  WHERE pm.pod_product_id = p_new_pod_product_id
    AND pm.is_global_default = true AND pm.status = 'Active'
  ORDER BY pm.split_pct DESC NULLS LAST
  LIMIT 1;
  IF v_new_boonz_id IS NULL THEN
    RAISE EXCEPTION 'reconcile: pod_product % has no global product_mapping; add the mapping first (Issue-3 launch gate)', p_new_pod_product_id;
  END IF;

  -- Lock guard: a shelf with a linked refill_plan_output past pending is physically committed.
  SELECT m.official_name, sc.shelf_code INTO v_machine_name, v_shelf_code
  FROM public.machines m
  JOIN public.shelf_configurations sc ON sc.shelf_id = p_shelf_id
  WHERE m.machine_id = p_machine_id;

  SELECT COUNT(*) INTO v_locked
  FROM public.refill_plan_output rpo
  WHERE rpo.plan_date = CURRENT_DATE
    AND rpo.machine_name = v_machine_name
    AND rpo.shelf_code   = v_shelf_code
    AND rpo.operator_status IS DISTINCT FROM 'pending';
  IF v_locked > 0 THEN
    RAISE EXCEPTION 'reconcile refused: shelf % / % has % refill_plan_output row(s) past pending (physically committed)', v_machine_name, v_shelf_code, v_locked;
  END IF;

  -- Build the diff (rows to archive on this shelf).
  SELECT jsonb_agg(jsonb_build_object(
           'pod_inventory_id', pi.pod_inventory_id, 'boonz_product_id', pi.boonz_product_id,
           'current_stock', pi.current_stock, 'expiration_date', pi.expiration_date)),
         COUNT(*)
  INTO v_archive, v_archived_n
  FROM public.pod_inventory pi
  WHERE pi.machine_id = p_machine_id AND pi.shelf_id = p_shelf_id AND pi.status = 'Active';

  IF NOT p_confirm THEN
    RETURN jsonb_build_object(
      'mode', 'diff_only', 'confirm', false,
      'machine', v_machine_name, 'shelf_code', v_shelf_code,
      'rows_to_archive', COALESCE(v_archive, '[]'::jsonb), 'archive_count', v_archived_n,
      'seed', jsonb_build_object('pod_product_id', p_new_pod_product_id,
        'boonz_product_id', v_new_boonz_id, 'current_stock', 0,
        'note', 'identity-only seed; correct stock via add_stock afterwards'),
      'reason', p_reason);
  END IF;

  -- p_confirm = true: canonical archive-then-seed.
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'reconcile_pod_inventory_shelf', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  UPDATE public.pod_inventory
     SET status = 'Inactive',
         removal_reason = format('archived_%s_reconcile_weimi', CURRENT_DATE),
         last_decremented_at = now()
   WHERE machine_id = p_machine_id AND shelf_id = p_shelf_id AND status = 'Active';

  INSERT INTO public.pod_inventory
    (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
     estimated_remaining, expiration_date, batch_id, status, snapshot_at)
  VALUES
    (p_machine_id, p_shelf_id, v_new_boonz_id, CURRENT_DATE, 0, 0, NULL,
     format('POD_RECONCILE-%s', CURRENT_DATE), 'Active', now())
  RETURNING pod_inventory_id INTO v_new_pod_id;

  RETURN jsonb_build_object(
    'mode', 'applied', 'confirm', true,
    'machine', v_machine_name, 'shelf_code', v_shelf_code,
    'archived_count', v_archived_n, 'rows_archived', COALESCE(v_archive, '[]'::jsonb),
    'new_pod_inventory_id', v_new_pod_id, 'new_boonz_product_id', v_new_boonz_id,
    'reason', p_reason);
END $function$;
GRANT EXECUTE ON FUNCTION public.reconcile_pod_inventory_shelf(uuid,uuid,uuid,text,boolean) TO authenticated;
