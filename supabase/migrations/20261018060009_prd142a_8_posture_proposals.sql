-- PRD-142a 5.1 and 5.2: nightly posture proposal and diagnosis sentence.
--
-- performance_index = gp_day_90 / archetype benchmark gp_day_90 (median of the
--   same archetype and population, machines aged >= 90 days, excluding the
--   machine; population median when fewer than 3 peers). Falls back to
--   rev_day_90 when GP is NULL (partner machines until partner_revenue_share
--   is set). RAMPING: performance_index = ramp_index.
-- Strong = performance_index >= 0.85 (RAMPING: ramp_index >= 0.8).
-- mix_gap = 1 - actual / expected net rev over the 90-day window, over the
--   machine's current lanes (v_shelf_capacity.current_product, normalised to
--   a pod) that have a peer rate. Peer rate of a pod = median over peer
--   machines (same archetype and population, else population when fewer
--   than 3 peers carry it) of net rev per lane per active day.
-- Inside = mix_gap >= 0.25 or dead_shelf_pct_90 >= 0.35.
-- Posture: Strong -> PROTECT_GROW; Weak and Inside -> FIX_MIX;
--   Weak and Outside -> WATCH_ADAPT. NOT_FLIPPABLE is never proposed
--   automatically in 142a (it needs two monthly review cycles of history,
--   which do not exist yet); CS can set it.
-- Under-peer lanes = lanes whose own rate is under 40% of the peer rate.
-- Category balance (6.3): per cluster, share of lanes vs share of 90-day net
--   rev; gap <= -0.15 over-shelved, >= +0.15 under-shelved.
-- The job writes only posture_proposed, proposed_at, proposed_reason,
-- proposal_detail and archetype_code. A proposal equal to a rejected one is
-- suppressed until rejected_until.

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

-- CS writer: confirm a posture (accept, or accept with edits).
CREATE OR REPLACE FUNCTION public.set_machine_strategy(p_machine_id uuid, p_posture text, p_params jsonb DEFAULT NULL,
                                                       p_shelf_overrides jsonb DEFAULT NULL, p_notes text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_old  machine_strategy%ROWTYPE;
  v_pop  text;
  v_par  jsonb;
  v_rev  date;
BEGIN
  IF NOT is_admin(v_uid) THEN RAISE EXCEPTION 'set_machine_strategy: operator_admin or superadmin only'; END IF;
  IF p_posture NOT IN ('PROTECT_GROW', 'FIX_MIX', 'WATCH_ADAPT', 'NOT_FLIPPABLE') THEN
    RAISE EXCEPTION 'set_machine_strategy: unknown posture %', p_posture;
  END IF;
  SELECT strategy_population(venue_group, official_name) INTO v_pop FROM machines WHERE machine_id = p_machine_id;
  IF v_pop IS NULL THEN RAISE EXCEPTION 'set_machine_strategy: machine % not found', p_machine_id; END IF;

  SELECT * INTO v_old FROM machine_strategy WHERE machine_id = p_machine_id;
  v_par := COALESCE((SELECT params FROM strategy_posture_defaults WHERE posture = p_posture AND population = v_pop), '{}'::jsonb)
           || COALESCE(p_params, '{}'::jsonb);
  v_rev := CASE WHEN v_par ? 'review_days' THEN ((now() AT TIME ZONE 'Asia/Dubai')::date + (v_par ->> 'review_days')::int) END;

  INSERT INTO machine_strategy (machine_id, posture, params, shelf_overrides, notes, confirmed_at, confirmed_by, review_by, updated_at)
  VALUES (p_machine_id, p_posture, v_par, COALESCE(p_shelf_overrides, '[]'::jsonb), p_notes, now(), v_uid, v_rev, now())
  ON CONFLICT (machine_id) DO UPDATE SET
    posture = EXCLUDED.posture, params = EXCLUDED.params,
    shelf_overrides = COALESCE(p_shelf_overrides, machine_strategy.shelf_overrides),
    notes = COALESCE(p_notes, machine_strategy.notes),
    confirmed_at = now(), confirmed_by = v_uid, review_by = EXCLUDED.review_by,
    rejected_posture = NULL, rejected_until = NULL, rejected_reason = NULL, updated_at = now();

  INSERT INTO strategy_change_log (entity, entity_id, field, old_value, new_value, changed_by, source)
  VALUES ('machine', p_machine_id, 'posture',
          jsonb_build_object('posture', v_old.posture, 'params', v_old.params, 'shelf_overrides', v_old.shelf_overrides),
          jsonb_build_object('posture', p_posture, 'params', v_par, 'shelf_overrides', COALESCE(p_shelf_overrides, v_old.shelf_overrides),
                             'notes', p_notes, 'proposed', v_old.posture_proposed),
          v_uid, 'cs');

  RETURN jsonb_build_object('machine_id', p_machine_id, 'posture', p_posture, 'params', v_par, 'review_by', v_rev);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.set_machine_strategy(uuid, text, jsonb, jsonb, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_machine_strategy(uuid, text, jsonb, jsonb, text) TO authenticated;

-- CS writer: reject the current proposal; the same proposal is suppressed for 30 days.
CREATE OR REPLACE FUNCTION public.reject_machine_strategy_proposal(p_machine_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old machine_strategy%ROWTYPE;
BEGIN
  IF NOT is_admin(v_uid) THEN RAISE EXCEPTION 'reject_machine_strategy_proposal: operator_admin or superadmin only'; END IF;
  IF COALESCE(trim(p_reason), '') = '' THEN RAISE EXCEPTION 'reject_machine_strategy_proposal: a reason is required'; END IF;
  SELECT * INTO v_old FROM machine_strategy WHERE machine_id = p_machine_id;
  IF NOT FOUND OR v_old.posture_proposed IS NULL THEN RAISE EXCEPTION 'reject_machine_strategy_proposal: no proposal for %', p_machine_id; END IF;

  UPDATE machine_strategy
  SET rejected_posture = v_old.posture_proposed,
      rejected_until = (now() AT TIME ZONE 'Asia/Dubai')::date + 30,
      rejected_reason = p_reason,
      posture_proposed = posture,
      updated_at = now()
  WHERE machine_id = p_machine_id;

  INSERT INTO strategy_change_log (entity, entity_id, field, old_value, new_value, changed_by, source)
  VALUES ('machine', p_machine_id, 'proposal_rejected', to_jsonb(v_old.posture_proposed),
          jsonb_build_object('reason', p_reason, 'suppressed_until', (now() AT TIME ZONE 'Asia/Dubai')::date + 30), v_uid, 'cs');

  RETURN jsonb_build_object('machine_id', p_machine_id, 'rejected', v_old.posture_proposed);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.reject_machine_strategy_proposal(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reject_machine_strategy_proposal(uuid, text) TO authenticated;

SELECT public.propose_machine_postures(NULL);
