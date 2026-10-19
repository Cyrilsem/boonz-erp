-- PRD-142b A6: cannibalisation flag (spec 6.3, cut from 142a), display only, in the product drawer.
-- get_strategy_product_detail gains a 'cannibalisation' list; everything else in the body is unchanged
-- from prd142a_13. Read-only.

CREATE OR REPLACE FUNCTION public.get_strategy_product_detail(p_pod_product_id uuid, p_population text DEFAULT 'boonz')
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_as_of date;
  v_cw    date;
BEGIN
  IF NOT is_admin(auth.uid()) THEN RAISE EXCEPTION 'get_strategy_product_detail: operator_admin or superadmin only'; END IF;
  SELECT max(as_of) INTO v_as_of FROM product_playbook;
  v_cw := date_trunc('week', v_as_of)::date;
  RETURN (
    WITH m AS (
      SELECT f.machine_id, mc.official_name, sum(f.units) AS units, round(sum(f.net_rev_exvat), 2) AS net,
             round(sum(f.units) / count(DISTINCT date_trunc('week', f.d)), 2) AS velocity
      FROM fact_product_machine_daily f JOIN machines mc USING (machine_id)
      WHERE f.pod_product_id = p_pod_product_id AND f.d >= v_cw - 56 AND f.d < v_cw
        AND (p_population = 'all' OR f.population = p_population)
      GROUP BY 1, 2
    ),
    -- PRD-142b A6 (spec 6.3, display only): cannibalisation within the product's cluster on the machines it sells on.
    -- A pair is flagged when a newcomer's units in its first 4 weeks on a machine are >= 30% of the cluster's units
    -- in the 4 weeks before, the cluster total did not rise by 30% or more, and an incumbent of the same cluster
    -- (>= 4 units before) sold less but was still selling (an incumbent at 0 was swapped out, not cannibalised).
    cw AS (
      SELECT f.machine_id, f.pod_product_id, date_trunc('week', f.d)::date AS w, sum(f.units) AS u
      FROM fact_product_machine_daily f JOIN pod_products pp USING (pod_product_id)
      WHERE strategy_cluster(pp.product_category) = (SELECT strategy_cluster(product_category) FROM pod_products WHERE pod_product_id = p_pod_product_id)
        AND f.d >= v_cw - 7 * 60 AND f.d < v_cw
        AND (p_population = 'all' OR f.population = p_population)
        AND f.machine_id IN (SELECT machine_id FROM fact_product_machine_daily WHERE pod_product_id = p_pod_product_id AND d >= v_cw - 7 * 60)
      GROUP BY 1, 2, 3
    ),
    cfw AS (SELECT machine_id, pod_product_id, min(w) AS t FROM cw GROUP BY 1, 2),
    cpairs AS (
      SELECT a.machine_id, a.pod_product_id AS newcomer, i.pod_product_id AS incumbent, a.t,
        (SELECT sum(u) FROM cw WHERE cw.machine_id = a.machine_id AND w >= a.t - 28 AND w < a.t) AS cl_before,
        (SELECT sum(u) FROM cw WHERE cw.machine_id = a.machine_id AND w >= a.t AND w < a.t + 28) AS cl_after,
        (SELECT sum(u) FROM cw WHERE cw.machine_id = a.machine_id AND cw.pod_product_id = a.pod_product_id AND w >= a.t AND w < a.t + 28) AS new_after,
        (SELECT sum(u) FROM cw WHERE cw.machine_id = a.machine_id AND cw.pod_product_id = i.pod_product_id AND w >= a.t - 28 AND w < a.t) AS inc_before,
        (SELECT COALESCE(sum(u), 0) FROM cw WHERE cw.machine_id = a.machine_id AND cw.pod_product_id = i.pod_product_id AND w >= a.t AND w < a.t + 28) AS inc_after
      FROM cfw a
      JOIN cfw i ON i.machine_id = a.machine_id AND i.pod_product_id <> a.pod_product_id AND i.t < a.t
      WHERE a.t >= (SELECT min(w) FROM cw WHERE cw.machine_id = a.machine_id) + 28 AND a.t + 28 <= v_cw
        AND p_pod_product_id IN (a.pod_product_id, i.pod_product_id)
    ),
    canni AS (
      SELECT c.*, mc.official_name, n.pod_product_name AS newcomer_name, ip.pod_product_name AS incumbent_name
      FROM cpairs c JOIN machines mc USING (machine_id)
      JOIN pod_products n ON n.pod_product_id = c.newcomer JOIN pod_products ip ON ip.pod_product_id = c.incumbent
      WHERE c.cl_before > 0 AND c.new_after >= 0.3 * c.cl_before AND c.cl_after < 1.3 * c.cl_before
        AND c.inc_before >= 4 AND c.inc_after > 0 AND c.inc_after < c.inc_before
    )
    SELECT jsonb_build_object(
      'as_of', v_as_of, 'week0', v_cw - 7 * 60,
      'playbook', (SELECT to_jsonb(pb) FROM product_playbook pb WHERE pb.pod_product_id = p_pod_product_id AND pb.as_of = v_as_of AND pb.population = p_population),
      'strategy', (SELECT to_jsonb(ps) FROM product_strategy ps WHERE ps.pod_product_id = p_pod_product_id),
      'supply', (SELECT to_jsonb(s) FROM product_supply_daily s WHERE s.pod_product_id = p_pod_product_id ORDER BY s.d DESC LIMIT 1),
      'machines', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.velocity DESC), '[]'::jsonb) FROM m),
      'archetypes', (SELECT COALESCE(jsonb_agg(x ORDER BY x ->> 'archetype'), '[]'::jsonb)
                     FROM (SELECT jsonb_build_object('archetype', a.archetype_code, 'velocity', round(sum(m.units) / NULLIF(sum(m.units / NULLIF(m.velocity, 0)), 0), 2),
                                  'machines', count(*)) AS x
                           FROM m JOIN machine_archetype_assignment a ON a.machine_id = m.machine_id
                            AND a.as_of = (SELECT max(as_of) FROM machine_archetype_assignment)
                           GROUP BY a.archetype_code) t),
      'history', (SELECT COALESCE(jsonb_agg(jsonb_build_object('field', l.field, 'old', l.old_value, 'new', l.new_value, 'changed_at', l.changed_at,
                    'source', l.source) ORDER BY l.changed_at DESC), '[]'::jsonb)
                  FROM strategy_change_log l WHERE l.entity = 'product' AND l.entity_id = p_pod_product_id),
      'cannibalisation', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                            'machine', c.official_name, 'week_added', c.t,
                            'role', CASE WHEN c.newcomer = p_pod_product_id THEN 'newcomer' ELSE 'incumbent' END,
                            'newcomer', c.newcomer_name, 'incumbent', c.incumbent_name,
                            'cluster_before', c.cl_before, 'cluster_after', c.cl_after, 'newcomer_after', c.new_after,
                            'incumbent_before', c.inc_before, 'incumbent_after', c.inc_after) ORDER BY c.t DESC), '[]'::jsonb)
                          FROM (SELECT * FROM canni ORDER BY t DESC LIMIT 10) c)));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_strategy_product_detail(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_strategy_product_detail(uuid, text) TO authenticated;
