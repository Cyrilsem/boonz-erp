-- PRD-100 WS2: v_shelf_holes — per-SLOT present-tense emptiness (the hole signal).
-- Grain = physical slot row. is_hole = empty OR fill ratio <= hole_frac (fraction of
-- capacity, never a flat count). Velocity/grade come from v_shelf_sales_identity
-- (pooled product grain) — its alias fold is replicated in the join key.
CREATE OR REPLACE VIEW public.v_shelf_holes AS
WITH alias(pod_product_id, canonical_pod) AS (
  VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,
          '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
)
SELECT
  vls.machine_id, vls.slot_name, vls.goods_name_raw, vls.current_stock, vls.max_stock,
  ROUND(vls.current_stock::numeric / NULLIF(vls.max_stock, 0), 3) AS fill_ratio,
  CASE WHEN COALESCE(vsi.dvel,0) >= p.a_floor THEN 'A'
       WHEN COALESCE(vsi.dvel,0) >= p.b_floor THEN 'B'
       WHEN COALESCE(vsi.dvel,0) >  0         THEN 'C'
       ELSE 'D' END AS grade,
  CASE WHEN COALESCE(vsi.dvel,0) >= p.a_floor THEN p.hole_wt_a
       WHEN COALESCE(vsi.dvel,0) >= p.b_floor THEN p.hole_wt_b
       WHEN COALESCE(vsi.dvel,0) >  0         THEN p.hole_wt_c
       ELSE p.hole_wt_d END AS hole_wt,
  (vls.current_stock = 0
   OR vls.current_stock::numeric / NULLIF(vls.max_stock, 0) <= p.hole_frac) AS is_hole
FROM public.v_live_shelf_stock vls
CROSS JOIN public.pick_urgency_params p
LEFT JOIN alias al ON al.pod_product_id = vls.pod_product_id
LEFT JOIN public.v_shelf_sales_identity vsi
  ON vsi.machine_id = vls.machine_id
 AND vsi.pod_product_id = COALESCE(al.canonical_pod, vls.pod_product_id)
WHERE vls.is_enabled
  AND COALESCE(vls.is_broken, false) = false
  AND vls.is_eligible_machine
  AND vls.pod_product_id IS NOT NULL;

COMMENT ON VIEW public.v_shelf_holes IS
'PRD-100: canonical per-slot hole state. A hole = enabled, unbroken, eligible slot with current_stock=0 OR fill ratio <= pick_urgency_params.hole_frac. grade/hole_wt from pooled product velocity (v_shelf_sales_identity). Consumed by v_machine_priority (s_holes).';
