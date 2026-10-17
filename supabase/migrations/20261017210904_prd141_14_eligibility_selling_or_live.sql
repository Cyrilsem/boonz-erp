-- PRD-141 item 14 + PRD-138 WS-C.1: a selling machine is eligible even when its Adyen labels are
-- stale; v_machine_eligibility_drift names the cause (label_not_live / in_repurpose_grace).
-- Night window only. Fleet diff in a rolled-back txn is in docs/prds/PRD-141-log.md.
-- Rollback: supabase/rollbacks/prd141_14_rollback.sql.

ALTER TABLE public.pick_urgency_params
  ADD COLUMN IF NOT EXISTS live_by_sales_48h_min integer NOT NULL DEFAULT 3;

CREATE OR REPLACE VIEW public.v_machine_eligibility AS
WITH p AS (
  SELECT repurpose_grace_days::integer AS grace_days, repurpose_min_days, repurpose_min_sales, live_by_sales_48h_min
  FROM public.pick_urgency_params
  LIMIT 1
), base AS (
  SELECT m.machine_id, m.adyen_status, m.adyen_inventory_in_store, m.repurposed_at, m.relaunched_at,
    GREATEST(m.repurposed_at, (m.relaunched_at AT TIME ZONE 'Asia/Dubai')::date) AS era_start,
    (m.repurposed_at IS NOT NULL AND m.repurposed_at >= now() - make_interval(days => p.grace_days)) AS in_repurpose_grace_window,
    p.grace_days, p.repurpose_min_days, p.repurpose_min_sales, p.live_by_sales_48h_min
  FROM public.machines m CROSS JOIN p
)
SELECT b.machine_id,
  (b.adyen_status = 'Online today' AND b.adyen_inventory_in_store = 'Live') AS flags_live,
  b.repurposed_at,
  b.era_start,
  b.in_repurpose_grace_window,
  rs.n AS sales_since_repurpose,
  (b.adyen_status = 'Online today' AND b.adyen_inventory_in_store = 'Live' OR s48.n >= b.live_by_sales_48h_min)
    AND (b.repurposed_at IS NULL
         OR b.repurposed_at < now() - make_interval(days => b.grace_days)
         OR (b.repurposed_at <= now() - make_interval(days => b.repurpose_min_days)
             AND rs.n >= b.repurpose_min_sales)) AS is_eligible_machine,
  CASE WHEN b.era_start IS NULL OR b.era_start <= (now() AT TIME ZONE 'Asia/Dubai')::date - 30 THEN 30
       ELSE LEAST(30, GREATEST(1, (now() AT TIME ZONE 'Asia/Dubai')::date - b.era_start)) END AS era_days,
  s48.n AS sales_48h
FROM base b
LEFT JOIN LATERAL (
  SELECT count(*) AS n
  FROM public.sales_history s
  WHERE b.in_repurpose_grace_window
    AND s.machine_id = b.machine_id
    AND s.delivery_status = ANY (ARRAY['Success','Successful'])
    AND s.transaction_date >= (b.repurposed_at::timestamp AT TIME ZONE 'Asia/Dubai')
) rs ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS n
  FROM public.sales_history s
  WHERE s.machine_id = b.machine_id
    AND s.delivery_status = ANY (ARRAY['Success','Successful'])
    AND s.transaction_date >= now() - interval '48 hours'
) s48 ON true;

CREATE OR REPLACE VIEW public.v_machine_eligibility_drift AS
SELECT m.machine_id,
  m.official_name,
  m.status,
  m.adyen_status,
  m.adyen_inventory_in_store,
  m.repurposed_at,
  count(s.*) AS sales_7d,
  CASE
    WHEN NOT COALESCE(e.flags_live, false) THEN 'label_not_live'
    WHEN e.in_repurpose_grace_window AND NOT COALESCE(e.is_eligible_machine, false) THEN 'in_repurpose_grace'
    ELSE 'selling but invisible to grading'
  END AS drift_reason,
  EXTRACT(day FROM now() - m.updated_at)::integer AS age_days
FROM public.machines m
JOIN public.v_machine_eligibility e ON e.machine_id = m.machine_id
JOIN public.sales_history s ON s.machine_id = m.machine_id
  AND s.transaction_date >= (now() - '7 days'::interval)
  AND s.delivery_status = ANY (ARRAY['Success'::text, 'Successful'::text])
WHERE m.status = 'Active'
  AND (NOT COALESCE(e.flags_live, false)
       OR NOT EXISTS (SELECT 1 FROM public.v_shelf_sales_identity i WHERE i.machine_id = m.machine_id))
GROUP BY m.machine_id, m.official_name, m.status, m.adyen_status, m.adyen_inventory_in_store,
  m.repurposed_at, m.updated_at, e.flags_live, e.in_repurpose_grace_window, e.is_eligible_machine;

-- The nightly check carries the reason into the alert payload.
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
           'sales_7d', d.sales_7d, 'age_days', d.age_days,
           'drift_reason', d.drift_reason)), '[]'::jsonb),
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
