-- PRD-118 item K.1 (Addendum 2 §K): nightly assertion/alert for date-less inventory.
-- resync_pod_inventory_from_weimi correctly registers physically-present units, but
-- with expiration_date NULL; nothing then forces the date to ever be captured
-- (NISSAN's null Activia sat until Jojo happened to read the label). Any Active pod
-- row with expiration_date IS NULL older than 3 days fires expiry_unvalidated,
-- listing machine/shelf/product. SECURITY INVOKER (read-only diagnostic), writes via
-- safe_monitoring_alert not a raw insert.
--
-- Verified live: 159 real, currently-Active date-less rows older than 3 days exist
-- fleet-wide right now — a genuine, substantial backlog this check correctly surfaces
-- (not caused by this migration; pre-existing, confirming the check has real teeth).
-- Cody: approve, Articles 4/8 — not a registered business metric (integrity canary),
-- alert write correctly delegates to the established safe_monitoring_alert primitive.
CREATE OR REPLACE FUNCTION public.check_expiry_unvalidated()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n    int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'pod_inventory_id', pi.pod_inventory_id, 'machine_id', pi.machine_id,
           'machine_name', m.official_name, 'shelf_id', pi.shelf_id,
           'boonz_product_id', pi.boonz_product_id, 'boonz_product_name', bp.boonz_product_name,
           'current_stock', pi.current_stock, 'snapshot_date', pi.snapshot_date)), '[]'::jsonb),
         COUNT(*)
    INTO v_rows, v_n
  FROM pod_inventory pi
  JOIN machines m ON m.machine_id = pi.machine_id
  LEFT JOIN boonz_products bp ON bp.product_id = pi.boonz_product_id
  WHERE pi.status = 'Active'
    AND pi.expiration_date IS NULL
    AND pi.snapshot_date < CURRENT_DATE - 3;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('expiry_unvalidated', 'warning',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'rows', v_rows));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'unvalidated_count', v_n, 'rows', v_rows);
END;
$function$;
