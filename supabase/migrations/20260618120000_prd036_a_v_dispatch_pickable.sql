-- PRD-036 Phase A: canonical pickable-stock truth for the packing screen.
-- One row per dispatch line. Consumes the existing canonical objects only
-- (Article 16): v_dispatch_availability (serving [primary,secondary] pickable,
-- reservation-aware, the registered "Dispatch committed/available" metric) and
-- v_wh_pickable (registered "WH pickable stock"). Adds a stranded-stock signal so
-- a serving-WH 0 is explained (stock exists in a NON-serving warehouse -> transfer),
-- instead of the picker distrusting the 0 and packing manually.
--
-- Read-only VIEW, security_invoker=true (underlying RLS applies; no DEFINER).
-- No writes. Replaces the packing FE's client-side re-derivation from v_wh_pickable
-- (kills the Article 16 client re-derivation while keeping the MM/MCC commingling
-- guard: stranded units are reported separately, never folded into pickable).
--
-- NOTE (cold routing): serving set mirrors v_dispatch_availability = [primary,
-- secondary]. Cold products that route from WH_CENTRAL while WH_CENTRAL is not in
-- that set would surface as "stranded at WH_CENTRAL"; all PRD-036 cases have
-- primary=WH_CENTRAL so this is moot here. Flagged as a follow-up, not fixed here.

CREATE OR REPLACE VIEW public.v_dispatch_pickable
WITH (security_invoker = true) AS
SELECT
  da.dispatch_id,
  da.machine_id,
  da.boonz_product_id,
  da.pod_product_id,
  da.shelf_id,
  da.dispatch_date,
  da.action,
  da.target_qty,
  da.packed,
  da.picked_up,
  da.wh_stock_now            AS serving_pickable_units,  -- canonical serving-WH pickable
  da.reserved_by_earlier,
  da.available_qty,                                       -- LEAST(target, serving - reserved_by_earlier)
  da.pack_status,                                         -- ready | partial | blocked_no_wh | packed
  COALESCE(s.stranded_units, 0)::integer AS stranded_units,
  s.stranded_warehouses
FROM public.v_dispatch_availability da
LEFT JOIN LATERAL (
  SELECT
    SUM(p.warehouse_stock)::integer        AS stranded_units,
    array_agg(DISTINCT p.warehouse_id)     AS stranded_warehouses
  FROM public.v_wh_pickable p
  JOIN public.machines m ON m.machine_id = da.machine_id
  WHERE p.boonz_product_id = da.boonz_product_id
    AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = da.machine_id)
    -- NON-serving warehouses only (NULL-safe; secondary may be NULL)
    AND p.warehouse_id NOT IN (
      SELECT w FROM unnest(ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id]) w
      WHERE w IS NOT NULL
    )
) s ON true;

COMMENT ON VIEW public.v_dispatch_pickable IS
  'PRD-036 Phase A. Per dispatch line: canonical serving-WH pickable units (from v_dispatch_availability) + stranded_units/stranded_warehouses (same product pickable in non-serving WHs). Packing FE reads this instead of re-deriving from v_wh_pickable. security_invoker.';

GRANT SELECT ON public.v_dispatch_pickable TO authenticated;
