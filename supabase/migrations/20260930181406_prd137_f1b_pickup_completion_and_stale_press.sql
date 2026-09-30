-- PRD-137 F1b, drafted 2026-09-30 daytime, NOT YET APPLIED. This migration touches dispatch/
-- packing/pickup functions and must only be applied inside the confirmed 22:00-06:00 Dubai
-- window (this run's own hard rule, and the standing rule in docs/REFILL-DAILY-LOOP.md). It is
-- fully drafted and tested in rolled-back transactions against real evidence below; apply it
-- verbatim tonight, then rename it to match whatever version apply_migration actually records
-- (see the F9 migration's note on why -- this bit CS again on the very next request, so treat it
-- as certain, not likely).
--
-- CS evidence, two distinct bugs:
--
-- (1) AMZ-1038-3001-O1, 2026-09-30 08:14 Dubai: 10 of 11 lines packed, picked_up=0 on all of
-- them. The 11th line has pack_outcome='not_filled' (warehouse deliberately did not fill it) --
-- it will NEVER reach packed=true, so "every line packed" is the wrong completion signal. The
-- right signal is "every active line has been DECIDED" (pack_outcome is no longer NULL), which
-- not_filled/returned/no_pack_needed/packed/partial/packed_transferred all satisfy. F1 (already
-- live) only propagates pickup once at least one row already has picked_up=true; it does nothing
-- for a machine that reaches full completion with ZERO manual presses yet, which is exactly this
-- case.
--
-- (2) MC-2004-0100-O1 B09 and VML-1003-0400-O1 A13, 2026-09-30: traced via write_audit_log.
-- Two lines on the same machine/date packed 351ms apart (04:36:35.501 and .852 UTC) via
-- pack_dispatch_line, BEFORE any pickup press. mark_picked_up was called 52 seconds later
-- (04:37:27) but its audit row shows only ONE of the two dispatch_ids flipped to picked_up=true
-- -- the FE's own p_dispatch_ids array, built from client state captured before the second pack
-- event, never included it. F1's "sticky" trigger does not help here either: at the moment the
-- second line packed, no row for that machine/date had picked_up=true yet (the first pickup
-- happens ONLY inside that same mark_picked_up call), so the sticky condition correctly found
-- nothing to propagate from. The real bug is that mark_picked_up trusts its caller's array as
-- complete instead of re-deriving the true current set at execution time.
--
-- Fix (1): a new trigger fires whenever a row's pack_outcome is set (transitions from NULL, or
-- is set on insert) and checks whether that machine/date now has zero active rows still awaiting
-- a pack decision (pack_outcome IS NULL, excluding cancelled/skipped/include=false). If so, every
-- packed=true row for that machine/date is marked picked_up=true, mirroring exactly what
-- mark_picked_up itself would do -- no manual press required at all for a machine that reaches
-- full completion with none yet.
--
-- Fix (2): mark_picked_up no longer trusts p_dispatch_ids as the complete set. It still validates
-- the literal input (not found / not packed / already picked up reporting is unchanged, and the
-- RPC still requires a non-empty array so it cannot be called with no context), but the actual
-- UPDATE is widened to every packed=true, picked_up=false row for the (machine_id, dispatch_date)
-- pairs the input array touches -- so a line packed a second before the press, or missed by a
-- stale client list, is picked up in the same call regardless.
--
-- Rollback: supabase/rollback/20260930181406_prd137_f1b_pickup_completion_and_stale_press_rollback.sql
CREATE OR REPLACE FUNCTION public.tg_auto_pickup_on_machine_complete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.refill_dispatching d
     WHERE d.machine_id = NEW.machine_id
       AND d.dispatch_date = NEW.dispatch_date
       AND COALESCE(d.cancelled,false) = false
       AND COALESCE(d.skipped,false) = false
       AND COALESCE(d.include,true) = true
       AND d.pack_outcome IS NULL
  ) THEN
    PERFORM set_config('app.via_trigger', 'true', true);
    UPDATE public.refill_dispatching
       SET picked_up = true
     WHERE machine_id = NEW.machine_id
       AND dispatch_date = NEW.dispatch_date
       AND packed = true
       AND picked_up = false;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_auto_pickup_on_completion_insert
  AFTER INSERT ON public.refill_dispatching
  FOR EACH ROW
  WHEN (NEW.pack_outcome IS NOT NULL)
  EXECUTE FUNCTION public.tg_auto_pickup_on_machine_complete();

CREATE TRIGGER trg_auto_pickup_on_completion_update
  AFTER UPDATE OF pack_outcome ON public.refill_dispatching
  FOR EACH ROW
  WHEN (NEW.pack_outcome IS NOT NULL AND OLD.pack_outcome IS NULL)
  EXECUTE FUNCTION public.tg_auto_pickup_on_machine_complete();

CREATE OR REPLACE FUNCTION public.mark_picked_up(p_dispatch_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role           text;
  v_caller_id             uuid;
  v_picked_up_count       int := 0;
  v_already_picked_up_ids uuid[];
  v_not_packed_ids        uuid[];
  v_not_found_ids         uuid[];
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'mark_picked_up', true);

  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'No authenticated caller');
  END IF;

  -- Role validation: field driver, warehouse manager (in case they pick up themselves), or admin.
  SELECT role INTO v_caller_role
  FROM public.user_profiles
  WHERE id = v_caller_id;

  IF v_caller_role NOT IN ('field_staff', 'warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'error',  'Insufficient role — pickup requires field_staff / warehouse / admin'
    );
  END IF;

  IF p_dispatch_ids IS NULL OR array_length(p_dispatch_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'p_dispatch_ids must be a non-empty array');
  END IF;

  -- Compute "not found" / "not packed" / "already picked up" before the UPDATE, still against
  -- the literal input for reporting purposes.
  SELECT array_agg(id) INTO v_not_found_ids
  FROM unnest(p_dispatch_ids) AS id
  WHERE NOT EXISTS (
    SELECT 1 FROM public.refill_dispatching d WHERE d.dispatch_id = id
  );

  SELECT array_agg(d.dispatch_id) INTO v_not_packed_ids
  FROM public.refill_dispatching d
  WHERE d.dispatch_id = ANY(p_dispatch_ids)
    AND d.packed     = false;

  SELECT array_agg(d.dispatch_id) INTO v_already_picked_up_ids
  FROM public.refill_dispatching d
  WHERE d.dispatch_id = ANY(p_dispatch_ids)
    AND d.packed      = true
    AND d.picked_up   = true;

  -- PRD-137 F1b: apply against every packed=true, picked_up=false row for the (machine_id,
  -- dispatch_date) pairs the input touches, not just the literal dispatch_ids. A line packed a
  -- moment before the press, or missed by a stale client list, is included in the same call.
  UPDATE public.refill_dispatching t
  SET picked_up = true
  WHERE t.packed = true
    AND t.picked_up = false
    AND EXISTS (
      SELECT 1 FROM public.refill_dispatching seed
       WHERE seed.dispatch_id = ANY(p_dispatch_ids)
         AND seed.machine_id = t.machine_id
         AND seed.dispatch_date = t.dispatch_date
    );

  GET DIAGNOSTICS v_picked_up_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'status',                'ok',
    'picked_up_count',       v_picked_up_count,
    'already_picked_up_ids', COALESCE(v_already_picked_up_ids, ARRAY[]::uuid[]),
    'not_packed_ids',        COALESCE(v_not_packed_ids,        ARRAY[]::uuid[]),
    'not_found_ids',         COALESCE(v_not_found_ids,         ARRAY[]::uuid[]),
    'caller_id',             v_caller_id,
    'caller_role',           v_caller_role
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'status', 'error',
    'error',  SQLERRM,
    'detail', SQLSTATE
  );
END;
$function$;
