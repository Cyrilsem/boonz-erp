-- Phase B.1.2: dedicated all-time first-sale-per-machine view.
-- The B.1.1 ramping check used MIN(transaction_date) over the loaded
-- 62-day sales window, which incorrectly flagged mature machines as
-- ramping if they had a quiet patch within the window. This view gives
-- the ALL-TIME first sale per machine, used by evaluate-lifecycle to
-- correctly distinguish "newly deployed" from "mature with quiet patch".

CREATE OR REPLACE VIEW public.v_machine_first_sale AS
SELECT
  machine_id,
  MIN(transaction_date) AS first_sale_at,
  MAX(transaction_date) AS last_sale_at,
  COUNT(*) AS total_sales
FROM public.sales_history
WHERE delivery_status = 'Successful'
GROUP BY machine_id;

ALTER VIEW public.v_machine_first_sale SET (security_invoker = true);

COMMENT ON VIEW public.v_machine_first_sale IS
  'All-time first-sale and last-sale timestamps per machine, derived from sales_history. Used by evaluate-lifecycle to compute MACHINE_RAMPING flag based on actual deployment age, not 62-day-window-min. SECURITY INVOKER — honors caller RLS.';
