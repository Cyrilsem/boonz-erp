-- Close-out follow-up 1c: check_expiry_unvalidated's 175/164 date-less pod
-- rows are a PRD-119 ASK-flow condition, not a code defect -- fixed at the
-- point of ORIGIN by whoever visits/checks the shelf via the existing P3
-- expiry-check flow (apply_expiry_check), never by inventing a date here.
--
-- Per-item ask-list produced: docs/ops/expiry-ask-list-2026-09-07.md --
-- machine, shelf, product, qty for all 164 current rows, ordered by
-- trailing-30d machine sales velocity (highest-traffic machines first, so
-- the highest-value lanes get checked before low-traffic ones).
--
-- This migration makes the assertion itself report a per-machine
-- breakdown (`by_machine`: [{machine_name, count}], sorted descending) in
-- both its return value and the alert payload it raises, so a single scary
-- "164" number becomes a scannable per-machine list matching the ask-list
-- doc's own grouping. Row-level detail (`rows`) is unchanged and still
-- returned in full.
--
-- No remediation performed -- 0 dates invented, 0 rows touched.
--
-- Cody: approve, Article 16 (still the one canonical detector; this is an
-- additive reporting shape change, not a new object), read-only.
CREATE OR REPLACE FUNCTION public.check_expiry_unvalidated()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows        jsonb;
  v_by_machine  jsonb;
  v_n           int;
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

  SELECT COALESCE(jsonb_agg(jsonb_build_object('machine_name', x.machine_name, 'count', x.n) ORDER BY x.n DESC), '[]'::jsonb)
    INTO v_by_machine
  FROM (
    SELECT m.official_name AS machine_name, COUNT(*) AS n
    FROM pod_inventory pi
    JOIN machines m ON m.machine_id = pi.machine_id
    WHERE pi.status = 'Active'
      AND pi.expiration_date IS NULL
      AND pi.snapshot_date < CURRENT_DATE - 3
    GROUP BY m.official_name
  ) x;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('expiry_unvalidated', 'warning',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'by_machine', v_by_machine, 'rows', v_rows));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'unvalidated_count', v_n, 'by_machine', v_by_machine, 'rows', v_rows);
END;
$function$;
