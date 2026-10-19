-- PRD-144 P1-7: "Close transfer" on the Pending tab.
-- 1. get_open_m2m_transfers(p_days): every M2M transfer whose destination leg is received (item_added) while its
--    source Remove leg is still open. One row per transfer, with both machines, the product, what the source says
--    (driver confirmation, else planned) and what the destination received. SECURITY INVOKER, so RLS decides.
-- 2. close_m2m_transfer(p_transfer_id, p_reason), operator_admin/superadmin only: checks the transfer still
--    qualifies, calls approve_m2m_transfer (which receives the source leg with no warehouse credit and raises if
--    warehouse stock moves), and appends the reason to the source leg's comment.
CREATE OR REPLACE FUNCTION public.get_open_m2m_transfers(p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS d)
  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'dispatch_date' DESC, x->>'source_machine'), '[]'::jsonb)
    FROM (
      SELECT jsonb_build_object(
               'transfer_id', s.m2m_transfer_id, 'dispatch_date', s.dispatch_date,
               'source_dispatch_id', s.dispatch_id, 'dest_dispatch_id', d.dispatch_id,
               'source_machine', ms.official_name, 'source_shelf', ss.shelf_code,
               'dest_machine', md.official_name, 'dest_shelf', ds.shelf_code,
               'product', COALESCE(bp.boonz_product_name, pp.pod_product_name),
               'source_qty', COALESCE(s.driver_confirmed_qty, s.quantity),
               'dest_received', d.filled_quantity) AS x
        FROM public.refill_dispatching s
        CROSS JOIN today
        JOIN public.refill_dispatching d
          ON d.m2m_transfer_id = s.m2m_transfer_id AND d.dispatch_id <> s.dispatch_id
         AND d.action IN ('Refill', 'Add New', 'Add') AND COALESCE(d.is_m2m, false) AND COALESCE(d.item_added, false)
        JOIN public.machines ms ON ms.machine_id = s.machine_id
        JOIN public.machines md ON md.machine_id = d.machine_id
        LEFT JOIN public.shelf_configurations ss ON ss.shelf_id = s.shelf_id
        LEFT JOIN public.shelf_configurations ds ON ds.shelf_id = d.shelf_id
        LEFT JOIN public.boonz_products bp ON bp.product_id = s.boonz_product_id
        LEFT JOIN public.pod_products pp ON pp.pod_product_id = s.pod_product_id
       WHERE s.action = 'Remove' AND COALESCE(s.is_m2m, false) AND s.m2m_transfer_id IS NOT NULL
         AND s.include AND NOT COALESCE(s.item_added, false) AND NOT COALESCE(s.cancelled, false)
         AND s.dispatch_date >= today.d - LEAST(GREATEST(COALESCE(p_days, 30), 1), 90)
    ) t;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_open_m2m_transfers(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_open_m2m_transfers(integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.close_m2m_transfer(p_transfer_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role   text;
  v_reason text := NULLIF(trim(COALESCE(p_reason, '')), '');
  v_res    jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin') THEN
    RAISE EXCEPTION 'close_m2m_transfer: operator_admin only (role %)', COALESCE(v_role, 'none');
  END IF;
  IF v_reason IS NULL OR length(v_reason) < 5 THEN
    RAISE EXCEPTION 'close_m2m_transfer: a reason (5+ characters) is required';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.refill_dispatching s
     WHERE s.m2m_transfer_id = p_transfer_id AND s.action = 'Remove' AND COALESCE(s.is_m2m, false)
       AND s.include AND NOT COALESCE(s.item_added, false) AND NOT COALESCE(s.cancelled, false)
  ) THEN
    RAISE EXCEPTION 'close_m2m_transfer: transfer % has no open source Remove leg', p_transfer_id;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.refill_dispatching d
     WHERE d.m2m_transfer_id = p_transfer_id AND d.action IN ('Refill', 'Add New', 'Add')
       AND COALESCE(d.is_m2m, false) AND COALESCE(d.item_added, false)
  ) THEN
    RAISE EXCEPTION 'close_m2m_transfer: transfer % is not delivered at the destination yet', p_transfer_id;
  END IF;

  v_res := public.approve_m2m_transfer(p_transfer_id, auth.uid());

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'close_m2m_transfer', true);
  PERFORM set_config('app.mutation_reason', format('close_m2m_transfer %s by %s: %s', p_transfer_id, auth.uid(), v_reason), true);
  UPDATE public.refill_dispatching
     SET comment = concat_ws(' ', NULLIF(comment, ''), format('[Transfer closed from Pending: %s]', v_reason))
   WHERE m2m_transfer_id = p_transfer_id AND action = 'Remove' AND COALESCE(is_m2m, false);

  RETURN v_res || jsonb_build_object('reason', v_reason);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.close_m2m_transfer(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.close_m2m_transfer(uuid, text) TO authenticated, service_role;
