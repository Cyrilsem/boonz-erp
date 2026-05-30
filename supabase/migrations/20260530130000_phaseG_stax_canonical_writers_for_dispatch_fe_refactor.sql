-- PROGRAM-2026-06-01 Stax FE refactor — Decisions A1-A5
-- 3 new canonical writers for refill_dispatching so the FE can stop writing directly:
--   A1 update_dispatch_comment  — comment-only edit
--   A2 set_dispatch_include     — include flag flip
--   A3 insert_driver_remove_line — driver inserts an off-plan Remove line
--
-- Also extends the enforce_canonical_dispatch_write allow-list with the 3 new names
-- (STILL RAISE WARNING — the RAISE EXCEPTION flip is Decision D1, a separate migration
-- that ships only AFTER the 2026-06-05 pre-flip soak passes). Adding the names now keeps
-- the soak window clean: calls from the new RPCs are recognised as canonical instead of
-- logging spurious bypass_violation_log rows.

-- ── A1: update_dispatch_comment ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_dispatch_comment(
  p_dispatch_id uuid,
  p_comment     text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_caller_id uuid := auth.uid(); v_caller_role text; v_old_comment text;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'update_dispatch_comment: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'update_dispatch_comment', true);

  SELECT comment INTO v_old_comment FROM refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch_id % not found', p_dispatch_id; END IF;

  UPDATE refill_dispatching SET comment = NULLIF(TRIM(p_comment), '')
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', p_dispatch_id,
    'old_comment', v_old_comment, 'new_comment', NULLIF(TRIM(p_comment), ''));
END $$;
GRANT EXECUTE ON FUNCTION public.update_dispatch_comment(uuid,text) TO authenticated;

-- ── A2: set_dispatch_include ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_dispatch_include(
  p_dispatch_id uuid,
  p_include     boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_caller_id uuid := auth.uid(); v_caller_role text;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'set_dispatch_include: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;
  IF p_include IS NULL THEN RAISE EXCEPTION 'p_include required'; END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_dispatch_include', true);

  UPDATE refill_dispatching SET include = p_include WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'dispatch_id % not found', p_dispatch_id; END IF;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', p_dispatch_id, 'include', p_include);
END $$;
GRANT EXECUTE ON FUNCTION public.set_dispatch_include(uuid,boolean) TO authenticated;

-- ── A3: insert_driver_remove_line ────────────────────────────────────────────
-- Driver inserts a Remove line on the spot (off-plan return / multi-variant split).
-- Verified caller context: field/dispatching/[machineId]/page.tsx:497
-- handleConfirmExtraReturn — a driver-initiated sibling Remove row. Action casing
-- is Title Case 'Remove' per feedback_dispatching_action_casing.
CREATE OR REPLACE FUNCTION public.insert_driver_remove_line(
  p_machine_id        uuid,
  p_boonz_product_id  uuid,
  p_pod_product_id    uuid,
  p_shelf_id          uuid,
  p_quantity          numeric,
  p_expiry_date       date,
  p_reason            text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_caller_id uuid := auth.uid(); v_caller_role text; v_dispatch_id uuid;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'insert_driver_remove_line: role % not authorized', COALESCE(v_caller_role, 'none');
  END IF;
  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_quantity required (qty > 0)';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'insert_driver_remove_line', true);

  -- Cody A4 revision: filled_quantity (nullable, no default) and item_added are
  -- set explicitly to mirror the proven direct insert at dispatching:497 exactly.
  INSERT INTO refill_dispatching
    (machine_id, boonz_product_id, pod_product_id, shelf_id,
     dispatch_date, action, quantity, filled_quantity, expiry_date,
     packed, picked_up, dispatched, returned, item_added, include, comment)
  VALUES
    (p_machine_id, p_boonz_product_id, p_pod_product_id, p_shelf_id,
     CURRENT_DATE, 'Remove', p_quantity, 0, p_expiry_date,
     true, true, false, false, false, true,
     format('[DRIVER-INSERT] %s', p_reason))
  RETURNING dispatch_id INTO v_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', v_dispatch_id,
    'machine_id', p_machine_id, 'qty', p_quantity, 'reason', p_reason);
END $$;
GRANT EXECUTE ON FUNCTION public.insert_driver_remove_line(uuid,uuid,uuid,uuid,numeric,date,text) TO authenticated;

-- ── Allow-list extension (still RAISE WARNING; flip is Decision D1) ───────────
-- Re-declare enforce_canonical_dispatch_write with the 3 new names appended to the
-- allow-list. Body is otherwise byte-for-byte the live function (RAISE WARNING path
-- preserved). The RAISE WARNING -> RAISE EXCEPTION flip is NOT done here.
CREATE OR REPLACE FUNCTION public.enforce_canonical_dispatch_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_via_rpc text     := current_setting('app.via_rpc', true);
  v_rpc_name text    := current_setting('app.rpc_name', true);
  v_via_trigger text := current_setting('app.via_trigger', true);
  v_uid uuid         := auth.uid();
  v_role text;
  v_allowlist text[] := ARRAY[
    -- original 11 (A.2)
    'write_refill_plan','pack_dispatch_line','receive_dispatch_line','return_dispatch_line',
    'swap_between_machines','repair_unbound_dispatch','repair_orphan_internal_transfer',
    'cancel_dispatch_line','mark_dispatch_vox_sourced','mark_internal_transfer',
    'sync_dispatch_expiry_from_pinned_wh',
    -- Phase C L-a additions (11 verified: pg_proc check confirmed direct INSERT)
    'add_dispatch_row','approve_refill_plan','auto_generate_refill_plan',
    'edit_dispatch_product','edit_dispatch_qty','edit_dispatch_shelf',
    'inject_swap','push_plan_to_dispatch','remove_dispatch_row',
    'set_dispatch_source','wh_approve_remove_receipt_multivariant',
    -- PROGRAM-2026-06-01 Stax FE refactor additions (3 new canonical writers)
    'update_dispatch_comment','set_dispatch_include','insert_driver_remove_line'
  ];
  v_pre_image jsonb; v_post_image jsonb; v_pk text;
BEGIN
  IF coalesce(v_via_rpc,'')='true' AND coalesce(v_rpc_name,'') = ANY(v_allowlist) THEN
    RETURN coalesce(NEW, OLD);
  END IF;
  IF coalesce(v_via_trigger,'') = 'true' THEN RETURN coalesce(NEW, OLD); END IF;

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  END IF;
  IF TG_OP='DELETE' THEN v_pre_image := to_jsonb(OLD); v_pk := OLD.dispatch_id::text;
  ELSIF TG_OP='UPDATE' THEN v_pre_image := to_jsonb(OLD); v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text;
  ELSE v_post_image := to_jsonb(NEW); v_pk := NEW.dispatch_id::text;
  END IF;

  INSERT INTO public.bypass_violation_log
    (table_name, operation, actor, caller_role, rpc_name, via_rpc, app_via_trigger, row_pk, pre_image, post_image, client_info)
  VALUES
    (TG_TABLE_NAME, TG_OP, v_uid, v_role, v_rpc_name, coalesce(v_via_rpc,'')='true', v_via_trigger,
     v_pk, v_pre_image, v_post_image, current_setting('application_name', true));

  RAISE WARNING 'enforce_canonical_dispatch_write: bypass on %.% (op=%, rpc_name=%, via_rpc=%, actor=%).',
    TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, coalesce(v_rpc_name,'<null>'), coalesce(v_via_rpc,'<null>'), coalesce(v_uid::text,'<null>');
  RETURN coalesce(NEW, OLD);
END $function$;
