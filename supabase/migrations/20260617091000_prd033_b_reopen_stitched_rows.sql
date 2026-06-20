-- PRD-033 Phase B (R2): reopen_stitched_rows - flip selected stitched pod rows back to
-- 'approved' IN PLACE so a targeted re-stitch can re-resolve them against current WH,
-- WITHOUT a re-derive (reset_and_restitch wipes manual rows) or a supersede.
--
-- New DEFINER writer of pod_refill_plan (protected). Role-gated operator_admin/superadmin.
-- Sets app.via_rpc + app.rpc_name so the generic tg_audit_pod_refill_plan:audit_log_write
-- trigger records the write; also writes the domain pod_refill_plan_audit (edit_type='reopen')
-- like add/edit_pod_refill_row. Refuses any selected row whose linked refill_plan_output is
-- past 'pending' (already dispatched/reviewed) - same lock predicate as add/edit_pod_refill_row.
-- Bumps edited_at so the existing restitch_after_edits (needs approved AND edited_at>last_stitch)
-- also accepts these rows (Phase B3). No supersede, no delete, no qty change.
--
-- Re-stitch idempotency (B2): stitch_pod_to_boonz gates on status='approved' and writes via
-- write_refill_plan, which DELETEs only operator_status='pending' refill_plan_output rows for
-- the affected machines then re-inserts. Dispatched/reviewed (non-pending) lines are untouched,
-- and this RPC refuses to reopen rows whose output is past pending, so a re-stitch cannot
-- duplicate an already-dispatched line. No writer change needed.

CREATE OR REPLACE FUNCTION public.reopen_stitched_rows(
  p_plan_date  date,
  p_machine_ids uuid[],
  p_shelf_ids  uuid[] DEFAULT NULL,
  p_reason     text  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_reopened integer := 0;
  v_blocked  jsonb   := '[]'::jsonb;
  r          record;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = ANY(ARRAY['operator_admin','superadmin'])
  ) THEN
    RAISE EXCEPTION 'forbidden: reopen_stitched_rows requires operator_admin or superadmin';
  END IF;

  IF p_plan_date IS NULL OR p_machine_ids IS NULL OR array_length(p_machine_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'reopen_stitched_rows: p_plan_date and a non-empty p_machine_ids are required';
  END IF;
  IF COALESCE(p_reason, '') = '' OR length(p_reason) < 10 THEN
    RAISE EXCEPTION 'reopen_stitched_rows: p_reason is required (>= 10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'reopen_stitched_rows', true);

  -- Guard: refuse the whole call if any selected stitched row has linked refill_plan_output
  -- past 'pending' (dispatched/reviewed). Surface the blocked list; change nothing.
  FOR r IN
    SELECT m.official_name AS machine_name, sc.shelf_code,
           prp.pod_product_id, prp.action
    FROM public.pod_refill_plan prp
    JOIN public.machines m            ON m.machine_id = prp.machine_id
    JOIN public.shelf_configurations sc ON sc.shelf_id = prp.shelf_id
    WHERE prp.plan_date = p_plan_date
      AND prp.machine_id = ANY(p_machine_ids)
      AND (p_shelf_ids IS NULL OR prp.shelf_id = ANY(p_shelf_ids))
      AND prp.status = 'stitched'
      AND EXISTS (
        SELECT 1 FROM public.refill_plan_output rpo
        WHERE rpo.plan_date    = prp.plan_date
          AND rpo.machine_name = m.official_name
          AND rpo.shelf_code   = sc.shelf_code
          AND COALESCE(rpo.tier, 'phase_f_stitch') = 'phase_f_stitch'
          AND rpo.operator_status <> 'pending'
      )
  LOOP
    v_blocked := v_blocked || jsonb_build_object(
      'machine', r.machine_name, 'shelf', r.shelf_code,
      'pod_product_id', r.pod_product_id, 'action', r.action,
      'reason', 'linked refill_plan_output is past pending (dispatched/reviewed)');
  END LOOP;

  IF jsonb_array_length(v_blocked) > 0 THEN
    RETURN jsonb_build_object(
      'status', 'blocked', 'reopened', 0, 'blocked', v_blocked,
      'message', 'Some selected rows have dispatched/reviewed output and cannot be reopened. Resolve or exclude those shelves first.');
  END IF;

  -- Flip stitched -> approved in place, per row, with audit.
  FOR r IN
    SELECT prp.* FROM public.pod_refill_plan prp
    WHERE prp.plan_date = p_plan_date
      AND prp.machine_id = ANY(p_machine_ids)
      AND (p_shelf_ids IS NULL OR prp.shelf_id = ANY(p_shelf_ids))
      AND prp.status = 'stitched'
  LOOP
    UPDATE public.pod_refill_plan
       SET status     = 'approved',
           edited_at  = now(),
           edited_by  = COALESCE(auth.uid()::text, current_user),
           reasoning  = COALESCE(reasoning, '{}'::jsonb) || jsonb_build_object(
                          'reopened', jsonb_build_object(
                            'at', now(), 'from', 'stitched', 'reason', p_reason,
                            'by', COALESCE(auth.uid()::text, current_user))),
           updated_at = now()
     WHERE plan_date = r.plan_date AND machine_id = r.machine_id AND shelf_id = r.shelf_id
       AND pod_product_id = r.pod_product_id AND action = r.action;

    INSERT INTO public.pod_refill_plan_audit
      (plan_date, machine_id, shelf_id, pod_product_id, action,
       edit_type, before_state, after_state, reason)
    VALUES
      (r.plan_date, r.machine_id, r.shelf_id, r.pod_product_id, r.action,
       'reopen',
       jsonb_build_object('status', 'stitched', 'qty', r.qty),
       jsonb_build_object('status', 'approved', 'qty', r.qty),
       p_reason);

    v_reopened := v_reopened + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'ok', 'reopened', v_reopened, 'plan_date', p_plan_date,
    'restitch_hint', 'run stitch_pod_to_boonz(p_plan_date, false) to re-resolve the reopened rows against current warehouse stock');
END $function$;
