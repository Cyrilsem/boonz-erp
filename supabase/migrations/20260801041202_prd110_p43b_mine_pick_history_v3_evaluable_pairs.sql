-- PRD-110 P4.3b · WS-H4 — mine_pick_history_v3
--
-- Learns picker WEIGHTS from CS's own keep/drop history, and proposes. It never
-- applies: pick_urgency_params is read SELECT-only and the application is parked
-- for CS (S-138). Fixture 58 re-proves that parking on every single run, because
-- "the body contains no such write" is a comment until something checks it.
--
-- THE METHOD. On each learnable plan_date, every (kept, dropped) machine pair is
-- one observation. A feature is CONCORDANT on a pair when the kept machine's
-- value is higher. Concordance over the window says how strongly CS's selection
-- tracks that feature; 50% is a coin flip and carries no information at all.
--
-- WHAT LEG 86's CALIBRATION FORCED INTO THIS DESIGN
--   · Days are filtered through v_pick_decision_cohorts_v3, never re-derived
--     here (Article 16). 241 live drops are dominated by route/day SCOPE - "cancel
--     entire 5-Jun plan", "AMZ-only route today" - and a learner that reads those
--     as "the picker over-ranked this machine" learns to down-weight VOX because
--     VOX days are episodic. Only mixed_capacity days compare machines CS was
--     genuinely choosing between.
--   · Polarity lives in picker_feature_param_map_v3.param_rewards, not in a CASE
--     here, so a one-row UPDATE can falsify the sign.
--   · Candidates aggregate BY DIAL. Two features on one dial collapse to a single
--     proposal led by the stronger, and `pairs` is the LEAD's - never the sum,
--     which would double-count the same machines under two names.
--   · S-137: this function owns the CHECK (proposed_weight <> current_weight)
--     boundary rather than discovering it. A move that rounds back onto the
--     current weight is refused BY NAME; it does not abort the run and take every
--     other proposal down with it.

CREATE OR REPLACE FUNCTION public.mine_pick_history_v3(
  p_as_of       date    DEFAULT NULL,
  p_window_days integer DEFAULT NULL,
  p_dry_run     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_uid          uuid;
  v_role         text;
  v_as_of        date;
  v_days         int;
  v_from         date;
  v_win_default  int;
  v_min_pairs    int;
  v_min_days     int;
  v_max_prop     int;
  v_band         numeric;
  v_max_delta    numeric;
  v_learnable    int   := 0;
  v_cohorts      jsonb := '{}'::jsonb;
  v_candidates   jsonb := '[]'::jsonb;
  v_targets      jsonb := '[]'::jsonb;
  v_refusals     jsonb := '[]'::jsonb;
  v_unusable     jsonb := '[]'::jsonb;
  v_n_would      int   := 0;
  v_n_made       int   := 0;
  v_gates        text[];
  v_refused      text;
  v_cur          numeric;
  v_delta        numeric;
  v_prop         numeric;
  v_dir          text;
  v_ev           jsonb;
  t              record;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                 true);
  PERFORM set_config('app.rpc_name', 'mine_pick_history_v3', true);

  -- ---- Article 4 role gate, mirroring mine_edit_history_v3 ----
  -- S-121: under the golden harness auth.uid() is NULL and this short-circuits,
  -- which proves the gate EXISTS but never that it ADMITS. Fixture 58 therefore
  -- impersonates through request.jwt.claims so the admitting path is exercised.
  v_uid := auth.uid();
  IF v_uid IS NOT NULL THEN
    SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin') THEN
      RAISE EXCEPTION 'mine_pick_history_v3: caller % with role % is not permitted to mine picker weight proposals',
        v_uid, COALESCE(v_role, '<none>');
    END IF;
  END IF;

  SELECT r.pl_min_pairs, r.pl_min_days, r.pl_max_proposals,
         r.pl_concordance_band, r.pl_max_weight_delta_pct, r.pl_window_days
    INTO v_min_pairs, v_min_days, v_max_prop, v_band, v_max_delta, v_win_default
    FROM public.refill_policy_params r
   LIMIT 1;

  v_as_of := COALESCE(p_as_of, current_date);
  v_days  := COALESCE(p_window_days, v_win_default);
  IF v_days IS NULL OR v_days <= 0 THEN
    RAISE EXCEPTION 'mine_pick_history_v3: window_days must be positive (got %)',
      COALESCE(p_window_days::text, '<null>');
  END IF;
  v_from := v_as_of - (v_days - 1);

  -- ---- Article 16: the cohort classification comes from its canonical object ----
  SELECT count(*)::int INTO v_learnable
    FROM public.v_pick_decision_cohorts_v3 c
   WHERE c.plan_date BETWEEN v_from AND v_as_of
     AND c.is_learnable;

  SELECT COALESCE(jsonb_object_agg(x.cohort, x.n), '{}'::jsonb) INTO v_cohorts
    FROM (SELECT c.cohort, count(*)::int AS n
            FROM public.v_pick_decision_cohorts_v3 c
           WHERE c.plan_date BETWEEN v_from AND v_as_of
           GROUP BY c.cohort) x;

  -- An active mapping pointing at a non-numeric column would abort the whole run
  -- at cast time. Same rule as S-137: own the boundary, refuse by name.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'scope', 'feature', 'name', m.feature,
           'reason', 'feature_is_not_a_numeric_column_on_machines_to_visit')
           ORDER BY m.feature), '[]'::jsonb)
    INTO v_unusable
    FROM public.picker_feature_param_map_v3 m
   WHERE m.is_active
     AND NOT EXISTS (
       SELECT 1 FROM information_schema.columns ic
        WHERE ic.table_schema = 'public' AND ic.table_name = 'machines_to_visit'
          AND ic.column_name = m.feature
          AND ic.data_type IN ('integer','numeric','bigint','smallint','double precision','real'));

  -- ---- the pairwise evidence, one row per active feature ----
  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.target_param, a.feature), '[]'::jsonb)
    INTO v_candidates
    FROM (
      WITH lrn AS (
        SELECT c.plan_date
          FROM public.v_pick_decision_cohorts_v3 c
         WHERE c.plan_date BETWEEN v_from AND v_as_of
           AND c.is_learnable
      ),
      base AS (
        -- Article 16 carve-out (METRICS_REGISTRY, leg 86): the cohort predicate
        -- comes from the view; the FEATURE VALUES are a base-table read no view
        -- supplies, scoped to plan_dates the view has already classified.
        SELECT v.plan_date, (v.dropped_at IS NOT NULL) AS was_dropped, to_jsonb(v) AS j
          FROM public.machines_to_visit v
          JOIN lrn ON lrn.plan_date = v.plan_date
         WHERE v.add_source = 'picker'
      ),
      feat AS (
        SELECT m.feature, m.target_param, m.param_rewards
          FROM public.picker_feature_param_map_v3 m
         WHERE m.is_active
           AND EXISTS (
             SELECT 1 FROM information_schema.columns ic
              WHERE ic.table_schema = 'public' AND ic.table_name = 'machines_to_visit'
                AND ic.column_name = m.feature
                AND ic.data_type IN ('integer','numeric','bigint','smallint','double precision','real'))
      ),
      px AS (
        SELECT f.feature, f.target_param, f.param_rewards, k.plan_date,
               (k.j ->> f.feature)::numeric AS kv,
               (d.j ->> f.feature)::numeric AS dv
          FROM feat f
          CROSS JOIN base k
          JOIN base d ON d.plan_date = k.plan_date AND d.was_dropped
         WHERE NOT k.was_dropped
      ),
      agg AS (
        SELECT px.feature, px.target_param, px.param_rewards,
               -- EVALUABLE pairs: both sides carry a value. Ties are evidence -
               -- they say CS was NOT discriminating on this feature - so they
               -- belong in the denominator of "how much did we look at", even
               -- though they cannot belong in "which way did it point".
               count(*)::int AS pairs,
               count(*) FILTER (WHERE px.kv > px.dv)::int AS concordant,
               count(*) FILTER (WHERE px.kv < px.dv)::int AS discordant,
               count(DISTINCT px.plan_date) FILTER (WHERE px.kv <> px.dv)::int AS days_covered
          FROM px
         WHERE px.kv IS NOT NULL AND px.dv IS NOT NULL
         GROUP BY 1, 2, 3
      )
      SELECT agg.feature, agg.target_param, agg.param_rewards,
             agg.concordant, agg.discordant, agg.days_covered,
             agg.pairs,
             (agg.concordant + agg.discordant) AS comparable_pairs,
             CASE WHEN agg.concordant + agg.discordant = 0 THEN NULL
                  ELSE round(100.0 * agg.concordant / (agg.concordant + agg.discordant), 2)
             END AS concordance_pct
        FROM agg
    ) a;

  -- ---- one candidate per DIAL, led by the strongest feature on it ----
  FOR t IN
    WITH leads AS (
      SELECT DISTINCT ON (c.target_param)
             c.feature, c.target_param, c.param_rewards,
             c.concordant, c.discordant, c.days_covered, c.pairs,
             c.comparable_pairs, c.concordance_pct
        FROM jsonb_to_recordset(v_candidates)
          AS c(feature text, target_param text, param_rewards text,
               concordant int, discordant int, days_covered int,
               pairs int, comparable_pairs int, concordance_pct numeric)
       WHERE c.concordance_pct IS NOT NULL
       ORDER BY c.target_param, abs(c.concordance_pct - 50) DESC, c.feature
    )
    -- strongest first, so if pl_max_proposals binds it keeps the best evidence
    SELECT * FROM leads ORDER BY abs(concordance_pct - 50) DESC, target_param
  LOOP
    v_gates   := ARRAY[]::text[];
    v_refused := NULL;
    v_dir     := NULL;
    v_delta   := NULL;
    v_prop    := NULL;

    -- ⛔ S-137: strictly greater. A candidate exactly ON the band computes a zero
    --    move, and a zero move violates CHECK (proposed_weight <> current_weight).
    IF abs(t.concordance_pct - 50) <= v_band THEN
      v_gates := v_gates || 'below_concordance_band'::text;
    END IF;
    -- ⛔ Gate on the DISCRIMINATING count, not the evaluable one. 150 pairs of
    --    which 149 are ties is one observation, not 150. The evaluable count is
    --    still what gets STORED, so a reviewer can see how thin the signal was.
    IF t.comparable_pairs < v_min_pairs THEN
      v_gates := v_gates || 'below_min_pairs'::text;
    END IF;
    IF t.days_covered < v_min_days THEN
      v_gates := v_gates || 'below_min_days'::text;
    END IF;

    -- ⛔ S-138: SELECT ONLY. This function never writes pick_urgency_params.
    SELECT (to_jsonb(p) ->> t.target_param)::numeric INTO v_cur
      FROM public.pick_urgency_params p
     LIMIT 1;

    IF v_cur IS NULL THEN
      v_gates := v_gates || 'no_such_dial'::text;
    END IF;

    -- Every failed gate is reported, not merely the first one tested. A caller
    -- who fixes only the gate the code happened to name comes straight back.
    IF array_length(v_gates, 1) IS NOT NULL THEN
      v_refused := array_to_string(v_gates, '+');
    ELSE
      v_dir := CASE WHEN (t.concordance_pct > 50) = (t.param_rewards = 'high')
                    THEN 'raise' ELSE 'lower' END;
      v_delta := v_max_delta * LEAST(1.0, (abs(t.concordance_pct - 50) - v_band) / (50 - v_band));
      v_prop  := round(CASE WHEN v_dir = 'raise' THEN v_cur * (1 + v_delta / 100)
                                                 ELSE v_cur * (1 - v_delta / 100) END, 3);

      IF v_prop = round(v_cur, 3) THEN
        v_refused := 'round_to_equal';
      ELSIF EXISTS (SELECT 1 FROM public.picker_weight_proposals_v3 q
                     WHERE q.target_param = t.target_param AND q.status = 'pending') THEN
        v_refused := 'pending_exists';
      ELSIF v_n_would >= v_max_prop THEN
        v_refused := 'max_proposals_reached';
      END IF;
    END IF;

    IF v_refused IS NULL THEN
      v_n_would := v_n_would + 1;
      IF NOT p_dry_run THEN
        v_ev := jsonb_build_object(
          'as_of', v_as_of, 'window_days', v_days, 'learnable_days', v_learnable,
          'band', v_band, 'delta_pct', round(v_delta, 4), 'max_delta_pct', v_max_delta,
          'min_pairs', v_min_pairs, 'min_days', v_min_days,
          'param_rewards', t.param_rewards,
          'pairs_evaluable', t.pairs, 'pairs_comparable', t.comparable_pairs,
          'ties', t.pairs - t.comparable_pairs,
          'features', (SELECT jsonb_agg(e) FROM jsonb_array_elements(v_candidates) e
                        WHERE e ->> 'target_param' = t.target_param));

        INSERT INTO public.picker_weight_proposals_v3
          (window_start, window_end, target_param, current_weight, proposed_weight,
           direction, lead_feature, concordance_pct, pairs, concordant, discordant,
           days_covered, evidence)
        VALUES
          (v_from, v_as_of, t.target_param, round(v_cur, 3), v_prop,
           v_dir, t.feature, t.concordance_pct, t.pairs, t.concordant, t.discordant,
           t.days_covered, v_ev);

        v_n_made := v_n_made + 1;
      END IF;
    END IF;

    v_targets := v_targets || jsonb_build_object(
      'target_param',    t.target_param,
      'lead_feature',    t.feature,
      'param_rewards',   t.param_rewards,
      'concordance_pct', t.concordance_pct,
      'pairs',            t.pairs,
      'comparable_pairs', t.comparable_pairs,
      'ties',             t.pairs - t.comparable_pairs,
      'concordant',      t.concordant,
      'discordant',      t.discordant,
      'days_covered',    t.days_covered,
      'current_weight',  v_cur,
      'direction',       v_dir,
      'delta_pct',       round(v_delta, 4),
      'proposed_weight', v_prop,
      'refused',         v_refused);
  END LOOP;

  -- Named refusals for everything the map declines to learn from. 7 of the 11
  -- features are refused, and a refusal nobody can read is a silence.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'scope', 'feature', 'name', m.feature,
           'reason', 'inactive_in_map', 'note', m.note) ORDER BY m.feature), '[]'::jsonb)
    INTO v_refusals
    FROM public.picker_feature_param_map_v3 m
   WHERE NOT m.is_active;

  v_refusals := v_refusals || v_unusable || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'scope', 'feature', 'name', c.feature,
             'reason', CASE WHEN c.concordance_pct IS NULL THEN 'no_comparable_pairs'
                            ELSE 'not_lead_for_' || c.target_param END)
             ORDER BY c.feature)
      FROM jsonb_to_recordset(v_candidates)
        AS c(feature text, target_param text, concordance_pct numeric)
     WHERE c.concordance_pct IS NULL
        OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_targets) tt
                        WHERE tt ->> 'lead_feature' = c.feature)
  ), '[]'::jsonb);

  RETURN jsonb_build_object(
    'ok',                     true,
    'as_of',                  v_as_of,
    'window_start',           v_from,
    'window_end',             v_as_of,
    'window_days',            v_days,
    'dry_run',                p_dry_run,
    'learnable_days',         v_learnable,
    'cohorts',                v_cohorts,
    'gates',                  jsonb_build_object(
                                'min_pairs', v_min_pairs, 'min_days', v_min_days,
                                'concordance_band', v_band, 'max_delta_pct', v_max_delta,
                                'max_proposals', v_max_prop),
    'candidates',             v_candidates,
    'targets',                v_targets,
    'refusals',               v_refusals,
    'proposals_would_create', v_n_would,
    'proposals_created',      v_n_made);
END
$fn$;

-- ⛔ NEW-FUNCTION ACL TRAP: Supabase default privileges grant EXECUTE to `anon`
--    EXPLICITLY, so REVOKE ... FROM PUBLIC does not remove it. Name anon.
REVOKE ALL ON FUNCTION public.mine_pick_history_v3(date, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mine_pick_history_v3(date, integer, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.mine_pick_history_v3(date, integer, boolean)
  TO postgres, authenticated, service_role;

COMMENT ON FUNCTION public.mine_pick_history_v3(date, integer, boolean) IS
  'PRD-110 P4.3b WS-H4. Mines CS keep/drop history into picker weight PROPOSALS. Reads learnable plan_dates from v_pick_decision_cohorts_v3 (Article 16) and feature values from machines_to_visit. Reads pick_urgency_params SELECT-ONLY - application is parked for CS (S-138) and fixture 58 re-proves that every run. Polarity from picker_feature_param_map_v3.param_rewards.';
