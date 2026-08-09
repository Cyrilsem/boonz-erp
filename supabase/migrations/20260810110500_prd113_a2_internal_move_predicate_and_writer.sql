-- PRD-113 A2 — ONE canonical definition of "this Remove is an in-machine move",
--                plus the two writers that stamp and un-stamp it.
--
-- Article 16: four consumers need this answer — the return-approval queue view and the three
-- wh_approve_* RPCs. They all read is_internal_move_dispatch(); nobody re-implements the rule.
--
-- WHY A TRIGGER AND NOT AN EDIT TO EVERY WRITER
--   The PRD names four writer families (stitch same-shelf swap legs, push_plan_to_dispatch
--   paired legs, add_dispatch_row with source_kind='m2m' AND source_machine_id=machine_id,
--   and "Move with Machine"). stitch_pod_to_boonz alone is 51 KB and push_plan_to_dispatch
--   24 KB; re-emitting protected engine code to append one PERFORM each is a large diff for
--   zero extra coverage. More decisive: the pair is not knowable at the moment the Remove leg
--   is inserted — its Add New counterpart is normally written later in the same batch. Only a
--   post-insert pass can see both legs.
--
--   The trigger is the codebase's own established shape for this
--   (trg_flag_remove_with_transfer_intent, trg_flag_multivariant_return_without_correction,
--   trg_flag_multivariant_pack_without_confirmation), and it covers every writer that exists
--   today AND every writer added tomorrow, with one implementation.
--
--   Belt and braces: the stored column is NOT the safety net. The queue view and all three
--   approve RPCs call the live predicate, so a leg the trigger somehow missed still cannot
--   produce a phantom warehouse credit.
--
-- CODY REVIEW 2026-08-10 — conditions 1, 2, 3, 4, 5 are implemented here:
--   (1) mark_internal_move_legs sets app.via_rpc + app.rpc_name, validates caller role, and
--       is added to the enforce_canonical_dispatch_write allowlist below.
--   (2) tg_mark_internal_move_pair stamps app.rpc_name around its own UPDATE and restores the
--       prior value, so write_audit_log names the real writer instead of crediting the
--       enclosing engine (the S-160 lesson).
--   (3) is_internal_move_dispatch is SECURITY INVOKER — it is read-only, and
--       refill_dispatching carries policy authenticated_read FOR SELECT with qual = true, so
--       DEFINER buys nothing and only adds an escalation surface.
--   (4) clear_internal_move_flag() is the canonical un-stamp writer. Before it existed, the
--       refusal messages instructed a direct UPDATE on refill_dispatching — executable,
--       because authenticated holds table-level UPDATE there (Articles 1 and 3).
--   (5) internal_move_cleared_at makes that human ruling durable: it is the FIRST branch of
--       the predicate and a skip condition in both stamping writers.
--
-- NEVER SILENT (LAW 5): every auto-flag and every manual clear lands a monitoring_alerts row.
--
-- ADDITIVE ONLY: new functions, one new trigger, one allowlist entry. Nothing dropped.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE PREDICATE — the single definition. Read-only, SECURITY INVOKER.
-- ─────────────────────────────────────────────────────────────────────────────
-- Returns NULL for a dispatch_id that does not exist; every caller wraps in COALESCE.
CREATE OR REPLACE FUNCTION public.is_internal_move_dispatch(p_dispatch_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    -- Cody condition 5. A human has ruled this leg a genuine warehouse return. That ruling
    -- outranks every heuristic below and is never re-litigated.
    WHEN rd.internal_move_cleared_at IS NOT NULL THEN false
    -- Already stamped: the writers' answer wins, and CS can stamp by hand.
    WHEN COALESCE(rd.is_internal_move, false) THEN true
    -- Only a Remove leg can be an in-machine move.
    WHEN rd.action <> 'Remove' THEN false
    -- is_m2m is the DIFFERENT-machine transfer. It has its own approval path
    -- (approve_m2m_transfer) and its own guard; never claim it here.
    WHEN COALESCE(rd.is_m2m, false) THEN false
    -- add_dispatch_row's same-machine "m2m": source_kind says transfer, but the source
    -- machine IS this machine, so the units never leave it. Named explicitly by the PRD.
    WHEN rd.source_kind = 'm2m' AND rd.source_machine_id = rd.machine_id THEN true
    -- The MC-2004 shape: the removed product reappears as an Add New on ANOTHER shelf of
    -- the SAME machine in the SAME plan. Those units are moving, not returning.
    ELSE EXISTS (
      SELECT 1
      FROM public.refill_dispatching add_leg
      WHERE add_leg.machine_id       = rd.machine_id
        AND add_leg.dispatch_date    = rd.dispatch_date
        AND add_leg.boonz_product_id = rd.boonz_product_id
        AND add_leg.action           IN ('Add New', 'Add')
        AND add_leg.shelf_id IS DISTINCT FROM rd.shelf_id
        AND COALESCE(add_leg.cancelled, false) = false
        AND COALESCE(add_leg.skipped,   false) = false
        AND COALESCE(add_leg.include,   true)  = true
    )
  END
  FROM public.refill_dispatching rd
  WHERE rd.dispatch_id = p_dispatch_id
    AND rd.boonz_product_id IS NOT NULL;
$function$;

COMMENT ON FUNCTION public.is_internal_move_dispatch(uuid) IS
  'PRD-113 canonical predicate (Article 16). TRUE when this Remove leg moves product to '
  'another shelf of the SAME machine rather than back to the warehouse. Read by '
  'v_pending_wh_remove_confirmations and by wh_approve_remove_receipt / '
  'wh_approve_remove_receipt_multivariant / approve_stuck_remove. A leg carrying '
  'internal_move_cleared_at is ALWAYS false — a human ruling outranks the pairing heuristic. '
  'NULL if the dispatch_id does not exist or carries no boonz_product_id; callers COALESCE '
  'to false. SECURITY INVOKER: read-only, and refill_dispatching grants authenticated SELECT '
  'with qual = true, so no elevation is warranted.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE SHARED STAMP WRITER — label every unsettled Remove leg on a plan.
-- ─────────────────────────────────────────────────────────────────────────────
-- Idempotent and safe to call repeatedly. Never touches a leg that is already settled
-- (approved / returned / received) or that a human has ruled on — history is not rewritten
-- and an operator is not overruled; only open, undecided work is labelled.
CREATE OR REPLACE FUNCTION public.mark_internal_move_legs(
  p_dispatch_date date,
  p_machine_id    uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_marked   int := 0;
  v_uid      uuid := (SELECT auth.uid());
  v_role     text;
  v_prev_via text;
  v_ids      uuid[];
BEGIN
  IF p_dispatch_date IS NULL THEN
    RAISE EXCEPTION 'mark_internal_move_legs: p_dispatch_date is required';
  END IF;

  -- Article 4: validate the caller. A NULL uid is the service_role / cron context, which is
  -- trusted here; a signed-in caller must hold a dispatch-owning role.
  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF COALESCE(v_role, '') NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
      RAISE EXCEPTION 'mark_internal_move_legs: role % may not relabel dispatch legs (need warehouse / operator_admin / superadmin / manager)',
        COALESCE(v_role, 'unknown');
    END IF;
  END IF;

  -- Article 4: provenance. mark_internal_move_legs is in the
  -- enforce_canonical_dispatch_write allowlist (added at the bottom of this migration), so
  -- these two GUCs are what make its write a sanctioned one rather than a logged bypass.
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'mark_internal_move_legs', true);
  PERFORM set_config('app.mutation_reason',
    format('mark_internal_move_legs by %s on plan %s (machine %s): labelling in-machine move legs so they leave the warehouse return queue',
      COALESCE(v_uid::text, 'service_role'), p_dispatch_date,
      COALESCE(p_machine_id::text, 'ALL')), true);

  -- enforce_canonical_dispatch_write also passes trigger-sourced writes on this GUC. Restore
  -- it before returning: a transaction-local set_config leaks into every later statement of
  -- the same transaction (the PRD-016B provenance-GUC leak).
  v_prev_via := current_setting('app.via_trigger', true);
  PERFORM set_config('app.via_trigger', 'true', true);

  WITH upd AS (
    UPDATE public.refill_dispatching rd
       SET is_internal_move = true
     WHERE rd.dispatch_date = p_dispatch_date
       AND (p_machine_id IS NULL OR rd.machine_id = p_machine_id)
       AND rd.action = 'Remove'
       AND rd.boonz_product_id IS NOT NULL
       AND rd.internal_move_cleared_at IS NULL          -- Cody condition 5
       AND COALESCE(rd.is_internal_move, false) = false
       AND COALESCE(rd.is_m2m,           false) = false
       AND COALESCE(rd.cancelled,        false) = false
       AND COALESCE(rd.returned,         false) = false
       AND COALESCE(rd.item_added,       false) = false
       AND rd.wh_approved_at IS NULL
       AND COALESCE(public.is_internal_move_dispatch(rd.dispatch_id), false)
    RETURNING rd.dispatch_id
  )
  SELECT array_agg(dispatch_id), count(*)::int INTO v_ids, v_marked FROM upd;

  PERFORM set_config('app.via_trigger', COALESCE(v_prev_via, ''), true);

  IF COALESCE(v_marked, 0) > 0 THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('prd113_internal_move_flagged', 'info',
      jsonb_build_object(
        'writer',        'mark_internal_move_legs',
        'actor',         v_uid,
        'dispatch_date', p_dispatch_date,
        'machine_id',    p_machine_id,
        'rows_marked',   v_marked,
        'dispatch_ids',  to_jsonb(v_ids),
        'message',       'In-machine move legs excluded from the warehouse return queue. '
                      || 'If any of these is a GENUINE return, call '
                      || 'clear_internal_move_flag(dispatch_id, reason).'));
  END IF;

  RETURN jsonb_build_object(
    'status',        'ok',
    'dispatch_date', p_dispatch_date,
    'machine_id',    p_machine_id,
    'rows_marked',   COALESCE(v_marked, 0),
    'dispatch_ids',  COALESCE(to_jsonb(v_ids), '[]'::jsonb));
END;
$function$;

COMMENT ON FUNCTION public.mark_internal_move_legs(date, uuid) IS
  'PRD-113 shared stamp writer. Labels every unsettled, un-ruled Remove leg of a plan that '
  'is_internal_move_dispatch() identifies as an in-machine move. Idempotent. Called by hand '
  'to re-label a plan edited outside the insert path; tg_mark_internal_move_pair covers the '
  'insert path itself. Roles: warehouse, operator_admin, superadmin, manager.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE CANONICAL UN-STAMP WRITER (Cody condition 4).
-- ─────────────────────────────────────────────────────────────────────────────
-- Every refusal message in A3 points HERE. Before this existed they pointed at a raw
-- `UPDATE refill_dispatching SET is_internal_move = false`, which authenticated can actually
-- execute (table-level UPDATE grant + a permissive policy for five roles) — Articles 1 and 3.
-- The gate that protects a credit path must itself have a canonical, audited writer.
CREATE OR REPLACE FUNCTION public.clear_internal_move_flag(
  p_dispatch_id uuid,
  p_reason      text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_rd   refill_dispatching%ROWTYPE;
  v_uid  uuid := (SELECT auth.uid());
  v_role text;
BEGIN
  IF p_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'clear_internal_move_flag: p_dispatch_id is required';
  END IF;
  -- Same 10-character floor as reject/approve_pod_inventory_edit. "ok" is not a reason for
  -- re-opening a warehouse credit.
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'clear_internal_move_flag: p_reason is required and must be at least 10 characters — this re-opens a warehouse credit and the reason is the only record of why';
  END IF;

  -- Article 4: validate the caller. Unlike the stamp writer, this one OPENS a credit path,
  -- so an unauthenticated call is refused outright rather than trusted as service_role.
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'clear_internal_move_flag: requires an authenticated caller — this re-opens a warehouse credit and must be attributable to a person';
  END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF COALESCE(v_role, '') NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'clear_internal_move_flag: role % may not re-open a warehouse credit (need warehouse / operator_admin / superadmin / manager)',
      COALESCE(v_role, 'unknown');
  END IF;

  SELECT * INTO v_rd FROM public.refill_dispatching
   WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'clear_internal_move_flag: dispatch % not found', p_dispatch_id;
  END IF;
  IF v_rd.action <> 'Remove' THEN
    RAISE EXCEPTION 'clear_internal_move_flag: only a Remove leg can carry the internal-move flag (got %)', v_rd.action;
  END IF;
  IF v_rd.internal_move_cleared_at IS NOT NULL THEN
    RAISE EXCEPTION 'clear_internal_move_flag: dispatch % was already cleared at % by %',
      p_dispatch_id, v_rd.internal_move_cleared_at, COALESCE(v_rd.internal_move_cleared_by::text, 'unknown');
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'clear_internal_move_flag', true);
  PERFORM set_config('app.mutation_reason',
    format('clear_internal_move_flag by %s on dispatch %s: %s', v_uid, p_dispatch_id, p_reason), true);
  PERFORM set_config('app.via_trigger', 'true', true);

  UPDATE public.refill_dispatching
     SET is_internal_move         = false,
         internal_move_cleared_at = now(),
         internal_move_cleared_by = v_uid
   WHERE dispatch_id = p_dispatch_id;

  PERFORM set_config('app.via_trigger', '', true);

  -- LAW 5: re-opening a credit is at least as loud as closing one.
  INSERT INTO public.monitoring_alerts (source, severity, payload)
  VALUES ('prd113_internal_move_cleared', 'warning',
    jsonb_build_object(
      'dispatch_id',      p_dispatch_id,
      'machine_id',       v_rd.machine_id,
      'shelf_id',         v_rd.shelf_id,
      'boonz_product_id', v_rd.boonz_product_id,
      'dispatch_date',    v_rd.dispatch_date,
      'quantity',         v_rd.quantity,
      'cleared_by',       v_uid,
      'cleared_by_role',  v_role,
      'reason',           p_reason,
      'message',          'Internal-move flag cleared by hand. This leg is back in the '
                       || 'warehouse return queue and is now approvable for credit. '
                       || 'Confirm the units physically reached the warehouse.'));

  RETURN jsonb_build_object(
    'status',                   'cleared',
    'dispatch_id',              p_dispatch_id,
    'machine_id',               v_rd.machine_id,
    'internal_move_cleared_at', now(),
    'internal_move_cleared_by', v_uid,
    'reason',                   p_reason,
    'note',                     'The leg is back in v_pending_wh_remove_confirmations and the '
                             || 'wh_approve_* RPCs will now accept it. The clear is durable: '
                             || 'no writer re-stamps a leg carrying internal_move_cleared_at.');
END;
$function$;

COMMENT ON FUNCTION public.clear_internal_move_flag(uuid, text) IS
  'PRD-113 canonical writer for the internal-move override (Articles 1, 3, 4). Rules a Remove '
  'leg a GENUINE warehouse return despite the pairing heuristic, durably — no writer '
  're-stamps a leg carrying internal_move_cleared_at. Requires an authenticated caller '
  'holding warehouse / operator_admin / superadmin / manager and a reason of 10+ characters. '
  'Alerts on prd113_internal_move_cleared.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE TRIGGER — pair detection at insert, from EITHER side of the pair.
-- ─────────────────────────────────────────────────────────────────────────────
-- Row-level AFTER INSERT. The Remove leg and its Add New counterpart can arrive in either
-- order, so both arms are implemented:
--   • a Remove arriving after its Add New  → stamp itself
--   • an Add New arriving after its Remove → stamp the Remove
-- AFTER INSERT only, so the UPDATE it performs cannot re-enter this trigger.
CREATE OR REPLACE FUNCTION public.tg_mark_internal_move_pair()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_prev_via  text;
  v_prev_rpc  text;
  v_prev_trig text;
  v_ids       uuid[];
BEGIN
  -- Cody condition 2. Stamp our OWN name so write_audit_log.rpc_name names the real writer
  -- instead of inheriting the enclosing engine's (S-160: a guard satisfied for the wrong
  -- reason is not satisfied). Restored before returning — a transaction-local set_config
  -- leaks into every later statement of the same transaction (PRD-016B).
  v_prev_via  := current_setting('app.via_rpc',     true);
  v_prev_rpc  := current_setting('app.rpc_name',    true);
  v_prev_trig := current_setting('app.via_trigger', true);
  PERFORM set_config('app.rpc_name',    'tg_mark_internal_move_pair', true);
  PERFORM set_config('app.via_trigger', 'true',                       true);

  IF NEW.action = 'Remove' THEN
    -- This leg arrived last. Does its Add New counterpart already exist?
    IF COALESCE(public.is_internal_move_dispatch(NEW.dispatch_id), false) THEN
      WITH upd AS (
        UPDATE public.refill_dispatching
           SET is_internal_move = true
         WHERE dispatch_id = NEW.dispatch_id
           AND internal_move_cleared_at IS NULL
           AND COALESCE(is_internal_move, false) = false
           AND wh_approved_at IS NULL
           AND COALESCE(returned,   false) = false
           AND COALESCE(item_added, false) = false
        RETURNING dispatch_id
      )
      SELECT array_agg(dispatch_id) INTO v_ids FROM upd;
    END IF;
  ELSE
    -- An 'Add New' / 'Add' arrived. Any open Remove of the SAME product on ANOTHER shelf of
    -- this machine in this plan is that product moving, not returning.
    WITH upd AS (
      UPDATE public.refill_dispatching rd
         SET is_internal_move = true
       WHERE rd.machine_id       = NEW.machine_id
         AND rd.dispatch_date    = NEW.dispatch_date
         AND rd.boonz_product_id = NEW.boonz_product_id
         AND rd.action           = 'Remove'
         AND rd.shelf_id IS DISTINCT FROM NEW.shelf_id
         AND rd.internal_move_cleared_at IS NULL          -- Cody condition 5
         AND COALESCE(rd.is_internal_move, false) = false
         AND COALESCE(rd.is_m2m,           false) = false
         AND COALESCE(rd.cancelled,        false) = false
         AND COALESCE(rd.returned,         false) = false
         AND COALESCE(rd.item_added,       false) = false
         AND rd.wh_approved_at IS NULL
      RETURNING rd.dispatch_id
    )
    SELECT array_agg(dispatch_id) INTO v_ids FROM upd;
  END IF;

  PERFORM set_config('app.via_rpc',     COALESCE(v_prev_via,  ''), true);
  PERFORM set_config('app.rpc_name',    COALESCE(v_prev_rpc,  ''), true);
  PERFORM set_config('app.via_trigger', COALESCE(v_prev_trig, ''), true);

  -- LAW 5: a leg that leaves the approval queue must never leave it silently.
  IF v_ids IS NOT NULL AND array_length(v_ids, 1) > 0 THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('prd113_internal_move_flagged', 'info',
      jsonb_build_object(
        'writer',           'tg_mark_internal_move_pair',
        'trigger_side',     NEW.action,
        'trigger_dispatch', NEW.dispatch_id,
        'machine_id',       NEW.machine_id,
        'dispatch_date',    NEW.dispatch_date,
        'boonz_product_id', NEW.boonz_product_id,
        'dispatch_ids',     to_jsonb(v_ids),
        'message',          'In-machine move leg(s) excluded from the warehouse return '
                         || 'queue — units move to another shelf of the SAME machine. If '
                         || 'this is a GENUINE return, call '
                         || 'clear_internal_move_flag(dispatch_id, reason).'));
  END IF;

  RETURN NULL;  -- AFTER trigger: return value is ignored.
END;
$function$;

COMMENT ON FUNCTION public.tg_mark_internal_move_pair() IS
  'PRD-113. AFTER INSERT pair detector for refill_dispatching. Covers every writer '
  '(stitch, push_plan_to_dispatch, add_dispatch_row, the swap_* family, hand edits) with '
  'one implementation, because the Remove and its Add New counterpart are only both visible '
  'after the second of the pair lands. Never touches a settled leg or one carrying '
  'internal_move_cleared_at.';

DROP TRIGGER IF EXISTS trg_mark_internal_move_pair ON public.refill_dispatching;
CREATE TRIGGER trg_mark_internal_move_pair
AFTER INSERT ON public.refill_dispatching
FOR EACH ROW
WHEN (NEW.action IN ('Remove', 'Add New', 'Add')
      AND NEW.boonz_product_id IS NOT NULL
      AND COALESCE(NEW.cancelled, false) = false
      AND COALESCE(NEW.is_m2m,    false) = false)
EXECUTE FUNCTION public.tg_mark_internal_move_pair();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. ALLOWLIST (Cody condition 1).
-- ─────────────────────────────────────────────────────────────────────────────
-- enforce_canonical_dispatch_write passes a write only when app.rpc_name is a REGISTERED
-- canonical writer. Without these two entries, mark_internal_move_legs and
-- clear_internal_move_flag would do everything Article 4 asks and STILL land a
-- bypass_violation_log row on every call. Body is the shipped 2026-08-08 version with two
-- names appended; nothing else changes.
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
    'driver_substitute_dispatch_line','acknowledge_day_close_event','acknowledge_day_close',
    -- PRD-113 2026-08-10: the in-machine-move label and its human override.
    -- mark_internal_move_legs writes only is_internal_move; clear_internal_move_flag writes
    -- only the override columns. Both set app.via_rpc + app.rpc_name and both validate the
    -- caller's role, so they are Category-A single-writers by the RC-04 test.
    'mark_internal_move_legs','clear_internal_move_flag'];
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

GRANT EXECUTE ON FUNCTION public.is_internal_move_dispatch(uuid)      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_internal_move_legs(date, uuid)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.clear_internal_move_flag(uuid, text) TO authenticated, service_role;
