-- PRD-053 Phase C fix — a REJECTED driver addition must not ship (FILE only).
--
-- The applied review_driver_addition only set review_status='rejected' + cleared the
-- flag; the line stayed include=true and would still ship. Fix: on 'rejected', also
-- EXCLUDE / CANCEL the line through the canonical writer so it does not ship —
--   * pending addition (the normal case: dispatched=false) -> set_dispatch_include(false)
--   * already-dispatched, WH-unbound, not-cancelled -> cancel_dispatch_line(...)
-- 'accepted' leaves the line included (no include/cancel change). Never deletes,
-- never cuts qty. Composes the canonical writers (Art 1); forward-only (Art 12).

CREATE OR REPLACE FUNCTION public.review_driver_addition(
  p_dispatch_id uuid,
  p_decision text,            -- 'accepted' | 'rejected'
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid       uuid := auth.uid();
  v_role      text;
  v_row       refill_dispatching%ROWTYPE;
  v_excluded  text := null;   -- how the rejected line was taken out of dispatch
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'review_driver_addition', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'review_driver_addition: Head Office decision requires operator_admin/superadmin/manager (got %)', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_decision NOT IN ('accepted','rejected') THEN
    RAISE EXCEPTION 'review_driver_addition: p_decision must be accepted | rejected';
  END IF;

  SELECT * INTO v_row FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'review_driver_addition: dispatch % not found', p_dispatch_id; END IF;
  IF NOT COALESCE(v_row.needs_review,false) THEN
    RAISE EXCEPTION 'review_driver_addition: dispatch % is not flagged for review', p_dispatch_id;
  END IF;

  PERFORM set_config('app.mutation_reason',
    format('PRD-053 Head Office %s of driver addition %s%s', p_decision, p_dispatch_id,
           COALESCE(' — '||p_reason, '')), true);

  -- record the decision + clear the review flag
  UPDATE refill_dispatching
     SET review_status = p_decision,
         needs_review  = false,
         reviewed_by   = v_uid,
         reviewed_at   = now()
   WHERE dispatch_id = p_dispatch_id;

  -- REJECTED -> the addition must not ship. Take it out via the canonical writer.
  IF p_decision = 'rejected' THEN
    IF COALESCE(v_row.dispatched,false) = true
       AND v_row.from_wh_inventory_id IS NULL
       AND COALESCE(v_row.cancelled,false) = false THEN
      PERFORM public.cancel_dispatch_line(
        p_dispatch_id,
        COALESCE(NULLIF(trim(p_reason),''), 'Head Office rejected driver addition (PRD-053)'));
      v_excluded := 'cancelled';
    ELSE
      PERFORM public.set_dispatch_include(p_dispatch_id, false);
      v_excluded := 'excluded';   -- include=false
    END IF;
  END IF;
  -- ACCEPTED -> leave the line included (no include/cancel change).

  RETURN jsonb_build_object(
    'status','ok',
    'dispatch_id', p_dispatch_id,
    'review_status', p_decision,
    'reviewed_by', v_uid,
    'rejected_line_taken_out_via', v_excluded
  );
END;
$function$;

COMMENT ON FUNCTION public.review_driver_addition(uuid,text,text) IS
  'PRD-053 Phase C (fixed): Head Office accept/reject of a flagged driver addition. Reject also takes the line out of dispatch via the canonical writer (set_dispatch_include(false), or cancel_dispatch_line if already dispatched) so it does not ship. Accept leaves it included. No delete, no qty cut.';

GRANT EXECUTE ON FUNCTION public.review_driver_addition(uuid,text,text) TO authenticated, service_role;
