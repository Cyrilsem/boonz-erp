-- PRD-087 P4 v2 — ledger over the last N COMPLETE weeks (Dubai, Mon-start);
-- the in-progress week is reported separately (current_week_units) and does
-- NOT dilute avg_per_week. Active-week basis + refund exclusion unchanged.
DROP FUNCTION IF EXISTS public.get_product_velocity_ledger(integer, text);
CREATE OR REPLACE FUNCTION public.get_product_velocity_ledger(
  p_weeks integer DEFAULT 6,
  p_scope text DEFAULT 'non_vox'
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
  -- the last w COMPLETE weeks, oldest -> newest (current week excluded)
  SELECT gs AS idx,
         (p.cur_week_start - ((p.w - gs) * 7))::date AS week_start
  FROM params p, generate_series(0, (SELECT w - 1 FROM params)) gs
),
win AS (
  SELECT (SELECT min(week_start) FROM weeks) AS start_date,
         (SELECT cur_week_start FROM params) AS end_date  -- exclusive
),
scoped AS (
  SELECT
    COALESCE(NULLIF(TRIM(pnc.official_name), ''), TRIM(sh.pod_product_name)) AS pname,
    m.official_name AS machine_name,
    sh.qty,
    (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date AS txn_date
  FROM sales_history sh
  JOIN machines m ON m.machine_id = sh.machine_id
  LEFT JOIN product_name_conventions pnc
    ON lower(TRIM(pnc.original_name)) = lower(TRIM(sh.pod_product_name))
  WHERE sh.delivery_status IN ('Success', 'Successful')
    AND NOT (COALESCE(sh.refunded_amount, 0) > 0
             AND COALESCE(sh.refunded_amount, 0) >= COALESCE(sh.paid_amount, 0))
    AND COALESCE(m.venue_group, '') <> 'WH'
    AND upper(m.official_name) NOT LIKE 'WH%'
    AND (
      p_scope = 'all'
      OR (p_scope = 'non_vox' AND upper(m.official_name) NOT LIKE 'VOX%')
      OR (p_scope = 'vox' AND upper(m.official_name) LIKE 'VOX%')
      OR (p_scope NOT IN ('all', 'non_vox', 'vox') AND m.venue_group = p_scope)
    )
),
firsts AS (
  SELECT pname, min(txn_date) AS first_sale
  FROM scoped
  GROUP BY 1
),
base AS (
  SELECT * FROM scoped
  WHERE txn_date >= (SELECT start_date FROM win)
    AND txn_date < (SELECT end_date FROM win)
),
cur AS (
  SELECT pname, sum(qty) AS units
  FROM scoped
  WHERE txn_date >= (SELECT end_date FROM win)
  GROUP BY 1
),
prod AS (
  SELECT pname,
         sum(qty) AS total_units,
         count(DISTINCT machine_name) AS machine_count
  FROM base
  GROUP BY 1
),
machine_units AS (
  SELECT pname, machine_name, sum(qty) AS units,
         row_number() OVER (PARTITION BY pname ORDER BY sum(qty) DESC, machine_name) AS rn
  FROM base
  GROUP BY 1, 2
),
tops AS (
  SELECT pname,
         jsonb_agg(jsonb_build_object('machine', machine_name, 'units', units)
                   ORDER BY units DESC) AS top_machines
  FROM machine_units
  WHERE rn <= 3
  GROUP BY 1
),
weekly AS (
  SELECT pname, date_trunc('week', txn_date)::date AS wk, sum(qty) AS units
  FROM base
  GROUP BY 1, 2
),
arr AS (
  SELECT p.pname,
         array_agg(COALESCE(wu.units, 0) ORDER BY wk.week_start) AS weekly_units
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
  p.total_units,
  aw.active_weeks,
  round(p.total_units / aw.active_weeks::numeric, 1) AS avg_per_week,
  p.machine_count,
  COALESCE(t.top_machines, '[]'::jsonb) AS top_machines,
  a.weekly_units,
  (SELECT array_agg(week_start ORDER BY week_start) FROM weeks) AS week_start_dates,
  COALESCE(c.units, 0) AS current_week_units,
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

COMMENT ON FUNCTION public.get_product_velocity_ledger(integer, text) IS
'PRD-087: live product velocity ledger over last N complete Dubai weeks (active-week basis, refund-excluded, current partial week reported separately). Scopes: non_vox | vox | all | <venue_group>. Read-only.';
