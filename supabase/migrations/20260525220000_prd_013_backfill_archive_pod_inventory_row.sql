-- PRD-013 P2.C: helper RPC for backlog cleanup. Archives a single pod_inventory
-- row (stock=0, est=0, status=Inactive, removal_reason) via the canonical writer
-- path so app.via_rpc=true and the audit trigger captures the write. Gated to
-- superadmin + operator_admin per PRD §C.3.
-- Cody verdict: approve. p_reason min 10 chars (Cody F1 — matches reject RPC).

CREATE OR REPLACE FUNCTION public.backfill_archive_pod_inventory_row(
  p_pod_inventory_id uuid,
  p_reason           text,
  p_edit_id_link     uuid    DEFAULT NULL,
  p_caller_id        uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id     uuid;
  v_caller_role text;
  v_pod         public.pod_inventory%ROWTYPE;
  v_reason      text;
BEGIN
  v_user_id := COALESCE(p_caller_id, auth.uid());
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'backfill_archive_pod_inventory_row: no caller identity';
  END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('superadmin','operator_admin') THEN
    RAISE EXCEPTION 'backfill_archive_pod_inventory_row: forbidden for role % (superadmin or operator_admin required)', COALESCE(v_caller_role, 'unknown');
  END IF;
  v_reason := trim(COALESCE(p_reason, ''));
  IF length(v_reason) < 10 THEN
    RAISE EXCEPTION 'backfill_archive_pod_inventory_row: p_reason required (min 10 chars, got %)', length(v_reason);
  END IF;

  SELECT * INTO v_pod FROM public.pod_inventory WHERE pod_inventory_id = p_pod_inventory_id FOR UPDATE;
  IF v_pod.pod_inventory_id IS NULL THEN
    RAISE EXCEPTION 'backfill_archive_pod_inventory_row: pod_inventory % not found', p_pod_inventory_id;
  END IF;
  IF v_pod.status = 'Inactive' THEN
    RAISE NOTICE 'backfill_archive_pod_inventory_row: pod % already Inactive; overwriting removal_reason from % to %',
      p_pod_inventory_id, v_pod.removal_reason, v_reason;
  END IF;

  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'backfill_archive_pod_inventory_row', true);
  PERFORM set_config('app.mutation_reason',
    format('backfill_archive pod=%s edit_link=%s by=%s reason=%s',
           p_pod_inventory_id, COALESCE(p_edit_id_link::text, 'none'), v_user_id, v_reason), true);

  UPDATE public.pod_inventory
     SET current_stock        = 0,
         estimated_remaining  = 0,
         status               = 'Inactive',
         removal_reason       = v_reason,
         last_decremented_at  = now()
   WHERE pod_inventory_id = p_pod_inventory_id;

  RETURN jsonb_build_object(
    'result',            'success',
    'pod_inventory_id',  p_pod_inventory_id,
    'previous_status',   v_pod.status,
    'previous_stock',    v_pod.current_stock,
    'previous_est',      v_pod.estimated_remaining,
    'new_status',        'Inactive',
    'reason',            v_reason,
    'edit_id_link',      p_edit_id_link,
    'reviewed_by',       v_user_id,
    'reviewed_at',       now()
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.backfill_archive_pod_inventory_row(uuid,text,uuid,uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.backfill_archive_pod_inventory_row(uuid,text,uuid,uuid) TO authenticated;

COMMENT ON FUNCTION public.backfill_archive_pod_inventory_row(uuid,text,uuid,uuid) IS
  'PRD-013 P2.C backlog cleanup helper. Archives a single pod_inventory row (stock=0, est=0, status=Inactive, removal_reason). Gated to superadmin + operator_admin. p_reason min 10 chars; p_edit_id_link optional for audit linkage. Use approve_pod_inventory_edit for any new flow; this is for backfill only.';
