-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-107 Pack-stage truth, step 4/5. Source: docs/prds/PRD-107-EXECUTION-LOG.md Phase 2/3;
-- docs/architecture/MIGRATIONS_REGISTRY.md:686.
-- confirm_machine_packed now reads v_dispatch_pack_progress instead of an inline predicate
-- (FE/RPC divergence structurally impossible), gains the R4 orphaned-swap-leg guard, and is
-- added to the enforce_canonical_dispatch_write allowlist (Cody block #2 - orphan flags would
-- otherwise log as bypasses).
-- NOTE: this function was FURTHER modified the same day by 20260729080517
-- (prd107_auto_resolve_driver_legs_at_pack_close), which adds the R2/R5 driver-leg
-- auto-resolve UPDATE block. That block is deliberately OMITTED below to reflect this
-- migration's own delta; the cumulative post-080517 body lives in that later file.

CREATE OR REPLACE FUNCTION public.confirm_machine_packed(p_machine_name text, p_dispatch_date date DEFAULT NULL::date, p_packed_by uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_final boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid(); v_role text; v_machine_id uuid;
  v_date date := COALESCE(p_dispatch_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date);
  v_unresolved jsonb; v_summary jsonb;
  v_p record;                 -- v_dispatch_pack_progress row
  v_orphans jsonb := '[]'::jsonb;
  v_orphan_n integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','confirm_machine_packed',true);
  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'confirm_machine_packed: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'confirm_machine_packed: p_reason required (>= 10 chars)';
  END IF;
  PERFORM set_config('app.mutation_reason', p_reason, true);
  SELECT machine_id INTO v_machine_id FROM public.machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'confirm_machine_packed: machine % not found', p_machine_name; END IF;

  -- Article 16: the canonical object decides readiness. No inline re-derivation.
  SELECT * INTO v_p FROM public.v_dispatch_pack_progress
   WHERE machine_id = v_machine_id AND dispatch_date = v_date;

  IF NOT FOUND THEN
    -- No included, non-cancelled lines at all for this machine/date.
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count',0,'unresolved','[]'::jsonb,
      'message','No included dispatch lines for this machine and date.');
  END IF;

  -- Line-level detail for the blocked response. Same predicate as the view.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dispatch_id', rd.dispatch_id, 'shelf_id', rd.shelf_id,
            'boonz_product_id', rd.boonz_product_id, 'action', rd.action, 'quantity', rd.quantity) ORDER BY rd.shelf_id), '[]'::jsonb)
    INTO v_unresolved
  FROM public.refill_dispatching rd
  WHERE rd.machine_id = v_machine_id AND rd.dispatch_date = v_date
    AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.include, true) = true
    AND COALESCE(rd.packed, false) = false AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.pack_outcome::text, '') <> 'not_filled' AND rd.action IN ('Refill','Add New','Add');

  IF p_final AND NOT v_p.ready_to_pack_close THEN
    RETURN jsonb_build_object('status','blocked','machine',p_machine_name,'dispatch_date',v_date,
      'unresolved_count', v_p.packable_n - v_p.resolved_n,
      'unresolved', v_unresolved,
      'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
      'driver_action_n', v_p.driver_action_n,
      'message','Finish blocked: some included lines are neither packed nor marked not_filled/skipped. Pack/mark them, or use Save & come back.');
  END IF;

  -- R4: orphaned swap-leg guard. A live REMOVE whose paired swap-in all died
  -- would ship an EMPTY shelf. Flag it, surface it, propose the skip. Never silent,
  -- never auto-applied - the packer accepts it explicitly via skip_dispatch_line.
  IF p_final THEN
    v_orphans   := COALESCE(v_p.orphaned_swap_legs, '[]'::jsonb);
    v_orphan_n  := COALESCE(v_p.orphaned_swap_leg_n, 0);
    IF v_orphan_n > 0 THEN
      UPDATE public.refill_dispatching rd
         SET needs_review  = true,
             review_reason = 'orphaned_swap_leg',
             review_status = 'pending'   -- matches idx_refill_dispatching_needs_review
       WHERE rd.dispatch_id IN (
               SELECT (x->>'dispatch_id')::uuid FROM jsonb_array_elements(v_orphans) x)
         AND COALESCE(rd.needs_review,false) = false;
    END IF;
  END IF;

  SELECT jsonb_build_object(
    'total_included', COUNT(*) FILTER (WHERE COALESCE(include,true) AND NOT COALESCE(cancelled,false)),
    'packed', COUNT(*) FILTER (WHERE packed AND COALESCE(pack_outcome::text,'packed') NOT IN ('partial','not_filled')),
    'partial', COUNT(*) FILTER (WHERE pack_outcome = 'partial'),
    'not_filled', COUNT(*) FILTER (WHERE pack_outcome = 'not_filled'),
    'skipped', COUNT(*) FILTER (WHERE skipped))
  INTO v_summary FROM public.refill_dispatching
  WHERE machine_id = v_machine_id AND dispatch_date = v_date AND NOT COALESCE(cancelled,false);

  v_summary := v_summary || jsonb_build_object(
    'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
    'driver_action_n', v_p.driver_action_n, 'no_pack_needed_n', v_p.no_pack_needed_n,
    'orphaned_swap_leg_n', v_orphan_n);

  INSERT INTO public.dispatch_pack_confirmation (machine_id, dispatch_date, confirmed_by, confirmed_at, reason, summary, final)
  VALUES (v_machine_id, v_date, COALESCE(p_packed_by, v_uid), now(), p_reason, v_summary, p_final)
  ON CONFLICT (machine_id, dispatch_date) DO UPDATE
    SET confirmed_by = EXCLUDED.confirmed_by, confirmed_at = now(), reason = EXCLUDED.reason,
        summary = EXCLUDED.summary, final = EXCLUDED.final;

  IF p_final THEN
    RETURN jsonb_build_object('status','ok','confirmed',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','completed','confirmed_by',COALESCE(p_packed_by, v_uid),
      'packed_n',(v_summary->>'packed')::int,'partial_n',(v_summary->>'partial')::int,
      'skipped_n',(v_summary->>'skipped')::int,'not_filled_n',(v_summary->>'not_filled')::int,
      'packable_n', v_p.packable_n, 'resolved_n', v_p.resolved_n,
      'driver_action_n', v_p.driver_action_n,
      'orphaned_swap_legs', v_orphans, 'orphaned_swap_leg_n', v_orphan_n,
      'needs_review', (v_orphan_n > 0),
      'summary',v_summary);
  ELSE
    RETURN jsonb_build_object('status','saved','saved',true,'machine',p_machine_name,'dispatch_date',v_date,
      'pack_state','in_progress',
      'resolved_n',v_p.resolved_n,'remaining_n', v_p.packable_n - v_p.resolved_n,
      'packable_n', v_p.packable_n, 'driver_action_n', v_p.driver_action_n,
      'summary',v_summary);
  END IF;
END; $function$;

-- Allowlist entry so the orphan-guard UPDATE above does not log as a bypass violation.
-- Reconstructed at this migration's era (07-29): includes RC-04 2026-07-19 prep entries and
-- this migration's own 'confirm_machine_packed' addition; deliberately EXCLUDES entries added
-- by later, already-committed migrations (PRD-110 2026-08-04, PRD-112 2026-08-08,
-- PRD-113 2026-08-10) so replay order matches history.
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
    'confirm_machine_packed'];
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
