-- PRD-142a Phase 4, 6.1, 6.2 and 6.4: product playbook (the Portfolio Map on the
-- fact layer) and product strategy proposals.
--
-- Definitions (handover section 3, spec 6.1 and 6.2):
--   Unit = pod product (product_name_conventions normalised). Weeks = Monday weeks, Dubai.
--   Current window = last 8 complete weeks. Series = 60 complete weeks.
--   velocity = units / machine-weeks with a sale. coverage = average over the
--     weeks of machines selling it / machines in the population with any sale
--     that week (weeks without a sale count as 0).
--   prime = best 4-week window by velocity over the series with >= 16 units and
--     >= 8 machine-weeks (fallback >= 4 when no window reaches 8) and velocity
--     <= 40. retention = current velocity / prime velocity. momentum = units of
--     the last 4 weeks vs the 4 before (up > +15%, down < -15%).
--   maturity from first-ever sale: New < 3 months, Growing 3-6, Established
--     6-12, Mature 12+ (30.44-day months).
--   Medians and the velocity top quartile: products with >= 8 units in the
--     current window, same population.
--   Products in scope: >= 30 units over the series in the population (the
--     handover's filter).
--   Playbook rules in order, first match wins: SUPERSEDED, ANOMALY, INCUBATE
--     (< 3 months), MISSED_THE_WAVE, COOLED_OFF, (< 8 current units: EXIT at
--     >= 6 months else INCUBATE), DOUBLE_DOWN, PROTECT, REDUCE_REPLACE, then
--     EXIT (>= 6 months) or INCUBATE. "Now below prime" for MISSED_THE_WAVE =
--     retention < 0.7, or coverage < 60% of prime coverage, or current units
--     per week below prime units per week.
--   Product posture proposal (6.4): DOUBLE_DOWN -> GROW (target archetypes =
--     archetypes where its velocity ratio >= 1.2, lowest coverage first, up to
--     2); PROTECT -> HOLD (fuel_risk flag); MISSED_THE_WAVE -> RESOURCE;
--     COOLED_OFF and REDUCE_REPLACE -> DRAIN; EXIT -> EXIT; INCUBATE -> HOLD
--     with a new flag. Proposals are made on the Boonz population (the one
--     procurement fuels); partner rows carry the playbook only.

CREATE TABLE public.product_superseded (
  pod_product_id           uuid PRIMARY KEY REFERENCES public.pod_products(pod_product_id),
  successor_pod_product_id uuid REFERENCES public.pod_products(pod_product_id),
  note                     text,
  created_at               timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.product_superseded (pod_product_id, successor_pod_product_id, note)
SELECT o.pod_product_id, s.pod_product_id, x.note
FROM (VALUES ('Krambals & Zigi', 'Krambals', 'Split into Krambals and Zigi (handover superseded list).'),
             ('Pepsi Mix', 'Pepsi Black', 'Split by flavour (handover superseded list); successor is a guess, CS to confirm.'),
             ('Healthy Cola - Mix', 'Healthy Cola - Cola', 'Renamed (handover superseded list).')) x(old_name, new_name, note)
JOIN pod_products o ON o.pod_product_name = x.old_name
LEFT JOIN pod_products s ON s.pod_product_name = x.new_name;

CREATE TABLE public.product_playbook (
  as_of            date NOT NULL,
  population       text NOT NULL CHECK (population IN ('boonz', 'partner', 'all')),
  pod_product_id   uuid NOT NULL,
  pod_product_name text,
  cluster          text,
  first_sale       date,
  maturity         text,
  months_live      numeric,
  cur_units        numeric,
  cur_machine_weeks int,
  velocity         numeric,
  coverage         numeric,
  momentum         numeric,
  prime_week_start date,
  prime_units      numeric,
  prime_velocity   numeric,
  prime_coverage   numeric,
  prime_weeks_ago  int,
  retention        numeric,
  net_rev_8w       numeric,
  gp_8w            numeric,
  cogs_coverage_8w numeric,
  price_per_unit   numeric,
  wh_status        text,
  weeks_of_cover   numeric,
  open_po_units    numeric,
  deployed_units   numeric,
  weekly_rate      numeric,
  superseded       boolean NOT NULL DEFAULT false,
  anomaly          boolean NOT NULL DEFAULT false,
  playbook         text NOT NULL,
  fuel_risk        boolean NOT NULL DEFAULT false,
  reason           jsonb,
  series_units     numeric[],
  series_machines  int[],
  series_fleet     int[],
  PRIMARY KEY (as_of, population, pod_product_id)
);

CREATE TABLE public.product_strategy (
  pod_product_id    uuid PRIMARY KEY REFERENCES public.pod_products(pod_product_id),
  boonz_product_id  uuid,
  posture           text CHECK (posture IN ('GROW', 'HOLD', 'RESOURCE', 'DRAIN', 'EXIT')),
  posture_proposed  text CHECK (posture_proposed IN ('GROW', 'HOLD', 'RESOURCE', 'DRAIN', 'EXIT')),
  proposed_reason   jsonb,
  proposed_at       timestamptz,
  target_archetypes text[],
  confirmed_at      timestamptz,
  confirmed_by      uuid,
  notes             text,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.product_superseded IS 'PRD-142a 6.1. Renamed or split pods, quarantined from the map. CS extends it when pods are renamed.';
COMMENT ON TABLE public.product_playbook IS 'PRD-142a 6.1/6.2. Nightly Portfolio Map per population (boonz, partner, all) with the playbook label and the numbers that fired it (reason). Built by build_product_playbook().';
COMMENT ON TABLE public.product_strategy IS 'PRD-142a 6.4. Product posture. The nightly job writes posture_proposed, proposed_reason, proposed_at, target_archetypes only; posture is written by set_product_strategy (CS).';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['product_superseded','product_playbook','product_strategy'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_admin((SELECT auth.uid())))', t || '_admin_select', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
  END LOOP;
END $$;

-- Applied through several execute_sql calls (apply_migration and larger
-- execute_sql payloads returned "Invalid or expired requestState"), which is
-- why the build is split into small functions: prepare, clear, insert, propose.

-- Clears the as_of rows and anything older than 400 days.
CREATE OR REPLACE FUNCTION public.strategy_playbook_clear(v_as_of date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  DELETE FROM product_playbook WHERE as_of = v_as_of OR as_of < v_as_of - 400;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.strategy_playbook_clear(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.strategy_playbook_clear(date) TO service_role;

-- Prepare step: builds the session temp tables _wk, _win, _pr, _base, _money,
-- _med that build_product_playbook() reads. Split out only to keep each
-- function under the MCP payload limit; never called on its own.
CREATE OR REPLACE FUNCTION public.strategy_playbook_prepare(v_as_of date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_cw    date := date_trunc('week', v_as_of)::date;      -- current (incomplete) week
  v_w0    date := date_trunc('week', v_as_of)::date - 7 * 60;
  v_c0    date := date_trunc('week', v_as_of)::date - 7 * 8;
BEGIN
  -- Weekly series per population, 'all' = sum of the disjoint populations.
  CREATE TEMP TABLE _wk ON COMMIT DROP AS
  WITH weeks AS (SELECT (v_w0 + 7 * i)::date AS ws, i FROM generate_series(0, 59) i),
  fleet AS (
    SELECT ws, population, sum(n)::int AS n FROM (
      SELECT date_trunc('week', d)::date AS ws, population, count(DISTINCT machine_id) AS n
      FROM fact_machine_daily WHERE d >= v_w0 AND d < v_cw AND units > 0 GROUP BY 1, 2) x
    GROUP BY GROUPING SETS ((ws, population), (ws))
  ),
  pw AS (
    SELECT pod_product_id, week_start AS ws, population, units, net_rev_exvat, machines_selling
    FROM fact_product_weekly WHERE week_start >= v_w0 AND week_start < v_cw
  ),
  pw_all AS (
    SELECT pod_product_id, ws, population, units, machines_selling FROM pw
    UNION ALL
    SELECT pod_product_id, ws, 'all', sum(units), sum(machines_selling) FROM pw GROUP BY 1, 2
  ),
  prods AS (SELECT pod_product_id, population FROM pw_all GROUP BY 1, 2 HAVING sum(units) >= 30)
  SELECT p.pod_product_id, p.population, w.ws, w.i,
         COALESCE(x.units, 0) AS units, COALESCE(x.machines_selling, 0) AS mw,
         COALESCE(f.n, 0) AS fleet
  FROM prods p CROSS JOIN weeks w
  LEFT JOIN pw_all x ON x.pod_product_id = p.pod_product_id AND x.population = p.population AND x.ws = w.ws
  LEFT JOIN fleet f ON f.ws = w.ws AND COALESCE(f.population, 'all') = p.population;

  -- 4-week windows for prime.
  CREATE TEMP TABLE _win ON COMMIT DROP AS
  SELECT pod_product_id, population, ws, i,
         sum(units) OVER w4 AS u4, sum(mw) OVER w4 AS mw4,
         avg(mw::numeric / NULLIF(fleet, 0)) OVER w4 AS cov4,
         count(*) OVER w4 AS nweeks
  FROM _wk
  WINDOW w4 AS (PARTITION BY pod_product_id, population ORDER BY i ROWS BETWEEN CURRENT ROW AND 3 FOLLOWING);

  CREATE TEMP TABLE _pr ON COMMIT DROP AS
  WITH elig AS (
    SELECT *, u4 / NULLIF(mw4, 0) AS v4,
           bool_or(mw4 >= 8 AND u4 >= 16 AND u4 / NULLIF(mw4, 0) <= 40) OVER (PARTITION BY pod_product_id, population) AS any8
    FROM _win WHERE nweeks = 4
  )
  SELECT DISTINCT ON (pod_product_id, population) pod_product_id, population, ws AS prime_ws, u4 AS prime_units,
         v4 AS prime_velocity, cov4 AS prime_coverage
  FROM elig
  WHERE u4 >= 16 AND v4 <= 40 AND mw4 >= CASE WHEN any8 THEN 8 ELSE 4 END
  ORDER BY pod_product_id, population, v4 DESC, ws DESC;

  CREATE TEMP TABLE _base ON COMMIT DROP AS
  SELECT k.pod_product_id, k.population, pp.pod_product_name, strategy_cluster(pp.product_category) AS cluster,
         fs.first_sale,
         round(((v_cw - fs.first_sale) / 30.44)::numeric, 1) AS months_live,
         sum(k.units) FILTER (WHERE k.ws >= v_c0) AS cur_units,
         sum(k.mw) FILTER (WHERE k.ws >= v_c0)::int AS cur_mw,
         avg(k.mw::numeric / NULLIF(k.fleet, 0)) FILTER (WHERE k.ws >= v_c0) AS coverage,
         sum(k.units) FILTER (WHERE k.ws >= v_cw - 28) AS u_last4,
         sum(k.units) FILTER (WHERE k.ws >= v_cw - 56 AND k.ws < v_cw - 28) AS u_prev4,
         sum(k.units) AS series_units_total,
         max(k.units) AS max_week_units,
         (SELECT max(w.u4 / NULLIF(w.mw4, 0)) FROM _win w WHERE w.pod_product_id = k.pod_product_id
            AND w.population = k.population AND w.nweeks = 4 AND w.u4 >= 16) AS raw_max_velocity,
         array_agg(k.units ORDER BY k.i) AS s_units, array_agg(k.mw ORDER BY k.i) AS s_mw, array_agg(k.fleet ORDER BY k.i) AS s_fleet
  FROM _wk k
  JOIN pod_products pp USING (pod_product_id)
  LEFT JOIN LATERAL (SELECT min(d) AS first_sale FROM fact_product_machine_daily f
                     WHERE f.pod_product_id = k.pod_product_id AND (k.population = 'all' OR f.population = k.population)) fs ON true
  GROUP BY k.pod_product_id, k.population, pp.pod_product_name, pp.product_category, fs.first_sale;

  CREATE TEMP TABLE _money ON COMMIT DROP AS
  SELECT f.pod_product_id, pop.population, sum(f.net_rev_exvat) AS net, sum(f.units) AS units,
         sum(f.net_rev_exvat) FILTER (WHERE f.cogs_aed IS NOT NULL) - sum(f.cogs_aed) AS gp_costed,
         sum(f.net_rev_exvat) FILTER (WHERE f.cogs_aed IS NOT NULL) AS net_costed,
         sum(f.units) FILTER (WHERE f.cogs_aed IS NOT NULL) / NULLIF(sum(f.units), 0) AS cogs_cov
  FROM fact_product_machine_daily f
  CROSS JOIN (VALUES ('boonz'), ('partner'), ('all')) pop(population)
  WHERE f.d >= v_c0 AND f.d < v_cw AND (pop.population = 'all' OR f.population = pop.population)
  GROUP BY 1, 2;

  CREATE TEMP TABLE _med ON COMMIT DROP AS
  SELECT population,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY cur_units / NULLIF(cur_mw, 0)) AS med_v,
         percentile_cont(0.75) WITHIN GROUP (ORDER BY cur_units / NULLIF(cur_mw, 0)) AS p75_v,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY coverage) AS med_c
  FROM _base WHERE cur_units >= 8 GROUP BY population;

END;
$$;
REVOKE EXECUTE ON FUNCTION public.strategy_playbook_prepare(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.strategy_playbook_prepare(date) TO service_role;

-- Product posture proposals (6.4) for the Boonz population, from the
-- product_playbook rows of p_as_of. Writes posture_proposed, proposed_reason,
-- proposed_at and target_archetypes only; never posture.
CREATE OR REPLACE FUNCTION public.propose_product_strategy(v_as_of date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_cw date := date_trunc('week', v_as_of)::date;
  v_c0 date := date_trunc('week', v_as_of)::date - 7 * 8;
BEGIN
  INSERT INTO product_strategy (pod_product_id, boonz_product_id, posture_proposed, proposed_reason, proposed_at, target_archetypes, updated_at)
  SELECT p.pod_product_id,
         (SELECT pm.boonz_product_id FROM product_mapping pm WHERE pm.pod_product_id = p.pod_product_id AND pm.status = 'Active'
          ORDER BY pm.is_global_default DESC, pm.split_pct DESC NULLS LAST LIMIT 1),
         CASE p.playbook WHEN 'DOUBLE_DOWN' THEN 'GROW' WHEN 'PROTECT' THEN 'HOLD' WHEN 'MISSED_THE_WAVE' THEN 'RESOURCE'
                         WHEN 'COOLED_OFF' THEN 'DRAIN' WHEN 'REDUCE_REPLACE' THEN 'DRAIN' WHEN 'EXIT' THEN 'EXIT' ELSE 'HOLD' END,
         p.reason || jsonb_build_object('playbook', p.playbook, 'fuel_risk', p.fuel_risk, 'new', p.playbook = 'INCUBATE',
                                        'open_po_units', p.open_po_units),
         now(),
         CASE WHEN p.playbook = 'DOUBLE_DOWN' THEN (
           SELECT array_agg(archetype_code ORDER BY cov, archetype_code) FROM (
             SELECT a.archetype_code,
                    (sum(f.units) / count(DISTINCT (f.machine_id, date_trunc('week', f.d)))) / NULLIF(p.velocity, 0) AS ratio,
                    count(DISTINCT f.machine_id)::numeric
                      / NULLIF((SELECT count(*) FROM machine_archetype_assignment a2 JOIN machine_features mf2 USING (machine_id, as_of)
                                WHERE a2.as_of = a.as_of AND a2.archetype_code = a.archetype_code AND mf2.population = 'boonz'), 0) AS cov
             FROM fact_product_machine_daily f
             JOIN machine_archetype_assignment a ON a.machine_id = f.machine_id AND a.as_of = (SELECT max(as_of) FROM machine_archetype_assignment)
             WHERE f.pod_product_id = p.pod_product_id AND f.population = 'boonz' AND f.d >= v_c0 AND f.d < v_cw
             GROUP BY a.archetype_code, a.as_of
             HAVING (sum(f.units) / count(DISTINCT (f.machine_id, date_trunc('week', f.d)))) / NULLIF(p.velocity, 0) >= 1.2
             ORDER BY cov LIMIT 2) t) END,
         now()
  FROM product_playbook p
  WHERE p.as_of = v_as_of AND p.population = 'boonz' AND p.playbook NOT IN ('SUPERSEDED', 'ANOMALY')
  ON CONFLICT (pod_product_id) DO UPDATE SET
    boonz_product_id = EXCLUDED.boonz_product_id,
    proposed_at = CASE WHEN product_strategy.posture_proposed IS DISTINCT FROM EXCLUDED.posture_proposed THEN now() ELSE product_strategy.proposed_at END,
    posture_proposed = EXCLUDED.posture_proposed,
    proposed_reason = EXCLUDED.proposed_reason,
    target_archetypes = EXCLUDED.target_archetypes,
    updated_at = now();

END;
$$;
REVOKE EXECUTE ON FUNCTION public.propose_product_strategy(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.propose_product_strategy(date) TO service_role;

-- Inserts the playbook rows from the temp tables built by strategy_playbook_prepare().
CREATE OR REPLACE FUNCTION public.strategy_playbook_insert(v_as_of date)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_cw date := date_trunc('week', v_as_of)::date;
  v_n  int;
BEGIN
  INSERT INTO product_playbook (as_of, population, pod_product_id, pod_product_name, cluster, first_sale, maturity, months_live,
    cur_units, cur_machine_weeks, velocity, coverage, momentum, prime_week_start, prime_units, prime_velocity, prime_coverage,
    prime_weeks_ago, retention, net_rev_8w, gp_8w, cogs_coverage_8w, price_per_unit, wh_status, weeks_of_cover, open_po_units,
    deployed_units, weekly_rate, superseded, anomaly, playbook, fuel_risk, reason, series_units, series_machines, series_fleet)
  SELECT v_as_of, b.population, b.pod_product_id, b.pod_product_name, b.cluster, b.first_sale,
         CASE WHEN b.months_live < 3 THEN 'New' WHEN b.months_live < 6 THEN 'Growing' WHEN b.months_live < 12 THEN 'Established' ELSE 'Mature' END,
         b.months_live, b.cur_units, b.cur_mw, round(c.vel, 3), round(b.coverage, 4), round(c.mom, 3),
         pr.prime_ws, pr.prime_units, round(pr.prime_velocity, 3), round(pr.prime_coverage, 4),
         c.prime_ago, round(c.ret, 3),
         round(m.net, 2), round(m.net * (m.gp_costed / NULLIF(m.net_costed, 0)), 2), round(m.cogs_cov, 3),
         round(m.net / NULLIF(m.units, 0), 2),
         s.wh_status, s.weeks_of_cover, s.open_po_units, s.deployed_units, s.weekly_rate,
         c.superseded, c.anomaly, c.playbook,
         c.playbook = 'PROTECT' AND (s.wh_status = 'none' OR COALESCE(s.weeks_of_cover, 99) < 2),
         jsonb_build_object('velocity', round(c.vel, 2), 'median_velocity', round(md.med_v::numeric, 2), 'p75_velocity', round(md.p75_v::numeric, 2),
                            'coverage', round(b.coverage, 3), 'median_coverage', round(md.med_c::numeric, 3),
                            'prime_velocity', round(pr.prime_velocity, 2), 'prime_units', pr.prime_units, 'prime_coverage', round(pr.prime_coverage, 3),
                            'prime_weeks_ago', c.prime_ago, 'retention', round(c.ret, 2), 'current_units', b.cur_units,
                            'months_live', b.months_live, 'wh_status', s.wh_status, 'raw_max_velocity', round(b.raw_max_velocity, 2),
                            'unserved_units_per_week', CASE WHEN c.playbook = 'MISSED_THE_WAVE'
                                THEN round(GREATEST(pr.prime_units / 4.0 - b.cur_units / 8.0, 0), 1) END),
         b.s_units, b.s_mw, b.s_fleet
  FROM _base b
  LEFT JOIN _pr pr USING (pod_product_id, population)
  LEFT JOIN _money m USING (pod_product_id, population)
  LEFT JOIN _med md USING (population)
  LEFT JOIN LATERAL (SELECT * FROM product_supply_daily x WHERE x.pod_product_id = b.pod_product_id ORDER BY x.d DESC LIMIT 1) s ON true
  CROSS JOIN LATERAL (
    SELECT z.*,
      CASE
        WHEN z.superseded THEN 'SUPERSEDED'
        WHEN z.anomaly THEN 'ANOMALY'
        WHEN b.months_live < 3 THEN 'INCUBATE'
        WHEN pr.prime_velocity >= md.med_v AND pr.prime_units >= 20 AND s.wh_status = 'none'
             AND (z.ret < 0.7 OR b.coverage < 0.6 * pr.prime_coverage OR b.cur_units / 8.0 < pr.prime_units / 4.0)
             AND z.prime_ago >= 4 THEN 'MISSED_THE_WAVE'
        WHEN pr.prime_velocity >= md.med_v AND pr.prime_units >= 20 AND z.ret < 0.5 AND COALESCE(s.wh_status, 'none') <> 'none'
             AND z.prime_ago >= 4 THEN 'COOLED_OFF'
        WHEN COALESCE(b.cur_units, 0) < 8 THEN CASE WHEN b.months_live >= 6 THEN 'EXIT' ELSE 'INCUBATE' END
        WHEN z.vel >= md.med_v AND b.coverage < 0.5 AND (z.vel >= md.p75_v OR b.coverage < md.med_c) THEN 'DOUBLE_DOWN'
        WHEN z.vel >= md.med_v THEN 'PROTECT'
        WHEN b.coverage >= md.med_c THEN 'REDUCE_REPLACE'
        WHEN b.months_live >= 6 THEN 'EXIT'
        ELSE 'INCUBATE'
      END AS playbook
    FROM (SELECT
            EXISTS (SELECT 1 FROM product_superseded ps WHERE ps.pod_product_id = b.pod_product_id) AS superseded,
            COALESCE(COALESCE(b.cur_units, 0) = 0 AND (b.raw_max_velocity > 40 OR b.max_week_units >= 0.6 * b.series_units_total), false) AS anomaly,
            b.cur_units / NULLIF(b.cur_mw, 0) AS vel,
            (b.cur_units / NULLIF(b.cur_mw, 0)) / NULLIF(pr.prime_velocity, 0) AS ret,
            b.u_last4 / NULLIF(b.u_prev4, 0) - 1 AS mom,
            CASE WHEN pr.prime_ws IS NOT NULL THEN ((v_cw - (pr.prime_ws + 28)) / 7)::int END AS prime_ago) z
  ) c;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.strategy_playbook_insert(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.strategy_playbook_insert(date) TO service_role;

CREATE OR REPLACE FUNCTION public.build_product_playbook(p_as_of date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '300s'
AS $$
DECLARE
  v_as_of date := COALESCE(p_as_of, (now() AT TIME ZONE 'Asia/Dubai')::date);
  v_cw    date := date_trunc('week', v_as_of)::date;      -- current (incomplete) week
  v_w0    date := date_trunc('week', v_as_of)::date - 7 * 60;
  v_c0    date := date_trunc('week', v_as_of)::date - 7 * 8;
  v_n     int;
BEGIN
  PERFORM strategy_playbook_prepare(v_as_of);

  PERFORM strategy_playbook_clear(v_as_of);
  v_n := strategy_playbook_insert(v_as_of);
  PERFORM propose_product_strategy(v_as_of);
  RETURN jsonb_build_object('as_of', v_as_of, 'rows', v_n,
    'boonz_playbook', (SELECT jsonb_object_agg(playbook, n) FROM (SELECT playbook, count(*) n FROM product_playbook
                        WHERE as_of = v_as_of AND population = 'boonz' GROUP BY 1) t));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.build_product_playbook(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_product_playbook(date) TO service_role;


SELECT public.build_product_playbook(NULL);
