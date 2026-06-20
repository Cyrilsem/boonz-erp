-- PRD-033 Phase E (R6): convert_shelf - first-class product swap. Atomically writes
-- REMOVE/M2W(old, tracked physical qty) + ADD_NEW(new, new_qty) on one shelf, replacing the
-- manual swap_pod_refill_row + add + edit dance (which left the incumbent counted against
-- capacity and never removed its physical units). Depends on Phase A: after the REMOVE row is
-- written, v_shelf_capacity.headroom reflects post-removal capacity, so the ADD_NEW clamp is
-- no longer pinned to the occupied free space.
--
-- New DEFINER writer of pod_refill_plan (protected). Role-gated operator_admin/superadmin/
-- warehouse (same as add_pod_refill_row). Sets app.via_rpc + app.rpc_name (generic
-- audit_log_write trigger records both writes); also writes pod_refill_plan_audit
-- (edit_type='convert') per row. No deletes; rows are upserted (insert, or qty-update if the
-- 5-tuple already exists). No qty cut without the per-row before/after audit.
--
-- return_mode: 'wh' -> M2W (return incumbent to warehouse); else -> REMOVE (clear shelf). The
-- REMOVE qty is the tracked physical stock of the old pod on the shelf (SUM of Active
-- v_pod_inventory_latest current_stock over its mapped boonz). ADD_NEW qty is clamped to the
-- post-removal headroom from v_shelf_capacity (read AFTER the REMOVE row is in place, same tx).

CREATE OR REPLACE FUNCTION public.convert_shelf(
  p_plan_date         date,
  p_machine_id        uuid,
  p_shelf_id          uuid,
  p_old_pod_product_id uuid,
  p_new_pod_product_id uuid,
  p_new_qty           integer,
  p_return_mode       text DEFAULT 'wh',
  p_reason            text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_machine_name text;
  v_shelf_code   text;
  v_locked       int;
  v_remove_action text;
  v_tracked_qty  integer;
  v_headroom     integer;
  v_add_qty      integer;
  v_clamped      boolean := false;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: convert_shelf requires operator_admin, superadmin, or warehouse';
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL
     OR p_old_pod_product_id IS NULL OR p_new_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'convert_shelf: plan_date, machine_id, shelf_id, old_pod, new_pod are required';
  END IF;
  IF p_new_qty IS NULL OR p_new_qty < 0 THEN
    RAISE EXCEPTION 'convert_shelf: invalid p_new_qty % (must be >= 0)', p_new_qty;
  END IF;
  IF p_return_mode NOT IN ('wh','m2m','truck_transfer','unknown') THEN
    RAISE EXCEPTION 'convert_shelf: invalid p_return_mode %', p_return_mode;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pod_products WHERE pod_product_id = p_new_pod_product_id) THEN
    RAISE EXCEPTION 'convert_shelf: new pod_product_id % does not exist', p_new_pod_product_id;
  END IF;

  SELECT m.official_name, sc.shelf_code INTO v_machine_name, v_shelf_code
  FROM public.machines m
  JOIN public.shelf_configurations sc ON sc.shelf_id = p_shelf_id
  WHERE m.machine_id = p_machine_id;
  IF v_shelf_code IS NULL THEN
    RAISE EXCEPTION 'convert_shelf: shelf % not found on machine %', p_shelf_id, p_machine_id;
  END IF;

  -- Same lock predicate as add/edit_pod_refill_row: refuse if output past pending.
  SELECT COUNT(*) INTO v_locked
  FROM public.refill_plan_output rpo
  WHERE rpo.plan_date = p_plan_date AND rpo.machine_name = v_machine_name
    AND rpo.shelf_code = v_shelf_code
    AND COALESCE(rpo.tier,'phase_f_stitch') = 'phase_f_stitch'
    AND rpo.operator_status <> 'pending';
  IF v_locked > 0 THEN
    RAISE EXCEPTION 'convert_shelf: % linked refill_plan_output row(s) past pending on this shelf', v_locked;
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'convert_shelf', true);

  v_remove_action := CASE WHEN p_return_mode = 'wh' THEN 'M2W' ELSE 'REMOVE' END;

  -- Tracked physical qty of the old pod on this shelf (Active live snapshot).
  SELECT COALESCE(SUM(pil.current_stock), 0)::int INTO v_tracked_qty
  FROM public.v_pod_inventory_latest pil
  WHERE pil.machine_id = p_machine_id AND pil.shelf_id = p_shelf_id AND pil.status = 'Active'
    AND pil.boonz_product_id IN (
      SELECT pm.boonz_product_id FROM public.product_mapping pm
      WHERE pm.pod_product_id = p_old_pod_product_id AND pm.status = 'Active'
        AND (pm.machine_id = p_machine_id OR pm.machine_id IS NULL));

  -- 1) REMOVE/M2W the incumbent (only if there is tracked stock). Upsert the 5-tuple.
  IF v_tracked_qty > 0 THEN
    IF EXISTS (SELECT 1 FROM public.pod_refill_plan
               WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
                 AND pod_product_id=p_old_pod_product_id AND action=v_remove_action) THEN
      UPDATE public.pod_refill_plan
         SET qty = v_tracked_qty, status = 'draft', edited_at = now(),
             edited_by = COALESCE(auth.uid()::text, current_user), updated_at = now(),
             reasoning = COALESCE(reasoning,'{}'::jsonb) || jsonb_build_object('convert_remove',
               jsonb_build_object('at',now(),'qty',v_tracked_qty,'reason',p_reason))
       WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
         AND pod_product_id=p_old_pod_product_id AND action=v_remove_action;
    ELSE
      INSERT INTO public.pod_refill_plan
        (plan_date, machine_id, shelf_id, pod_product_id, action, qty, status, source_origin,
         reasoning, created_at, updated_at, edited_at, edited_by)
      VALUES
        (p_plan_date, p_machine_id, p_shelf_id, p_old_pod_product_id, v_remove_action,
         v_tracked_qty, 'draft', 'warehouse',
         jsonb_build_object('convert_remove', jsonb_build_object('at',now(),'qty',v_tracked_qty,
           'return_mode',p_return_mode,'reason',p_reason,'by',COALESCE(auth.uid()::text,current_user))),
         now(), now(), now(), COALESCE(auth.uid()::text, current_user));
    END IF;

    INSERT INTO public.pod_refill_plan_audit
      (plan_date, machine_id, shelf_id, pod_product_id, action, edit_type, before_state, after_state, reason)
    VALUES (p_plan_date, p_machine_id, p_shelf_id, p_old_pod_product_id, v_remove_action,
            'convert', '{}'::jsonb,
            jsonb_build_object('action',v_remove_action,'qty',v_tracked_qty), p_reason);
  END IF;

  -- 2) Read post-removal headroom (Phase A view nets the REMOVE just written), clamp the ADD.
  SELECT headroom INTO v_headroom FROM public.v_shelf_capacity WHERE shelf_id = p_shelf_id;
  v_add_qty := p_new_qty;
  IF v_headroom IS NOT NULL AND p_new_qty > v_headroom THEN
    v_add_qty := GREATEST(v_headroom, 0);
    v_clamped := true;
  END IF;

  -- 3) ADD_NEW the replacement. Upsert the 5-tuple.
  IF EXISTS (SELECT 1 FROM public.pod_refill_plan
             WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
               AND pod_product_id=p_new_pod_product_id AND action='ADD_NEW') THEN
    UPDATE public.pod_refill_plan
       SET qty = v_add_qty, status = 'draft', edited_at = now(),
           edited_by = COALESCE(auth.uid()::text, current_user), updated_at = now(),
           reasoning = COALESCE(reasoning,'{}'::jsonb) || jsonb_build_object('convert_add',
             jsonb_build_object('at',now(),'qty',v_add_qty,'requested_qty',p_new_qty,'reason',p_reason))
     WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
       AND pod_product_id=p_new_pod_product_id AND action='ADD_NEW';
  ELSE
    INSERT INTO public.pod_refill_plan
      (plan_date, machine_id, shelf_id, pod_product_id, action, qty, status, source_origin,
       reasoning, created_at, updated_at, edited_at, edited_by)
    VALUES
      (p_plan_date, p_machine_id, p_shelf_id, p_new_pod_product_id, 'ADD_NEW',
       v_add_qty, 'draft', 'warehouse',
       jsonb_build_object('convert_add', jsonb_build_object('at',now(),'qty',v_add_qty,
         'requested_qty',p_new_qty,'reason',p_reason,'by',COALESCE(auth.uid()::text,current_user))),
       now(), now(), now(), COALESCE(auth.uid()::text, current_user));
  END IF;

  INSERT INTO public.pod_refill_plan_audit
    (plan_date, machine_id, shelf_id, pod_product_id, action, edit_type, before_state, after_state, reason)
  VALUES (p_plan_date, p_machine_id, p_shelf_id, p_new_pod_product_id, 'ADD_NEW',
          'convert', '{}'::jsonb,
          jsonb_build_object('action','ADD_NEW','qty',v_add_qty,'requested_qty',p_new_qty), p_reason);

  RETURN jsonb_build_object(
    'status', 'ok', 'plan_date', p_plan_date, 'machine_name', v_machine_name, 'shelf_code', v_shelf_code,
    'removed', jsonb_build_object('pod_product_id', p_old_pod_product_id, 'action', v_remove_action, 'qty', v_tracked_qty),
    'added',   jsonb_build_object('pod_product_id', p_new_pod_product_id, 'action', 'ADD_NEW',
                 'qty', v_add_qty, 'requested_qty', p_new_qty,
                 'clamp_reason', CASE WHEN v_clamped THEN 'capacity_capped' ELSE NULL END,
                 'post_removal_headroom', v_headroom),
    'restitch_required', true);
END $function$;
