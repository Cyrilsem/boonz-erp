-- PRD-141 item 14 + PRD-138 WS-C.1 rollback.
-- Fast path (no DDL): selling no longer makes a machine eligible.
--   UPDATE public.pick_urgency_params SET live_by_sales_48h_min = 999999;
-- Full path: re-apply supabase/migrations/20261017210334_prd138_wsb_era_aware_eligibility.sql
-- section 2 (v_machine_eligibility without sales_48h cannot drop the appended column, so keep the
-- fast path), and restore the pre-WS-C drift view:
CREATE OR REPLACE VIEW public.v_machine_eligibility_drift AS
 SELECT m.machine_id, m.official_name, m.status, m.adyen_status, m.adyen_inventory_in_store, m.repurposed_at,
    count(s.*) AS sales_7d,
    'selling but invisible to grading'::text AS drift_reason,
    EXTRACT(day FROM now() - m.updated_at)::integer AS age_days
   FROM machines m
     JOIN sales_history s ON s.machine_id = m.machine_id AND s.transaction_date >= (now() - '7 days'::interval) AND (s.delivery_status = ANY (ARRAY['Success'::text, 'Successful'::text]))
  WHERE m.status = 'Active'::text AND NOT (EXISTS ( SELECT 1 FROM v_shelf_sales_identity i WHERE i.machine_id = m.machine_id))
  GROUP BY m.machine_id, m.official_name, m.status, m.adyen_status, m.adyen_inventory_in_store, m.repurposed_at, m.updated_at;
