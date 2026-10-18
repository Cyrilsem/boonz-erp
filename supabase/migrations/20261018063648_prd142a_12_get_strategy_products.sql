-- PRD-142a 6.1, 6.3, 6.4, 6.5: product read RPCs and the product strategy writer.
-- All SECURITY DEFINER, operator_admin / superadmin only (is_admin), granted to
-- authenticated, never anon.

-- 6.1 + 6.3 cluster summary + 6.5 PO hygiene + KPI strip, one call for the Products tab.
CREATE OR REPLACE FUNCTION public.get_strategy_products(p_population text DEFAULT 'boonz', p_position text DEFAULT 'trails')
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_as_of date;
BEGIN
  IF NOT is_admin(auth.uid()) THEN RAISE EXCEPTION 'get_strategy_products: operator_admin or superadmin only'; END IF;
  IF p_population NOT IN ('boonz', 'partner', 'all') THEN RAISE EXCEPTION 'get_strategy_products: population must be boonz, partner or all'; END IF;
  SELECT max(as_of) INTO v_as_of FROM product_playbook;
  RETURN (
    WITH p AS (
      SELECT pb.*, pc.cluster_label, ps.posture, ps.posture_proposed, ps.target_archetypes, ps.confirmed_at, pp.product_category
      FROM product_playbook pb
      JOIN pod_products pp USING (pod_product_id)
      LEFT JOIN (SELECT DISTINCT cluster_code, cluster_label FROM product_clusters) pc ON pc.cluster_code = pb.cluster
      LEFT JOIN product_strategy ps USING (pod_product_id)
      WHERE pb.as_of = v_as_of AND pb.population = p_population
    )
    SELECT jsonb_build_object(
      'as_of', v_as_of, 'population', p_population, 'position', p_position,
      'medians', (SELECT reason - 'velocity' - 'coverage' - 'retention' - 'current_units' - 'months_live' - 'wh_status'
                  - 'prime_velocity' - 'prime_units' - 'prime_coverage' - 'prime_weeks_ago' - 'raw_max_velocity' - 'unserved_units_per_week'
                  FROM p WHERE reason ? 'median_velocity' LIMIT 1),
      'products', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'pod_product_id', pod_product_id, 'name', pod_product_name, 'cluster', cluster, 'cluster_label', COALESCE(cluster_label, 'Unclassified'),
          'category', product_category, 'first_sale', first_sale, 'maturity', maturity, 'months_live', months_live,
          'units_8w', cur_units, 'machine_weeks_8w', cur_machine_weeks, 'velocity', velocity, 'coverage', coverage, 'momentum', momentum,
          'prime_week_start', prime_week_start, 'prime_units', prime_units, 'prime_velocity', prime_velocity, 'prime_coverage', prime_coverage,
          'prime_weeks_ago', prime_weeks_ago, 'retention', retention,
          'net_rev_8w', net_rev_8w, 'gp_8w', gp_8w, 'cogs_coverage_8w', cogs_coverage_8w, 'price_per_unit', price_per_unit,
          'aed_per_facing_week', round(velocity * price_per_unit, 2),
          'wh_status', wh_status, 'weeks_of_cover', weeks_of_cover, 'open_po_units', open_po_units, 'deployed_units', deployed_units,
          'weekly_rate', weekly_rate, 'superseded', superseded, 'anomaly', anomaly, 'playbook', playbook, 'fuel_risk', fuel_risk,
          'reason', reason, 'posture', posture, 'posture_proposed', posture_proposed, 'target_archetypes', to_jsonb(target_archetypes),
          'confirmed_at', confirmed_at, 'series_units', to_jsonb(series_units), 'series_machines', to_jsonb(series_machines),
          'series_fleet', to_jsonb(series_fleet)) ORDER BY net_rev_8w DESC NULLS LAST), '[]'::jsonb) FROM p),
      'kpis', (SELECT jsonb_build_object(
          'products_shown', count(*) FILTER (WHERE playbook NOT IN ('SUPERSEDED', 'ANOMALY')),
          'units_8w', sum(cur_units), 'net_rev_8w', round(sum(net_rev_8w), 2),
          'by_playbook', (SELECT jsonb_object_agg(playbook, n) FROM (SELECT playbook, count(*) n FROM p GROUP BY 1) t),
          'unserved_units_per_week', round(COALESCE(sum((reason ->> 'unserved_units_per_week')::numeric), 0), 1),
          'missed_prime_units_8w', round(COALESCE(sum(prime_units * 2) FILTER (WHERE playbook = 'MISSED_THE_WAVE'), 0)),
          'missed_current_units_8w', COALESCE(sum(cur_units) FILTER (WHERE playbook = 'MISSED_THE_WAVE'), 0)) FROM p),
      'clusters', (SELECT COALESCE(jsonb_agg(jsonb_build_object('cluster', c.cluster, 'label', c.label, 'net_rev_8w', c.rev, 'products', c.n,
                       'by_playbook', c.byp, 'read', c.read) ORDER BY c.rev DESC NULLS LAST), '[]'::jsonb)
                   FROM (SELECT cluster, COALESCE(max(cluster_label), 'Unclassified') AS label, round(sum(net_rev_8w), 2) AS rev, count(*) AS n,
                                (SELECT jsonb_object_agg(playbook, k) FROM (SELECT playbook, count(*) k FROM p p2 WHERE p2.cluster = p.cluster GROUP BY 1) t) AS byp,
                                concat_ws(', ',
                                  CASE WHEN count(*) FILTER (WHERE playbook = 'DOUBLE_DOWN') > 0 THEN count(*) FILTER (WHERE playbook = 'DOUBLE_DOWN') || ' double down' END,
                                  CASE WHEN count(*) FILTER (WHERE playbook = 'PROTECT') > 0 THEN count(*) FILTER (WHERE playbook = 'PROTECT') || ' protect' END,
                                  CASE WHEN count(*) FILTER (WHERE playbook = 'MISSED_THE_WAVE') > 0 THEN count(*) FILTER (WHERE playbook = 'MISSED_THE_WAVE') || ' missed the wave' END,
                                  CASE WHEN count(*) FILTER (WHERE playbook IN ('COOLED_OFF', 'REDUCE_REPLACE', 'EXIT')) > 0
                                       THEN count(*) FILTER (WHERE playbook IN ('COOLED_OFF', 'REDUCE_REPLACE', 'EXIT')) || ' to drain or exit' END)
                                || ' of ' || count(*) FILTER (WHERE playbook NOT IN ('SUPERSEDED', 'ANOMALY')) || ' products' AS read
                         FROM p GROUP BY cluster) c),
      'po_hygiene', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pod_product_id', pod_product_id, 'name', pod_product_name, 'playbook', playbook,
                         'open_po_units', open_po_units, 'weekly_rate', weekly_rate,
                         'weeks_of_cover_from_po', CASE WHEN weekly_rate > 0 THEN round(open_po_units / weekly_rate, 1) END)
                         ORDER BY open_po_units DESC), '[]'::jsonb)
                     FROM p WHERE playbook IN ('COOLED_OFF', 'REDUCE_REPLACE', 'EXIT') AND COALESCE(open_po_units, 0) > 0),
      'quarantined', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pod_product_id', pod_product_id, 'name', pod_product_name, 'playbook', playbook,
                         'note', (SELECT note FROM product_superseded s WHERE s.pod_product_id = p.pod_product_id))), '[]'::jsonb)
                      FROM p WHERE playbook IN ('SUPERSEDED', 'ANOMALY')),
      'uncategorised', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pod_product_id', pod_product_id, 'name', pod_product_name) ORDER BY pod_product_name), '[]'::jsonb)
                        FROM pod_products WHERE product_category IS NULL)
    ));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_strategy_products(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_strategy_products(text, text) TO authenticated;
