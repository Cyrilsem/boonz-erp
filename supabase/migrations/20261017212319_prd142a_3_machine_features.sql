-- PRD-142a Phase 1, item 3.3: machine feature snapshot and ramp curve.
--
-- One row per machine with an open era per as_of day (yesterday, Dubai),
-- 400 days kept. Window = last 90 days inside the current era (fewer for
-- younger machines; every *_90 figure is per active era day, not per 90).
--
-- Defaults (logged in docs/prds/PRD-142-log.md):
--   weekend = Saturday and Sunday (UAE weekend since 2022).
--   dead shelf = a shelf in use (current product, or a sale in the window)
--     selling less than one unit per 14 active days in the window.
--   drinks = boonz_products.attr_drink of the pod's main mapped product.
--   cv_monthly_12 = stddev_samp / avg of monthly net revenue over the last
--     12 full calendar months inside the era; NULL under 4 full months.
--   trend_30_vs_90 = avg daily net rev last 30 days / avg daily prior 60
--     days - 1; NULL when the prior window has under 30 era days.
--   ramp_index (age < 90 days) = cumulative net rev at age N / median
--     cumulative net rev at age N of the same population's eras whose
--     inception is inside the fact window (Boonz vs Boonz, partner vs
--     partner; never blended).

CREATE TABLE public.machine_features (
  machine_id             uuid NOT NULL,
  as_of                  date NOT NULL,
  era_id                 uuid NOT NULL,
  population             text NOT NULL,
  inception              date,
  age_days               int,
  active_days_90         int,
  rev_day_90             numeric,
  units_day_90           numeric,
  gp_day_90              numeric,
  ticket_90              numeric,
  units_per_basket_90    numeric,
  card_share_90          numeric,
  peak_hour_share_90     numeric,
  peak_hours_90          int[],
  weekend_share_90       numeric,
  weekday_lunch_share_90 numeric,
  drinks_share_90        numeric,
  top5_shelf_share_90    numeric,
  dead_shelf_pct_90      numeric,
  shelves_configured     int,
  cv_monthly_12          numeric,
  trend_30_vs_90         numeric,
  ramp_index             numeric,
  created_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (machine_id, as_of)
);
CREATE INDEX machine_features_as_of_idx ON public.machine_features (as_of);

CREATE TABLE public.strategy_ramp_curve (
  population      text NOT NULL,
  day_index       int NOT NULL,
  median_cum_rev  numeric,
  median_cum_units numeric,
  eras            int NOT NULL,
  built_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (population, day_index)
);

COMMENT ON TABLE public.machine_features IS 'PRD-142a 3.3. Nightly machine feature snapshot (current era, 90-day window). Built by build_machine_features().';
COMMENT ON TABLE public.strategy_ramp_curve IS 'PRD-142a 3.3. Fleet median cumulative net rev and units by day index from first sale in an era (day 1 = inception), per population, eras with inception inside the fact window. Up to day 365.';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['machine_features','strategy_ramp_curve'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_admin((SELECT auth.uid())))', t || '_admin_select', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.build_machine_features(p_as_of date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '300s'
AS $$
DECLARE
  v_t0    timestamptz := clock_timestamp();
  v_as_of date := COALESCE(p_as_of, (now() AT TIME ZONE 'Asia/Dubai')::date - 1);
  v_fmin  date;
  v_n     int;
BEGIN
  SELECT min(d) INTO v_fmin FROM fact_machine_daily;

  -- Era inception (first sale inside each era) and day index per fact row.
  CREATE TEMP TABLE _inc ON COMMIT DROP AS
  SELECT e.era_id, e.machine_id, f.population,
         (SELECT min(x.d) FROM fact_machine_daily x WHERE x.era_id = e.era_id AND x.units > 0) AS inception,
         e.era_end
  FROM machine_eras e
  JOIN LATERAL (SELECT population FROM fact_machine_daily x WHERE x.machine_id = e.machine_id LIMIT 1) f ON true;

  -- Ramp curve: eras whose inception is inside the fact window.
  DELETE FROM strategy_ramp_curve WHERE true;
  INSERT INTO strategy_ramp_curve (population, day_index, median_cum_rev, median_cum_units, eras)
  WITH c AS (
    SELECT i.population, i.era_id, (f.d - i.inception + 1) AS k,
           sum(f.net_rev_exvat) OVER (PARTITION BY i.era_id ORDER BY f.d) AS cum_rev,
           sum(f.units) OVER (PARTITION BY i.era_id ORDER BY f.d) AS cum_units
    FROM _inc i
    JOIN fact_machine_daily f ON f.era_id = i.era_id AND f.d >= i.inception
    WHERE i.inception IS NOT NULL AND i.inception > v_fmin
  )
  SELECT population, k,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY cum_rev),
         percentile_cont(0.5) WITHIN GROUP (ORDER BY cum_units),
         count(*)
  FROM c WHERE k BETWEEN 1 AND 365
  GROUP BY population, k;

  -- Shelves in use: a current product on the shelf (v_shelf_capacity) or a sale in the window.
  -- Configured but empty shelves (e.g. the unused B to E cabinets on AMZ) are not counted.
  CREATE TEMP TABLE _cap_live ON COMMIT DROP AS
  SELECT DISTINCT machine_id, shelf_code FROM v_shelf_capacity WHERE current_product IS NOT NULL;

  DELETE FROM machine_features WHERE as_of = v_as_of OR as_of < v_as_of - 400;

  INSERT INTO machine_features (machine_id, as_of, era_id, population, inception, age_days, active_days_90,
    rev_day_90, units_day_90, gp_day_90, ticket_90, units_per_basket_90, card_share_90,
    peak_hour_share_90, peak_hours_90, weekend_share_90, weekday_lunch_share_90, drinks_share_90,
    top5_shelf_share_90, dead_shelf_pct_90, shelves_configured, cv_monthly_12, trend_30_vs_90, ramp_index)
  WITH cur AS (
    SELECT i.era_id, i.machine_id, i.population, i.inception,
           GREATEST(COALESCE(i.inception, v_as_of), v_as_of - 89) AS w_from
    FROM _inc i
    WHERE i.era_end IS NULL
  ),
  fw AS (
    SELECT f.*
    FROM cur c JOIN fact_machine_daily f ON f.era_id = c.era_id AND f.d BETWEEN c.w_from AND v_as_of
  ),
  base AS (
    SELECT machine_id, count(*) AS n_days, sum(units) AS units, sum(net_rev_exvat) AS net,
           sum(gross_profit_aed) AS gp, count(gross_profit_aed) AS gp_days, sum(baskets) AS baskets,
           sum(card_txns) AS card, sum(baskets) FILTER (WHERE card_txns IS NOT NULL) AS card_base,
           sum(units) FILTER (WHERE extract(isodow FROM d) IN (6, 7)) AS wkend_units
    FROM fw GROUP BY machine_id
  ),
  hrs AS (
    SELECT fw.machine_id, h.idx - 1 AS hr,
           sum(h.v::numeric) AS u,
           sum(h.v::numeric) FILTER (WHERE extract(isodow FROM fw.d) BETWEEN 1 AND 5) AS u_wkday
    FROM fw CROSS JOIN LATERAL jsonb_array_elements_text(fw.hour_profile) WITH ORDINALITY h(v, idx)
    WHERE fw.hour_profile IS NOT NULL
    GROUP BY 1, 2
  ),
  peak AS (
    SELECT machine_id,
           sum(u) FILTER (WHERE rn <= 3) / NULLIF(sum(u), 0) AS peak_share,
           array_agg(hr ORDER BY rn) FILTER (WHERE rn <= 3) AS peak_hours,
           sum(u_wkday) FILTER (WHERE hr BETWEEN 11 AND 14) / NULLIF(sum(u), 0) AS lunch_share
    FROM (SELECT *, row_number() OVER (PARTITION BY machine_id ORDER BY u DESC, hr) AS rn FROM hrs) x
    GROUP BY machine_id
  ),
  drinks AS (
    SELECT c.machine_id,
           sum(p.units) FILTER (WHERE bp.attr_drink) / NULLIF(sum(p.units), 0) AS share
    FROM cur c
    JOIN fact_product_machine_daily p ON p.era_id = c.era_id AND p.d BETWEEN c.w_from AND v_as_of
    LEFT JOIN boonz_products bp ON bp.product_id = p.boonz_product_id
    GROUP BY c.machine_id
  ),
  shelf_units AS (
    SELECT sc.machine_id, sc.shelf_code, COALESCE(sum(s.units), 0) AS units
    FROM cur c
    JOIN shelf_configurations sc ON sc.machine_id = c.machine_id AND NOT COALESCE(sc.is_phantom, false)
    LEFT JOIN fact_shelf_daily s ON s.machine_id = sc.machine_id AND s.shelf_code = sc.shelf_code
                                AND s.era_id = c.era_id AND s.d BETWEEN c.w_from AND v_as_of
    GROUP BY 1, 2
    HAVING COALESCE(sum(s.units), 0) > 0
        OR EXISTS (SELECT 1 FROM _cap_live l WHERE l.machine_id = sc.machine_id AND l.shelf_code = sc.shelf_code)
  ),
  shelves AS (
    SELECT su.machine_id, count(*) AS n_shelves,
           count(*) FILTER (WHERE su.units < b.n_days / 14.0) AS n_dead,
           (SELECT sum(units) FROM (SELECT units FROM shelf_units x WHERE x.machine_id = su.machine_id ORDER BY units DESC LIMIT 5) t)
             / NULLIF(sum(su.units), 0) AS top5
    FROM shelf_units su JOIN base b USING (machine_id)
    GROUP BY su.machine_id
  ),
  months AS (
    SELECT c.machine_id, date_trunc('month', f.d)::date AS mth, sum(f.net_rev_exvat) AS net, count(*) AS days
    FROM cur c JOIN fact_machine_daily f ON f.era_id = c.era_id
    WHERE f.d >= GREATEST(c.inception, (date_trunc('month', v_as_of + 1) - interval '12 months')::date)
      AND f.d < date_trunc('month', v_as_of + 1)::date
    GROUP BY 1, 2
  ),
  cv AS (
    SELECT machine_id,
           CASE WHEN count(*) FILTER (WHERE days = extract(day FROM (mth + interval '1 month' - interval '1 day'))) >= 4
             THEN stddev_samp(net) FILTER (WHERE days = extract(day FROM (mth + interval '1 month' - interval '1 day')))
                  / NULLIF(avg(net) FILTER (WHERE days = extract(day FROM (mth + interval '1 month' - interval '1 day'))), 0)
           END AS cv
    FROM months
    GROUP BY machine_id
  ),
  trend AS (
    SELECT c.machine_id,
           avg(f.net_rev_exvat) FILTER (WHERE f.d > v_as_of - 30) AS last30,
           avg(f.net_rev_exvat) FILTER (WHERE f.d <= v_as_of - 30 AND f.d > v_as_of - 90) AS prior60,
           count(*) FILTER (WHERE f.d <= v_as_of - 30 AND f.d > v_as_of - 90) AS prior_days
    FROM cur c JOIN fact_machine_daily f ON f.era_id = c.era_id AND f.d > v_as_of - 90 AND f.d <= v_as_of AND f.d >= c.inception
    GROUP BY c.machine_id
  ),
  ramp AS (
    SELECT c.machine_id,
           (SELECT sum(f.net_rev_exvat) FROM fact_machine_daily f WHERE f.era_id = c.era_id AND f.d BETWEEN c.inception AND v_as_of)
             / NULLIF((SELECT rc.median_cum_rev FROM strategy_ramp_curve rc
                       WHERE rc.population = c.population AND rc.day_index = (v_as_of - c.inception + 1)), 0) AS ri
    FROM cur c WHERE c.inception IS NOT NULL AND v_as_of - c.inception + 1 < 90
  )
  SELECT c.machine_id, v_as_of, c.era_id, c.population, c.inception,
         CASE WHEN c.inception IS NOT NULL THEN v_as_of - c.inception + 1 END,
         b.n_days,
         round(b.net / NULLIF(b.n_days, 0), 2),
         round(b.units / NULLIF(b.n_days, 0), 2),
         CASE WHEN b.gp_days > 0 THEN round(b.gp / b.n_days, 2) END,
         round(b.net / NULLIF(b.baskets, 0), 2),
         round(b.units / NULLIF(b.baskets, 0), 3),
         round(b.card::numeric / NULLIF(b.card_base, 0), 3),
         round(pk.peak_share, 3), pk.peak_hours,
         round(b.wkend_units / NULLIF(b.units, 0), 3),
         round(pk.lunch_share, 3),
         round(dr.share, 3),
         round(sh.top5, 3),
         round(sh.n_dead::numeric / NULLIF(sh.n_shelves, 0), 3),
         sh.n_shelves,
         round(cv.cv, 3),
         CASE WHEN tr.prior_days >= 30 AND tr.prior60 > 0 THEN round(tr.last30 / tr.prior60 - 1, 3) END,
         round(rp.ri, 3)
  FROM cur c
  LEFT JOIN base b USING (machine_id)
  LEFT JOIN peak pk USING (machine_id)
  LEFT JOIN drinks dr USING (machine_id)
  LEFT JOIN shelves sh USING (machine_id)
  LEFT JOIN cv USING (machine_id)
  LEFT JOIN trend tr USING (machine_id)
  LEFT JOIN ramp rp USING (machine_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('as_of', v_as_of, 'machines', v_n,
    'ramp_curve_rows', (SELECT count(*) FROM strategy_ramp_curve),
    'seconds', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 2));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.build_machine_features(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_machine_features(date) TO service_role;
