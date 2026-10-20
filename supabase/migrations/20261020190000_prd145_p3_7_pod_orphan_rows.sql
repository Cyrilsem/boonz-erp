-- PRD-145 P3-7: pod_inventory rows of products that are not what WEIMI says is on the lane.
-- On 20 Oct pod_inventory carried 423 such rows on 36 machines (cleared by hand). They inflate shelf stock, hide empty
-- lanes from the engine and put the wrong product on the driver's shelf picture.
--   get_pod_orphan_rows(p_machine_id)      Active rows with stock whose product has no product_mapping row (any status,
--                                          any scope) to the pod product on that lane in the machine's latest WEIMI
--                                          snapshot, plus rows on shelves absent from that snapshot. The WEIMI name is
--                                          resolved the way weimi_lane_now resolves it (pod name, case-insensitive pod
--                                          name, product_name_conventions original -> official, weimi_product_alias);
--                                          slot codes are zero-padded (A1 -> A01). A lane whose WEIMI name does not
--                                          resolve is left alone (nothing is cleared that cannot be checked).
--   pod_orphan_clear_gate(p_machine_id)    the snapshot must be newer than the machine's last refill: the latest packed
--                                          dispatch_date up to today has no line still in the van, and the snapshot was
--                                          taken after the last delivery / driver confirmation / pack confirmation.
--   clear_pod_orphan_rows(p_machine_id, p_reason)   operator_admin; adjust_pod_inventory to 0 for each orphan row.
--   get_pod_orphan_summary()               per machine counts + gate + the last nightly count, for the Pending tab.
--   record_pod_orphan_counts()             nightly (04:00 Dubai, after the 23:59 WEIMI snapshot); writes the counts to
--                                          monitoring_alerts (pod_orphan_rows_nightly). Never clears.
CREATE FUNCTION public.get_pod_orphan_rows(p_machine_id uuid DEFAULT NULL)
 RETURNS TABLE(machine_id uuid, machine_name text, shelf_id uuid, shelf_code text, pod_inventory_id uuid,
               boonz_product_id uuid, boonz_product_name text, current_stock numeric, expiration_date date,
               weimi_product_name text, weimi_pod_product_id uuid, reason text, snapshot_at timestamptz)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH snap AS (
    SELECT w.machine_id, max(w.snapshot_at) AS snapshot_at
      FROM public.weimi_aisle_snapshots w
     WHERE p_machine_id IS NULL OR w.machine_id = p_machine_id
     GROUP BY w.machine_id
  ), lanes AS (
    SELECT w.machine_id, s.snapshot_at,
           upper(substring(w.slot_code FROM '^[A-Za-z]+')) || lpad(substring(w.slot_code FROM '\d+$'), 2, '0') AS code,
           w.product_name,
           COALESCE(
             (SELECT pp.pod_product_id FROM public.pod_products pp WHERE pp.pod_product_name = w.product_name LIMIT 1),
             (SELECT pp.pod_product_id FROM public.pod_products pp
               WHERE lower(trim(pp.pod_product_name)) = lower(trim(w.product_name)) LIMIT 1),
             (SELECT pp.pod_product_id FROM public.product_name_conventions pnc
                JOIN public.pod_products pp ON pp.pod_product_name = pnc.official_name
               WHERE pnc.original_name = w.product_name LIMIT 1),
             (SELECT a.pod_product_id FROM public.weimi_product_alias a WHERE a.weimi_name = w.product_name
               ORDER BY (EXISTS (SELECT 1 FROM public.product_mapping pm
                                  WHERE pm.pod_product_id = a.pod_product_id AND pm.status = 'Active')) DESC
               LIMIT 1)) AS pod_product_id
      FROM public.weimi_aisle_snapshots w
      JOIN snap s ON s.machine_id = w.machine_id AND s.snapshot_at = w.snapshot_at
  )
  SELECT pi.machine_id, m.official_name, pi.shelf_id, sc.shelf_code, pi.pod_inventory_id,
         pi.boonz_product_id, bp.boonz_product_name, pi.current_stock, pi.expiration_date,
         l.product_name, l.pod_product_id,
         CASE WHEN l.code IS NULL THEN 'shelf_not_in_snapshot' ELSE 'not_mapped_to_weimi_pod' END,
         s.snapshot_at
    FROM public.pod_inventory pi
    JOIN snap s ON s.machine_id = pi.machine_id
    JOIN public.machines m ON m.machine_id = pi.machine_id
    JOIN public.shelf_configurations sc ON sc.shelf_id = pi.shelf_id
    LEFT JOIN public.boonz_products bp ON bp.product_id = pi.boonz_product_id
    LEFT JOIN lanes l ON l.machine_id = pi.machine_id AND l.code = sc.shelf_code
   WHERE pi.status = 'Active' AND COALESCE(pi.current_stock, 0) > 0
     AND (p_machine_id IS NULL OR pi.machine_id = p_machine_id)
     AND (
           l.code IS NULL
        OR (l.pod_product_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM public.product_mapping pm
                             WHERE pm.boonz_product_id = pi.boonz_product_id AND pm.pod_product_id = l.pod_product_id))
     )
   ORDER BY m.official_name, sc.shelf_code, bp.boonz_product_name;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_pod_orphan_rows(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_pod_orphan_rows(uuid) TO authenticated, service_role;

CREATE FUNCTION public.pod_orphan_clear_gate(p_machine_id uuid)
 RETURNS TABLE(ok boolean, reason text, snapshot_at timestamptz, last_refill_date date, last_refill_at timestamptz)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_snap timestamptz; v_date date; v_at timestamptz; v_open int;
BEGIN
  SELECT max(w.snapshot_at) INTO v_snap FROM public.weimi_aisle_snapshots w WHERE w.machine_id = p_machine_id;
  SELECT max(d.dispatch_date) INTO v_date FROM public.refill_dispatching d
   WHERE d.machine_id = p_machine_id AND d.dispatch_date <= v_today AND COALESCE(d.packed, false)
     AND COALESCE(d.include, true) AND NOT COALESCE(d.cancelled, false);
  IF v_snap IS NULL THEN
    RETURN QUERY SELECT false, 'no WEIMI snapshot for this machine', v_snap, v_date, NULL::timestamptz; RETURN;
  END IF;
  IF v_date IS NULL THEN
    RETURN QUERY SELECT true, 'no packed refill on record', v_snap, v_date, NULL::timestamptz; RETURN;
  END IF;
  SELECT count(*) INTO v_open FROM public.refill_dispatching d
   WHERE d.machine_id = p_machine_id AND d.dispatch_date = v_date AND COALESCE(d.packed, false)
     AND COALESCE(d.include, true) AND NOT COALESCE(d.cancelled, false) AND NOT COALESCE(d.skipped, false)
     AND d.action IN ('Refill', 'Add New', 'Add') AND NOT COALESCE(d.item_added, false) AND NOT COALESCE(d.returned, false)
     AND d.pack_outcome IS DISTINCT FROM 'not_filled' AND COALESCE(d.filled_quantity, 0) > 0;
  SELECT GREATEST(
           (SELECT max(GREATEST(d.delivered_at, d.driver_confirmed_at, d.driver_outcome_at)) FROM public.refill_dispatching d
             WHERE d.machine_id = p_machine_id AND d.dispatch_date = v_date),
           (SELECT max(c.confirmed_at) FROM public.dispatch_pack_confirmation c
             WHERE c.machine_id = p_machine_id AND c.dispatch_date = v_date))
    INTO v_at;
  IF v_open > 0 THEN
    RETURN QUERY SELECT false, format('%s line(s) of the %s refill are still in the van', v_open, v_date), v_snap, v_date, v_at; RETURN;
  END IF;
  IF v_at IS NULL THEN
    v_at := ((v_date + 1)::timestamp AT TIME ZONE 'Asia/Dubai');
  END IF;
  IF v_snap <= v_at THEN
    RETURN QUERY SELECT false, format('the latest WEIMI snapshot (%s) is not newer than the %s refill (%s)',
                                      v_snap AT TIME ZONE 'Asia/Dubai', v_date, v_at AT TIME ZONE 'Asia/Dubai'),
                        v_snap, v_date, v_at;
    RETURN;
  END IF;
  RETURN QUERY SELECT true, 'snapshot is newer than the last refill', v_snap, v_date, v_at;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.pod_orphan_clear_gate(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.pod_orphan_clear_gate(uuid) TO authenticated, service_role;

CREATE FUNCTION public.clear_pod_orphan_rows(p_machine_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text; v_reason text := NULLIF(trim(COALESCE(p_reason, '')), '');
  v_gate record; v_name text; v_lines jsonb; v_n int; v_res jsonb;
BEGIN
  SELECT role INTO v_role FROM public.user_profiles WHERE id = auth.uid();
  IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('operator_admin', 'superadmin') THEN
    RAISE EXCEPTION 'clear_pod_orphan_rows: operator_admin only (role %)', COALESCE(v_role, 'none');
  END IF;
  IF v_reason IS NULL OR length(v_reason) < 5 THEN
    RAISE EXCEPTION 'clear_pod_orphan_rows: a reason (5+ characters) is required';
  END IF;
  SELECT official_name INTO v_name FROM public.machines WHERE machine_id = p_machine_id;
  IF v_name IS NULL THEN RAISE EXCEPTION 'clear_pod_orphan_rows: machine % not found', p_machine_id; END IF;
  SELECT * INTO v_gate FROM public.pod_orphan_clear_gate(p_machine_id);
  IF NOT v_gate.ok THEN
    RAISE EXCEPTION 'clear_pod_orphan_rows: % refused, %', v_name, v_gate.reason;
  END IF;

  SELECT count(*), jsonb_agg(jsonb_build_object('boonz_product_id', o.boonz_product_id, 'new_qty', 0,
                                               'expiration_date', o.expiration_date, 'shelf_code', o.shelf_code))
    INTO v_n, v_lines
    FROM public.get_pod_orphan_rows(p_machine_id) o;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('status', 'nothing_to_clear', 'machine', v_name, 'rows', 0);
  END IF;
  v_res := public.adjust_pod_inventory(v_name, (now() AT TIME ZONE 'Asia/Dubai')::date, v_lines,
                                       format('PRD-145 P3-7 pod rows off WEIMI: %s', v_reason));
  RETURN jsonb_build_object('status', 'ok', 'machine', v_name, 'rows', v_n, 'snapshot_at', v_gate.snapshot_at,
                            'lines_zeroed', v_res->'lines_zeroed', 'details', v_res->'details');
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.clear_pod_orphan_rows(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.clear_pod_orphan_rows(uuid, text) TO authenticated, service_role;

CREATE FUNCTION public.get_pod_orphan_summary()
 RETURNS TABLE(machine_id uuid, machine_name text, orphan_rows int, orphan_units numeric, snapshot_at timestamptz,
               clear_ok boolean, clear_reason text, nightly_rows int, nightly_at timestamptz)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH o AS (
    SELECT o.machine_id, o.machine_name, count(*)::int AS n, sum(o.current_stock) AS u, max(o.snapshot_at) AS s
      FROM public.get_pod_orphan_rows(NULL) o GROUP BY o.machine_id, o.machine_name
  ), nightly AS (
    SELECT a.created_at, a.payload FROM public.monitoring_alerts a
     WHERE a.source = 'pod_orphan_rows_nightly' ORDER BY a.created_at DESC LIMIT 1
  )
  SELECT o.machine_id, o.machine_name, o.n, o.u, o.s, g.ok, g.reason,
         (SELECT (e->>'rows')::int FROM nightly, jsonb_array_elements(nightly.payload->'machines') e
           WHERE e->>'machine_id' = o.machine_id::text),
         (SELECT created_at FROM nightly)
    FROM o CROSS JOIN LATERAL public.pod_orphan_clear_gate(o.machine_id) g
   ORDER BY o.n DESC, o.machine_name;
$function$;
REVOKE EXECUTE ON FUNCTION public.get_pod_orphan_summary() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_pod_orphan_summary() TO authenticated, service_role;

CREATE FUNCTION public.record_pod_orphan_counts()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb; v_total int; v_machines int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object('machine_id', machine_id, 'machine', machine_name, 'rows', n, 'units', u)
                            ORDER BY n DESC), '[]'::jsonb),
         COALESCE(sum(n), 0), count(*)
    INTO v_rows, v_total, v_machines
    FROM (SELECT o.machine_id, o.machine_name, count(*)::int AS n, sum(o.current_stock) AS u
            FROM public.get_pod_orphan_rows(NULL) o GROUP BY o.machine_id, o.machine_name) x;
  INSERT INTO public.monitoring_alerts (source, severity, payload)
  VALUES ('pod_orphan_rows_nightly', CASE WHEN v_total > 0 THEN 'warning' ELSE 'info' END,
          jsonb_build_object('checked_at', now(), 'rows', v_total, 'machine_count', v_machines, 'machines', v_rows,
            'title', format('%s pod_inventory rows on %s machines are not the product WEIMI shows on the lane', v_total, v_machines)));
  RETURN jsonb_build_object('rows', v_total, 'machines', v_machines);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.record_pod_orphan_counts() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_pod_orphan_counts() TO service_role;

SELECT cron.schedule('prd145_pod_orphan_rows_0400_dubai', '0 0 * * *', 'SELECT public.record_pod_orphan_counts();');
