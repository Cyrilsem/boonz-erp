-- PRD-141 item 19 (E3): days_since_visit and last visit move on delivery confirmation, not dispatch.
-- Before: v_machine_health_signals.last_visit = max(dispatch_date) of v_delivery_verification 'landed'
-- (picked_up on the dispatch_date plus WEIMI movement that day): a bag delivered two days after pickup
-- never counted, and a picked-up machine whose WEIMI rose for another reason did.
-- After: last visit = the latest of
--   * refill_dispatching.delivered_at (new; stamped by receive_dispatch_line when a Refill / Add New /
--     Add line is received with a filled quantity; backfilled from write_audit_log receive events),
--   * driver_confirmed_at of a Remove the driver confirmed (a removal visit is a visit),
--   * manual refill / adjust audit rows (unchanged).
-- Rollback: supabase/rollbacks/prd141_19_rollback.sql.

ALTER TABLE public.refill_dispatching ADD COLUMN IF NOT EXISTS delivered_at timestamptz;
COMMENT ON COLUMN public.refill_dispatching.delivered_at IS
  'PRD-141 item 19: when the line was received at the machine (receive_dispatch_line).';

DO $backfill$
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd141_19_backfill_delivered_at', true);
  UPDATE public.refill_dispatching rd
     SET delivered_at = a.first_receive
    FROM (SELECT w.row_pk::uuid AS dispatch_id, min(w.occurred_at) AS first_receive
            FROM public.write_audit_log w
           WHERE w.rpc_name = 'receive_dispatch_line' AND w.table_name = 'refill_dispatching'
           GROUP BY w.row_pk) a
   WHERE rd.dispatch_id = a.dispatch_id
     AND rd.delivered_at IS NULL
     AND rd.item_added = true
     AND rd.action IN ('Refill', 'Add New', 'Add')
     AND COALESCE(rd.filled_quantity, 0) > 0
     AND rd.dispatch_date >= CURRENT_DATE - 120;
END
$backfill$;

CREATE INDEX IF NOT EXISTS idx_refill_dispatching_machine_delivered
  ON public.refill_dispatching (machine_id, delivered_at DESC) WHERE delivered_at IS NOT NULL;

DO $patch$
DECLARE
  v_def text; n int;
  a_old text := '     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,';
  a_new text := '     SET filled_quantity = p_filled_quantity, item_added = true, dispatched = true, packed = true, picked_up = true,' || chr(10)
             || '         delivered_at = CASE WHEN v_dispatch.action IN (''Refill'',''Add New'',''Add'') AND p_filled_quantity > 0 THEN now() ELSE delivered_at END,  -- PRD-141 item 19';
BEGIN
  v_def := pg_get_functiondef('public.receive_dispatch_line(uuid,numeric,uuid,jsonb,boolean,text)'::regprocedure);
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'prd141_19: receive_dispatch_line anchor count %', n; END IF;
  EXECUTE replace(v_def, a_old, a_new);
END
$patch$;
REVOKE EXECUTE ON FUNCTION public.receive_dispatch_line(uuid, numeric, uuid, jsonb, boolean, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.receive_dispatch_line(uuid, numeric, uuid, jsonb, boolean, text) TO authenticated, service_role;

DO $view$
DECLARE
  v_def text := pg_get_viewdef('public.v_machine_health_signals'::regclass, true);
  i int; j int;
  v_new_cte text := 'last_visit AS MATERIALIZED (' || chr(10)
    || '         SELECT b_1.machine_id,' || chr(10)
    || '            GREATEST(( SELECT max((rd.delivered_at AT TIME ZONE ''Asia/Dubai''::text)::date) AS max' || chr(10)
    || '                   FROM refill_dispatching rd' || chr(10)
    || '                  WHERE rd.machine_id = b_1.machine_id AND rd.delivered_at IS NOT NULL), ( SELECT max((rd.driver_confirmed_at AT TIME ZONE ''Asia/Dubai''::text)::date) AS max' || chr(10)
    || '                   FROM refill_dispatching rd' || chr(10)
    || '                  WHERE rd.machine_id = b_1.machine_id AND rd.action = ''Remove''::text AND rd.driver_confirmed_at IS NOT NULL AND COALESCE(rd.driver_confirmed_qty, 0::numeric) > 0::numeric)) AS last_visit_date' || chr(10)
    || '           FROM base b_1' || chr(10)
    || '        ), manual_refill_visit AS (';
BEGIN
  i := strpos(v_def, 'last_visit AS MATERIALIZED (');
  j := strpos(v_def, 'manual_refill_visit AS (');
  IF i = 0 OR j = 0 OR j < i THEN RAISE EXCEPTION 'prd141_19: view anchors missing'; END IF;
  IF strpos(substr(v_def, i, j - i), 'v_delivery_verification') = 0 THEN RAISE EXCEPTION 'prd141_19: unexpected last_visit body'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_machine_health_signals AS ' || substr(v_def, 1, i - 1) || v_new_cte || substr(v_def, j + length('manual_refill_visit AS (')) ;
END
$view$;
