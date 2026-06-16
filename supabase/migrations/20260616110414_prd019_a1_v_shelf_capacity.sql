-- PRD-019 A1 (AC-A2): canonical per-shelf capacity view.
-- NOT APPLIED. Author-only; apply after CS sign-off.
-- One row per real (non-phantom) shelf_id with the physical capacity the
-- conductor MUST read before setting any manual fill / ADD_NEW qty.
--   max_stock     = live weimi max (v_live_shelf_stock) -> planogram max_capacity -> 10
--                   (same COALESCE precedence the engine uses)
--   current_stock = live shelf stock for the mapped slot
--   headroom      = GREATEST(max_stock - current_stock, 0)
--   size_class    = shelf_configurations.shelf_size (small / big / large)
--   current_product = product currently shown on the shelf (highest-stock slot)
-- Consumed by add_pod_refill_row / edit_pod_refill_row (capacity clamp) and by
-- the compact planning view (Phase C).
CREATE OR REPLACE VIEW public.v_shelf_capacity AS
WITH live AS (
  SELECT
    sc.shelf_id,
    sc.machine_id,
    sc.shelf_code,
    sc.shelf_size,
    sc.max_capacity,
    GREATEST(COALESCE(MAX(vls.current_stock), 0), 0)::int AS current_stock,
    MAX(vls.max_stock)::int                               AS live_max_stock,
    (array_agg(NULLIF(btrim(vls.goods_name_raw), '') ORDER BY vls.current_stock DESC NULLS LAST)
       FILTER (WHERE NULLIF(btrim(vls.goods_name_raw), '') IS NOT NULL))[1] AS current_product
  FROM public.shelf_configurations sc
  LEFT JOIN public.v_live_shelf_stock vls
    ON vls.machine_id = sc.machine_id
   AND vls.slot_name = LEFT(sc.shelf_code, 1) || (SUBSTR(sc.shelf_code, 2)::int)::text
  WHERE sc.is_phantom = false
  GROUP BY sc.shelf_id, sc.machine_id, sc.shelf_code, sc.shelf_size, sc.max_capacity
)
SELECT
  l.shelf_id,
  l.machine_id,
  l.shelf_code,
  l.shelf_size AS size_class,
  COALESCE(NULLIF(l.live_max_stock, 0), NULLIF(l.max_capacity, 0), 10)::int AS max_stock,
  l.current_stock,
  GREATEST(COALESCE(NULLIF(l.live_max_stock, 0), NULLIF(l.max_capacity, 0), 10) - l.current_stock, 0)::int AS headroom,
  l.current_product
FROM live l;

COMMENT ON VIEW public.v_shelf_capacity IS
'PRD-019 A1 (AC-A2). Per shelf_id: max_stock (live weimi -> planogram max_capacity -> 10), current_stock, headroom, size_class, current_product. The conductor and the manual ADD/fill RPCs MUST read this before setting a fill qty so no manual fill exceeds physical capacity (R-A1/R-A2).';

GRANT SELECT ON public.v_shelf_capacity TO anon, authenticated, service_role;
