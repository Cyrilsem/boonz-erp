-- PRD-CLEAN-05 M2 (data): backfill the four ID columns for rows with
-- plan_date >= CURRENT_DATE - 60 (older rows stay NULL; push v9 falls back to names).
-- Sets ONLY the new nullable ID columns; operator_status/dispatched untouched, and the
-- approve->dispatch trigger is AFTER UPDATE OF operator_status so it cannot fire.
UPDATE refill_plan_output rpo
SET machine_id = (SELECT m.machine_id FROM machines m WHERE m.official_name = rpo.machine_name LIMIT 1),
    shelf_id = (SELECT sc.shelf_id FROM shelf_configurations sc
                 JOIN machines m2 ON m2.machine_id = sc.machine_id AND m2.official_name = rpo.machine_name
                 WHERE sc.shelf_code = regexp_replace(rpo.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2')
                 LIMIT 1),
    pod_product_id = (SELECT pp.pod_product_id FROM pod_products pp
                       WHERE lower(trim(pp.pod_product_name)) = lower(trim(rpo.pod_product_name)) LIMIT 1),
    boonz_product_id = (SELECT bp.product_id FROM boonz_products bp
                         WHERE lower(trim(bp.boonz_product_name)) = lower(trim(rpo.boonz_product_name)) LIMIT 1)
WHERE rpo.plan_date >= CURRENT_DATE - 60
  AND rpo.machine_id IS NULL;
