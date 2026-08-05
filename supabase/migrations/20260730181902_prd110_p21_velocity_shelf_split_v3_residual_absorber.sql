-- PRD-110 P2.1 leg 21 · second forward fix to prd110_p21_velocity_shelf_split_v3 (Article 12).
-- FINAL body of the object as of leg 21.
--
-- DEFECT, measured on the applied object after the un-rounding fix: exact conservation still failed on
-- 6 of 476 (machine, pod) pairs. Cause is NOT the model - it is numeric division scale. w = h_i / H
-- truncates at 20 decimal places, so a repeating decimal never sums back to 1:
--   GRIT-1022 Al Ain Zero  n=7  7 x 0.14285714285714285714 = 1 - 2e-20
--   GRIT-1022 Evian        n=3  3 x 0.33333333333333333333 = 1 - 1e-20
--   + IFLYMCC-1024 Aquafina (6), MPMCC-1058 Aquafina (7), ACTIVATE-2005 Aquafina (11),
--     VOXMM-1013 Aquafina (3).  Residual always +/-1e-20 or +/-2e-20.
--
-- FIX: a deterministic residual absorber. Per (machine, pod) one shelf - the one with the most
-- in-stock hours, ties broken by shelf_id so it never depends on scan order - takes (1 - SUM(w)).
-- SUM(w) is then EXACTLY 1, and because numeric multiplication is exact, SUM(v_pod * w_i) is then
-- EXACTLY v_pod. This is the largest-remainder pattern already used by estimate_shelf_composition_v3.
--
-- WHY BOTHER over a 2e-20 discrepancy: the fixture for this object asserts conservation. A tolerance
-- loose enough to pass (1e-9) is also loose enough to hide a real 1e-9 defect. An exact law cannot be
-- silently broken. The adjustment lands on the largest leg, so w stays in [0,1] by construction.
--
-- ⚠️ is_residual_absorber is appended LAST on purpose: CREATE OR REPLACE VIEW may only APPEND columns.
--    A first attempt placing it mid-list failed with 42P16 "cannot change name of view column
--    velocity_instock_pod to is_residual_absorber".
--
-- Contract after this migration (re-verified live on the applied object, 544 shelves):
--   V1 one row per pod-bound shelf in v_shelf_state, no fan-out   544 rows / 544 shelf_ids / 544 expected
--   V2 SUM(w_instock) = 1                                         EXACTLY, 0 violations
--   V3 SUM(velocity_instock_shelf) = velocity_instock_pod         EXACTLY, 0 violations
--   V3b same for velocity_raw_shelf                               EXACTLY, 0 violations
--   V4 w_instock in [0,1]                                         0 violations
--   V5 shelf_instock_hours <= pod_instock_hours                   0 violations
--   V6 velocity_instock_pod NULL <=> velocity_instock_shelf NULL  0 violations (LAW 5)
--   V7 exactly one is_residual_absorber per (machine, pod)        0 violations

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
         END AS w_raw
  FROM shelves s
  JOIN wt ON wt.machine_id     = s.machine_id
         AND wt.shelf_id       = s.shelf_id
         AND wt.pod_product_id = s.pod_product_id
),
-- Deterministic absorber: most in-stock hours wins, ties broken by shelf_id (never scan order).
absorb AS (
  SELECT sp.*,
         sum(sp.w_raw) OVER (PARTITION BY sp.machine_id, sp.pod_product_id) AS w_sum,
         row_number() OVER (PARTITION BY sp.machine_id, sp.pod_product_id
                            ORDER BY sp.shelf_instock_hours DESC, sp.shelf_id) AS absorber_rank
  FROM split sp
),
fin AS (
  SELECT a.*,
         CASE WHEN a.absorber_rank = 1 THEN a.w_raw + (1.0::numeric - a.w_sum)
              ELSE a.w_raw END AS w_instock
  FROM absorb a
),
vel AS MATERIALIZED (
  SELECT machine_id, pod_product_id, velocity_instock, velocity_raw, velocity_status
  FROM public.v_shelf_instock_velocity_v3
)
SELECT f.machine_id,
       f.machine_name,
       f.shelf_id,
       f.shelf_code,
       f.slot_name,
       f.pod_product_id,
       f.pod_name,
       f.n                                   AS pod_shelf_count,
       round(f.shelf_instock_hours, 4)       AS shelf_instock_hours,
       round(f.pod_instock_hours, 4)         AS pod_instock_hours,
       f.split_method,
       f.w_instock,
       1.0::numeric / f.n                    AS w_equal,
       v.velocity_instock                     AS velocity_instock_pod,
       v.velocity_raw                         AS velocity_raw_pod,
       -- `velocity_status` carries WHY (out_of_canonical_scope / below_floor); a NULL status means
       -- the pod has no row in the pod-grain view at all.
       -- NOT rounded: conservation must be exact, not within a tolerance. See header.
       -- NULL when the pod has no velocity: an absent signal, never a silent 0 (LAW 5).
       v.velocity_instock * f.w_instock      AS velocity_instock_shelf,
       v.velocity_raw     * f.w_instock      AS velocity_raw_shelf,
       v.velocity_status,
       w.t_start,
       w.t_anchor,
       (f.absorber_rank = 1)                 AS is_residual_absorber
FROM fin f
CROSS JOIN w
LEFT JOIN vel v ON v.machine_id     = f.machine_id
               AND v.pod_product_id = f.pod_product_id;

ALTER VIEW public.v_shelf_instock_velocity_split_v3 SET (security_invoker = true);

COMMENT ON VIEW public.v_shelf_instock_velocity_split_v3 IS
'PRD-110 P2.1. Shelf-grain in-stock velocity: pod-grain v_shelf_instock_velocity_v3 divided across a
pod''s shelves by each shelf''s share of in-stock hours (leg-16 F7 - 1/n is wrong by up to 2x in the
tail). One row per pod-bound shelf in v_shelf_state. SUM(w_instock)=1 and
SUM(velocity_instock_shelf)=velocity_instock_pod hold EXACTLY per (machine, pod): the conserved columns
are unrounded and one deterministic shelf per pod (is_residual_absorber, most in-stock hours, ties by
shelf_id) absorbs the 1e-20 numeric-division residue. split_method names the branch; NULL velocity is an absent signal, never 0 (LAW 5).
Anchor is the moving t_anchor of the pod-grain view (RISK 53 resolved: assert the mechanism, do not
pin) - t_start/t_anchor exposed so fixtures record what they ran against. Metric status inherits the
pod-grain view: NOT YET CANONICAL pending D-10.';

-- Match v_shelf_state exactly: authenticated + service_role, and deliberately NOT anon.
GRANT SELECT ON public.v_shelf_instock_velocity_split_v3 TO authenticated, service_role;
