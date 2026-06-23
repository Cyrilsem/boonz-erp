-- PRD-053 PHASE B — field per-expiry split, TOTAL LOCKED to plan (FILE only).
--
-- The driver can split ONE dispatch line across real expiry dates, but the line
-- TOTAL is immutable (locked to the plan). New canonical writer
-- set_dispatch_line_breakdown stores the per-expiry breakdown in
-- refill_dispatching.driver_confirmed_breakdown using the SAME jsonb shape that
-- receive_dispatch_line already consumes as p_batch_breakdown:
--   [ { "qty": <number>, "expiry": "<YYYY-MM-DD>"|null, "wh_inventory_id": <uuid>|null }, ... ]
-- It enforces SUM(qty) = line.quantity and never touches quantity/action/status
-- (only the expiry distribution + the convenience expiry_date = earliest entry).
-- At receive time the FE passes driver_confirmed_breakdown straight into
-- receive_dispatch_line(p_batch_breakdown) so WH is credited per expiry.
--
-- Forward-only; DEFINER; app.via_rpc/rpc_name; role + input validation; the generic
-- write_audit_log trigger on refill_dispatching captures the edit.

CREATE OR REPLACE FUNCTION public.set_dispatch_line_breakdown(
  p_dispatch_id uuid,
  p_batch_breakdown jsonb,
  p_edit_role text DEFAULT NULL,
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
  v_dispatch  refill_dispatching%ROWTYPE;
  v_total     numeric := 0;
  v_entry     jsonb;
  v_qty       numeric;
  v_n         int := 0;
  v_earliest  date := NULL;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'set_dispatch_line_breakdown', true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'set_dispatch_line_breakdown: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  IF p_dispatch_id IS NULL OR p_batch_breakdown IS NULL OR jsonb_typeof(p_batch_breakdown) <> 'array' THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: p_dispatch_id and a JSON array p_batch_breakdown are required';
  END IF;
  IF jsonb_array_length(p_batch_breakdown) = 0 THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: p_batch_breakdown is empty';
  END IF;

  SELECT * INTO v_dispatch FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: dispatch % not found', p_dispatch_id;
  END IF;
  -- editing the expiry split is only meaningful before the line is dispatched/received
  IF COALESCE(v_dispatch.item_added,false) OR COALESCE(v_dispatch.dispatched,false) THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: dispatch % already dispatched/received — breakdown is locked', p_dispatch_id;
  END IF;

  -- validate entries + accumulate the total (qty >= 0; expiry optional = to-confirm)
  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_batch_breakdown)
  LOOP
    v_qty := (v_entry->>'qty')::numeric;
    IF v_qty IS NULL OR v_qty < 0 THEN
      RAISE EXCEPTION 'set_dispatch_line_breakdown: each entry needs qty >= 0 (got %)', v_entry;
    END IF;
    v_total := v_total + v_qty;
    v_n := v_n + 1;
    IF NULLIF(v_entry->>'expiry','') IS NOT NULL THEN
      v_earliest := LEAST(v_earliest, (v_entry->>'expiry')::date);
    END IF;
  END LOOP;

  -- TOTAL LOCKED: the breakdown must sum to the line total; quantity is never changed.
  IF v_total <> v_dispatch.quantity THEN
    RAISE EXCEPTION 'set_dispatch_line_breakdown: breakdown total (%) must equal the line total (%) — the total is immutable, only the expiry distribution may change',
      v_total, v_dispatch.quantity;
  END IF;

  PERFORM set_config('app.mutation_reason',
    COALESCE(p_reason, format('PRD-053 driver per-expiry breakdown on dispatch %s (%s entries, total %s)', p_dispatch_id, v_n, v_total)),
    true);

  UPDATE refill_dispatching
     SET driver_confirmed_breakdown = p_batch_breakdown,
         expiry_date          = COALESCE(v_earliest, expiry_date),
         last_edited_by       = v_uid,
         last_edited_by_role  = COALESCE(p_edit_role, v_role),
         last_edited_at       = now(),
         edit_count           = COALESCE(edit_count, 0) + 1
   WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object(
    'status','ok',
    'dispatch_id', p_dispatch_id,
    'line_total', v_dispatch.quantity,
    'breakdown_total', v_total,
    'entries', v_n,
    'earliest_expiry', v_earliest,
    'breakdown', p_batch_breakdown
  );
END;
$function$;

COMMENT ON FUNCTION public.set_dispatch_line_breakdown(uuid, jsonb, text, text) IS
  'PRD-053 Phase B: set the per-expiry breakdown on a dispatch line (driver_confirmed_breakdown), reusing the receive_dispatch_line p_batch_breakdown shape. Enforces SUM(qty)=line total; total/action/status immutable.';

GRANT EXECUTE ON FUNCTION public.set_dispatch_line_breakdown(uuid, jsonb, text, text) TO authenticated, service_role;
