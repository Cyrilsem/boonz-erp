-- PRD-102 D2: decline_swap_pair - the field "Don't swap" decision.
-- Dara semantics (chosen): skipped=true + include=false + skip_reason (the established
-- PRD-020/028 skip state machine: visible as a DECISION in the skipped panel, pack
-- refuses unconditionally, unskip_dispatch_line is the logged reactivation) with the
-- decline distinguishable via skip_reason prefix 'decline_swap:' AND edit-log kind.
-- NOT bare include=false (that is remove-from-plan; vanishes).
-- Role gate includes field_staff + warehouse (2026-07-18 role-vocab incident: never
-- reuse driver/warehouse_manager-only lists).
-- Learning signal: ONE refill_edit_signals row per declined pair,
-- signal_type='swap_rejected', pod_product_id = the INCOMING pod (the Add New leg)
-- because engine_swap_pod's suppression (_suppressed_swap_subs) keys on the incoming
-- pod; the REMOVED pod's no-repeat-removal protection comes from the rpo-based
-- _r5_removal_cooldown which exists independently. Removed pod + reason go in note.
-- Article 7: refill_dispatching_edit_log CHECKs extended with 'decline_swap'
-- (before+after state shape); the log stays append-only.
-- Rollback: DROP FUNCTION public.decline_swap_pair(date,uuid,uuid,uuid[],text);
--           (CHECK extension is forward-only and harmless to keep; signal rows stay.)

ALTER TABLE public.refill_dispatching_edit_log
  DROP CONSTRAINT refill_dispatching_edit_log_edit_kind_check;
ALTER TABLE public.refill_dispatching_edit_log
  ADD CONSTRAINT refill_dispatching_edit_log_edit_kind_check
  CHECK (edit_kind = ANY (ARRAY['qty','shelf','product','source','add','remove','decline_swap']));

ALTER TABLE public.refill_dispatching_edit_log
  DROP CONSTRAINT refill_dispatching_edit_log_state_coherence;
ALTER TABLE public.refill_dispatching_edit_log
  ADD CONSTRAINT refill_dispatching_edit_log_state_coherence
  CHECK (
    ((edit_kind = 'add') AND (before_state IS NULL) AND (after_state IS NOT NULL))
    OR ((edit_kind = 'remove') AND (before_state IS NOT NULL) AND (after_state IS NULL))
    OR ((edit_kind = ANY (ARRAY['qty','shelf','product','source','decline_swap']))
        AND (before_state IS NOT NULL) AND (after_state IS NOT NULL))
  );

CREATE OR REPLACE FUNCTION public.decline_swap_pair(
  p_plan_date    date,
  p_machine_id   uuid,
  p_shelf_id     uuid,
  p_dispatch_ids uuid[],
  p_reason       text
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
  v_id        uuid;
  v_declined  jsonb := '[]'::jsonb;
  v_signal_pod   uuid;
  v_removed_pod  uuid;
  v_before    jsonb;
  v_n         int := 0;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'decline_swap_pair', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'decline_swap_pair: forbidden for role %', COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL OR p_shelf_id IS NULL THEN
    RAISE EXCEPTION 'decline_swap_pair: plan_date, machine_id, shelf_id are required';
  END IF;
  IF p_dispatch_ids IS NULL OR array_length(p_dispatch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'decline_swap_pair: p_dispatch_ids must be a non-empty array';
  END IF;
  IF COALESCE(p_reason, '') = '' OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'decline_swap_pair: p_reason required (>= 10 chars)';
  END IF;

  PERFORM set_config('app.mutation_reason', 'decline_swap: ' || p_reason, true);

  FOREACH v_id IN ARRAY p_dispatch_ids LOOP
    SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'decline_swap_pair: dispatch % not found', v_id;
    END IF;
    IF v_row.machine_id <> p_machine_id OR v_row.shelf_id IS DISTINCT FROM p_shelf_id
       OR v_row.dispatch_date <> p_plan_date THEN
      RAISE EXCEPTION 'decline_swap_pair: dispatch % does not belong to machine/shelf/date', v_id;
    END IF;
    IF v_row.action NOT IN ('Remove', 'Add New') THEN
      RAISE EXCEPTION 'decline_swap_pair: dispatch % is % - only swap legs (Remove / Add New) can be declined', v_id, v_row.action;
    END IF;
    IF COALESCE(v_row.filled_quantity, 0) <> 0 OR COALESCE(v_row.packed, false)
       OR COALESCE(v_row.picked_up, false) THEN
      RAISE EXCEPTION 'decline_swap_pair: dispatch % already started (filled/packed/picked up) - too late to decline', v_id;
    END IF;
    IF COALESCE(v_row.cancelled, false) THEN
      RAISE EXCEPTION 'decline_swap_pair: dispatch % is cancelled', v_id;
    END IF;
    IF COALESCE(v_row.skipped, false) THEN
      RAISE EXCEPTION 'decline_swap_pair: dispatch % is already skipped/declined', v_id;
    END IF;

    v_before := jsonb_build_object(
      'include', v_row.include, 'skipped', COALESCE(v_row.skipped, false),
      'quantity', v_row.quantity, 'action', v_row.action,
      'boonz_product_id', v_row.boonz_product_id, 'pod_product_id', v_row.pod_product_id);

    UPDATE public.refill_dispatching
       SET skipped = true,
           include = false,
           skip_reason = 'decline_swap: ' || trim(p_reason),
           skipped_at = now(),
           skipped_by = v_uid,
           edit_count = COALESCE(edit_count, 0) + 1,
           last_edited_by = v_uid,
           last_edited_by_role = COALESCE(v_role, 'system'),
           last_edited_at = now()
     WHERE dispatch_id = v_id;

    INSERT INTO public.refill_dispatching_edit_log
      (dispatch_id, edited_by, edited_by_role, edit_kind, before_state, after_state, reason, conductor_session)
    VALUES
      (v_id, v_uid, COALESCE(v_role, 'system'), 'decline_swap', v_before,
       jsonb_build_object('include', false, 'skipped', true,
                          'skip_reason', 'decline_swap: ' || trim(p_reason)),
       p_reason, NULL);

    IF v_row.action = 'Add New' THEN
      v_signal_pod := COALESCE(v_signal_pod, v_row.pod_product_id);
    ELSE
      v_removed_pod := COALESCE(v_removed_pod, v_row.pod_product_id);
    END IF;

    v_declined := v_declined || jsonb_build_object('dispatch_id', v_id, 'action', v_row.action);
    v_n := v_n + 1;
  END LOOP;

  -- Learning signal (one per declined pair): incoming pod primary (engine suppression
  -- keys on pod_in); fall back to the removed pod for remove-only declines.
  INSERT INTO public.refill_edit_signals
    (plan_date, machine_id, shelf_id, pod_product_id, action, signal_type, source, note, created_by)
  VALUES
    (p_plan_date, p_machine_id, p_shelf_id, COALESCE(v_signal_pod, v_removed_pod),
     'decline_swap', 'swap_rejected', 'field',
     format('declined swap pair (removed_pod=%s, incoming_pod=%s): %s',
            COALESCE(v_removed_pod::text, 'none'), COALESCE(v_signal_pod::text, 'none'), trim(p_reason)),
     v_uid);

  RETURN jsonb_build_object(
    'status', 'ok',
    'declined', v_declined,
    'legs', v_n,
    'signal_pod_product_id', COALESCE(v_signal_pod, v_removed_pod),
    'reason', p_reason
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.decline_swap_pair(date, uuid, uuid, uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.decline_swap_pair(date, uuid, uuid, uuid[], text) TO authenticated, service_role;

COMMENT ON FUNCTION public.decline_swap_pair(date, uuid, uuid, uuid[], text) IS
'PRD-102 D2: canonical field decline of a planner swap pair. Marks unstarted Remove/Add New legs skipped (visible decision, PRD-028 semantics), writes append-only edit-log rows (decline_swap) and one refill_edit_signals swap_rejected row (incoming pod) feeding engine_swap_pod suppression. Roles: field_staff, warehouse, operator_admin, superadmin, manager.';
