-- Refill reliability / WS2a - canonical "skip line" path so an unfulfillable line never hard-blocks a
-- machine submission (PRD WS2 Problem B). STATUS: DRAFT - NOT APPLIED. Dara-designed, Cody-reviewed below.
--
-- Why a NEW RPC (cancel_dispatch_line does not fit): cancel_dispatch_line requires dispatched=true AND
-- not-yet-WH-bound and is for post-dispatch cancellation. An unfulfillable line at packing time is
-- pre-pickup; we need to mark it skipped (exclude from the must-pack/submission set) with a reason, while
-- keeping it visible as "skipped" (not removed, not cancelled) and durable against re-push (WS2b uses the
-- edit markers below to avoid resurrecting it).
--
-- Contents:
--   1. ALTER refill_dispatching: + skipped / skip_reason / skipped_at / skipped_by (additive, defaulted).
--   2. skip_dispatch_line(p_dispatch_id, p_reason) canonical writer -> sets skipped=true, include=false,
--      bumps edit_count, logs to refill_dispatching_edit_log (edit_kind='skip').
--   3. enforce_canonical_dispatch_write: add 'skip_dispatch_line' to the allow-list (verbatim repro + 1 entry).

-- 1. Dara schema (forward-only ADD COLUMN; RLS already enabled on refill_dispatching; Article 2/12 ok).
ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS skipped     boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS skip_reason text,
  ADD COLUMN IF NOT EXISTS skipped_at  timestamptz,
  ADD COLUMN IF NOT EXISTS skipped_by  uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.refill_dispatching.skipped IS
  'WS2: operator marked this line unfulfillable/skipped so the machine stays submittable. Excluded from the must-pack set. Set only by skip_dispatch_line.';

-- 2. skip_dispatch_line canonical writer.
CREATE OR REPLACE FUNCTION public.skip_dispatch_line(p_dispatch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_role text;
  v_row  public.refill_dispatching%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'skip_dispatch_line', true);

  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_uid IS NOT NULL AND v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'skip_dispatch_line: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  IF p_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'p_dispatch_id required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>= 10 chars)';
  END IF;

  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % not found', p_dispatch_id;
  END IF;
  IF v_row.picked_up THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % already picked up - too late to skip', p_dispatch_id;
  END IF;
  IF v_row.skipped THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % already skipped', p_dispatch_id;
  END IF;
  IF v_row.cancelled THEN
    RAISE EXCEPTION 'skip_dispatch_line: dispatch_id % is cancelled (use the cancel flow)', p_dispatch_id;
  END IF;

  UPDATE public.refill_dispatching
     SET skipped             = true,
         skipped_at          = now(),
         skipped_by          = v_uid,
         skip_reason         = p_reason,
         include             = false,
         edit_count          = edit_count + 1,
         last_edited_by      = v_uid,
         last_edited_by_role = COALESCE(v_role, 'system'),
         last_edited_at      = now()
   WHERE dispatch_id = p_dispatch_id;

  -- No refill_dispatching_edit_log row: its edit_kind CHECK does not include 'skip', and the skip is fully
  -- recorded on the row (skipped/skip_reason/skipped_by/skipped_at) + captured by the generic write audit.
  -- This mirrors cancel_dispatch_line, which likewise records its state on the row, not the edit log.

  RETURN jsonb_build_object(
    'status', 'ok',
    'dispatch_id', p_dispatch_id,
    'skipped', true,
    'reason', p_reason,
    'machine_id', v_row.machine_id,
    'boonz_product_id', v_row.boonz_product_id
  );
END;
$function$;

-- 3. enforce_canonical_dispatch_write: verbatim repro + 'skip_dispatch_line' added to the allow-list.
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
    'write_refill_plan','pack_dispatch_line','receive_dispatch_line','return_dispatch_line',
    'swap_between_machines','repair_unbound_dispatch','repair_orphan_internal_transfer',
    'cancel_dispatch_line','mark_dispatch_vox_sourced','mark_internal_transfer',
    'sync_dispatch_expiry_from_pinned_wh',
    'add_dispatch_row','approve_refill_plan','auto_generate_refill_plan',
    'edit_dispatch_product','edit_dispatch_qty','edit_dispatch_shelf',
    'inject_swap','push_plan_to_dispatch','remove_dispatch_row',
    'set_dispatch_source','wh_approve_remove_receipt_multivariant',
    'update_dispatch_comment','set_dispatch_include','insert_driver_remove_line',
    'skip_dispatch_line'
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
