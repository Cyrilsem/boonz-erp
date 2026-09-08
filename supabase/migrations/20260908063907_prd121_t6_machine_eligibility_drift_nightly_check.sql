-- PRD-121 T6a: nightly assertion that v_machine_eligibility_drift is empty,
-- same family as check_expiry_unvalidated / assert_sales_names_resolved.
-- age_days is appended (not inserted mid-list) so CREATE OR REPLACE VIEW
-- stays legal -- PRD-022 already hit 42P16 doing this wrong.

CREATE OR REPLACE VIEW public.v_machine_eligibility_drift AS
 SELECT m.machine_id,
    m.official_name,
    m.status,
    m.adyen_status,
    m.adyen_inventory_in_store,
    m.repurposed_at,
    count(s.*) AS sales_7d,
    'selling but invisible to grading'::text AS drift_reason,
    EXTRACT(day FROM now() - m.updated_at)::int AS age_days
   FROM machines m
     JOIN sales_history s ON s.machine_id = m.machine_id AND s.transaction_date >= (now() - '7 days'::interval) AND (s.delivery_status = ANY (ARRAY['Success'::text, 'Successful'::text]))
  WHERE m.status = 'Active'::text AND NOT (EXISTS ( SELECT 1
           FROM v_shelf_sales_identity i
          WHERE i.machine_id = m.machine_id))
  GROUP BY m.machine_id, m.official_name, m.status, m.adyen_status, m.adyen_inventory_in_store, m.repurposed_at, m.updated_at;

COMMENT ON VIEW public.v_machine_eligibility_drift IS
  'PRD-121: machines selling in the last 7 days but invisible to v_shelf_sales_identity grading -- the exact IRIS-1070 symptom class. age_days is an approximation (machines.updated_at, not a dedicated status-change timestamp -- machine_status_events.changed_at is the precise source once a machine has gone through set_machine_status).';

CREATE OR REPLACE FUNCTION public.check_machine_eligibility_drift()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n    int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine_id', d.machine_id, 'machine_name', d.official_name,
           'status', d.status, 'adyen_status', d.adyen_status,
           'adyen_inventory_in_store', d.adyen_inventory_in_store,
           'sales_7d', d.sales_7d, 'age_days', d.age_days)), '[]'::jsonb),
         COUNT(*)
    INTO v_rows, v_n
  FROM public.v_machine_eligibility_drift d;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('machine_eligibility_drift', 'critical',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'rows', v_rows));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'drift_count', v_n, 'rows', v_rows);
END;
$function$;

SELECT cron.schedule(
  'check_machine_eligibility_drift_nightly',
  '5 20 * * *',
  $$ SELECT public.check_machine_eligibility_drift(); $$
);
