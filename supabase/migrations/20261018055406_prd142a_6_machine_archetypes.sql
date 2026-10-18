-- PRD-142a Phase 2, item 4.3: machine archetypes (rules locked in a table).
--
-- Rules were written from the K-means diagnostic (docs/prds/PRD-142-kmeans.md,
-- Boonz k=4 silhouette 0.230; partner k=3 silhouette 0.186). Rule format:
--   {"all": [cond, ...], "override": bool}
--   cond = {"f": feature, "op": ">=|>|<=|<", "v": number}       fixed threshold
--        | {"f": feature, "op": ..., "p": 0.5}                   population percentile
-- Percentiles are computed per population over machines aged >= 90 days on
-- the same as_of. A NULL feature never matches. Evaluation: archetypes of the
-- machine's population (or 'all') in sort_order, first non-override match
-- wins; then an override archetype (SEASONAL_SWINGER) replaces it when it
-- matches, keeping the base in features.base_archetype. A manual override
-- (machine_archetype_override) beats everything until CS clears it.
-- Every change of a machine's archetype writes strategy_change_log.

CREATE TABLE public.machine_archetypes (
  code        text PRIMARY KEY,
  label       text NOT NULL,
  population  text NOT NULL CHECK (population IN ('boonz', 'partner', 'all')),
  description text,
  rule        jsonb NOT NULL,
  sort_order  int NOT NULL
);

CREATE TABLE public.machine_archetype_assignment (
  machine_id     uuid NOT NULL,
  as_of          date NOT NULL,
  archetype_code text NOT NULL REFERENCES public.machine_archetypes(code),
  method         text NOT NULL CHECK (method IN ('rule', 'manual')),
  confidence     numeric,
  features       jsonb,
  PRIMARY KEY (machine_id, as_of)
);
CREATE INDEX machine_archetype_assignment_as_of_idx ON public.machine_archetype_assignment (as_of);

CREATE TABLE public.machine_archetype_override (
  machine_id     uuid PRIMARY KEY,
  archetype_code text NOT NULL REFERENCES public.machine_archetypes(code),
  set_by         uuid,
  set_at         timestamptz NOT NULL DEFAULT now(),
  note           text
);

CREATE TABLE public.strategy_change_log (
  log_id     bigserial PRIMARY KEY,
  entity     text NOT NULL CHECK (entity IN ('machine', 'product')),
  entity_id  uuid NOT NULL,
  field      text NOT NULL,
  old_value  jsonb,
  new_value  jsonb,
  changed_by uuid,
  changed_at timestamptz NOT NULL DEFAULT now(),
  source     text NOT NULL CHECK (source IN ('model', 'cs'))
);
CREATE INDEX strategy_change_log_entity_idx ON public.strategy_change_log (entity, entity_id, changed_at DESC);

COMMENT ON TABLE public.machine_archetypes IS 'PRD-142a 4.3. Locked archetype rules (from the K-means diagnostic). Evaluated nightly by assign_machine_archetypes().';
COMMENT ON TABLE public.machine_archetype_assignment IS 'PRD-142a 4.3. Nightly archetype per machine. confidence: 1.0 rule or manual match, 0.6 fallback archetype (no specific rule matched).';
COMMENT ON TABLE public.machine_archetype_override IS 'PRD-142a 4.3. CS manual archetype; kept until cleared.';
COMMENT ON TABLE public.strategy_change_log IS 'PRD-142a. History of archetype, posture and product strategy changes (source model or cs).';

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['machine_archetypes','machine_archetype_assignment','machine_archetype_override','strategy_change_log'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_admin((SELECT auth.uid())))', t || '_admin_select', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
  END LOOP;
END $$;

INSERT INTO public.machine_archetypes (code, label, population, description, rule, sort_order) VALUES
  ('RAMPING', 'Ramping', 'all',
   'Under 90 days since first sale in the era. Benchmarked on the ramp curve, not on peers.',
   '{"all": [{"f": "age_days", "op": "<", "v": 90}]}', 10),
  ('GYM_GRAB', 'Gym grab', 'boonz',
   'Concentrated peaks outside office lunch hours and a drinks-led mix (GRIT cluster).',
   '{"all": [{"f": "peak_hour_share_90", "op": ">=", "v": 0.45}, {"f": "peak_hours_outside_11_15", "op": ">=", "v": 2}, {"f": "drinks_share_90", "op": ">=", "v": 0.5}]}', 30),
  ('OFFICE_LUNCH_ENGINE', 'Office lunch engine', 'boonz',
   'Weekday lunch-led office at or above the population median volume (K-means core and AMZ engine clusters).',
   '{"all": [{"f": "weekday_lunch_share_90", "op": ">=", "v": 0.35}, {"f": "units_day_90", "op": ">=", "p": 0.5}]}', 40),
  ('PREMIUM_OFFICE', 'Premium office', 'boonz',
   'Office with a high ticket (population 70th percentile) and below-median volume.',
   '{"all": [{"f": "weekday_lunch_share_90", "op": ">=", "v": 0.25}, {"f": "ticket_90", "op": ">=", "p": 0.7}, {"f": "units_day_90", "op": "<", "p": 0.5}]}', 50),
  ('LOBBY_TRICKLE', 'Lobby trickle', 'boonz',
   'Low volume (under the population 40th percentile of units per day). The spec peak-share condition (< 0.30) was dropped: no Boonz machine is under 0.396; the K-means trickle cluster is low volume with about half its shelves dead.',
   '{"all": [{"f": "units_day_90", "op": "<", "p": 0.4}]}', 60),
  ('OFFICE_STANDARD', 'Steady office', 'boonz',
   'Fallback for Boonz machines no specific rule claims (mid volume, lunch share under 0.35 or ticket under the 70th percentile).',
   '{"all": []}', 70),
  ('SEASONAL_SWINGER', 'Seasonal swinger', 'boonz',
   'Monthly net revenue CV >= 0.60 over full months in the era. Overrides the base archetype (kept in features.base_archetype). Threshold raised from 0.45: at 0.45 it claimed 9 of 22 mature machines, mostly growth curves rather than seasonality.',
   '{"all": [{"f": "cv_monthly_12", "op": ">=", "v": 0.60}], "override": true}', 20),
  ('CINEMA_IMPULSE', 'Cinema impulse', 'partner',
   'Leisure venue with weekend share >= 0.30 and ticket >= AED 15 (VOX, ACTIVATE, IFLY, MPMCC cluster). The spec weekend >= 0.40 alone missed real cinemas (VOXMCC-1012 0.346, VOXMCC-1005 0.389).',
   '{"all": [{"f": "weekend_share_90", "op": ">=", "v": 0.30}, {"f": "ticket_90", "op": ">=", "v": 15}]}', 40),
  ('VENUE_STANDARD', 'Venue standard', 'partner',
   'Fallback for partner machines (the LVLUP cluster: ticket about AED 10, weekend share about 0.26, snack-led).',
   '{"all": []}', 70);

CREATE OR REPLACE FUNCTION public.strategy_rule_match(p_feat jsonb, p_rule jsonb, p_pct jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path TO 'public'
AS $$
DECLARE
  c   jsonb;
  val numeric;
  thr numeric;
  ok  boolean;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(COALESCE(p_rule -> 'all', '[]'::jsonb)) LOOP
    val := (p_feat ->> (c ->> 'f'))::numeric;
    IF val IS NULL THEN RETURN false; END IF;
    thr := CASE WHEN c ? 'p' THEN (p_pct ->> ((c ->> 'f') || '@' || (c ->> 'p')))::numeric
                ELSE (c ->> 'v')::numeric END;
    IF thr IS NULL THEN RETURN false; END IF;
    ok := CASE c ->> 'op'
            WHEN '>=' THEN val >= thr WHEN '>' THEN val > thr
            WHEN '<=' THEN val <= thr WHEN '<' THEN val < thr
            ELSE false END;
    IF NOT ok THEN RETURN false; END IF;
  END LOOP;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_machine_archetypes(p_as_of date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_as_of date := COALESCE(p_as_of, (SELECT max(as_of) FROM machine_features));
  v_pct   jsonb := '{}'::jsonb;
  r       record;
  a       record;
  v_feat  jsonb;
  v_base  text;
  v_final text;
  v_conf  numeric;
  v_meth  text;
  v_prev  text;
  v_n     int := 0;
  v_chg   int := 0;
BEGIN
  -- Population percentiles for every (feature, p) the rules use.
  FOR a IN
    SELECT DISTINCT pop.population, c ->> 'f' AS f, (c ->> 'p')::numeric AS p
    FROM machine_archetypes ma
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(ma.rule -> 'all', '[]'::jsonb)) c
    CROSS JOIN (VALUES ('boonz'), ('partner')) pop(population)
    WHERE c ? 'p' AND ma.population IN (pop.population, 'all')
  LOOP
    EXECUTE format('SELECT percentile_cont(%s) WITHIN GROUP (ORDER BY %I) FROM machine_features WHERE as_of = $1 AND population = $2 AND age_days >= 90', a.p, a.f)
      INTO v_conf USING v_as_of, a.population;
    v_pct := v_pct || jsonb_build_object(a.population || ':' || a.f || '@' || a.p, v_conf);
  END LOOP;

  DELETE FROM machine_archetype_assignment WHERE as_of = v_as_of OR as_of < v_as_of - 400;

  FOR r IN SELECT * FROM machine_features WHERE as_of = v_as_of LOOP
    v_feat := to_jsonb(r) - 'created_at' - 'machine_id' - 'as_of' - 'era_id'
              || jsonb_build_object('peak_hours_outside_11_15',
                   (SELECT count(*) FROM unnest(r.peak_hours_90) h WHERE h < 11 OR h > 15));
    v_base := NULL; v_final := NULL;

    FOR a IN
      SELECT * FROM machine_archetypes
      WHERE population IN (r.population, 'all') AND NOT COALESCE((rule ->> 'override')::boolean, false)
      ORDER BY sort_order
    LOOP
      IF strategy_rule_match(v_feat, a.rule,
           (SELECT COALESCE(jsonb_object_agg(split_part(key, ':', 2), value), '{}'::jsonb)
            FROM jsonb_each(v_pct) WHERE split_part(key, ':', 1) = r.population)) THEN
        v_base := a.code;
        v_conf := CASE WHEN jsonb_array_length(COALESCE(a.rule -> 'all', '[]'::jsonb)) = 0 THEN 0.6 ELSE 1.0 END;
        EXIT;
      END IF;
    END LOOP;
    v_final := v_base;

    IF v_base IS DISTINCT FROM 'RAMPING' THEN
      FOR a IN
        SELECT * FROM machine_archetypes
        WHERE population IN (r.population, 'all') AND COALESCE((rule ->> 'override')::boolean, false)
        ORDER BY sort_order
      LOOP
        IF strategy_rule_match(v_feat, a.rule, '{}'::jsonb) THEN
          v_final := a.code; v_conf := 1.0; EXIT;
        END IF;
      END LOOP;
    END IF;

    v_meth := 'rule';
    SELECT archetype_code INTO v_prev FROM machine_archetype_override WHERE machine_id = r.machine_id;
    IF FOUND THEN v_final := v_prev; v_meth := 'manual'; v_conf := 1.0; END IF;

    INSERT INTO machine_archetype_assignment (machine_id, as_of, archetype_code, method, confidence, features)
    VALUES (r.machine_id, v_as_of, v_final, v_meth, v_conf,
            v_feat || jsonb_build_object('base_archetype', v_base,
              'percentiles', (SELECT jsonb_object_agg(split_part(key, ':', 2), value) FROM jsonb_each(v_pct) WHERE split_part(key, ':', 1) = r.population)));
    v_n := v_n + 1;

    SELECT archetype_code INTO v_prev FROM machine_archetype_assignment
    WHERE machine_id = r.machine_id AND as_of < v_as_of ORDER BY as_of DESC LIMIT 1;
    -- First-ever assignment is not a change.
    IF v_prev IS NOT NULL AND v_prev IS DISTINCT FROM v_final THEN
      INSERT INTO strategy_change_log (entity, entity_id, field, old_value, new_value, source)
      VALUES ('machine', r.machine_id, 'archetype', to_jsonb(v_prev), to_jsonb(v_final),
              CASE WHEN v_meth = 'manual' THEN 'cs' ELSE 'model' END);
      v_chg := v_chg + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('as_of', v_as_of, 'machines', v_n, 'changes_logged', v_chg);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.assign_machine_archetypes(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assign_machine_archetypes(date) TO service_role;

SELECT public.assign_machine_archetypes(NULL);
