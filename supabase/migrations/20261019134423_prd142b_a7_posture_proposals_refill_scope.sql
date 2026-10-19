-- PRD-142b A7: posture proposals restricted to machines with include_in_refill = true.
-- propose_machine_postures: the upsert only covers machines in refill (archetype and KPIs are still
-- computed for every machine and still feed the peer benchmarks); machine_strategy rows of machines
-- outside refill are left untouched. get_strategy_machines: adds in_refill so the UI shows them as
-- "not in refill". Bodies otherwise identical to prd142a_8 and prd142a_9.

CREATE OR REPLACE FUNCTION public.propose_machine_postures(p_as_of date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_as_of date := COALESCE(p_as_of, (SELECT max(as_of) FROM machine_features));
  v_n     int;
BEGIN
  CREATE TEMP TABLE _mf ON COMMIT DROP AS
  SELECT f.*, a.archetype_code, ma.label AS archetype_label,
         GREATEST(COALESCE(f.inception, v_as_of), v_as_of - 89) AS w_from
  FROM machine_features f
  JOIN machine_archetype_assignment a USING (machine_id, as_of)
  JOIN machine_archetypes ma ON ma.code = a.archetype_code
  WHERE f.as_of = v_as_of;

  -- Current lanes and their pod.
  CREATE TEMP TABLE _ln ON COMMIT DROP AS
  SELECT c.machine_id, c.shelf_code, pp.pod_product_id, strategy_cluster(pp.product_category) AS cluster
  FROM v_shelf_capacity c
  JOIN _mf f USING (machine_id)
  LEFT JOIN LATERAL (SELECT official_name FROM product_name_conventions n
                     WHERE n.original_name = c.current_product ORDER BY n.created_at DESC LIMIT 1) pnc ON true
  JOIN pod_products pp ON pp.pod_product_name = COALESCE(pnc.official_name, c.current_product)
  WHERE c.current_product IS NOT NULL;

  -- Rate per lane-day per (machine, pod) over each machine's window.
  CREATE TEMP TABLE _rt ON COMMIT DROP AS
  SELECT s.machine_id, s.pod_product_id, f.archetype_code, f.population, f.age_days,
         sum(s.net_rev_exvat) AS net,
         GREATEST(count(DISTINCT s.shelf_code),
                  (SELECT count(*) FROM _ln l WHERE l.machine_id = s.machine_id AND l.pod_product_id = s.pod_product_id)) AS lanes,
         f.active_days_90 AS days
  FROM fact_shelf_daily s JOIN _mf f USING (machine_id)
  WHERE s.d BETWEEN f.w_from AND v_as_of AND s.pod_product_id IS NOT NULL
  GROUP BY s.machine_id, s.pod_product_id, f.archetype_code, f.population, f.age_days, f.active_days_90;

  -- Lane-level expected vs actual.
  CREATE TEMP TABLE _lane ON COMMIT DROP AS
  SELECT l.machine_id, l.shelf_code, l.pod_product_id, l.cluster, f.active_days_90 AS days,
         COALESCE((SELECT sum(s.net_rev_exvat) FROM fact_shelf_daily s
                   WHERE s.machine_id = l.machine_id AND s.shelf_code = l.shelf_code AND s.d BETWEEN f.w_from AND v_as_of), 0) AS actual,
         COALESCE(
           (SELECT CASE WHEN count(*) >= 3 THEN percentile_cont(0.5) WITHIN GROUP (ORDER BY r.net / NULLIF(r.lanes * r.days, 0)) END
            FROM _rt r WHERE r.pod_product_id = l.pod_product_id AND r.machine_id <> l.machine_id
              AND r.archetype_code = f.archetype_code AND r.population = f.population AND r.age_days >= 90),
           (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY r.net / NULLIF(r.lanes * r.days, 0))
            FROM _rt r WHERE r.pod_product_id = l.pod_product_id AND r.machine_id <> l.machine_id
              AND r.population = f.population AND r.age_days >= 90))::numeric AS peer_rate
  FROM _ln l JOIN _mf f USING (machine_id);

  CREATE TEMP TABLE _bench ON COMMIT DROP AS
  SELECT f.machine_id,
         COALESCE(
           (SELECT CASE WHEN count(*) >= 3 THEN percentile_cont(0.5) WITHIN GROUP (ORDER BY COALESCE(p.gp_day_90, p.rev_day_90)) END
            FROM _mf p WHERE p.archetype_code = f.archetype_code AND p.population = f.population AND p.machine_id <> f.machine_id AND p.age_days >= 90),
           (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY COALESCE(p.gp_day_90, p.rev_day_90))
            FROM _mf p WHERE p.population = f.population AND p.machine_id <> f.machine_id AND p.age_days >= 90))::numeric AS bench_value,
         (SELECT count(*) FROM _mf p WHERE p.archetype_code = f.archetype_code AND p.population = f.population AND p.machine_id <> f.machine_id AND p.age_days >= 90) AS peers,
         CASE WHEN f.gp_day_90 IS NOT NULL THEN 'gp' ELSE 'rev' END AS basis
  FROM _mf f;

  CREATE TEMP TABLE _cat ON COMMIT DROP AS
  WITH lanes AS (SELECT machine_id, cluster, count(*) AS n FROM _ln GROUP BY 1, 2),
  rev AS (
    SELECT p.machine_id, strategy_cluster(pp.product_category) AS cluster, sum(p.net_rev_exvat) AS net
    FROM fact_product_machine_daily p JOIN _mf f USING (machine_id) JOIN pod_products pp USING (pod_product_id)
    WHERE p.d BETWEEN f.w_from AND v_as_of GROUP BY 1, 2
  )
  SELECT COALESCE(l.machine_id, r.machine_id) AS machine_id, COALESCE(l.cluster, r.cluster) AS cluster,
         COALESCE(l.n, 0)::numeric / NULLIF(sum(COALESCE(l.n, 0)) OVER (PARTITION BY COALESCE(l.machine_id, r.machine_id)), 0) AS lane_share,
         COALESCE(r.net, 0) / NULLIF(sum(COALESCE(r.net, 0)) OVER (PARTITION BY COALESCE(l.machine_id, r.machine_id)), 0) AS rev_share
  FROM lanes l FULL JOIN rev r ON r.machine_id = l.machine_id AND r.cluster = l.cluster;

  CREATE TEMP TABLE _prop ON COMMIT DROP AS
  WITH lane_sum AS (
    SELECT machine_id,
           sum(actual) FILTER (WHERE peer_rate IS NOT NULL) AS actual_cov,
           sum(peer_rate * days) FILTER (WHERE peer_rate IS NOT NULL) AS expected_cov,
           count(*) AS lanes, count(*) FILTER (WHERE peer_rate IS NOT NULL) AS lanes_with_peer,
           array_agg(shelf_code ORDER BY actual / NULLIF(peer_rate * days, 0), shelf_code)
             FILTER (WHERE peer_rate > 0 AND actual < 0.4 * peer_rate * days) AS under_lanes
    FROM _lane GROUP BY machine_id
  ),
  bask AS (
    SELECT f.machine_id,
           avg(d.baskets) FILTER (WHERE d.d > v_as_of - 30) AS b30,
           avg(d.baskets) FILTER (WHERE d.d <= v_as_of - 30 AND d.d > v_as_of - 90) AS b60
    FROM _mf f JOIN fact_machine_daily d ON d.era_id = f.era_id AND d.d > v_as_of - 90 AND d.d <= v_as_of AND d.d >= f.inception
    GROUP BY f.machine_id
  ),
  cat AS (
    SELECT DISTINCT ON (c.machine_id) c.machine_id, pc.cluster_label, c.lane_share, c.rev_share, c.rev_share - c.lane_share AS gap
    FROM _cat c LEFT JOIN (SELECT DISTINCT cluster_code, cluster_label FROM product_clusters) pc ON pc.cluster_code = c.cluster
    WHERE c.rev_share - c.lane_share <= -0.15
    ORDER BY c.machine_id, c.rev_share - c.lane_share
  )
  SELECT f.machine_id, f.population, f.archetype_code, f.archetype_label, f.age_days, f.ramp_index,
         f.dead_shelf_pct_90, f.trend_30_vs_90, b.bench_value, b.peers, b.basis,
         CASE WHEN f.archetype_code = 'RAMPING' THEN f.ramp_index
              ELSE COALESCE(f.gp_day_90, f.rev_day_90) / NULLIF(b.bench_value, 0) END AS perf_index,
         1 - ls.actual_cov / NULLIF(ls.expected_cov, 0) AS mix_gap,
         ls.actual_cov, ls.expected_cov, ls.lanes, ls.lanes_with_peer, ls.under_lanes,
         bk.b30 / NULLIF(bk.b60, 0) - 1 AS basket_trend,
         ct.cluster_label AS over_cluster, ct.lane_share AS over_lane_share, ct.rev_share AS over_rev_share
  FROM _mf f
  LEFT JOIN _bench b USING (machine_id)
  LEFT JOIN lane_sum ls USING (machine_id)
  LEFT JOIN bask bk USING (machine_id)
  LEFT JOIN cat ct USING (machine_id);

  INSERT INTO machine_strategy (machine_id, archetype_code, posture_proposed, proposed_at, proposed_reason, proposal_detail, updated_at)
  SELECT p.machine_id, p.archetype_code, x.posture, now(),
         -- Diagnosis sentence (5.2): generated from the components, no free text.
         concat_ws(' ',
           CASE
             WHEN p.archetype_code = 'RAMPING' THEN
               format('Ramping, day %s: cumulative revenue %s%% of the %s fleet median at the same age.',
                      p.age_days, COALESCE(round(100 * p.ramp_index)::text, 'n/a'), p.population)
             ELSE format('%s %s%% of %s benchmark.', CASE WHEN p.basis = 'gp' THEN 'GP' ELSE 'Rev' END,
                         COALESCE(round(100 * p.perf_index)::text, 'n/a'), p.archetype_label)
           END,
           CASE WHEN p.mix_gap >= 0.25 THEN
             format('Mix gap %s%%%s.', round(100 * p.mix_gap),
                    CASE WHEN cardinality(p.under_lanes) > 0
                      THEN format(': lanes %s under 40%% of peer median', array_to_string(p.under_lanes[1:3], ', ')) ELSE '' END)
           WHEN p.mix_gap IS NOT NULL AND p.mix_gap < 0.25 AND x.inside IS FALSE AND x.strong IS FALSE THEN
             format('Mix on par (gap %s%%).', round(100 * p.mix_gap))
           END,
           CASE WHEN p.dead_shelf_pct_90 >= 0.35 THEN format('Dead shelves %s%%.', round(100 * p.dead_shelf_pct_90)) END,
           CASE WHEN p.over_cluster IS NOT NULL THEN
             format('%s over-shelved (lanes %s%%, rev %s%%).', p.over_cluster, round(100 * p.over_lane_share), round(100 * COALESCE(p.over_rev_share, 0))) END,
           CASE WHEN x.strong IS FALSE AND x.inside IS FALSE THEN
             concat_ws(' ',
               CASE WHEN p.trend_30_vs_90 IS NOT NULL THEN format('Rev %s %s%% vs prior 60 days.',
                 CASE WHEN p.trend_30_vs_90 < 0 THEN 'down' ELSE 'up' END, abs(round(100 * p.trend_30_vs_90))) END,
               CASE WHEN p.basket_trend IS NOT NULL THEN format('Baskets per day %s %s%%.',
                 CASE WHEN p.basket_trend < 0 THEN 'down' ELSE 'up' END, abs(round(100 * p.basket_trend))) END,
               'Outside the machine.')
           END),
         jsonb_build_object(
           'as_of', v_as_of, 'performance_index', round(p.perf_index, 3), 'benchmark_value', round(p.bench_value, 2),
           'benchmark_basis', p.basis, 'benchmark_peers', p.peers, 'mix_gap', round(p.mix_gap, 3),
           'expected_net_90', round(p.expected_cov, 2), 'actual_net_90', round(p.actual_cov, 2),
           'lanes', p.lanes, 'lanes_with_peer', p.lanes_with_peer, 'under_peer_lanes', to_jsonb(p.under_lanes),
           'dead_shelf_pct_90', p.dead_shelf_pct_90, 'trend_30_vs_90', p.trend_30_vs_90, 'basket_trend', round(p.basket_trend, 3),
           'over_shelved_cluster', p.over_cluster, 'strong', x.strong, 'inside', x.inside,
           'cabinet_reset_flag', COALESCE(p.dead_shelf_pct_90 >= 0.5, false)),
         now()
  FROM _prop p
  -- PRD-142b A7: proposals only for machines in refill; rows of machines outside refill stay untouched.
  JOIN machines mr ON mr.machine_id = p.machine_id AND mr.include_in_refill IS TRUE
  CROSS JOIN LATERAL (
    SELECT s.strong, s.inside,
           CASE WHEN s.strong THEN 'PROTECT_GROW' WHEN s.inside THEN 'FIX_MIX' ELSE 'WATCH_ADAPT' END AS posture
    FROM (SELECT
            CASE WHEN p.archetype_code = 'RAMPING' THEN COALESCE(p.ramp_index >= 0.8, false)
                 ELSE COALESCE(p.perf_index >= 0.85, false) END AS strong,
            (COALESCE(p.mix_gap >= 0.25, false) OR COALESCE(p.dead_shelf_pct_90 >= 0.35, false)) AS inside) s
  ) x
  ON CONFLICT (machine_id) DO UPDATE SET
    archetype_code   = EXCLUDED.archetype_code,
    posture_proposed = CASE WHEN machine_strategy.rejected_posture = EXCLUDED.posture_proposed
                             AND machine_strategy.rejected_until >= v_as_of
                            THEN machine_strategy.posture_proposed ELSE EXCLUDED.posture_proposed END,
    proposed_at      = CASE WHEN machine_strategy.posture_proposed IS DISTINCT FROM EXCLUDED.posture_proposed
                            THEN EXCLUDED.proposed_at ELSE machine_strategy.proposed_at END,
    proposed_reason  = EXCLUDED.proposed_reason,
    proposal_detail  = EXCLUDED.proposal_detail,
    updated_at       = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('as_of', v_as_of, 'machines', v_n,
    'proposed', (SELECT jsonb_object_agg(posture_proposed, n) FROM (SELECT posture_proposed, count(*) n FROM machine_strategy GROUP BY 1) t));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.propose_machine_postures(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.propose_machine_postures(date) TO service_role;

CREATE OR REPLACE FUNCTION public.get_strategy_machines(p_population text DEFAULT 'boonz', p_window text DEFAULT '90d',
                                                        p_all_eras boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_as_of date;
  v_out   jsonb;
BEGIN
  IF NOT is_admin(auth.uid()) THEN RAISE EXCEPTION 'get_strategy_machines: operator_admin or superadmin only'; END IF;
  IF p_window NOT IN ('30d', '90d', '12m', 'era') THEN RAISE EXCEPTION 'get_strategy_machines: window must be 30d, 90d, 12m or era'; END IF;
  SELECT max(as_of) INTO v_as_of FROM machine_features;

  WITH f AS (
    SELECT mf.*, m.include_in_refill, m.official_name, m.venue_group, m.location_category, e.era_start, e.venue_label,
           a.archetype_code, ma.label AS archetype_label, a.method AS archetype_method,
           CASE p_window WHEN '30d' THEN v_as_of - 29 WHEN '90d' THEN v_as_of - 89 WHEN '12m' THEN v_as_of - 364 ELSE e.era_start END AS w_from
    FROM machine_features mf
    JOIN machines m USING (machine_id)
    JOIN machine_eras e ON e.era_id = mf.era_id
    LEFT JOIN machine_archetype_assignment a ON a.machine_id = mf.machine_id AND a.as_of = mf.as_of
    LEFT JOIN machine_archetypes ma ON ma.code = a.archetype_code
    WHERE mf.as_of = v_as_of AND (p_population = 'all' OR mf.population = p_population)
  ),
  win AS (
    SELECT f.machine_id, count(*) AS days, sum(d.units) AS units, sum(d.net_rev_exvat) AS net,
           sum(d.gross_profit_aed) AS gp, count(d.gross_profit_aed) AS gp_days,
           sum(d.units * d.cogs_coverage_pct) / NULLIF(sum(d.units), 0) AS cogs_cov
    FROM f JOIN fact_machine_daily d ON d.machine_id = f.machine_id
     AND d.d BETWEEN (CASE WHEN p_all_eras THEN f.w_from ELSE GREATEST(f.w_from, f.era_start) END) AND v_as_of
     AND (p_all_eras OR d.era_id = f.era_id)
    GROUP BY f.machine_id
  ),
  life AS (
    SELECT f.machine_id, sum(d.units) AS units, sum(d.net_rev_exvat) AS net, sum(d.gross_profit_aed) AS gp,
           sum(d.units * d.cogs_coverage_pct) / NULLIF(sum(d.units), 0) AS cogs_cov
    FROM f JOIN fact_machine_daily d ON d.machine_id = f.machine_id AND (p_all_eras OR d.era_id = f.era_id) AND d.d <= v_as_of
    GROUP BY f.machine_id
  ),
  months AS (
    SELECT f.machine_id, date_trunc('month', d.d) AS mth, count(*) AS days, sum(d.units) AS units,
           sum(d.net_rev_exvat) AS net, sum(d.gross_profit_aed) AS gp
    FROM f JOIN fact_machine_daily d ON d.machine_id = f.machine_id AND (p_all_eras OR d.era_id = f.era_id)
     AND d.d >= COALESCE(f.inception, f.era_start) AND d.d < date_trunc('month', v_as_of + 1)
    GROUP BY 1, 2
  ),
  mavg AS (
    SELECT machine_id, count(*) AS full_months, avg(units) AS units, avg(net) AS net, avg(gp) AS gp
    FROM months WHERE days = extract(day FROM (mth + interval '1 month' - interval '1 day'))
    GROUP BY machine_id
  ),
  bench AS (
    SELECT archetype_code, population,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY rev_day_90) AS rev_day_90,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY gp_day_90) AS gp_day_90,
           count(*) AS machines
    FROM f WHERE age_days >= 90 OR archetype_code = 'RAMPING'
    GROUP BY 1, 2
  ),
  chg AS (
    SELECT DISTINCT ON (entity_id) entity_id AS machine_id, changed_at, old_value, new_value
    FROM strategy_change_log
    WHERE entity = 'machine' AND field = 'archetype' AND changed_at > now() - interval '14 days'
    ORDER BY entity_id, changed_at DESC
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'machine_id', f.machine_id, 'official_name', f.official_name, 'venue_group', f.venue_group,
    'location_category', f.location_category, 'population', f.population,
    'era_start', f.era_start, 'venue_label', f.venue_label, 'inception', f.inception, 'age_days', f.age_days,
    'window', p_window, 'window_days', w.days,
    'units', w.units, 'net_rev', round(w.net, 2), 'gross_profit', round(w.gp, 2),
    'units_day', round(w.units / NULLIF(w.days, 0), 2), 'rev_day', round(w.net / NULLIF(w.days, 0), 2),
    'gp_day', CASE WHEN w.gp_days > 0 THEN round(w.gp / w.days, 2) END,
    'cogs_coverage', round(w.cogs_cov, 3),
    'month_full_months', ma.full_months, 'month_units', round(ma.units, 1), 'month_net_rev', round(ma.net, 2), 'month_gp', round(ma.gp, 2),
    'life_units', l.units, 'life_net_rev', round(l.net, 2), 'life_gp', round(l.gp, 2), 'life_cogs_coverage', round(l.cogs_cov, 3),
    'rev_day_90', f.rev_day_90, 'units_day_90', f.units_day_90, 'gp_day_90', f.gp_day_90,
    'ticket', f.ticket_90, 'units_per_basket', f.units_per_basket_90, 'card_share', f.card_share_90,
    'peak_hour_share', f.peak_hour_share_90, 'peak_hours', to_jsonb(f.peak_hours_90),
    'weekend_share', f.weekend_share_90, 'weekday_lunch_share', f.weekday_lunch_share_90, 'drinks_share', f.drinks_share_90,
    'top5_shelf_share', f.top5_shelf_share_90, 'dead_shelf_pct', f.dead_shelf_pct_90, 'shelves', f.shelves_configured,
    'concentration', CASE WHEN f.top5_shelf_share_90 IS NULL THEN NULL WHEN f.top5_shelf_share_90 < 0.45 THEN 'Balanced'
                          WHEN f.top5_shelf_share_90 <= 0.65 THEN 'Skewed' ELSE 'Concentrated' END,
    'cv_monthly_12', f.cv_monthly_12, 'trend_30_vs_90', f.trend_30_vs_90, 'ramp_index', f.ramp_index
  ) || jsonb_build_object(
    'archetype', f.archetype_code, 'archetype_label', f.archetype_label, 'archetype_method', f.archetype_method,
    'archetype_changed_at', c.changed_at, 'archetype_previous', c.old_value,
    'benchmark_rev_day_90', round(b.rev_day_90::numeric, 2), 'benchmark_gp_day_90', round(b.gp_day_90::numeric, 2),
    'benchmark_machines', b.machines,
    'posture', s.posture, 'posture_proposed', s.posture_proposed, 'proposed_at', s.proposed_at,
    'diagnosis', s.proposed_reason, 'performance_index', (s.proposal_detail ->> 'performance_index')::numeric,
    'mix_gap', (s.proposal_detail ->> 'mix_gap')::numeric, 'proposal_detail', s.proposal_detail,
    'params', s.params, 'shelf_overrides', s.shelf_overrides, 'notes', s.notes,
    'confirmed_at', s.confirmed_at, 'review_by', s.review_by,
    'rejected_posture', s.rejected_posture, 'rejected_until', s.rejected_until,
    'in_refill', COALESCE(f.include_in_refill, false)
  ) ORDER BY f.rev_day_90 DESC NULLS LAST), '[]'::jsonb)
  INTO v_out
  FROM f
  LEFT JOIN win w USING (machine_id)
  LEFT JOIN life l USING (machine_id)
  LEFT JOIN mavg ma USING (machine_id)
  LEFT JOIN bench b ON b.archetype_code = f.archetype_code AND b.population = f.population
  LEFT JOIN chg c USING (machine_id)
  LEFT JOIN machine_strategy s USING (machine_id);

  RETURN jsonb_build_object('as_of', v_as_of, 'population', p_population, 'window', p_window, 'all_eras', p_all_eras, 'machines', v_out);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_strategy_machines(text, text, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_strategy_machines(text, text, boolean) TO authenticated;
