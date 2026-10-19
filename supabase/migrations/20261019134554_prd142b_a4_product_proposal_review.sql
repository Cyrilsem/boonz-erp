-- PRD-142b A4: product review panel support.
-- Adds rejection suppression to product_strategy (same pattern as machine_strategy), the writer
-- reject_product_strategy_proposal (operator_admin / superadmin, audited in strategy_change_log), and makes
-- propose_product_strategy honour the suppression. Also stops the nightly job from overwriting
-- target_archetypes on products whose posture CS has confirmed (found while wiring 5.5 item 7).

ALTER TABLE public.product_strategy
  ADD COLUMN IF NOT EXISTS rejected_posture text,
  ADD COLUMN IF NOT EXISTS rejected_until date,
  ADD COLUMN IF NOT EXISTS rejected_reason text;

CREATE OR REPLACE FUNCTION public.reject_product_strategy_proposal(p_pod_product_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old product_strategy%ROWTYPE;
BEGIN
  IF NOT is_admin(v_uid) THEN RAISE EXCEPTION 'reject_product_strategy_proposal: operator_admin or superadmin only'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'reject_product_strategy_proposal: a reason is required'; END IF;
  SELECT * INTO v_old FROM product_strategy WHERE pod_product_id = p_pod_product_id;
  IF NOT FOUND OR v_old.posture_proposed IS NULL THEN RAISE EXCEPTION 'reject_product_strategy_proposal: no proposal for %', p_pod_product_id; END IF;

  UPDATE product_strategy
  SET rejected_posture = v_old.posture_proposed,
      rejected_until = (now() AT TIME ZONE 'Asia/Dubai')::date + 30,
      rejected_reason = p_reason,
      posture_proposed = posture,
      updated_at = now()
  WHERE pod_product_id = p_pod_product_id;

  INSERT INTO strategy_change_log (entity, entity_id, field, old_value, new_value, changed_by, source)
  VALUES ('product', p_pod_product_id, 'proposal_rejected', to_jsonb(v_old.posture_proposed),
          jsonb_build_object('reason', p_reason, 'suppressed_until', (now() AT TIME ZONE 'Asia/Dubai')::date + 30), v_uid, 'cs');

  RETURN jsonb_build_object('pod_product_id', p_pod_product_id, 'rejected', v_old.posture_proposed);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.reject_product_strategy_proposal(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reject_product_strategy_proposal(uuid, text) TO authenticated;

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
    -- PRD-142b A4: a rejected proposal stays quiet until rejected_until (30 days).
    posture_proposed = CASE WHEN product_strategy.rejected_posture = EXCLUDED.posture_proposed
                             AND product_strategy.rejected_until >= v_as_of
                            THEN product_strategy.posture_proposed ELSE EXCLUDED.posture_proposed END,
    proposed_reason = EXCLUDED.proposed_reason,
    -- PRD-142b A4: once CS has confirmed a posture, the target archetypes are CS's and the job leaves them alone.
    target_archetypes = CASE WHEN product_strategy.posture IS NULL THEN EXCLUDED.target_archetypes ELSE product_strategy.target_archetypes END,
    updated_at = now();

END;
$$;
REVOKE EXECUTE ON FUNCTION public.propose_product_strategy(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.propose_product_strategy(date) TO service_role;
