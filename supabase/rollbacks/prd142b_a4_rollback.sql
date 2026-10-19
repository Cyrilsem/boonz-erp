-- Rollback for prd142b_a4_product_proposal_review: restores the PRD-142a propose_product_strategy body and drops the reject RPC.
-- The three rejected_* columns are left in place (additive, harmless).

DROP FUNCTION IF EXISTS public.reject_product_strategy_proposal(uuid, text);

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
