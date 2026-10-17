-- PRD-142a Phase 1, item 3.2: daily fact tables and build_strategy_facts().
--
-- Sales basis (Portfolio Map rule, spec 3.2):
--   delivery_status IN ('Success','Successful'); fully refunded rows
--   (refunded_amount > 0 and refunded_amount >= paid_amount) excluded;
--   pod name normalised through product_name_conventions.official_name and
--   matched to pod_products.pod_product_name; WH machines excluded;
--   machine_id NULL rows ignored. Dates are Dubai dates.
-- Revenue: net_rev_exvat = (paid_amount - COALESCE(refunded_amount,0)) / 1.05.
--   Every row is VAT-inclusive (UAE consumer shelf price; see METRICS_REGISTRY).
-- COGS per row (Boonz machines): cost_amount when > 0 (a line total), else
--   qty * unit cost of the pod on that machine, where unit cost is the
--   split_pct-weighted cost of its Active product_mapping rows (machine rows,
--   else the global default), each boonz product costed at the preferred
--   supplier's last_unit_price_aed when > 0, else boonz_products.avg_cost
--   when > 0. NULL when nothing is known.
-- Gross profit (Boonz): margin of the costed rows applied to all revenue:
--   gp = net_rev * (1 - cogs / net_rev_of_costed_rows); NULL with 0 coverage.
--   This keeps GP comparable across machines with partial cost coverage.
-- Partner machines: cogs NULL; gp = net_rev * refill_settings
--   'partner_revenue_share'->>venue_group (NULL when not configured).
-- Card vs cash: classification_name and delivered_from are empty on current
--   rows, so card_txns = least(baskets, Adyen transactions attributed to the
--   machine that Dubai day) on days the Adyen feed has any row; NULL on days
--   it does not; cash_txns = baskets - card_txns.
-- baskets = count distinct split_part(internal_txn_sn, '_', 1).
-- Window: facts are rebuilt from LEAST(p_from, Monday 60 weeks back) to
--   yesterday (Dubai), so fact_product_weekly always holds 60 full weeks.

CREATE OR REPLACE FUNCTION public.strategy_shelf_code(p_goods_slot text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT CASE WHEN p_goods_slot ~ '^[0-9]+-[A-Z][0-9]+$'
    THEN chr(65 + split_part(p_goods_slot, '-', 1)::int)
         || lpad((substring(p_goods_slot FROM '-[A-Z]([0-9]+)$')::int + 1)::text, 2, '0')
  END
$$;
COMMENT ON FUNCTION public.strategy_shelf_code(text) IS
  'PRD-142a. goods_slot "C-Ann" (cabinet, zero-based position) to shelf code chr(65+C)||lpad(n+1,2,0). NULL for itemN basket lines.';

CREATE OR REPLACE FUNCTION public.strategy_size_class(p_official_name text, p_shelf_code text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path TO 'public'
AS $$
  WITH p AS (SELECT substring(p_shelf_code FROM 2)::int AS pos)
  SELECT CASE
    WHEN p_shelf_code IS NULL THEN NULL
    WHEN p_official_name ~ '^VOX[A-Z]*-(1012|1017|1001)-' THEN
      CASE WHEN pos <= 6 THEN 'Large' WHEN pos <= 9 THEN 'Medium' ELSE 'Small' END
    ELSE
      CASE WHEN pos <= 8 THEN 'Small' WHEN pos <= 14 THEN 'Medium' ELSE 'Large' END
  END FROM p
$$;
COMMENT ON FUNCTION public.strategy_size_class(text, text) IS
  'PRD-142a. Physical layout size class. VOX_PREMIUM_13 (machine numbers 1012, 1017, 1001 incl. VOXDFC-1001 after its rename): A01-06 Large, A07-09 Medium, A10-13 Small. STANDARD_16 per cabinet: 01-08 Small, 09-14 Medium, 15-16 Large.';

CREATE TABLE public.fact_machine_daily (
  machine_id        uuid NOT NULL,
  era_id            uuid,
  d                 date NOT NULL,
  population        text NOT NULL,
  units             numeric NOT NULL DEFAULT 0,
  gross_aed         numeric NOT NULL DEFAULT 0,
  refunds_aed       numeric NOT NULL DEFAULT 0,
  net_rev_exvat     numeric NOT NULL DEFAULT 0,
  cogs_aed          numeric,
  cogs_coverage_pct numeric,
  gross_profit_aed  numeric,
  txns              int NOT NULL DEFAULT 0,
  baskets           int NOT NULL DEFAULT 0,
  card_txns         int,
  cash_txns         int,
  hour_profile      jsonb,
  active            boolean NOT NULL,
  PRIMARY KEY (machine_id, d)
);
CREATE INDEX fact_machine_daily_era_idx ON public.fact_machine_daily (era_id, d);

CREATE TABLE public.fact_shelf_daily (
  machine_id     uuid NOT NULL,
  era_id         uuid,
  d              date NOT NULL,
  shelf_code     text NOT NULL,
  size_class     text,
  pod_product_id uuid,
  units          numeric NOT NULL,
  net_rev_exvat  numeric NOT NULL,
  max_stock      int,
  PRIMARY KEY (machine_id, shelf_code, d)
);
CREATE INDEX fact_shelf_daily_d_idx ON public.fact_shelf_daily (machine_id, d);

CREATE TABLE public.fact_product_machine_daily (
  pod_product_id   uuid NOT NULL,
  boonz_product_id uuid,
  machine_id       uuid NOT NULL,
  era_id           uuid,
  d                date NOT NULL,
  units            numeric NOT NULL,
  net_rev_exvat    numeric NOT NULL,
  cogs_aed         numeric,
  population       text NOT NULL,
  PRIMARY KEY (pod_product_id, machine_id, d)
);
CREATE INDEX fact_pmd_product_d_idx ON public.fact_product_machine_daily (pod_product_id, d);
CREATE INDEX fact_pmd_machine_d_idx ON public.fact_product_machine_daily (machine_id, d);

CREATE TABLE public.fact_product_weekly (
  pod_product_id         uuid NOT NULL,
  week_start             date NOT NULL,
  population             text NOT NULL,
  units                  numeric NOT NULL,
  net_rev_exvat          numeric NOT NULL,
  machines_selling       int NOT NULL,
  machine_weeks          int NOT NULL,
  fleet_machines_selling int NOT NULL,
  PRIMARY KEY (pod_product_id, population, week_start)
);
CREATE INDEX fact_pw_week_idx ON public.fact_product_weekly (pod_product_id, week_start);

COMMENT ON TABLE public.fact_machine_daily IS 'PRD-142a 3.2. One row per machine per Dubai day inside an era (zeros included, active=true) plus any sale day outside an era (active=false). Rebuilt nightly by build_strategy_facts.';
COMMENT ON TABLE public.fact_shelf_daily IS 'PRD-142a 3.2. Sparse: one row per machine, shelf (from goods_slot) and Dubai day with a sale. pod_product_id = the pod sold most that day on that shelf. max_stock from v_shelf_capacity (current config).';
COMMENT ON TABLE public.fact_product_machine_daily IS 'PRD-142a 3.2. Sparse: units and ex-VAT net revenue per pod product, machine and Dubai day. boonz_product_id = largest-split Active mapping.';
COMMENT ON TABLE public.fact_product_weekly IS 'PRD-142a 3.2. Portfolio Map weekly series, Monday weeks (Dubai), per population. machine_weeks = machines_selling (one week). fleet_machines_selling = machines in the population with any sale that week. 60 weeks kept; the current partial week is included and flagged by readers.';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['fact_machine_daily','fact_shelf_daily','fact_product_machine_daily','fact_product_weekly'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_admin((SELECT auth.uid())))', t || '_admin_select', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.build_strategy_facts(p_from date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '300s'
AS $$
DECLARE
  v_t0     timestamptz := clock_timestamp();
  v_today  date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_to     date := v_today - 1;
  v_wk0    date := date_trunc('week', v_today)::date - 7 * 60;
  v_from   date;
  v_share  jsonb;
  v_n_mach int; v_n_shelf int; v_n_pmd int; v_n_wk int;
BEGIN
  v_from := LEAST(COALESCE(p_from, v_today - 400), v_wk0);
  SELECT setting_value INTO v_share FROM refill_settings WHERE setting_key = 'partner_revenue_share';

  -- Machines in scope.
  CREATE TEMP TABLE _m ON COMMIT DROP AS
  SELECT machine_id, official_name, venue_group,
         strategy_population(venue_group, official_name) AS population
  FROM machines
  WHERE NOT strategy_is_excluded_machine(venue_group, official_name);

  -- Boonz unit cost.
  CREATE TEMP TABLE _bc ON COMMIT DROP AS
  SELECT bp.product_id AS boonz_product_id,
         COALESCE(sp.price, NULLIF(bp.avg_cost, 0)) AS unit_cost
  FROM boonz_products bp
  LEFT JOIN LATERAL (
    SELECT max(last_unit_price_aed) FILTER (WHERE is_preferred) AS pref,
           max(last_unit_price_aed) AS any_price
    FROM supplier_products s
    WHERE s.boonz_product_id = bp.product_id AND COALESCE(s.last_unit_price_aed, 0) > 0
  ) x ON true
  CROSS JOIN LATERAL (SELECT COALESCE(x.pref, x.any_price) AS price) sp;

  CREATE TEMP TABLE _pnc ON COMMIT DROP AS
  SELECT DISTINCT ON (original_name) original_name, official_name
  FROM product_name_conventions ORDER BY original_name, created_at DESC;

  -- Sales rows.
  CREATE TEMP TABLE _s ON COMMIT DROP AS
  SELECT s.machine_id,
         (s.transaction_date AT TIME ZONE 'Asia/Dubai')::date AS d,
         extract(hour FROM (s.transaction_date AT TIME ZONE 'Asia/Dubai'))::int AS hr,
         pp.pod_product_id,
         COALESCE(s.qty, 0) AS qty,
         COALESCE(s.paid_amount, 0) AS paid,
         COALESCE(s.refunded_amount, 0) AS refunded,
         (COALESCE(s.paid_amount, 0) - COALESCE(s.refunded_amount, 0)) / 1.05 AS net,
         NULLIF(s.cost_amount, 0) AS cost_amount,
         split_part(s.internal_txn_sn, '_', 1) AS basket,
         strategy_shelf_code(s.goods_slot) AS shelf_code,
         m.population, m.official_name
  FROM sales_history s
  JOIN _m m USING (machine_id)
  LEFT JOIN _pnc pnc ON pnc.original_name = s.pod_product_name
  LEFT JOIN pod_products pp ON pp.pod_product_name = COALESCE(pnc.official_name, s.pod_product_name)
  WHERE s.delivery_status IN ('Success', 'Successful')
    AND NOT (COALESCE(s.refunded_amount, 0) > 0 AND COALESCE(s.refunded_amount, 0) >= COALESCE(s.paid_amount, 0))
    AND s.transaction_date >= (v_from::timestamp AT TIME ZONE 'Asia/Dubai')
    AND s.transaction_date <  ((v_to + 1)::timestamp AT TIME ZONE 'Asia/Dubai');

  -- Pod unit cost per machine (machine-specific Active mappings, else global default).
  CREATE TEMP TABLE _pc ON COMMIT DROP AS
  WITH pairs AS (SELECT DISTINCT machine_id, pod_product_id FROM _s WHERE pod_product_id IS NOT NULL),
  maps AS (
    SELECT p.machine_id, p.pod_product_id, pm.boonz_product_id, COALESCE(NULLIF(pm.split_pct, 0), 100) AS w
    FROM pairs p
    JOIN product_mapping pm ON pm.pod_product_id = p.pod_product_id AND pm.status = 'Active'
     AND (pm.machine_id = p.machine_id
          OR (pm.machine_id IS NULL AND pm.is_global_default
              AND NOT EXISTS (SELECT 1 FROM product_mapping x WHERE x.pod_product_id = p.pod_product_id
                              AND x.machine_id = p.machine_id AND x.status = 'Active')))
  )
  SELECT mp.machine_id, mp.pod_product_id,
         sum(mp.w * bc.unit_cost) FILTER (WHERE bc.unit_cost IS NOT NULL)
           / NULLIF(sum(mp.w) FILTER (WHERE bc.unit_cost IS NOT NULL), 0) AS unit_cost,
         (array_agg(mp.boonz_product_id ORDER BY mp.w DESC))[1] AS boonz_product_id
  FROM maps mp LEFT JOIN _bc bc USING (boonz_product_id)
  GROUP BY 1, 2;

  CREATE TEMP TABLE _sc ON COMMIT DROP AS
  SELECT s.*,
         CASE WHEN s.population = 'partner' THEN NULL
              ELSE COALESCE(s.cost_amount, s.qty * pc.unit_cost) END AS cogs,
         pc.boonz_product_id
  FROM _s s
  LEFT JOIN _pc pc USING (machine_id, pod_product_id);

  -- Eras lookup.
  CREATE TEMP TABLE _e ON COMMIT DROP AS
  SELECT era_id, machine_id, era_start, COALESCE(era_end, v_to) AS era_to FROM machine_eras;

  -- Adyen card counts per machine-day.
  CREATE TEMP TABLE _a ON COMMIT DROP AS
  SELECT attributed_machine_id AS machine_id, (creation_date AT TIME ZONE 'Asia/Dubai')::date AS d, count(*) AS n
  FROM v_adyen_transactions_attributed
  WHERE creation_date >= (v_from::timestamp AT TIME ZONE 'Asia/Dubai') AND attributed_machine_id IS NOT NULL
  GROUP BY 1, 2;
  CREATE TEMP TABLE _ad ON COMMIT DROP AS SELECT DISTINCT d FROM _a;

  -- fact_machine_daily
  DELETE FROM fact_machine_daily WHERE d >= v_from;
  INSERT INTO fact_machine_daily (machine_id, era_id, d, population, units, gross_aed, refunds_aed, net_rev_exvat,
    cogs_aed, cogs_coverage_pct, gross_profit_aed, txns, baskets, card_txns, cash_txns, hour_profile, active)
  WITH days AS (
    SELECT e.machine_id, e.era_id, gs::date AS d, true AS active
    FROM _e e CROSS JOIN LATERAL generate_series(GREATEST(e.era_start, v_from), LEAST(e.era_to, v_to), interval '1 day') gs
    WHERE e.era_to >= v_from
    UNION ALL
    SELECT DISTINCT s.machine_id, NULL::uuid, s.d, false
    FROM _sc s
    WHERE NOT EXISTS (SELECT 1 FROM _e e WHERE e.machine_id = s.machine_id AND s.d BETWEEN e.era_start AND e.era_to)
  ),
  agg AS (
    SELECT machine_id, d,
           sum(qty) AS units, sum(paid) AS gross, sum(refunded) AS refunds, sum(net) AS net,
           sum(cogs) AS cogs,
           sum(qty) FILTER (WHERE cogs IS NOT NULL) AS units_costed,
           sum(net) FILTER (WHERE cogs IS NOT NULL) AS net_costed,
           count(*) AS txns, count(DISTINCT basket) AS baskets
    FROM _sc GROUP BY 1, 2
  ),
  hrs AS (
    SELECT md.machine_id, md.d, jsonb_agg(COALESCE(q.u, 0) ORDER BY h) AS hp
    FROM (SELECT DISTINCT machine_id, d FROM _sc) md
    CROSS JOIN generate_series(0, 23) h
    LEFT JOIN (SELECT machine_id, d, hr, sum(qty) AS u FROM _sc GROUP BY 1, 2, 3) q
      ON q.machine_id = md.machine_id AND q.d = md.d AND q.hr = h
    GROUP BY md.machine_id, md.d
  )
  SELECT dy.machine_id, dy.era_id, dy.d, m.population,
         COALESCE(a.units, 0), COALESCE(a.gross, 0), COALESCE(a.refunds, 0), COALESCE(a.net, 0),
         a.cogs,
         CASE WHEN COALESCE(a.units, 0) > 0 THEN round(COALESCE(a.units_costed, 0) / a.units, 4) END,
         CASE
           WHEN m.population = 'partner' THEN
             COALESCE(a.net, 0) * NULLIF(v_share ->> m.venue_group, '')::numeric
           WHEN COALESCE(a.units, 0) = 0 THEN 0
           WHEN COALESCE(a.net_costed, 0) > 0 THEN a.net * (1 - a.cogs / a.net_costed)
         END,
         COALESCE(a.txns, 0), COALESCE(a.baskets, 0),
         CASE WHEN ad.d IS NOT NULL THEN LEAST(COALESCE(a.baskets, 0), COALESCE(cd.n, 0))::int END,
         CASE WHEN ad.d IS NOT NULL THEN (COALESCE(a.baskets, 0) - LEAST(COALESCE(a.baskets, 0), COALESCE(cd.n, 0)))::int END,
         h.hp,
         dy.active
  FROM days dy
  JOIN _m m USING (machine_id)
  LEFT JOIN agg a USING (machine_id, d)
  LEFT JOIN hrs h USING (machine_id, d)
  LEFT JOIN _ad ad ON ad.d = dy.d
  LEFT JOIN _a cd ON cd.machine_id = dy.machine_id AND cd.d = dy.d;
  GET DIAGNOSTICS v_n_mach = ROW_COUNT;

  -- fact_shelf_daily (v_shelf_capacity is expensive: materialise it once)
  CREATE TEMP TABLE _cap ON COMMIT DROP AS
  SELECT machine_id, shelf_code, max(max_stock) AS max_stock FROM v_shelf_capacity GROUP BY 1, 2;
  DELETE FROM fact_shelf_daily WHERE d >= v_from;
  INSERT INTO fact_shelf_daily (machine_id, era_id, d, shelf_code, size_class, pod_product_id, units, net_rev_exvat, max_stock)
  SELECT s.machine_id,
         (SELECT e.era_id FROM _e e WHERE e.machine_id = s.machine_id AND s.d BETWEEN e.era_start AND e.era_to LIMIT 1),
         s.d, s.shelf_code, strategy_size_class(min(s.official_name), s.shelf_code),
         (array_agg(s.pod_product_id ORDER BY s.qty DESC) FILTER (WHERE s.pod_product_id IS NOT NULL))[1],
         sum(s.qty), sum(s.net),
         max(c.max_stock)
  FROM _sc s
  LEFT JOIN _cap c ON c.machine_id = s.machine_id AND c.shelf_code = s.shelf_code
  WHERE s.shelf_code IS NOT NULL
  GROUP BY s.machine_id, s.d, s.shelf_code;
  GET DIAGNOSTICS v_n_shelf = ROW_COUNT;

  -- fact_product_machine_daily
  DELETE FROM fact_product_machine_daily WHERE d >= v_from;
  INSERT INTO fact_product_machine_daily (pod_product_id, boonz_product_id, machine_id, era_id, d, units, net_rev_exvat, cogs_aed, population)
  SELECT s.pod_product_id, min(s.boonz_product_id::text)::uuid, s.machine_id,
         (SELECT e.era_id FROM _e e WHERE e.machine_id = s.machine_id AND s.d BETWEEN e.era_start AND e.era_to LIMIT 1),
         s.d, sum(s.qty), sum(s.net), sum(s.cogs), min(s.population)
  FROM _sc s
  WHERE s.pod_product_id IS NOT NULL
  GROUP BY s.pod_product_id, s.machine_id, s.d;
  GET DIAGNOSTICS v_n_pmd = ROW_COUNT;

  -- fact_product_weekly (60 weeks + current partial week)
  DELETE FROM fact_product_weekly WHERE true;
  INSERT INTO fact_product_weekly (pod_product_id, week_start, population, units, net_rev_exvat, machines_selling, machine_weeks, fleet_machines_selling)
  WITH w AS (
    SELECT pod_product_id, date_trunc('week', d)::date AS ws, population, machine_id, units, net_rev_exvat
    FROM fact_product_machine_daily WHERE d >= v_wk0
  ),
  fleet AS (
    SELECT date_trunc('week', d)::date AS ws, population, count(DISTINCT machine_id) AS n
    FROM fact_machine_daily WHERE d >= v_wk0 AND units > 0 GROUP BY 1, 2
  )
  SELECT w.pod_product_id, w.ws, w.population, sum(w.units), sum(w.net_rev_exvat),
         count(DISTINCT w.machine_id), count(DISTINCT w.machine_id), max(f.n)
  FROM w JOIN fleet f ON f.ws = w.ws AND f.population = w.population
  GROUP BY 1, 2, 3;
  GET DIAGNOSTICS v_n_wk = ROW_COUNT;

  RETURN jsonb_build_object('from', v_from, 'to', v_to, 'week0', v_wk0,
    'fact_machine_daily', v_n_mach, 'fact_shelf_daily', v_n_shelf,
    'fact_product_machine_daily', v_n_pmd, 'fact_product_weekly', v_n_wk,
    'seconds', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 2));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.build_strategy_facts(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_strategy_facts(date) TO service_role;
COMMENT ON FUNCTION public.build_strategy_facts(date) IS
  'PRD-142a 3.2. Idempotent rebuild (delete window, insert) of fact_machine_daily, fact_shelf_daily, fact_product_machine_daily, fact_product_weekly. Card rule: card_txns = least(baskets, Adyen attributed count) on days the Adyen feed covers, else NULL (classification_name / delivered_from are empty). VAT: all rows VAT-inclusive, /1.05.';
