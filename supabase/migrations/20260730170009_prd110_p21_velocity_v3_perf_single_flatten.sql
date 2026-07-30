-- PRD-110 P2.1 perf fix — v_shelf_instock_velocity_v3: 4 history-view evaluations -> 1.
--
-- APPLIED 2026-07-30 (leg 18) as `prd110_p21_velocity_v3_perf_single_flatten`, DB version
-- 20260730170009. Forward-only: this does NOT edit 20260730170002, it replaces the view body.
--
-- WHY. The prior body referenced v_weimi_shelf_history_v3 FOUR times — max(snapshot_at) TWICE
-- in `w`, plus `hist`, plus `snaps`. Each evaluation re-runs a triple-LATERAL JSONB flatten of
-- 79k rows plus four LATERAL resolver lookups per row, then a DISTINCT ON sort. Compounding it,
-- `w` derived its window bounds FROM the view itself, so t_start/t_anchor were not constants and
-- the 30-day predicate could not push down. A ~10-subquery probe of the old body saturated
-- production for ~35 minutes on 2026-07-30 (16:13->16:48 UTC).
--
-- WHAT CHANGES: `w` and `snaps` only. `hist` still reads v_weimi_shelf_history_v3 — the canonical
-- four-tier resolver is NEVER re-implemented (a hand-rolled version diverged on 17.1% of keys).
--
-- PROVEN EQUIVALENT BEFORE APPLY (all measured live, leg 18):
--   A1 anchor    — base(+machines join) max = raw base max = view max = 2026-07-30 14:00:39.507348+00
--   A2 snaps     — base 1208 = view 1208 over the 30d window; EXCEPT both directions 0 / 0
--   A3 output    — 687 = 687 rows, only_old 0, only_new 0, and ZERO diffs on stock_hours,
--                  elapsed_hours, velocity_instock, velocity_status, all five n_case_*, t_start,
--                  t_anchor. Verified again after apply against the _test shadow: 0 diffs.
--
-- CODY (Art 2, 3, 12, 14, 16): Approve with revisions. Stays a VIEW, so no Article 14 ADR is
-- needed. Reads base weimi_device_status ONLY for snapshot timestamps and structural presence —
-- NO stock quantity — so there is no Article 16 re-derivation of "live shelf stock"; all stock
-- still flows through v_weimi_shelf_history_v3 and the numerator is still
-- v_shelf_sales_identity.units_30d. Conditions discharged at apply: security_invoker verified
-- still true, column list unchanged (CREATE OR REPLACE VIEW errors otherwise; 18 cols), _test
-- shadow DROPPED, registry left at 🔴 not-yet-canonical (perf work does not make it canonical —
-- only the oracle comparison does).
--
-- ⚠️ STILL UNVERIFIED AGAINST THE P2.1 ORACLE. This migration makes the view FAST and proves it
-- did not change meaning. It does NOT prove the meaning is right. See PRD-110-P21-ORACLE.json.
--
-- ⚠️ PROBE RULE (this is what caused the incident): one cheap aggregate per statement, scoped to
-- one machine first, and ALWAYS `SET statement_timeout` — a client timeout does NOT cancel the
-- server query.

CREATE OR REPLACE VIEW public.v_shelf_instock_velocity_v3
WITH (security_invoker = true) AS
WITH p AS (SELECT 30 AS win_days, 48.0::numeric AS floor_hours),
w AS (
  -- PERF: window bounds from the BASE table, evaluated ONCE as an InitPlan scalar.
  -- JOIN machines mirrors the history view's own INNER JOIN, so t_anchor is attainable by
  -- that view BY CONSTRUCTION (A1) — this removes the assumption rather than relying on it.
  SELECT ba.t_anchor, ba.t_anchor - make_interval(days => p.win_days) AS t_start, p.floor_hours
  FROM p CROSS JOIN (
    SELECT max(ds.snapshot_at) AS t_anchor
    FROM public.weimi_device_status ds
    JOIN public.machines m ON m.machine_id = ds.machine_id
  ) ba
),
alias(pod_product_id, canonical_pod) AS (
  VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,'51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
),
hist AS (
  SELECT h.machine_id, COALESCE(al.canonical_pod, h.pod_product_id) AS pod_product_id,
         h.snapshot_at, h.slot_name, h.current_stock
  FROM public.v_weimi_shelf_history_v3 h
  CROSS JOIN w
  LEFT JOIN alias al ON al.pod_product_id = h.pod_product_id
  WHERE h.pod_product_id IS NOT NULL
    AND h.is_enabled AND COALESCE(h.is_broken,false) = false
    AND h.snapshot_at >= w.t_start AND h.snapshot_at <= w.t_anchor
),
snaps AS (
  -- PERF: interval boundaries need only (machine_id, snapshot_at) — never the JSONB flatten.
  -- EQUIVALENCE GUARD: a snapshot whose door_statuses flattens to zero aisles produces no rows
  -- in the history view, so it must not create an interval boundary here either. EXISTS
  -- short-circuits on the first aisle (O(1) per snapshot, not a flatten). A2 proves set-equality.
  SELECT DISTINCT ds.machine_id, ds.snapshot_at
  FROM public.weimi_device_status ds
  JOIN public.machines m ON m.machine_id = ds.machine_id
  CROSS JOIN w
  WHERE ds.snapshot_at >= w.t_start AND ds.snapshot_at <= w.t_anchor
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(ds.door_statuses) c(value),
                       jsonb_array_elements(c.value->'layers') l(value),
                       jsonb_array_elements(l.value->'aisles') a(value))
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
  LEFT JOIN pod_stock ps ON ps.machine_id = i.machine_id AND ps.pod_product_id = pd.pod_product_id
   AND ps.snapshot_at = i.t_i
),
cell_sales AS (
  SELECT c.machine_id, c.pod_product_id, c.t_i,
         COALESCE(SUM(s.qty),0)::numeric AS units, MIN(s.transaction_date) AS first_sale_at
  FROM cells c
  LEFT JOIN sales_ok s ON s.machine_id = c.machine_id AND s.pod_product_id = c.pod_product_id
   AND s.transaction_date >= c.t_i AND s.transaction_date < c.t_next
  GROUP BY 1,2,3
),
dep AS (
  SELECT c.machine_id, c.pod_product_id, c.t_i,
         (SELECT MIN(x.transaction_date) FROM (
            SELECT s.transaction_date,
                   SUM(s.qty) OVER (ORDER BY s.transaction_date, s.transaction_id ROWS UNBOUNDED PRECEDING) AS cum
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
    CASE WHEN NOT c.present AND cs.units = 0 THEN 'X'
         WHEN c.present AND COALESCE(c.stock,0) = 0 AND cs.units = 0 THEN 'A'
         WHEN COALESCE(c.stock,0) = 0 AND cs.units > 0 THEN 'D'
         WHEN c.stock > 0 AND cs.units <  c.stock THEN 'B'
         ELSE 'C' END AS case_code,
    CASE WHEN NOT c.present AND cs.units = 0 THEN NULL
         WHEN c.present AND COALESCE(c.stock,0) = 0 AND cs.units = 0 THEN 0::numeric
         WHEN COALESCE(c.stock,0) = 0 AND cs.units > 0
           THEN GREATEST(0::numeric, c.h_len - EXTRACT(epoch FROM (cs.first_sale_at - c.t_i))/3600.0)
         WHEN c.stock > 0 AND cs.units < c.stock THEN c.h_len
         ELSE GREATEST(0::numeric, EXTRACT(epoch FROM (d.t_dep - c.t_i))/3600.0) END AS stock_hours,
    CASE WHEN NOT c.present AND cs.units = 0 THEN NULL ELSE c.h_len END AS elapsed_hours
  FROM cells c
  JOIN cell_sales cs USING (machine_id, pod_product_id, t_i)
  LEFT JOIN dep d USING (machine_id, pod_product_id, t_i)
),
agg AS (
  SELECT machine_id, pod_product_id, SUM(stock_hours) AS stock_hours,
         SUM(elapsed_hours) AS elapsed_hours, SUM(units) AS units_window,
         count(*) FILTER (WHERE case_code='A') AS n_case_a,
         count(*) FILTER (WHERE case_code='B') AS n_case_b,
         count(*) FILTER (WHERE case_code='C') AS n_case_c,
         count(*) FILTER (WHERE case_code='D') AS n_case_d,
         count(*) FILTER (WHERE case_code='X') AS n_case_x
  FROM scored GROUP BY 1,2
)
SELECT a.machine_id, a.pod_product_id, si.units_30d AS units_30d_canonical, a.units_window,
       round(a.stock_hours,4) AS stock_hours, round(a.elapsed_hours,4) AS elapsed_hours,
       CASE WHEN a.elapsed_hours > 0 THEN round(1 - (a.stock_hours / a.elapsed_hours), 6) END AS stock_censoring,
       CASE WHEN si.units_30d IS NOT NULL AND a.stock_hours >= w.floor_hours AND a.stock_hours > 0
            THEN round(si.units_30d / (a.stock_hours / 24.0), 6) END AS velocity_instock,
       CASE WHEN si.units_30d IS NOT NULL THEN round(si.units_30d / 30.0, 6) END AS velocity_raw,
       CASE WHEN si.machine_id IS NULL THEN 'out_of_canonical_scope'
            WHEN a.stock_hours < w.floor_hours THEN 'below_floor' ELSE 'ok' END AS velocity_status,
       a.n_case_a, a.n_case_b, a.n_case_c, a.n_case_d, a.n_case_x,
       w.t_start, w.t_anchor, w.floor_hours
FROM agg a CROSS JOIN w
LEFT JOIN public.v_shelf_sales_identity si
       ON si.machine_id = a.machine_id AND si.pod_product_id = a.pod_product_id;
