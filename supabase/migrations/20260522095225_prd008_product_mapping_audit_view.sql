-- ============================================================================
-- PRD-008 — product_mapping audit view
--
-- Source PRD: docs/prds/refill-pipeline/PRD-008-refill-plan-shows-phantom-skus.md
--
-- AC#1: "Audit shows every boonz_product has a product_mapping entry"
--
-- Live audit (2026-05-22 via read MCP):
--   total_boonz_products = 300
--   with_active_mapping  = 222
--   without_mapping      = 78
--     of which 19 have active pod_inventory > 0
--     of which 7 have active warehouse_inventory > 0
--
-- These 19 (pod-active) and 7 (wh-active) unmapped products are the real gaps
-- that contribute to PRD-008 symptoms — Stitch cannot route a refill for a
-- product it can't map. The other ~52 are likely retired SKUs with no live
-- presence — safe to ignore for engine purposes but flagged for CS hygiene.
--
-- This migration creates `v_product_mapping_audit` exposing the gap by
-- category, plus a thin admin page would read it in a follow-up.
--
-- Cody Article 7: read-only view, security_invoker=true so underlying RLS
-- applies.
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_product_mapping_audit
WITH (security_invoker = true) AS
WITH mapped AS (
  SELECT DISTINCT boonz_product_id FROM public.product_mapping WHERE status = 'Active'
),
active_pod AS (
  SELECT boonz_product_id, SUM(current_stock)::numeric AS pod_units
  FROM public.pod_inventory
  WHERE status = 'Active' AND COALESCE(current_stock, 0) > 0
  GROUP BY boonz_product_id
),
active_wh AS (
  SELECT boonz_product_id, SUM(warehouse_stock)::numeric AS wh_units
  FROM public.warehouse_inventory
  WHERE status = 'Active' AND COALESCE(warehouse_stock, 0) > 0
  GROUP BY boonz_product_id
)
SELECT
  bp.product_id,
  bp.boonz_product_name,
  CASE WHEN m.boonz_product_id IS NOT NULL THEN 'mapped' ELSE 'unmapped' END AS mapping_state,
  COALESCE(ap.pod_units, 0) AS active_pod_units,
  COALESCE(aw.wh_units, 0)  AS active_wh_units,
  CASE
    WHEN m.boonz_product_id IS NOT NULL THEN 'ok'
    WHEN COALESCE(ap.pod_units, 0) > 0 OR COALESCE(aw.wh_units, 0) > 0 THEN 'gap_live_stock'
    ELSE 'gap_retired'
  END AS gap_severity
FROM public.boonz_products bp
LEFT JOIN mapped m     ON m.boonz_product_id  = bp.product_id
LEFT JOIN active_pod ap ON ap.boonz_product_id = bp.product_id
LEFT JOIN active_wh aw  ON aw.boonz_product_id = bp.product_id;

COMMENT ON VIEW public.v_product_mapping_audit IS
  'PRD-008 AC#1: surfaces boonz_products without an Active product_mapping. '
  '`gap_severity` separates products with live pod/WH stock (gap_live_stock — '
  'must fix; brain cannot route refills) from retired SKUs (gap_retired — '
  'hygiene only). CS reads this to drive the mapping-curation backlog.';

COMMIT;

-- ============================================================================
-- POST-APPLY USAGE
--
--   -- count gaps by severity
--   SELECT gap_severity, count(*)
--   FROM v_product_mapping_audit
--   WHERE mapping_state = 'unmapped'
--   GROUP BY gap_severity;
--
--   -- list the live-stock gaps (priority backlog)
--   SELECT * FROM v_product_mapping_audit
--   WHERE gap_severity = 'gap_live_stock'
--   ORDER BY active_pod_units DESC, active_wh_units DESC;
--
-- DEFERRED:
--   - Admin /admin/product-mapping page reading this view — Stax follow-up.
--   - Backfilling the missing mappings — CS curation, not in scope here.
-- ============================================================================
