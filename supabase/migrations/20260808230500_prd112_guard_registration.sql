-- PRD-112 unit 2b — register the substitution writer with the two dispatch guards
--
-- PRD-112 §4.1: "The packed-row guard stays; the RPC is the single sanctioned
-- writer through it." Both edits below are ADDITIVE registrations of a named
-- writer. No predicate is relaxed, no branch is removed, and no other writer's
-- behaviour changes. Diff vs the live bodies (captured from pg_get_functiondef
-- on 2026-08-08):
--
--   protect_packed_dispatch_row      : one equality becomes a two-element IN.
--   enforce_canonical_dispatch_write : two names appended to v_allowlist.
--
-- The duplicate-unstarted-row guard (prevent_duplicate_unstarted_dispatch) is
-- NOT touched here and is not touched anywhere in PRD-112. The substitution RPC
-- stays outside its predicate by requiring p_filled_qty > 0.

-- ── Guard 1: packed-row immutability ────────────────────────────────────────
-- A packed line is goods in motion, so its identity is frozen. The one thing a
-- driver standing at the machine legitimately changes is WHICH product went in
-- the shelf, which is exactly what edit_dispatch_product was already exempted
-- for. driver_substitute_dispatch_line joins that same exemption: it re-labels
-- a line, it never deletes one, and machine/shelf/date stay frozen for it just
-- as they are for every other writer.
CREATE OR REPLACE FUNCTION public.protect_packed_dispatch_row()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF OLD.packed = true THEN
    -- PRD-112 2026-08-08: driver_substitute_dispatch_line added. Both entries are
    -- product-relabel writers and NOTHING else may move product on a packed line.
    IF current_setting('app.rpc_name', true) IN ('edit_dispatch_product','driver_substitute_dispatch_line') THEN
      NULL;
    ELSE
      IF NEW.boonz_product_id IS DISTINCT FROM OLD.boonz_product_id THEN
        RAISE EXCEPTION 'Cannot change boonz_product_id on a packed dispatch line';
      END IF;
      IF NEW.pod_product_id IS DISTINCT FROM OLD.pod_product_id THEN
        RAISE EXCEPTION 'Cannot change pod_product_id on a packed dispatch line';
      END IF;
    END IF;
    IF NEW.machine_id IS DISTINCT FROM OLD.machine_id THEN
      RAISE EXCEPTION 'Cannot change machine_id on a packed dispatch line';
    END IF;
    IF NEW.shelf_id IS DISTINCT FROM OLD.shelf_id THEN
      RAISE EXCEPTION 'Cannot change shelf_id on a packed dispatch line';
    END IF;
    IF NEW.dispatch_date IS DISTINCT FROM OLD.dispatch_date THEN
      RAISE EXCEPTION 'Cannot change dispatch_date on a packed dispatch line';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

-- ── Guard 2: canonical-writer allowlist ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_canonical_dispatch_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    -- RC-04 prep 2026-07-19: verified context-setting single-writers (Category-A)
    'mark_picked_up','driver_confirm_remove','wh_approve_remove_receipt','review_driver_addition',
    'release_stale_unpacked_dispatches','decline_dispatch_return','unskip_dispatch_line',
    -- PRD-107 2026-07-29: orphaned swap-leg guard flags needs_review at pack close
    'confirm_machine_packed',
    -- PRD-110 P4.4b 2026-08-04: the post-facto fill path re-asserts its OWN
    -- name before writing filled_quantity. Without this entry it would pass
    -- only on receive_dispatch_line's LEAKED GUC, under another writer's
    -- identity - a guard satisfied for the wrong reason (S-160 family).
    'receive_dispatch_line_sourced_v3',
    -- PRD-112 2026-08-08: the driver's at-machine substitution and the CS
    -- day-close acknowledge. acknowledge_day_close_event calls
    -- adjust_pod_inventory, which overwrites app.rpc_name with its own name;
    -- it re-asserts this one afterwards rather than riding the leaked GUC
    -- (same S-160 lesson as the entry above).
    'driver_substitute_dispatch_line','acknowledge_day_close_event','acknowledge_day_close'];
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
END $function$;
