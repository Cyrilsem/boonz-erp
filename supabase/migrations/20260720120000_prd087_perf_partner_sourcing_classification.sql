-- PRD-087 PERF: fix fleet split classification.
-- The old logic classified VOX purely by `official_name LIKE 'VOX%'`, so
-- VOX-venue machines named ACTIVATE-*, ACTIVATEMCC-*, IFLYMCC-*, MPMCC-*
-- leaked into the "Non-VOX" bucket — skewing it (e.g. Aquafina, which only
-- sells on VOX-venue machines, ranked #1 under Non-VOX via ACTIVATE-2005).
--
-- New model (relabeled in the FE as "Boonz Sourcing" vs "Partner Sourcing"):
--   partner (p_scope='vox')  = machine is a partner-sourced venue, i.e.
--       venue_group IN ('VOX','LVLUP','LEVELUP')
--       OR official_name contains ACTIVATE / IFLY / VOX / MPMCC / LVLUP / LEVELUP
--   boonz  (p_scope='non_vox') = the complement (everything else).
-- venue_group is the canonical field; the name-contains clause is a
-- belt-and-suspenders guard for machines whose venue_group is not yet set.
-- Scope *values* ('non_vox'/'vox') are unchanged — only the labels moved.
CREATE OR REPLACE FUNCTION public.get_product_velocity_ledger(
  p_weeks integer DEFAULT 6,
  p_scope text DEFAULT 'non_vox',
  p_level text DEFAULT 'pod'
)
RETURNS TABLE(
  product_name text,
  total_units numeric,
  active_weeks integer,
  avg_per_week numeric,
  machine_count bigint,
  top_machines jsonb,
  weekly_units numeric[],
  week_start_dates date[],
  current_week_units numeric,
  first_sale_date date,
  is_new boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH params AS (
  SELECT date_trunc('week', (now() AT TIME ZONE 'Asia/Dubai'))::date AS cur_week_start,
         GREATEST(COALESCE(p_weeks, 6), 1) AS w
),
weeks AS (
  SELECT gs AS idx,
         (p.cur_week_start - ((p.w - gs) * 7))::date AS week_start
  FROM params p, generate_series(0, (SELECT w - 1 FROM params)) gs
),
win AS (
  SELECT (SELECT min(week_start) FROM weeks) AS start_date,
         (SELECT cur_week_start FROM params) AS end_date
),
raw AS MATERIALIZED (
  SELECT
    COALESCE(NULLIF(TRIM(pnc.official_name), ''), TRIM(sh.pod_product_name)) AS pod_name,
    pp.pod_product_id,
    sh.machine_id,
    m.official_name AS machine_name,
    sh.qty,
    (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date AS txn_date
  FROM sales_history sh
  JOIN machines m ON m.machine_id = sh.machine_id
  LEFT JOIN product_name_conventions pnc
    ON lower(TRIM(pnc.original_name)) = lower(TRIM(sh.pod_product_name))
  LEFT JOIN pod_products pp
    ON lower(TRIM(pp.pod_product_name)) =
       lower(TRIM(COALESCE(NULLIF(TRIM(pnc.official_name), ''), sh.pod_product_name)))
  WHERE sh.delivery_status IN ('Success', 'Successful')
    AND NOT (COALESCE(sh.refunded_amount, 0) > 0
             AND COALESCE(sh.refunded_amount, 0) >= COALESCE(sh.paid_amount, 0))
    AND COALESCE(m.venue_group, '') <> 'WH'
    AND upper(m.official_name) NOT LIKE 'WH%'
    AND (
      p_scope = 'all'
      -- Boonz Sourcing = everything that is NOT a partner-sourced venue
      OR (p_scope = 'non_vox' AND NOT (
            upper(COALESCE(m.venue_group, '')) IN ('VOX', 'LVLUP', 'LEVELUP')
            OR upper(m.official_name) LIKE ANY (ARRAY[
                 '%ACTIVATE%', '%IFLY%', '%VOX%', '%MPMCC%', '%LVLUP%', '%LEVELUP%'
               ])
         ))
      -- Partner Sourcing = VOX-venue machines + LVLUP machines
      OR (p_scope = 'vox' AND (
            upper(COALESCE(m.venue_group, '')) IN ('VOX', 'LVLUP', 'LEVELUP')
            OR upper(m.official_name) LIKE ANY (ARRAY[
                 '%ACTIVATE%', '%IFLY%', '%VOX%', '%MPMCC%', '%LVLUP%', '%LEVELUP%'
               ])
         ))
      OR (p_scope NOT IN ('all', 'non_vox', 'vox') AND m.venue_group = p_scope)
    )
),
pairs AS (
  SELECT DISTINCT pod_product_id, machine_id
  FROM raw
  WHERE p_level = 'boonz' AND pod_product_id IS NOT NULL
),
pair_map AS MATERIALIZED (
  SELECT x.pod_product_id, x.machine_id, x.boonz_product_id,
         x.split_pct / NULLIF(sum(x.split_pct) OVER (PARTITION BY x.pod_product_id, x.machine_id), 0) AS share
  FROM (
    SELECT pr.pod_product_id, pr.machine_id, pm.boonz_product_id, pm.split_pct
    FROM pairs pr
    JOIN product_mapping pm
      ON pm.pod_product_id = pr.pod_product_id
     AND pm.status = 'Active'
     AND (
       pm.machine_id = pr.machine_id
       OR (
         (pm.machine_id IS NULL OR pm.is_global_default)
         AND NOT EXISTS (
           SELECT 1 FROM product_mapping p3
           WHERE p3.pod_product_id = pr.pod_product_id
             AND p3.machine_id = pr.machine_id
             AND p3.status = 'Active'
         )
       )
     )
  ) x
),
dist AS (
  SELECT r.txn_date, r.machine_name,
         CASE
           WHEN p_level = 'boonz' AND pmap.boonz_product_id IS NOT NULL
             THEN bp.boonz_product_name
           ELSE r.pod_name
         END AS pname,
         CASE
           WHEN p_level = 'boonz' AND pmap.boonz_product_id IS NOT NULL
             THEN r.qty * pmap.share
           ELSE r.qty
         END AS qty,
         pmap.boonz_product_id AS mapped_id,
         r.pod_product_id
  FROM raw r
  LEFT JOIN pair_map pmap
    ON p_level = 'boonz'
   AND pmap.pod_product_id = r.pod_product_id
   AND pmap.machine_id = r.machine_id
  LEFT JOIN boonz_products bp ON bp.product_id = pmap.boonz_product_id
),
scoped AS (
  SELECT pname, machine_name, qty, txn_date
  FROM dist
  WHERE qty > 0
    AND ((p_level <> 'boonz') OR (mapped_id IS NOT NULL) OR (pod_product_id IS NULL))
),
firsts AS (
  SELECT pname, min(txn_date) AS first_sale FROM scoped GROUP BY 1
),
base AS (
  SELECT * FROM scoped
  WHERE txn_date >= (SELECT start_date FROM win)
    AND txn_date < (SELECT end_date FROM win)
),
cur AS (
  SELECT pname, sum(qty) AS units FROM scoped
  WHERE txn_date >= (SELECT end_date FROM win)
  GROUP BY 1
),
prod AS (
  SELECT pname, sum(qty) AS total_units,
         count(DISTINCT machine_name) AS machine_count
  FROM base GROUP BY 1
),
machine_units AS (
  SELECT pname, machine_name, sum(qty) AS units,
         row_number() OVER (PARTITION BY pname ORDER BY sum(qty) DESC, machine_name) AS rn
  FROM base GROUP BY 1, 2
),
tops AS (
  SELECT pname,
         jsonb_agg(jsonb_build_object('machine', machine_name, 'units', round(units))
                   ORDER BY units DESC) AS top_machines
  FROM machine_units WHERE rn <= 3 GROUP BY 1
),
weekly AS (
  SELECT pname, date_trunc('week', txn_date)::date AS wk, sum(qty) AS units
  FROM base GROUP BY 1, 2
),
arr AS (
  SELECT p.pname,
         array_agg(round(COALESCE(wu.units, 0)) ORDER BY wk.week_start) AS weekly_units
  FROM prod p
  CROSS JOIN weeks wk
  LEFT JOIN weekly wu ON wu.pname = p.pname AND wu.wk = wk.week_start
  GROUP BY 1
),
aw AS (
  SELECT f.pname,
         LEAST(
           (SELECT w FROM params),
           GREATEST(
             1,
             (((SELECT end_date FROM win) - date_trunc('week', f.first_sale)::date) / 7)::integer
           )
         ) AS active_weeks
  FROM firsts f
)
SELECT
  p.pname AS product_name,
  round(p.total_units) AS total_units,
  aw.active_weeks,
  round(p.total_units / aw.active_weeks::numeric, 1) AS avg_per_week,
  p.machine_count,
  COALESCE(t.top_machines, '[]'::jsonb) AS top_machines,
  a.weekly_units,
  (SELECT array_agg(week_start ORDER BY week_start) FROM weeks) AS week_start_dates,
  round(COALESCE(c.units, 0)) AS current_week_units,
  f.first_sale AS first_sale_date,
  (aw.active_weeks < (SELECT w FROM params)) AS is_new
FROM prod p
JOIN firsts f ON f.pname = p.pname
JOIN aw ON aw.pname = p.pname
LEFT JOIN tops t ON t.pname = p.pname
LEFT JOIN arr a ON a.pname = p.pname
LEFT JOIN cur c ON c.pname = p.pname
ORDER BY avg_per_week DESC, total_units DESC;
$$;
