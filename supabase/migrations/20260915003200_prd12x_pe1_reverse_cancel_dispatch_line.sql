-- ONE-LOOP-2 Block E: reverse_cancel_dispatch_line clears the 76 junk
-- 2030-dated dispatch rows (PRD-124 #41, PRD-122 R3.4 never executed).
-- cancel_dispatch_line cannot be used on them: it requires dispatched=true
-- (all 76 have dispatched=false) and refuses any row with
-- from_wh_inventory_id set (D-009, last night).
--
-- Guard, exactly as specified: only packed=false AND dispatched=false.
-- Clears from_wh_inventory_id and from_warehouse_id (no warehouse_stock
-- move -- the physical stock never left the shelf, only the soft
-- reservation is released, since wh_available_for's pin-subtraction reads
-- refill_dispatching WHERE cancelled=false; once cancelled=true the row
-- drops out of that SUM on its own). Sets cancelled=true, cancelled_at,
-- cancelled_by, cancellation_reason (existing columns built for exactly
-- this), include=false, and appends the reason to comment. The generic
-- tg_audit_refill_dispatching trigger (audit_log_write) captures the
-- before/after row into write_audit_log once app.via_rpc/app.rpc_name are
-- set and the RPC name is in enforce_canonical_dispatch_write's allowlist.
--
-- Real finding, not assumed: of the 76 rows, only 19 satisfy the guard
-- (packed=false AND dispatched=false); 57 are packed=true. The guard
-- refuses those 57 exactly as designed -- "packed" claims a real physical
-- warehouse action, and this RPC is deliberately conservative about
-- treating that claim as junk without a human decision. Only 2 of the
-- qualifying 19 are pinned (from_wh_inventory_id set), not the "25
-- previously pinned" the prompt anticipated -- most of the 25 pins sit on
-- the 57 packed rows this RPC does not touch. See
-- DECISIONS-2026-09-15.md D-022 for the full account.
CREATE OR REPLACE FUNCTION public.reverse_cancel_dispatch_line(
  p_dispatch_id uuid,
  p_reason text,
  p_caller uuid DEFAULT auth.uid(),
  p_dry_run boolean DEFAULT true
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_role text;
  v_row public.refill_dispatching%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'reverse_cancel_dispatch_line', true);

  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'forbidden: reverse_cancel_dispatch_line requires warehouse, operator_admin, superadmin, or manager';
    END IF;
  END IF;

  IF p_dispatch_id IS NULL THEN
    RAISE EXCEPTION 'reverse_cancel_dispatch_line: p_dispatch_id is required';
  END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN
    RAISE EXCEPTION 'reverse_cancel_dispatch_line: p_reason is required';
  END IF;

  SELECT * INTO v_row FROM public.refill_dispatching
   WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reverse_cancel_dispatch_line: no such dispatch_id %', p_dispatch_id;
  END IF;
  IF COALESCE(v_row.packed, false) THEN
    RAISE EXCEPTION 'reverse_cancel_dispatch_line: dispatch % is packed=true -- refused, this RPC only clears rows that were never packed', p_dispatch_id;
  END IF;
  IF COALESCE(v_row.dispatched, false) THEN
    RAISE EXCEPTION 'reverse_cancel_dispatch_line: dispatch % is dispatched=true -- use cancel_dispatch_line instead', p_dispatch_id;
  END IF;
  IF COALESCE(v_row.cancelled, false) THEN
    RAISE EXCEPTION 'reverse_cancel_dispatch_line: dispatch % is already cancelled', p_dispatch_id;
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'status', 'dry_run_ok',
      'dispatch_id', p_dispatch_id,
      'would_release_from_wh_inventory_id', v_row.from_wh_inventory_id,
      'would_release_from_warehouse_id', v_row.from_warehouse_id,
      'row', to_jsonb(v_row)
    );
  END IF;

  UPDATE public.refill_dispatching
     SET cancelled = true,
         cancelled_at = now(),
         cancelled_by = v_user_id,
         cancellation_reason = trim(p_reason),
         include = false,
         from_wh_inventory_id = NULL,
         from_warehouse_id = NULL,
         comment = COALESCE(comment || E'\n', '') || format('[reverse_cancel_dispatch_line] %s', trim(p_reason))
   WHERE dispatch_id = p_dispatch_id;

  SELECT * INTO v_row FROM public.refill_dispatching WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'dispatch_id', p_dispatch_id,
    'row', to_jsonb(v_row)
  );
END;
$function$;
