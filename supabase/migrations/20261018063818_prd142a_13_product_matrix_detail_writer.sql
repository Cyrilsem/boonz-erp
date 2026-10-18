-- PRD-142a 6.3 and 6.4: product x archetype matrix, product detail drawer, and
-- the product strategy writer. SECURITY DEFINER, is_admin gate, authenticated only.

-- 6.3: cell = units per selling machine-week over the last 8 complete weeks,
-- ratio to the product's population velocity, and machine count.
CREATE OR REPLACE FUNCTION public.get_strategy_product_archetype_matrix(p_population text DEFAULT 'boonz')
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
  IF NOT is_admin(auth.uid()) THEN RAISE EXCEPTION 'get_strategy_product_archetype_matrix: operator_admin or superadmin only'; END IF;
  SELECT max(as_of) INTO v_as_of FROM product_playbook;
  v_cw := date_trunc('week', v_as_of)::date;
  RETURN (
    WITH a AS (SELECT machine_id, archetype_code FROM machine_archetype_assignment WHERE as_of = (SELECT max(as_of) FROM machine_archetype_assignment)),
    cells AS (
      SELECT f.pod_product_id, a.archetype_code, sum(f.units) AS units,
             count(DISTINCT (f.machine_id, date_trunc('week', f.d))) AS mw, count(DISTINCT f.machine_id) AS machines
      FROM fact_product_machine_daily f JOIN a USING (machine_id)
      WHERE f.d >= v_cw - 56 AND f.d < v_cw AND (p_population = 'all' OR f.population = p_population)
      GROUP BY 1, 2
    )
    SELECT jsonb_build_object('as_of', v_as_of, 'population', p_population,
      'archetypes', (SELECT jsonb_agg(jsonb_build_object('code', code, 'label', label) ORDER BY sort_order)
                     FROM machine_archetypes WHERE population IN (p_population, 'all') OR p_population = 'all'),
      'cells', (SELECT COALESCE(jsonb_agg(jsonb_build_object('pod_product_id', c.pod_product_id, 'name', pb.pod_product_name,
                  'archetype', c.archetype_code, 'velocity', round(c.units / NULLIF(c.mw, 0), 2),
                  'ratio', round((c.units / NULLIF(c.mw, 0)) / NULLIF(pb.velocity, 0), 2), 'machines', c.machines,
                  'product_velocity', pb.velocity, 'product_net_rev_8w', pb.net_rev_8w, 'playbook', pb.playbook)), '[]'::jsonb)
                FROM cells c JOIN product_playbook pb ON pb.pod_product_id = c.pod_product_id AND pb.as_of = v_as_of AND pb.population = p_population
                WHERE pb.playbook NOT IN ('SUPERSEDED', 'ANOMALY'))));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_strategy_product_archetype_matrix(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_strategy_product_archetype_matrix(text) TO authenticated;

-- Product detail drawer: playbook row, best and worst machines (8 weeks), archetype
-- bars, supply, posture and history. Cannibalisation (backlog item 7) is not built
-- in 142a.
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

-- 6.4 writer: CS confirms a product posture.
CREATE OR REPLACE FUNCTION public.set_product_strategy(p_pod_product_id uuid, p_posture text,
                                                       p_target_archetypes text[] DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old product_strategy%ROWTYPE;
BEGIN
  IF NOT is_admin(v_uid) THEN RAISE EXCEPTION 'set_product_strategy: operator_admin or superadmin only'; END IF;
  IF p_posture NOT IN ('GROW', 'HOLD', 'RESOURCE', 'DRAIN', 'EXIT') THEN RAISE EXCEPTION 'set_product_strategy: unknown posture %', p_posture; END IF;
  IF NOT EXISTS (SELECT 1 FROM pod_products WHERE pod_product_id = p_pod_product_id) THEN
    RAISE EXCEPTION 'set_product_strategy: pod product % not found', p_pod_product_id;
  END IF;
  SELECT * INTO v_old FROM product_strategy WHERE pod_product_id = p_pod_product_id;

  INSERT INTO product_strategy (pod_product_id, posture, target_archetypes, notes, confirmed_at, confirmed_by, updated_at)
  VALUES (p_pod_product_id, p_posture, p_target_archetypes, p_notes, now(), v_uid, now())
  ON CONFLICT (pod_product_id) DO UPDATE SET
    posture = EXCLUDED.posture,
    target_archetypes = COALESCE(p_target_archetypes, product_strategy.target_archetypes),
    notes = COALESCE(p_notes, product_strategy.notes),
    confirmed_at = now(), confirmed_by = v_uid, updated_at = now();

  INSERT INTO strategy_change_log (entity, entity_id, field, old_value, new_value, changed_by, source)
  VALUES ('product', p_pod_product_id, 'posture', to_jsonb(v_old.posture),
          jsonb_build_object('posture', p_posture, 'target_archetypes', COALESCE(p_target_archetypes, v_old.target_archetypes),
                             'notes', p_notes, 'proposed', v_old.posture_proposed), v_uid, 'cs');

  RETURN jsonb_build_object('pod_product_id', p_pod_product_id, 'posture', p_posture);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.set_product_strategy(uuid, text, text[], text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_product_strategy(uuid, text, text[], text) TO authenticated;
