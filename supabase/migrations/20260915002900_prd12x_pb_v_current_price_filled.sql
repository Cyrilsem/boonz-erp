-- ONE-LOOP-2 Block B: v_current_price_filled fills the 16.5% price-data gap
-- that blocked PRD-126 A3/A5/A6/A7 last night (19,686 of 119,136
-- v_current_price rows have NULL effective_price_aed, including
-- ACTIVATEMCC-1037's own highest-velocity lane).
--
-- Grain: one row per (machine_id, pod_product_id) currently merchandised
-- (sourced from slot_lifecycle, archived=false, is_current=true -- the same
-- "what is actually planned" scope engine_add_pod uses), resolved to a
-- boonz_product_id via product_mapping (machine-specific first, else
-- global, same resolution pattern used throughout this session).
--
-- price_source ladder, exactly as specified:
--   1. effective_price_aed (v_current_price) when not null.
--   2. realised unit price on THIS machine over the last 30 days --
--      SUM(total_amount)/SUM(qty) from sales_history, scoped to the
--      Successful-delivery, resolved-pod-product rows already computed by
--      v_sales_history_resolved (joined back to sales_history by
--      transaction_id for total_amount, which v_sales_history_resolved
--      itself does not carry) -- when at least 3 units sold.
--   3. fleet median effective_price_aed for that pod product, across every
--      machine's v_current_price row for a boonz_product mapped to it.
--   4. fleet median realised price for that pod product (same 30-day
--      window, fleet-wide).
--   5. 0, price_source = 'unpriced'.
CREATE OR REPLACE VIEW public.v_current_price_filled AS
WITH lanes AS (
  SELECT DISTINCT sl.machine_id, sl.pod_product_id
    FROM public.slot_lifecycle sl
   WHERE sl.archived = false AND sl.is_current = true
),
resolved_mapping AS (
  SELECT l.machine_id, l.pod_product_id,
    (SELECT pm.boonz_product_id FROM public.product_mapping pm
      WHERE pm.pod_product_id = l.pod_product_id AND pm.status = 'Active'
        AND (pm.machine_id IS NULL OR pm.machine_id = l.machine_id)
      ORDER BY (pm.machine_id = l.machine_id) DESC NULLS LAST, pm.is_global_default DESC
      LIMIT 1) AS boonz_product_id
  FROM lanes l
),
tier1 AS (
  SELECT rm.machine_id, rm.pod_product_id, rm.boonz_product_id,
         cp.effective_price_aed
    FROM resolved_mapping rm
    LEFT JOIN public.v_current_price cp
      ON cp.machine_id = rm.machine_id AND cp.boonz_product_id = rm.boonz_product_id
),
realized_machine AS (
  SELECT vsr.machine_id, vsr.pod_product_id,
         SUM(sh.total_amount) / NULLIF(SUM(vsr.qty), 0) AS realized_price,
         SUM(vsr.qty) AS units_sold
    FROM public.v_sales_history_resolved vsr
    JOIN public.sales_history sh ON sh.transaction_id = vsr.transaction_id
   WHERE vsr.transaction_date >= now() - interval '30 days'
   GROUP BY vsr.machine_id, vsr.pod_product_id
),
realized_fleet AS (
  SELECT vsr.pod_product_id,
         SUM(sh.total_amount) / NULLIF(SUM(vsr.qty), 0) AS realized_price
    FROM public.v_sales_history_resolved vsr
    JOIN public.sales_history sh ON sh.transaction_id = vsr.transaction_id
   WHERE vsr.transaction_date >= now() - interval '30 days'
   GROUP BY vsr.pod_product_id
),
fleet_median_effective AS (
  SELECT rm.pod_product_id,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY cp.effective_price_aed) AS median_price
    FROM resolved_mapping rm
    JOIN public.v_current_price cp
      ON cp.boonz_product_id = rm.boonz_product_id
   WHERE cp.effective_price_aed IS NOT NULL
   GROUP BY rm.pod_product_id
)
SELECT
  t1.machine_id,
  t1.pod_product_id,
  t1.boonz_product_id,
  COALESCE(
    t1.effective_price_aed,
    CASE WHEN rmach.units_sold >= 3 THEN rmach.realized_price END,
    fme.median_price,
    rfleet.realized_price,
    0
  )::numeric(10,2) AS effective_price_aed,
  CASE
    WHEN t1.effective_price_aed IS NOT NULL THEN 'effective_price_aed'
    WHEN rmach.units_sold >= 3 THEN 'realized_machine_30d'
    WHEN fme.median_price IS NOT NULL THEN 'fleet_median_effective'
    WHEN rfleet.realized_price IS NOT NULL THEN 'fleet_median_realized'
    ELSE 'unpriced'
  END AS price_source
FROM tier1 t1
LEFT JOIN realized_machine rmach
  ON rmach.machine_id = t1.machine_id AND rmach.pod_product_id = t1.pod_product_id
LEFT JOIN fleet_median_effective fme ON fme.pod_product_id = t1.pod_product_id
LEFT JOIN realized_fleet rfleet ON rfleet.pod_product_id = t1.pod_product_id;
