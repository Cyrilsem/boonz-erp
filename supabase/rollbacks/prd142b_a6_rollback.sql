-- Rollback for prd142b_a6_cannibalisation_flag: restores the PRD-142a get_strategy_product_detail body.

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
                  FROM strategy_change_log l WHERE l.entity = 'product' AND l.entity_id = p_pod_product_id)));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_strategy_product_detail(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_strategy_product_detail(uuid, text) TO authenticated;
