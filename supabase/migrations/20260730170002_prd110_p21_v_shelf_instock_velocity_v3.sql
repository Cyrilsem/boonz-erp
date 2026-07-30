-- PRD-110 P2.1 — v_shelf_instock_velocity_v3
--
-- ⚠️ STATUS (corrected leg 18): APPLIED but NEVER VERIFIED, and TOO SLOW TO QUERY AS WRITTEN.
-- The header previously claimed this was "superseded same leg by 20260730170003 perf fix".
-- That claim is FALSE and has been removed: no migration 20260730170003 exists on disk or in
-- the database (leg 17 confirmed from the Postgres logs that its body never reached the DB;
-- leg 18 confirmed no such file exists anywhere in the repo). The perf fix is DRAFTED ONLY,
-- as a proposal, in docs/prds/PRD-110-P21-PERF-FIX-PROPOSAL.md — it is deliberately NOT a
-- migration file, so that disk and DB continue to agree (RELAY handoff invariant).
--
-- Querying this view caused a production incident on 2026-07-30 (~16:13 UTC): a read-only
-- SELECT with ~10 independent aggregates over it saturated the database for 30+ minutes.
-- DO NOT probe it with multiple subqueries in one statement. One cheap aggregate at a time,
-- scoped to a single machine, with SET statement_timeout — a client timeout does NOT cancel
-- the server query.
--
-- In-stock velocity at (machine_id, pod_product_id): units per IN-STOCK day, so a shelf
-- that sold out early is not read as low demand.
--
-- ARTICLE 16 (Cody ruling, leg 17): METRICS_REGISTRY binds `v_shelf_sales_identity` as the
-- sole source of per-(machine,product) shelf velocity — "must use this object, not
-- re-aggregate sales_history". Therefore the velocity NUMERATOR is read from
-- v_shelf_sales_identity.units_30d. Raw sales_history is used ONLY for intra-interval
-- depletion timestamps (cases C/D, ~2% of cells), which are not a registered metric.
-- Series outside the canonical object's scope get velocity_status='out_of_canonical_scope'
-- and a NULL velocity — never a silent 0 (LAW 5).
--
-- stock_hours per leg-15 A/B/C/D with the leg-16 F3 correction:
--   A  present AND stock=0 AND 0 sold        -> 0        (proven empty)
--   B  stock>0 AND sold < stock              -> H        (proven never emptied)
--   C  stock>0 AND sold >= stock             -> t(cum qty reaches stock) - t_i
--   D  stock=0 AND sold > 0                  -> H - (first_sale - t_i)
--   X  ABSENT from snapshot AND 0 sold       -> UNOBSERVABLE: excluded from stock_hours
--      AND elapsed. Never scored as proven-out. 2,930 cells / 58,532 hours ride on this.
-- 48h floor -> velocity_instock NULL. Leg-16 F4: the floor guards a thin series, NOT a
-- divide-by-tiny — no runaway rate exists in this data. Keep it; do not re-tune it looking
-- for the absurd rate leg 15 described.
--
-- Stock history from v_weimi_shelf_history_v3 (weimi_device_status). Identity by product
-- NAME only, never by slot (LAW 6).

CREATE OR REPLACE VIEW public.v_shelf_instock_velocity_v3
WITH (security_invoker = true) AS
WITH p AS (SELECT 30 AS win_days, 48.0::numeric AS floor_hours),
w AS (
  SELECT (SELECT max(h.snapshot_at) FROM public.v_weimi_shelf_history_v3 h) AS t_anchor,
         (SELECT max(h.snapshot_at) FROM public.v_weimi_shelf_history_v3 h)
           - make_interval(days => p.win_days) AS t_start,
         p.floor_hours
  FROM p
),
alias(pod_product_id, canonical_pod) AS (
  VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,'51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
),
hist AS (
  SELECT h.machine_id,
         COALESCE(al.canonical_pod, h.pod_product_id) AS pod_product_id,
         h.snapshot_at, h.slot_name, h.current_stock
  FROM public.v_weimi_shelf_history_v3 h
  CROSS JOIN w
  LEFT JOIN alias al ON al.pod_product_id = h.pod_product_id
  WHERE h.pod_product_id IS NOT NULL
    AND h.is_enabled AND COALESCE(h.is_broken,false) = false
    AND h.snapshot_at >= w.t_start AND h.snapshot_at <= w.t_anchor
),
snaps AS (
  SELECT DISTINCT h.machine_id, h.snapshot_at
  FROM public.v_weimi_shelf_history_v3 h CROSS JOIN w
  WHERE h.snapshot_at >= w.t_start AND h.snapshot_at <= w.t_anchor
),
intervals AS (
  SELECT machine_id, t_i, t_next, EXTRACT(epoch FROM (t_next - t_i))/3600.0 AS h_len
  FROM (SELECT machine_id, snapshot_at AS t_i,
               lead(snapshot_at) OVER (PARTITION BY machine_id ORDER BY snapshot_at) AS t_next
        FROM snaps) q
  WHERE t_next IS NOT NULL
),
pod_stock AS (
  SELECT machine_id, pod_product_id, snapshot_at, SUM(current_stock) AS stock
  FROM hist GROUP BY 1,2,3
),
pods AS (SELECT DISTINCT machine_id, pod_product_id FROM hist),
sale_resolved AS (
  SELECT s.machine_id,
         COALESCE(al.canonical_pod, COALESCE(d.pod_product_id, ci.pod_product_id, cv.pod_product_id)) AS pod_product_id,
         s.qty, s.transaction_date, s.transaction_id
  FROM public.sales_history s
  CROSS JOIN w
  LEFT JOIN public.pod_products d  ON d.pod_product_name = s.pod_product_name
  LEFT JOIN public.pod_products ci ON lower(btrim(ci.pod_product_name)) = lower(btrim(s.pod_product_name))
  LEFT JOIN public.product_name_conventions pnc ON pnc.original_name = s.pod_product_name
  LEFT JOIN public.pod_products cv ON cv.pod_product_name = pnc.official_name
  LEFT JOIN alias al ON al.pod_product_id = COALESCE(d.pod_product_id, ci.pod_product_id, cv.pod_product_id)
  WHERE (s.delivery_status = ANY (ARRAY['Success'::text,'Successful'::text]))
    AND s.transaction_date >= w.t_start AND s.transaction_date <= w.t_anchor
),
sales_ok AS (SELECT * FROM sale_resolved WHERE pod_product_id IS NOT NULL),
cells AS (
  SELECT i.machine_id, pd.pod_product_id, i.t_i, i.t_next, i.h_len,
         ps.stock, (ps.pod_product_id IS NOT NULL) AS present
  FROM intervals i
  JOIN pods pd ON pd.machine_id = i.machine_id
  LEFT JOIN pod_stock ps
    ON ps.machine_id = i.machine_id AND ps.pod_product_id = pd.pod_product_id
   AND ps.snapshot_at = i.t_i
),
cell_sales AS (
  SELECT c.machine_id, c.pod_product_id, c.t_i,
         COALESCE(SUM(s.qty),0)::numeric AS units,
         MIN(s.transaction_date) AS first_sale_at
  FROM cells c
  LEFT JOIN sales_ok s
    ON s.machine_id = c.machine_id AND s.pod_product_id = c.pod_product_id
   AND s.transaction_date >= c.t_i AND s.transaction_date < c.t_next
  GROUP BY 1,2,3
),
dep AS (
  SELECT c.machine_id, c.pod_product_id, c.t_i,
         (SELECT MIN(x.transaction_date) FROM (
            SELECT s.transaction_date,
                   SUM(s.qty) OVER (ORDER BY s.transaction_date, s.transaction_id
                                    ROWS UNBOUNDED PRECEDING) AS cum
            FROM sales_ok s
            WHERE s.machine_id = c.machine_id AND s.pod_product_id = c.pod_product_id
              AND s.transaction_date >= c.t_i AND s.transaction_date < c.t_next
          ) x WHERE x.cum >= c.stock) AS t_dep
  FROM cells c
  JOIN cell_sales cs USING (machine_id, pod_product_id, t_i)
  WHERE c.present AND c.stock > 0 AND cs.units >= c.stock
),
scored AS (
  SELECT c.machine_id, c.pod_product_id, c.h_len, cs.units,
    CASE
      WHEN NOT c.present AND cs.units = 0 THEN 'X'
      WHEN c.present AND COALESCE(c.stock,0) = 0 AND cs.units = 0 THEN 'A'
      WHEN COALESCE(c.stock,0) = 0 AND cs.units > 0 THEN 'D'
      WHEN c.stock > 0 AND cs.units <  c.stock THEN 'B'
      ELSE 'C'
    END AS case_code,
    CASE
      WHEN NOT c.present AND cs.units = 0 THEN NULL
      WHEN c.present AND COALESCE(c.stock,0) = 0 AND cs.units = 0 THEN 0::numeric
      WHEN COALESCE(c.stock,0) = 0 AND cs.units > 0
        THEN GREATEST(0::numeric, c.h_len - EXTRACT(epoch FROM (cs.first_sale_at - c.t_i))/3600.0)
      WHEN c.stock > 0 AND cs.units < c.stock THEN c.h_len
      ELSE GREATEST(0::numeric, EXTRACT(epoch FROM (d.t_dep - c.t_i))/3600.0)
    END AS stock_hours,
    CASE WHEN NOT c.present AND cs.units = 0 THEN NULL ELSE c.h_len END AS elapsed_hours
  FROM cells c
  JOIN cell_sales cs USING (machine_id, pod_product_id, t_i)
  LEFT JOIN dep d USING (machine_id, pod_product_id, t_i)
),
agg AS (
  SELECT machine_id, pod_product_id,
         SUM(stock_hours)   AS stock_hours,
         SUM(elapsed_hours) AS elapsed_hours,
         SUM(units)         AS units_window,
         count(*) FILTER (WHERE case_code='A') AS n_case_a,
         count(*) FILTER (WHERE case_code='B') AS n_case_b,
         count(*) FILTER (WHERE case_code='C') AS n_case_c,
         count(*) FILTER (WHERE case_code='D') AS n_case_d,
         count(*) FILTER (WHERE case_code='X') AS n_case_x
  FROM scored GROUP BY 1,2
)
SELECT a.machine_id,
       a.pod_product_id,
       si.units_30d                        AS units_30d_canonical,
       a.units_window,
       round(a.stock_hours,4)              AS stock_hours,
       round(a.elapsed_hours,4)            AS elapsed_hours,
       CASE WHEN a.elapsed_hours > 0
            THEN round(1 - (a.stock_hours / a.elapsed_hours), 6) END AS stock_censoring,
       CASE WHEN si.units_30d IS NOT NULL
             AND a.stock_hours >= w.floor_hours
             AND a.stock_hours > 0
            THEN round(si.units_30d / (a.stock_hours / 24.0), 6) END AS velocity_instock,
       CASE WHEN si.units_30d IS NOT NULL THEN round(si.units_30d / 30.0, 6) END AS velocity_raw,
       CASE WHEN si.machine_id IS NULL THEN 'out_of_canonical_scope'
            WHEN a.stock_hours < w.floor_hours THEN 'below_floor'
            ELSE 'ok' END                  AS velocity_status,
       a.n_case_a, a.n_case_b, a.n_case_c, a.n_case_d, a.n_case_x,
       w.t_start, w.t_anchor, w.floor_hours
FROM agg a
CROSS JOIN w
LEFT JOIN public.v_shelf_sales_identity si
       ON si.machine_id = a.machine_id AND si.pod_product_id = a.pod_product_id;

COMMENT ON VIEW public.v_shelf_instock_velocity_v3 IS
'PRD-110 P2.1. In-stock velocity at (machine_id, pod_product_id): units per IN-STOCK day, so a shelf that sold out is not scored as low demand. stock_hours per leg-15 A/B/C/D with leg-16 F3 correction: case A requires present AND stock=0; a pod ABSENT from the snapshot with no sales is UNOBSERVABLE (case X) and is excluded from BOTH stock_hours and elapsed - never scored as proven-out. 48h floor -> velocity_instock NULL (velocity_status=below_floor); the floor guards thin series, NOT a divide-by-tiny (leg-16 F4: no runaway rate exists in this data). ARTICLE 16: the velocity NUMERATOR is read from the canonical v_shelf_sales_identity.units_30d and is never re-aggregated from sales_history; raw sales_history is used ONLY for intra-interval depletion timestamps (cases C/D, ~2 pct of cells), which are not a registered metric. Series outside the canonical objects scope get velocity_status=out_of_canonical_scope and a NULL velocity - never a silent 0 (LAW 5). Stock history from v_weimi_shelf_history_v3 (weimi_device_status), identity by product NAME only (LAW 6).';
