-- PRD-110 · P2.1 · per-shelf in-stock split of pod-grain velocity  (leg-15 item 5 / leg-16 F7)
--
-- ⚠️ SUPERSEDED TWICE WITHIN LEG 21, by forward migrations (Article 12 - never edit an applied one):
--    20260730181608 _exact_conservation   - stopped rounding the two conserved velocity columns
--    20260730181902 _residual_absorber    - absorbed the 1e-20 numeric-division residue; FINAL body
--    Read 181902 for the object as it stands. This file is kept so the repo reproduces the DB
--    (file count must equal schema_migrations row count - S-24).
--    The header comments below are comment-only additions over the applied statement text.
--
-- WHY
--   `v_shelf_instock_velocity_v3` is at (machine_id, pod_product_id) grain, but the engine plans at
--   SHELF grain. 35 (machine, pod) pairs span more than one shelf (103 shelves, max span 11), so the
--   pod velocity has to be divided among them. Leg 16 (F7) measured that the naive `1/n` split is
--   right on average and wrong by up to 2x in the tail:
--     |w_instock - 1/n|  p50 0.015 · p90 0.235 · max 0.500
--   Worst cases (re-measured on the device_status path, leg 21 - F7 measured them on
--   weimi_aisle_snapshots and got the same four pairs and the same weights to +/-0.003):
--     VOXMM-1013 Tamreem Date Ball  A16/A04 = 1.000 / 0.000   (1/n would say 0.500 / 0.500)
--     HUAWEI-2003 Pepsi Black       B03/B07 = 0.973 / 0.027
--     HUAWEI-2003 Coca Cola Zero    B01/A12 = 0.973 / 0.027
--     ACTIVATE-2005 Chocolate Bar   B01/A04 = 0.942 / 0.058
--
-- WHAT
--   Weight each shelf by the hours IT held stock of the pod, not by 1/n:
--     w_instock = shelf_instock_hours / SUM(shelf_instock_hours) OVER (machine, pod)
--   `split_method` names the branch taken so no case is silent (LAW 5 in spirit):
--     single_shelf     n = 1                                  -> w = 1
--     instock_weighted the normal case                        -> w = hours share
--     zero_instock     pod had hours, THIS shelf had none      -> w = 0, named not hidden
--     equal_fallback   pod had NO in-stock hours anywhere      -> w = 1/n
--
-- DATA-SOURCE LAW (goal-command LAW 6)
--   * shelf universe + the shelf_id <-> WEIMI slot_name join come from `v_shelf_state`, which gets
--     them from `v_shelf_slot_identity`. That view owns the A01 <-> A1 normalisation
--     (`left(shelf_code,1) || substr(shelf_code,2)::integer::text`). It is NOT re-derived here.
--     ⛔ Never direct-join WEIMI `slot_name` to `shelf_configurations.shelf_code`.
--   * stock history comes from `v_weimi_shelf_history_v3` (weimi_device_status), never
--     `weimi_aisle_snapshots` (S-21).
--   * the slot->pod join is keyed on BOTH slot_name AND pod_product_id, so a shelf that rebound to a
--     different product inside the window (18% do - RISK 37) contributes hours only for the pod it
--     currently holds.
--
-- WINDOW / ANCHOR
--   Same 30d window and the same moving `t_anchor = max(weimi_device_status.snapshot_at)` as the
--   pod-grain view. RISK 53 is RESOLVED as "assert the mechanism, do not pin the anchor" (leg 20), so
--   `t_start` / `t_anchor` are exposed as columns and fixtures record the anchor they ran against.
--
-- INVARIANTS (all verified live on 544 shelves before apply, 0 violations - leg 21)
--   V1 one row per pod-bound shelf in v_shelf_state, no fan-out           (544 rows / 544 shelf_ids)
--   V2 SUM(w_instock) = 1 per (machine, pod)                              within 1e-9
--   V3 SUM(velocity_instock_shelf) = velocity_instock_pod                 within 1e-6
--   V4 w_instock in [0, 1]
--   V5 shelf_instock_hours <= pod_instock_hours
--   V6 velocity_instock_pod NULL  <=>  velocity_instock_shelf NULL   (LAW 5: never a silent 0)
--
-- ADDITIVE ONLY. New view, `_v3` suffixed. No existing object is altered, nothing consumes this yet
-- (`v_shelf_state.velocity_instock` stays NULL, so fixture 3 seq 15 stays valid).

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
       -- NULL when the pod has no velocity: an absent signal, never a silent 0 (LAW 5).
       -- `velocity_status` carries WHY (out_of_canonical_scope / below_floor); a NULL status means
       -- the pod has no row in the pod-grain view at all.
       CASE WHEN v.velocity_instock IS NULL THEN NULL
            ELSE round(v.velocity_instock * sp.w_instock, 6) END AS velocity_instock_shelf,
       CASE WHEN v.velocity_raw IS NULL THEN NULL
            ELSE round(v.velocity_raw * sp.w_instock, 6) END     AS velocity_raw_shelf,
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
tail). One row per pod-bound shelf in v_shelf_state. SUM(velocity_instock_shelf) = velocity_instock_pod
per (machine, pod). split_method names the branch; NULL velocity is an absent signal, never 0 (LAW 5).
Anchor is the moving t_anchor of the pod-grain view (RISK 53 resolved: assert the mechanism, do not
pin) - t_start/t_anchor exposed so fixtures record what they ran against. Metric status inherits the
pod-grain view: NOT YET CANONICAL pending D-10.';

-- Match v_shelf_state exactly: authenticated + service_role, and deliberately NOT anon.
GRANT SELECT ON public.v_shelf_instock_velocity_split_v3 TO authenticated, service_role;
