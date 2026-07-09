-- PRD-091 (Option 3, signal-only, Cody PASS): additive expiry-risk SIGNAL. NO engine edit.
-- Consumed later by PRD-095 (freeze-held). Inert until then. Reads canonical v_pod_inventory_latest.
ALTER TABLE public.refill_policy_params ADD COLUMN IF NOT EXISTS expiry_risk_days integer NOT NULL DEFAULT 7;
CREATE OR REPLACE VIEW public.v_shelf_expiry_risk AS
WITH t AS (SELECT COALESCE((SELECT expiry_risk_days FROM public.refill_policy_params LIMIT 1), 7) AS risk_days, (now() AT TIME ZONE 'Asia/Dubai')::date AS today)
SELECT pil.machine_id, pil.shelf_id, sl.pod_product_id,
       (MIN(pil.expiration_date) - t.today) AS days_to_expiry_min,
       ((MIN(pil.expiration_date) - t.today) < t.risk_days) AS expiry_risk
FROM public.v_pod_inventory_latest pil CROSS JOIN t
LEFT JOIN public.slot_lifecycle sl ON sl.machine_id = pil.machine_id AND sl.shelf_id = pil.shelf_id AND sl.is_current AND NOT sl.archived
WHERE pil.expiration_date IS NOT NULL AND pil.current_stock > 0
GROUP BY pil.machine_id, pil.shelf_id, sl.pod_product_id, t.today, t.risk_days;
GRANT SELECT ON public.v_shelf_expiry_risk TO authenticated, service_role;
COMMENT ON VIEW public.v_shelf_expiry_risk IS 'PRD-091 (signal-only): per-shelf on-machine expiry risk. Consumed by PRD-095 swap trigger. Additive/inert.';
