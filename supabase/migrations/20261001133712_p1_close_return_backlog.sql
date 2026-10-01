-- LOOP 2026-10-01, PART 1: return backlog, forward rule (CS approved: 14 day rolling cutoff).
-- Rollback: supabase/migrations/20261001133712_p1_close_return_backlog_rollback.sql
--
-- The one-time >14d historical backlog (730 lines / 2165 units) was already closed this morning
-- via individual wm_confirm_line(...,'acknowledged') calls. This migration ships
-- close_return_backlog as the ongoing FORWARD rule only: a reusable admin tool a human calls with
-- a rolling p_before (CURRENT_DATE - 14), never a fixed historical date again.
--
-- Two changes:
-- 1. enforce_canonical_dispatch_write's allowlist gains 'close_return_backlog'. Without this,
--    the new function's own writes fall through to the bypass-violation branch (logged +
--    WARNING, not blocked, but pollutes bypass_violation_log). Article 1.
-- 2. New close_return_backlog(p_before, p_reason, p_dry_run, p_caller_id): bulk-closes
--    refill_return_ack confirmations-inbox lines older than p_before with NO
--    warehouse_inventory credit and NO pod change. Sets wh_approved_at/wh_approved_by (the same
--    columns wm_confirm_line's refill_return_ack branch sets for an individual acknowledgment,
--    so the row drops out of v_wm_confirmations identically) plus a distinct review_reason
--    prefix ('acknowledged_no_credit: ...') so a bulk close is always distinguishable from an
--    individual human acknowledgment. Article 8's generic audit trigger
--    (tg_audit_refill_dispatching) gives the required audit-log row per line for free, since
--    app.via_rpc/app.rpc_name are set before the UPDATE.
--
-- Hard exclusions (CS, 2026-10-01):
-- - quarantine_batch is never touched by this function at all -- it operates only on
--   refill_dispatching, never warehouse_inventory, so an ack here can never release quarantined
--   stock into pickable. Structural, not a WHERE-clause condition.
-- - Five specific suspect refill_return_ack rows are hard-excluded by dispatch_id, regardless of
--   date, because they need reversal, not acknowledgment: USH-1008-0000-W1 A14 Nutella - Biscuit
--   T3 qty 8 (29 Sep), USH-1008-0000-W1 A04 Krambals - Green Olives & Sea Salt qty 2 (16 Sep,
--   item_added AND returned both true), ADDMIND-1007-0000-W0 A16 Coca Cola - Zero qty 8 (29 Sep),
--   AMZ-1038-3001-O1 A08 Nestle Kit-kat - Regular qty 10 (29 Sep) and qty 7 (30 Sep). Remove this
--   list once each of the five has been properly reversed and the exclusion is no longer needed.

CREATE OR REPLACE FUNCTION public.enforce_canonical_dispatch_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_via_rpc text := current_setting('app.via_rpc', true); v_rpc_name text := current_setting('app.rpc_name', true);
  v_via_trigger text := current_setting('app.via_trigger', true); v_uid uuid := auth.uid(); v_role text;
  v_allowlist text[] := ARRAY[
    'write_refill_plan','pack_dispatch_line','receive_dispatch_line','return_dispatch_line',
    'swap_between_machines','repair_unbound_dispatch','repair_orphan_internal_transfer',
    'cancel_dispatch_line','mark_dispatch_vox_sourced','mark_internal_transfer',
    'sync_dispatch_expiry_from_pinned_wh','add_dispatch_row','approve_refill_plan','auto_generate_refill_plan',
    'edit_dispatch_product','edit_dispatch_qty','edit_dispatch_shelf','inject_swap','push_plan_to_dispatch','remove_dispatch_row',
    'set_dispatch_source','wh_approve_remove_receipt_multivariant','update_dispatch_comment','set_dispatch_include','insert_driver_remove_line',
    'skip_dispatch_line','convert_removes_to_m2m_transfer',
    'mark_picked_up','driver_confirm_remove','wh_approve_remove_receipt','review_driver_addition',
    'release_stale_unpacked_dispatches','decline_dispatch_return','unskip_dispatch_line',
    'confirm_machine_packed',
    'receive_dispatch_line_sourced_v3',
    'driver_substitute_dispatch_line','acknowledge_day_close_event','acknowledge_day_close',
    'mark_internal_move_legs','clear_internal_move_flag',
    'mark_dispatched',
    'reverse_cancel_dispatch_line',
    'wm_confirm_line_split',
    'cancel_m2m_transfer',
    'close_return_backlog'];
  v_pre_image jsonb; v_post_image jsonb; v_pk text;
BEGIN
  IF coalesce(v_via_rpc,'')='true' AND coalesce(v_rpc_name,'') = ANY(v_allowlist) THEN RETURN coalesce(NEW, OLD); END IF;
  IF coalesce(v_via_trigger,'') = 'true' THEN RETURN coalesce(NEW, OLD); END IF;
  IF v_uid IS NOT NULL THEN SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid; END IF;
  IF TG_OP='DELETE' THEN v_pre_image := to_jsonb(OLD); v_pk := OLD.dispatch_id::text;
  ELSIF TG_OP='UPDATE' THEN v_pre_image := to_jsonb(OLD); v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text;
  ELSE v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text; END IF;
  INSERT INTO public.bypass_violation_log (table_name, operation, actor, caller_role, rpc_name, via_rpc, app_via_trigger, row_pk, pre_image, post_image, client_info)
  VALUES (TG_TABLE_NAME, TG_OP, v_uid, v_role, v_rpc_name, coalesce(v_via_rpc,'')='true', v_via_trigger, v_pk, v_pre_image, v_post_image, current_setting('application_name', true));
  RAISE WARNING 'enforce_canonical_dispatch_write: bypass on %.% (op=%, rpc_name=%, via_rpc=%, actor=%).', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, coalesce(v_rpc_name,'<null>'), coalesce(v_via_rpc,'<null>'), coalesce(v_uid::text,'<null>');
  RETURN coalesce(NEW, OLD);
END
$function$;

CREATE OR REPLACE FUNCTION public.close_return_backlog(
  p_before date,
  p_reason text,
  p_dry_run boolean DEFAULT true,
  p_caller_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller_role text;
  v_rows_matched int;
  v_units numeric;
  v_machine_count int;
  v_product_count int;
  -- Hard-excluded, regardless of date: known suspect refill_return_ack rows that need reversal,
  -- not acknowledgment. See the migration header for the machine/shelf/product/date detail of
  -- each. Remove an id from this list only once it has been properly reversed.
  v_excluded_ids uuid[] := ARRAY[
    '388b816d-66c2-4612-b5f6-b6a364ca0966', -- USH-1008-0000-W1 A04 Krambals qty 2, 16 Sep
    'd9da3b7f-ed5b-4787-a6cf-91dab8e3724e', -- ADDMIND-1007-0000-W0 A16 Coca Cola - Zero qty 8, 29 Sep
    'b99010d5-b46f-4a74-a5cb-a1ae07d82168', -- USH-1008-0000-W1 A14 Nutella - Biscuit T3 qty 8, 29 Sep
    '88532a0e-7272-4ede-b020-8163136f5caa', -- AMZ-1038-3001-O1 A08 Nestle Kit-kat qty 10, 29 Sep
    '23d5eb1c-a2d5-4d2d-be15-f65bcac1d066'  -- AMZ-1038-3001-O1 A08 Nestle Kit-kat qty 7, 30 Sep
  ]::uuid[];
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = p_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'close_return_backlog: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_before IS NULL THEN
    RAISE EXCEPTION 'close_return_backlog: p_before is required';
  END IF;
  IF p_before >= CURRENT_DATE THEN
    RAISE EXCEPTION 'close_return_backlog: p_before must be strictly in the past (got %), refusing to risk touching live rows', p_before;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'close_return_backlog: p_reason is required (>=10 chars)';
  END IF;

  SELECT count(*), coalesce(sum(quantity), 0), count(distinct machine_id), count(distinct boonz_product_id)
    INTO v_rows_matched, v_units, v_machine_count, v_product_count
  FROM refill_dispatching
  WHERE action IN ('Refill', 'Add', 'Add New')
    AND returned = true
    AND wh_approved_at IS NULL
    AND quantity > 0
    AND cancelled = false
    AND boonz_product_id IS NOT NULL
    AND dispatch_date < p_before
    AND dispatch_id <> ALL (v_excluded_ids);

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true, 'before', p_before, 'rows_matched', v_rows_matched,
      'units', v_units, 'machines', v_machine_count, 'products', v_product_count,
      'excluded_ids', v_excluded_ids);
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'close_return_backlog', true);
  PERFORM set_config('app.mutation_reason',
    format('close_return_backlog: %s rows / %s units before %s, reason=%s, caller=%s',
      v_rows_matched, v_units, p_before, p_reason, p_caller_id), true);

  UPDATE refill_dispatching
  SET wh_approved_at = now(),
      wh_approved_by = p_caller_id,
      review_reason = format('acknowledged_no_credit: %s', p_reason)
  WHERE action IN ('Refill', 'Add', 'Add New')
    AND returned = true
    AND wh_approved_at IS NULL
    AND quantity > 0
    AND cancelled = false
    AND boonz_product_id IS NOT NULL
    AND dispatch_date < p_before
    AND dispatch_id <> ALL (v_excluded_ids);

  RETURN jsonb_build_object(
    'dry_run', false, 'before', p_before, 'rows_closed', v_rows_matched,
    'units', v_units, 'machines', v_machine_count, 'products', v_product_count,
    'status', 'acknowledged_no_credit', 'excluded_ids', v_excluded_ids);
END;
$function$;
