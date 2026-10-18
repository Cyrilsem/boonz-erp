-- PRD-142a 4.2: machine detail RPC for /app/strategy.
-- SECURITY DEFINER, operator_admin / superadmin only (is_admin), granted
-- to authenticated, never to anon. Read-only.

CREATE OR REPLACE FUNCTION public.get_strategy_machine_detail(p_machine_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_as_of date;
  f       record;
  v_from  date;
  v_out   jsonb;
BEGIN
  IF NOT is_admin(auth.uid()) THEN RAISE EXCEPTION 'get_strategy_machine_detail: operator_admin or superadmin only'; END IF;
  SELECT max(as_of) INTO v_as_of FROM machine_features;
  SELECT mf.*, m.official_name, m.venue_group, m.building_id, e.era_start
  INTO f
  FROM machine_features mf JOIN machines m USING (machine_id) JOIN machine_eras e ON e.era_id = mf.era_id
  WHERE mf.machine_id = p_machine_id AND mf.as_of = v_as_of;
  IF NOT FOUND THEN RAISE EXCEPTION 'get_strategy_machine_detail: no features for machine %', p_machine_id; END IF;
  v_from := GREATEST(COALESCE(f.inception, v_as_of), v_as_of - 89);

  WITH daily AS (
    SELECT d.d, d.units, round(d.net_rev_exvat, 2) AS net, round(d.gross_profit_aed, 2) AS gp, d.baskets,
           (d.d - f.inception + 1) AS day_index
    FROM fact_machine_daily d WHERE d.era_id = f.era_id AND d.d <= v_as_of ORDER BY d.d
  ),
  adoption AS (
    SELECT dl.day_index, dl.d,
           round(avg(dl.net) OVER w7, 2) AS rev_7d, round(avg(dl.units) OVER w7, 2) AS units_7d,
           round(sum(dl.net) OVER wc, 2) AS cum_rev, sum(dl.units) OVER wc AS cum_units,
           round(rc.median_cum_rev::numeric, 2) AS fleet_cum_rev, round(rc.median_cum_units::numeric, 1) AS fleet_cum_units
    FROM daily dl
    LEFT JOIN strategy_ramp_curve rc ON rc.population = f.population AND rc.day_index = dl.day_index
    WHERE dl.day_index >= 1
    WINDOW w7 AS (ORDER BY dl.d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),
           wc AS (ORDER BY dl.d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
  ),
  monthly AS (
    SELECT mm.*, mm.days = extract(day FROM (mm.month + interval '1 month' - interval '1 day')) AS full_month
    FROM (SELECT date_trunc('month', d)::date AS month, count(*) AS days, sum(units) AS units, sum(net) AS net, sum(gp) AS gp
          FROM daily WHERE d >= f.inception GROUP BY 1) mm
  ),
  hours AS (
    SELECT h.idx - 1 AS hour, sum(h.v::numeric) AS units
    FROM fact_machine_daily d CROSS JOIN LATERAL jsonb_array_elements_text(d.hour_profile) WITH ORDINALITY h(v, idx)
    WHERE d.era_id = f.era_id AND d.d BETWEEN v_from AND v_as_of AND d.hour_profile IS NOT NULL
    GROUP BY 1
  ),
  wdays AS (
    SELECT extract(isodow FROM d.d)::int AS isodow, count(*) AS days, sum(d.units) AS units, round(sum(d.net_rev_exvat), 2) AS net
    FROM fact_machine_daily d WHERE d.era_id = f.era_id AND d.d BETWEEN v_from AND v_as_of GROUP BY 1
  ),
  lanes AS (
    SELECT c.shelf_code, c.max_stock, c.current_stock, c.current_product, pp.pod_product_id, pp.pod_product_name,
           strategy_size_class(f.official_name, c.shelf_code) AS size_class,
           strategy_cluster(pp.product_category) AS cluster
    FROM v_shelf_capacity c
    LEFT JOIN LATERAL (SELECT official_name FROM product_name_conventions n
                       WHERE n.original_name = c.current_product ORDER BY n.created_at DESC LIMIT 1) pnc ON true
    LEFT JOIN pod_products pp ON pp.pod_product_name = COALESCE(pnc.official_name, c.current_product)
    WHERE c.machine_id = p_machine_id
  ),
  lane_sales AS (
    SELECT s.shelf_code, sum(s.units) AS units, sum(s.net_rev_exvat) AS net,
           min(s.d) FILTER (WHERE s.pod_product_id = l.pod_product_id) AS first_sale_current
    FROM fact_shelf_daily s JOIN lanes l USING (shelf_code)
    WHERE s.machine_id = p_machine_id AND s.d BETWEEN v_from AND v_as_of
    GROUP BY s.shelf_code
  ),
  fleet_lanes AS (
    -- Every lane of the population over its own machine's 90-day window: units and rev per slot per day.
    SELECT s.machine_id, s.shelf_code, sum(s.units) / NULLIF(mf.active_days_90, 0) AS u_slot_day,
           sum(s.net_rev_exvat) / NULLIF(mf.active_days_90, 0) AS r_slot_day
    FROM fact_shelf_daily s
    JOIN machine_features mf ON mf.machine_id = s.machine_id AND mf.as_of = v_as_of AND mf.population = f.population
    WHERE s.d BETWEEN GREATEST(COALESCE(mf.inception, v_as_of), v_as_of - 89) AND v_as_of
    GROUP BY s.machine_id, s.shelf_code, mf.active_days_90
  ),
  shelf AS (
    SELECT l.shelf_code, l.size_class, l.pod_product_name AS product, l.current_product AS shelf_product_name,
           l.cluster, l.max_stock, l.current_stock,
           round(COALESCE(ls.units, 0) / NULLIF(f.active_days_90, 0), 3) AS units_slot_day,
           round(COALESCE(ls.net, 0) / NULLIF(f.active_days_90, 0), 2) AS rev_slot_day,
           (SELECT round(avg((fl.r_slot_day < COALESCE(ls.net, 0) / NULLIF(f.active_days_90, 0))::int), 3) FROM fleet_lanes fl) AS rev_pct_rank,
           (SELECT round(avg((fl.u_slot_day < COALESCE(ls.units, 0) / NULLIF(f.active_days_90, 0))::int), 3) FROM fleet_lanes fl) AS units_pct_rank,
           CASE WHEN ls.first_sale_current IS NOT NULL THEN v_as_of - ls.first_sale_current + 1 END AS slot_age_days
    FROM lanes l LEFT JOIN lane_sales ls USING (shelf_code)
  ),
  prod AS (
    SELECT p.pod_product_id, pp.pod_product_name, strategy_cluster(pp.product_category) AS cluster,
           sum(p.units) AS units, round(sum(p.net_rev_exvat), 2) AS net,
           round(sum(p.net_rev_exvat) - sum(p.cogs_aed), 2) AS gp_on_costed,
           count(DISTINCT date_trunc('week', p.d)) AS selling_weeks
    FROM fact_product_machine_daily p JOIN pod_products pp USING (pod_product_id)
    WHERE p.machine_id = p_machine_id AND p.d BETWEEN v_from AND v_as_of
    GROUP BY 1, 2, 3
  ),
  vel AS (
    -- Velocity = units per machine per selling week, same population, same 90-day window.
    SELECT p.pod_product_id, p.machine_id, m.venue_group, m.building_id,
           sum(p.units) / count(DISTINCT date_trunc('week', p.d)) AS v
    FROM fact_product_machine_daily p JOIN machines m USING (machine_id)
    WHERE p.population = f.population AND p.d BETWEEN v_as_of - 89 AND v_as_of
      AND p.pod_product_id IN (SELECT pod_product_id FROM prod)
    GROUP BY 1, 2, 3, 4
  ),
  prod2 AS (
    SELECT pr.*, round(pr.units::numeric / NULLIF(pr.selling_weeks, 0), 2) AS velocity_here,
           round(pr.units::numeric / NULLIF(sum(pr.units) OVER (), 0), 3) AS unit_share,
           (SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v.v)::numeric, 2) FROM vel v WHERE v.pod_product_id = pr.pod_product_id) AS velocity_fleet_median,
           (SELECT round(avg(v.v), 2) FROM vel v WHERE v.pod_product_id = pr.pod_product_id AND v.machine_id <> p_machine_id
              AND (v.venue_group = f.venue_group OR (f.building_id IS NOT NULL AND v.building_id = f.building_id))) AS velocity_siblings,
           (SELECT count(*) FROM vel v WHERE v.pod_product_id = pr.pod_product_id) AS fleet_machines
    FROM prod pr
  ),
  catbal AS (
    SELECT COALESCE(a.cluster, b.cluster) AS cluster,
           COALESCE(a.n, 0)::numeric / NULLIF(sum(COALESCE(a.n, 0)) OVER (), 0) AS lane_share,
           COALESCE(b.net, 0) / NULLIF(sum(COALESCE(b.net, 0)) OVER (), 0) AS rev_share
    FROM (SELECT cluster, count(*) AS n FROM lanes WHERE pod_product_id IS NOT NULL GROUP BY 1) a
    FULL JOIN (SELECT cluster, sum(net) AS net FROM prod GROUP BY 1) b USING (cluster)
  )
  SELECT jsonb_build_object(
    'as_of', v_as_of,
    'machine', jsonb_build_object('machine_id', p_machine_id, 'official_name', f.official_name, 'venue_group', f.venue_group,
                                  'population', f.population, 'era_start', f.era_start, 'inception', f.inception, 'age_days', f.age_days),
    'features', to_jsonb(f),
    'strategy', (SELECT to_jsonb(s) FROM machine_strategy s WHERE s.machine_id = p_machine_id),
    'archetype', (SELECT jsonb_build_object('code', a.archetype_code, 'label', ma.label, 'method', a.method, 'confidence', a.confidence,
                                            'base', a.features ->> 'base_archetype', 'description', ma.description)
                  FROM machine_archetype_assignment a JOIN machine_archetypes ma ON ma.code = a.archetype_code
                  WHERE a.machine_id = p_machine_id AND a.as_of = v_as_of),
    'eras', (SELECT jsonb_agg(jsonb_build_object('era_id', e.era_id, 'venue_label', e.venue_label, 'era_start', e.era_start, 'era_end', e.era_end) ORDER BY e.era_start)
             FROM machine_eras e WHERE e.machine_id = p_machine_id),
    'daily', (SELECT COALESCE(jsonb_agg(to_jsonb(dl) ORDER BY dl.d), '[]'::jsonb) FROM daily dl),
    'adoption', (SELECT COALESCE(jsonb_agg(to_jsonb(ad) ORDER BY ad.day_index), '[]'::jsonb) FROM adoption ad),
    'monthly', (SELECT COALESCE(jsonb_agg(to_jsonb(mo) ORDER BY mo.month), '[]'::jsonb) FROM monthly mo),
    'hours', (SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.hour), '[]'::jsonb) FROM hours h),
    'weekdays', (SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY w.isodow), '[]'::jsonb) FROM wdays w),
    'shelves', (SELECT COALESCE(jsonb_agg(to_jsonb(sh) || jsonb_build_object('quadrant',
                  CASE WHEN sh.product IS NULL AND sh.shelf_product_name IS NULL THEN 'Empty'
                       WHEN sh.slot_age_days IS NOT NULL AND sh.slot_age_days < 14 THEN 'Too new'
                       WHEN COALESCE(sh.units_slot_day, 0) < 1 / 14.0 THEN 'Dead'
                       WHEN sh.rev_pct_rank >= 0.5 AND sh.units_pct_rank >= 0.5 THEN 'Prime'
                       WHEN sh.units_pct_rank >= 0.5 THEN 'Volume-cheap'
                       WHEN sh.rev_pct_rank >= 0.5 THEN 'Premium-slow'
                       ELSE 'Weak' END) ORDER BY sh.shelf_code), '[]'::jsonb) FROM shelf sh),
    'products', (SELECT COALESCE(jsonb_agg(to_jsonb(p2) || jsonb_build_object(
                    'label', CASE WHEN p2.velocity_fleet_median IS NULL OR p2.fleet_machines < 3 THEN 'Too few machines'
                                  WHEN p2.velocity_here >= 1.25 * p2.velocity_fleet_median THEN 'Local hero'
                                  WHEN p2.velocity_here <= 0.75 * p2.velocity_fleet_median THEN 'Underperformer'
                                  ELSE 'On par' END) ORDER BY p2.net DESC), '[]'::jsonb) FROM prod2 p2),
    'category_balance', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'cluster', cb.cluster, 'cluster_label', (SELECT max(cluster_label) FROM product_clusters pc WHERE pc.cluster_code = cb.cluster),
                    'lane_share', round(cb.lane_share, 3), 'rev_share', round(cb.rev_share, 3),
                    'gap', round(cb.rev_share - cb.lane_share, 3),
                    'read', CASE WHEN cb.rev_share - cb.lane_share <= -0.15 THEN 'over-shelved'
                                 WHEN cb.rev_share - cb.lane_share >= 0.15 THEN 'under-shelved' ELSE 'balanced' END)
                    ORDER BY cb.cluster), '[]'::jsonb) FROM catbal cb),
    'history', (SELECT COALESCE(jsonb_agg(jsonb_build_object('field', l.field, 'old', l.old_value, 'new', l.new_value,
                    'changed_at', l.changed_at, 'source', l.source, 'changed_by', l.changed_by) ORDER BY l.changed_at DESC), '[]'::jsonb)
                FROM strategy_change_log l WHERE l.entity = 'machine' AND l.entity_id = p_machine_id),
    'posture_defaults', (SELECT jsonb_object_agg(posture, jsonb_build_object('label', label, 'params', params))
                         FROM strategy_posture_defaults WHERE population = f.population)
  ) INTO v_out;

  RETURN v_out;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_strategy_machine_detail(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_strategy_machine_detail(uuid) TO authenticated;
