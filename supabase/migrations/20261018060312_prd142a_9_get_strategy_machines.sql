-- PRD-142a 4.1 and 4.2: machine read RPCs for /app/strategy.
-- Both SECURITY DEFINER, operator_admin / superadmin only (is_admin), granted
-- to authenticated, never to anon. Read-only.

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
    SELECT mf.*, m.official_name, m.venue_group, m.location_category, e.era_start, e.venue_label,
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
    'rejected_posture', s.rejected_posture, 'rejected_until', s.rejected_until
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
