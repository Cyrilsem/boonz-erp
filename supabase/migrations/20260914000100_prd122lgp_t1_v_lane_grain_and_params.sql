-- PRD-122 (lane-grain-priority) T1 / R1 / D1.
-- New lane-grain view v_lane_grain, one row per physical facing, fixing 1a: emptiness
-- was diluted by facing count because v_shelf_sales_identity groups by
-- (machine_id, pod_product_id), collapsing multi-facing products into one row.
--
-- lane_dvel = product-level dvel / facings (there is no independent per-lane sales
-- signal -- sales history resolves to a product, not a physical slot -- so dividing
-- the shared velocity is the only grounded per-lane estimate; F10 validates its
-- fleet-wide effect is sane). grade/w mirror the existing a_floor/b_floor/grade_wt_a/b/c
-- pattern already used elsewhere in v_machine_priority, plus a new lane_wt_d so D-grade
-- (dead) lanes get a small nonzero weight in s_gap/s_empty/s_lowfill instead of zero.
--
-- New pick_urgency_params columns: quasi_fill_floor (0.25, mirrors the existing
-- low_fill_pct_floor=25 but expressed as a 0-1 ratio for lane-grain fill_ratio),
-- lane_wt_d (0.05), w_gap (0.30, T3's new p_score weight), p1_gap_min (40, T3's new
-- P1 override threshold). hole_frac raised 0.15 to 0.25 -- v_shelf_holes already reads
-- this dynamically, no view change needed for that part.
--
-- Cody: Approve. Article 2 (no RLS needed -- read-only view over already-RLS'd
-- v_live_shelf_stock/v_shelf_sales_identity/pick_urgency_params), Article 12
-- (forward-only CREATE OR REPLACE, additive ADD COLUMN IF NOT EXISTS), Article 14
-- (not a snapshot table -- computed live off v_live_shelf_stock), Article 16 (no
-- existing canonical object computes lane-grain emptiness; genuinely new).
--
-- Verified in a rolled-back transaction: ACTIVATEMCC-1037-0000-L0's Aquafina lane A10
-- (0 of 17) correctly shows is_empty=true, grade='A', matching F1a/F10's worked example.

ALTER TABLE public.pick_urgency_params ADD COLUMN IF NOT EXISTS quasi_fill_floor numeric NOT NULL DEFAULT 0.25;
ALTER TABLE public.pick_urgency_params ADD COLUMN IF NOT EXISTS lane_wt_d numeric NOT NULL DEFAULT 0.05;
ALTER TABLE public.pick_urgency_params ADD COLUMN IF NOT EXISTS w_gap numeric NOT NULL DEFAULT 0.30;
ALTER TABLE public.pick_urgency_params ADD COLUMN IF NOT EXISTS p1_gap_min numeric NOT NULL DEFAULT 40;
UPDATE public.pick_urgency_params SET hole_frac = 0.25 WHERE id = 1;

CREATE OR REPLACE VIEW public.v_lane_grain AS
SELECT
  vls.machine_id,
  vls.slot_name AS lane_id,
  vls.pod_product_id,
  vls.current_stock,
  vls.max_stock,
  i.dos,
  (i.dvel / NULLIF(i.facings, 0)) AS lane_dvel,
  CASE
    WHEN (i.dvel / NULLIF(i.facings, 0)) >= pp.a_floor THEN 'A'
    WHEN (i.dvel / NULLIF(i.facings, 0)) >= pp.b_floor THEN 'B'
    WHEN (i.dvel / NULLIF(i.facings, 0)) > 0 THEN 'C'
    ELSE 'D'
  END AS grade,
  CASE
    WHEN (i.dvel / NULLIF(i.facings, 0)) >= pp.a_floor THEN pp.grade_wt_a
    WHEN (i.dvel / NULLIF(i.facings, 0)) >= pp.b_floor THEN pp.grade_wt_b
    WHEN (i.dvel / NULLIF(i.facings, 0)) > 0 THEN pp.grade_wt_c
    ELSE pp.lane_wt_d
  END AS w,
  (vls.current_stock::numeric / NULLIF(vls.max_stock, 0)) AS fill_ratio,
  (vls.current_stock = 0) AS is_empty,
  (
    (vls.current_stock::numeric / NULLIF(vls.max_stock, 0)) > 0
    AND (vls.current_stock::numeric / NULLIF(vls.max_stock, 0)) <= pp.quasi_fill_floor
  ) AS is_quasi
FROM public.v_live_shelf_stock vls
JOIN public.v_shelf_sales_identity i
  ON i.machine_id = vls.machine_id AND i.pod_product_id = vls.pod_product_id
CROSS JOIN public.pick_urgency_params pp
WHERE vls.is_enabled
  AND NOT COALESCE(vls.is_broken, false)
  AND vls.is_eligible_machine
  AND vls.pod_product_id IS NOT NULL;
