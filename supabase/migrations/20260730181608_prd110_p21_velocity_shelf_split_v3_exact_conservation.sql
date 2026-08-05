-- PRD-110 P2.1 leg 21 · forward fix to prd110_p21_velocity_shelf_split_v3 (Article 12: new migration,
-- never an edit of the applied one).
--
-- DEFECT (found by the post-apply verify, not predicted): rounding velocity_instock_shelf to 6dp made
-- the conservation law INEXACT. Measured on the applied object: SUM(velocity_instock_shelf) drifted
-- from velocity_instock_pod by up to n x 5e-7 - worst case IFLYMCC-1024 Aquafina (n=6), delta 2e-6,
-- which breaks a 1e-6 contract. The weights themselves were exact: the same pods show
-- SUM(velocity_instock_pod * w_instock) - velocity_instock_pod = 0 to 20 decimal places.
--
-- FIX: do not round the two conserved columns. Consumers round for display. The diagnostic hour
-- columns stay rounded - they are not conserved.
--
-- ⚠️ This was NOT sufficient on its own - see 20260730181902_..._residual_absorber, which found that
--    exact conservation still failed on 6 pods because numeric division truncates at 20dp.

CREATE OR REPLACE VIEW public.v_shelf_instock_velocity_split_v3 AS
WITH p AS (
  SELECT 30 AS win_days
),
w AS (
  SELECT ba.t_anchor,
         ba.t_anchor - make_interval(days => p.win_days) AS t_start
  FROM p
  CROSS JOIN (
    SELECT max(ds.snapshot_at) AS t_anchor
    FROM weimi_device_status ds
    JOIN machines m ON m.machine_id = ds.machine_id
  ) ba
),
-- canonical shelf universe; owns the A01<->A1 join via v_shelf_slot_identity
shelves AS MATERIALIZED (
  SELECT ss.machine_id, ss.machine_name, ss.shelf_id, ss.shelf_code, ss.slot_name,
         ss.pod_product_id, ss.pod_name, ss.pod_shelf_count::int AS n
  FROM public.v_shelf_state ss
  WHERE ss.pod_product_id IS NOT NULL
),
snaps AS MATERIALIZED (
  SELECT DISTINCT ds.machine_id, ds.snapshot_at
  FROM weimi_device_status ds
  JOIN machines m ON m.machine_id = ds.machine_id
  CROSS JOIN w
  WHERE ds.snapshot_at >= w.t_start AND ds.snapshot_at <= w.t_anchor
),
iv AS MATERIALIZED (
  SELECT machine_id, t_i, EXTRACT(epoch FROM t_next - t_i) / 3600.0 AS h_len
  FROM (
    SELECT machine_id,
           snapshot_at AS t_i,
           lead(snapshot_at) OVER (PARTITION BY machine_id ORDER BY snapshot_at) AS t_next
    FROM snaps
  ) q
  WHERE t_next IS NOT NULL
),
slot_stock AS MATERIALIZED (
  SELECT h.machine_id, h.slot_name, h.pod_product_id, h.snapshot_at,
         sum(h.current_stock) AS stock
  FROM v_weimi_shelf_history_v3 h
  CROSS JOIN w
  WHERE h.pod_product_id IS NOT NULL
    AND h.is_enabled
    AND COALESCE(h.is_broken, false) = false
    AND h.snapshot_at >= w.t_start AND h.snapshot_at <= w.t_anchor
  GROUP BY 1, 2, 3, 4
),
-- LEFT JOIN to iv on purpose: a machine with no snapshots in the window must still yield its shelves
-- at 0 hours rather than dropping them from the output.
shelf_hours AS MATERIALIZED (
  SELECT s.machine_id, s.shelf_id, s.pod_product_id,
         COALESCE(sum(iv.h_len) FILTER (WHERE ss.stock > 0), 0)::numeric AS shelf_instock_hours
  FROM shelves s
  LEFT JOIN iv ON iv.machine_id = s.machine_id
  LEFT JOIN slot_stock ss
         ON ss.machine_id     = s.machine_id
        AND ss.slot_name      = s.slot_name
        AND ss.pod_product_id = s.pod_product_id
        AND ss.snapshot_at    = iv.t_i
  GROUP BY 1, 2, 3
),
wt AS (
  SELECT sh.*,
         sum(sh.shelf_instock_hours) OVER (PARTITION BY sh.machine_id, sh.pod_product_id)
           AS pod_instock_hours
  FROM shelf_hours sh
),
split AS (
  SELECT s.machine_id, s.machine_name, s.shelf_id, s.shelf_code, s.slot_name,
         s.pod_product_id, s.pod_name, s.n,
         wt.shelf_instock_hours, wt.pod_instock_hours,
         CASE
           WHEN s.n = 1                                                     THEN 'single_shelf'
           WHEN wt.pod_instock_hours > 0 AND wt.shelf_instock_hours = 0     THEN 'zero_instock'
           WHEN wt.pod_instock_hours > 0                                    THEN 'instock_weighted'
           ELSE 'equal_fallback'
         END AS split_method,
         CASE
           WHEN s.n = 1                  THEN 1.0::numeric
           WHEN wt.pod_instock_hours > 0 THEN wt.shelf_instock_hours / wt.pod_instock_hours
           ELSE 1.0::numeric / s.n
         END AS w_instock
  FROM shelves s
  JOIN wt ON wt.machine_id     = s.machine_id
         AND wt.shelf_id       = s.shelf_id
         AND wt.pod_product_id = s.pod_product_id
),
vel AS MATERIALIZED (
  SELECT machine_id, pod_product_id, velocity_instock, velocity_raw, velocity_status
  FROM public.v_shelf_instock_velocity_v3
)
SELECT sp.machine_id,
       sp.machine_name,
       sp.shelf_id,
       sp.shelf_code,
       sp.slot_name,
       sp.pod_product_id,
       sp.pod_name,
       sp.n                                   AS pod_shelf_count,
       round(sp.shelf_instock_hours, 4)       AS shelf_instock_hours,
       round(sp.pod_instock_hours, 4)         AS pod_instock_hours,
       sp.split_method,
       sp.w_instock,
       1.0::numeric / sp.n                    AS w_equal,
       v.velocity_instock                     AS velocity_instock_pod,
       v.velocity_raw                         AS velocity_raw_pod,
       -- `velocity_status` carries WHY (out_of_canonical_scope / below_floor); a NULL status means
       -- the pod has no row in the pod-grain view at all.
       -- NOT rounded: conservation must be exact, not within a tolerance. See header.
       -- NULL when the pod has no velocity: an absent signal, never a silent 0 (LAW 5).
       v.velocity_instock * sp.w_instock      AS velocity_instock_shelf,
       v.velocity_raw     * sp.w_instock      AS velocity_raw_shelf,
       v.velocity_status,
       w.t_start,
       w.t_anchor
FROM split sp
CROSS JOIN w
LEFT JOIN vel v ON v.machine_id     = sp.machine_id
               AND v.pod_product_id = sp.pod_product_id;

ALTER VIEW public.v_shelf_instock_velocity_split_v3 SET (security_invoker = true);

COMMENT ON VIEW public.v_shelf_instock_velocity_split_v3 IS
'PRD-110 P2.1. Shelf-grain in-stock velocity: pod-grain v_shelf_instock_velocity_v3 divided across a
pod''s shelves by each shelf''s share of in-stock hours (leg-16 F7 - 1/n is wrong by up to 2x in the
tail). One row per pod-bound shelf in v_shelf_state. SUM(velocity_instock_shelf) = velocity_instock_pod EXACTLY
per (machine, pod) - the conserved columns are deliberately UNROUNDED; round for display only. split_method names the branch; NULL velocity is an absent signal, never 0 (LAW 5).
Anchor is the moving t_anchor of the pod-grain view (RISK 53 resolved: assert the mechanism, do not
pin) - t_start/t_anchor exposed so fixtures record what they ran against. Metric status inherits the
pod-grain view: NOT YET CANONICAL pending D-10.';

-- Match v_shelf_state exactly: authenticated + service_role, and deliberately NOT anon.
GRANT SELECT ON public.v_shelf_instock_velocity_split_v3 TO authenticated, service_role;
