-- PRD-075 follow-up 3 (2026-07-05): the drift monitor trusted labels ('Pending Setup' treated as
-- legitimately excluded), which hid MPMCC-1058 (4 empty shelves, real P1 urg 68) and NISSAN-0804
-- ('Switched off' while selling 44/wk). New truth test: a machine with recent sales that produces
-- zero grading rows is DRIFT, no matter what any label says.
CREATE OR REPLACE VIEW v_machine_eligibility_drift AS
SELECT m.machine_id,
       m.official_name,
       m.status,
       m.adyen_status,
       m.adyen_inventory_in_store,
       m.repurposed_at,
       count(s.*) AS sales_7d,
       'selling but invisible to grading' AS drift_reason
FROM machines m
JOIN sales_history s
  ON s.machine_id = m.machine_id
 AND s.transaction_date >= now() - interval '7 days'
 AND s.delivery_status = ANY (ARRAY['Success'::text,'Successful'::text])
WHERE m.status = 'Active'
  AND NOT EXISTS (SELECT 1 FROM v_shelf_sales_identity i WHERE i.machine_id = m.machine_id)
GROUP BY m.machine_id, m.official_name, m.status, m.adyen_status, m.adyen_inventory_in_store, m.repurposed_at;
