-- PRD-110 P2.2b - fixture 29, LAW 1 (FIXTURE FIRST). Applied BEFORE v_pod_demand_dispersion_v3
-- exists, so seq 1 is RED on purpose and that failing baseline is recorded in the EXECUTION-LOG.
--
-- What it pins: the dispersion resolver phi = sigma_obs / sqrt(mu_obs), its three-tier fallback
-- ladder with a NAMED source, the canonical pod key, and the RISK 91 delivery_status vocabulary.
--
-- NOTE on the scope check: this fixture uses the PARENTHESISED symmetric difference. The
-- unparenthesised form (fixture 28 seq 3) is left-associative in Postgres - it reduces to
-- ((A EXCEPT B) UNION ALL C) EXCEPT D, which reports 0 for an INVENTED row. See S-46.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  29,
  'Demand dispersion resolver (P2.2b sigma)',
  'PRD-110 S-44 + RISK 91. S-44: sigma history is sparse - the archetype prior is the MAJORITY path, so the prior must be an estimated phi, not a fixed sigma, and phi must never be computed on a different basis from mu (S-13 in a new costume). RISK 91: delivery_status is ''Successful'' and never ''Success'', so the natural-looking literal returns 0 rows, sigma collapses to 0 fleet-wide and every shelf silently loses its safety stock.',
  'P2',
  '2030-01-29',
  true,
  'failing_expected',
  'P2.2b. Pins the dispersion contract: one row per in-scope canonical (machine, pod) pair, phi never NULL, phi_source always named, the own/pod_prior/fleet_prior ladder matching an independent re-derivation, the phi floor honoured, zero-sales pairs still covered, and the pod key CANONICAL (S-37/S-38). Reads nothing but the two views + its own re-derivation; writes only golden.scratch. Cheap: sales-only, not subject to RISK 88.',
$fx29body$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DO $fx29$
DECLARE
  v_payload      jsonb;
  v_rows         bigint;
  v_scope_mm     bigint;
  v_null_phi     bigint;
  v_unnamed      bigint;
  v_phi_mm       bigint;
  v_neg          bigint;
  v_below_floor  bigint;
  v_ok_lit       bigint;
  v_bad_lit      bigint;
  v_own          bigint;
  v_prior        bigint;
  v_own_wo_hist  bigint;
  v_nosales      bigint;
  v_nosales_null bigint;
  v_alias_nonid  bigint;
  v_alias_hunter bigint;
  v_raw_keys     bigint;
  v_min_days     integer;
  v_look         integer;
  v_floor        numeric;
  v_prec         text;
BEGIN
  IF to_regclass('public.v_pod_demand_dispersion_v3') IS NULL
     OR to_regclass('public.v_pod_product_canonical_v3') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES ({{fixture_id}}, 'obs', jsonb_build_object('view_exists','false'));
    RETURN;
  END IF;

  SELECT base_stock_sigma_min_days, base_stock_sigma_lookback_days,
         base_stock_sigma_phi_floor, base_stock_sigma_prior_precedence
    INTO v_min_days, v_look, v_floor, v_prec
    FROM public.refill_policy_params LIMIT 1;

  -- The fixture''s OWN re-derivation, written out in full rather than reusing the view, so that a
  -- later edit which changes the view''s MEANING is caught rather than mirrored. The pod alias is
  -- the same inline literal both canonical velocity objects carry, which makes this fixture the
  -- standing guard that v_pod_product_canonical_v3 has not drifted away from them (S-37 / S-38).
  CREATE TEMP TABLE fx29_exp ON COMMIT DROP AS
  WITH alias(pod_product_id, canonical_pod) AS (
    VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid,'51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
  ), scope AS (
    SELECT DISTINCT ss.machine_id, COALESCE(al.canonical_pod, ss.pod_product_id) AS pod
      FROM public.v_shelf_state ss
      LEFT JOIN alias al ON al.pod_product_id = ss.pod_product_id
     WHERE ss.pod_product_id IS NOT NULL
  ), d AS (
    SELECT s.machine_id, COALESCE(al.canonical_pod, s.pod_product_id) AS pod,
           s.transaction_date::date AS dt, SUM(s.qty) AS q
      FROM public.v_sales_history_resolved s
      JOIN (SELECT DISTINCT machine_id FROM scope) sc ON sc.machine_id = s.machine_id
      LEFT JOIN alias al ON al.pod_product_id = s.pod_product_id
     WHERE s.pod_product_id IS NOT NULL
       AND s.delivery_status = ANY (ARRAY['Success','Successful'])
       AND s.transaction_date::date >= CURRENT_DATE - v_look
     GROUP BY 1,2,3
  ), agg AS (
    SELECT machine_id, pod, count(*)::int AS n_days,
           avg(q)::numeric AS mu_obs, stddev_samp(q)::numeric AS sd_obs
      FROM d GROUP BY 1,2
  ), ownp AS (
    SELECT machine_id, pod, n_days, mu_obs, sd_obs,
           CASE WHEN n_days >= v_min_days AND mu_obs > 0 AND sd_obs IS NOT NULL
                THEN sd_obs / sqrt(mu_obs) END AS phi_own
      FROM agg
  ), podp AS (
    SELECT pod, percentile_cont(0.5) WITHIN GROUP (ORDER BY phi_own)::numeric AS phi_pod
      FROM ownp WHERE phi_own IS NOT NULL GROUP BY pod
  ), fl AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY phi_own)::numeric AS phi_fleet
      FROM ownp WHERE phi_own IS NOT NULL
  )
  SELECT s.machine_id, s.pod, o.n_days, o.mu_obs, o.sd_obs,
         o.phi_own, pp.phi_pod, f.phi_fleet,
         CASE WHEN o.phi_own IS NOT NULL                                   THEN 'own'
              WHEN v_prec <> 'fleet_only' AND pp.phi_pod IS NOT NULL       THEN 'pod_prior'
              WHEN f.phi_fleet IS NOT NULL                                 THEN 'fleet_prior'
              ELSE 'floor_no_history' END AS exp_source,
         GREATEST(v_floor,
                  COALESCE(o.phi_own,
                           CASE WHEN v_prec <> 'fleet_only' THEN pp.phi_pod END,
                           f.phi_fleet,
                           v_floor)) AS exp_phi
    FROM scope s
    CROSS JOIN fl f
    LEFT JOIN ownp o  ON o.machine_id = s.machine_id AND o.pod = s.pod
    LEFT JOIN podp pp ON pp.pod = s.pod;

  EXECUTE 'CREATE TEMP TABLE fx29_act ON COMMIT DROP AS SELECT * FROM public.v_pod_demand_dispersion_v3';

  SELECT count(*) INTO v_rows FROM fx29_act;

  -- PARENTHESISED symmetric difference: catches a DROPPED pair and an INVENTED one (S-46).
  SELECT count(*) INTO v_scope_mm FROM (
    (SELECT machine_id, pod_product_id FROM fx29_act
     EXCEPT
     SELECT machine_id, pod            FROM fx29_exp)
    UNION ALL
    (SELECT machine_id, pod            FROM fx29_exp
     EXCEPT
     SELECT machine_id, pod_product_id FROM fx29_act)
  ) q;

  SELECT count(*) FILTER (WHERE phi IS NULL),
         count(*) FILTER (WHERE phi_source IS NULL
                             OR phi_source NOT IN ('own','pod_prior','fleet_prior','floor_no_history')),
         count(*) FILTER (WHERE phi < 0),
         count(*) FILTER (WHERE phi < v_floor),
         count(*) FILTER (WHERE phi_source = 'own'),
         count(*) FILTER (WHERE phi_source IN ('pod_prior','fleet_prior','floor_no_history')),
         count(*) FILTER (WHERE phi_source = 'own'
                            AND (n_sale_days IS NULL OR n_sale_days < v_min_days))
    INTO v_null_phi, v_unnamed, v_neg, v_below_floor, v_own, v_prior, v_own_wo_hist
    FROM fx29_act;

  SELECT count(*) INTO v_phi_mm
    FROM fx29_act a
    JOIN fx29_exp e ON e.machine_id = a.machine_id AND e.pod = a.pod_product_id
   WHERE a.phi_source IS DISTINCT FROM e.exp_source
      OR round(a.phi, 9) IS DISTINCT FROM round(e.exp_phi, 9);

  -- Pairs with ZERO sales rows in the window must still be covered with a non-NULL phi, or the
  -- engine sizes them off nothing. 52 such pairs measured 2026-07-31.
  SELECT count(*), count(*) FILTER (WHERE a.phi IS NULL)
    INTO v_nosales, v_nosales_null
    FROM fx29_act a
    JOIN fx29_exp e ON e.machine_id = a.machine_id AND e.pod = a.pod_product_id
   WHERE e.n_days IS NULL;

  -- RISK 91 tripwire. The correct filter must be non-vacuous AND the bare ''Success'' literal must
  -- match nothing - which is exactly why a build that used it would silently produce sigma = 0.
  SELECT count(*) FILTER (WHERE delivery_status = ANY (ARRAY['Success','Successful'])),
         count(*) FILTER (WHERE delivery_status = 'Success')
    INTO v_ok_lit, v_bad_lit
    FROM public.v_sales_history_resolved
   WHERE transaction_date::date >= CURRENT_DATE - v_look;

  -- The canonical alias owner must agree EXACTLY with the inline literal the velocity objects use.
  SELECT count(*) FILTER (WHERE pod_product_id IS DISTINCT FROM canonical_pod_product_id),
         count(*) FILTER (WHERE pod_product_id            = '168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid
                            AND canonical_pod_product_id  = '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
    INTO v_alias_nonid, v_alias_hunter
    FROM public.v_pod_product_canonical_v3;

  -- No row may be keyed by a NON-canonical pod id (the S-37 asymmetry, in its new home).
  SELECT count(*) INTO v_raw_keys
    FROM fx29_act a
    JOIN public.v_pod_product_canonical_v3 c ON c.pod_product_id = a.pod_product_id
   WHERE c.canonical_pod_product_id IS DISTINCT FROM a.pod_product_id;

  v_payload := jsonb_build_object(
    'view_exists',       'true',
    'rows',              v_rows::text,
    'scope_mismatch',    v_scope_mm::text,
    'null_phi',          v_null_phi::text,
    'unnamed_phi_source',v_unnamed::text,
    'phi_mismatch',      v_phi_mm::text,
    'phi_negative',      v_neg::text,
    'phi_below_floor',   v_below_floor::text,
    'tier_own',          v_own::text,
    'tier_prior',        v_prior::text,
    'own_without_history', v_own_wo_hist::text,
    'no_sales_pairs',    v_nosales::text,
    'no_sales_null_phi', v_nosales_null::text,
    'sales_rows_correct_literal', v_ok_lit::text,
    'sales_rows_bare_success',    v_bad_lit::text,
    'alias_nonidentity', v_alias_nonid::text,
    'alias_hunter_present', v_alias_hunter::text,
    'noncanonical_keys', v_raw_keys::text);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx29$;
$fx29body$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(29, 1, 'The dispersion resolver and the canonical pod-alias owner both exist (red until the P2.2b view migration lands - this is the recorded LAW-1 baseline)',
 'SELECT value->>''view_exists'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'true', true, 'P2'),
(29, 2, 'NON-VACUITY: the resolver returns rows at all, so every mismatch=0 assertion below is earned rather than vacuous',
 'SELECT value->>''rows'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P2'),
(29, 3, 'SCOPE: exactly one row per in-scope canonical (machine, pod) pair - none dropped, none invented (PARENTHESISED symmetric difference, S-46)',
 'SELECT value->>''scope_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 4, 'LAW 5: no pair resolves to a NULL phi. A NULL phi propagates to a NULL sigma and the base-stock term vanishes silently',
 'SELECT value->>''null_phi'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 5, 'LAW 6: phi_source NAMES which tier fired - always one of own / pod_prior / fleet_prior / floor_no_history, never invented and never NULL',
 'SELECT value->>''unnamed_phi_source'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 6, 'CONTRACT: phi and phi_source match the fixture''s INDEPENDENT re-derivation on every pair (ladder, precedence param and floor all included)',
 'SELECT value->>''phi_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 7, 'SANITY: phi is never negative - a negative dispersion would subtract safety stock',
 'SELECT value->>''phi_negative'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 8, 'FLOOR HONOURED: no pair sits below base_stock_sigma_phi_floor (inert at 0 today; this is the assertion that makes D-15 a one-line UPDATE)',
 'SELECT value->>''phi_below_floor'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 9, 'S-44 NON-VACUITY (own): the own-history tier actually fires on real pairs - if this hits 0 the ladder has collapsed to prior-only and phi stopped being machine-specific',
 'SELECT value->>''tier_own'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P2'),
(29, 10, 'S-44 NON-VACUITY (prior): the prior tier fires too - S-44 measured it as the MAJORITY path, so a 0 here means the min-history guard silently stopped guarding',
 'SELECT value->>''tier_prior'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P2'),
(29, 11, 'MIN-HISTORY GUARD: no pair claims phi_source=own while holding fewer than base_stock_sigma_min_days of history',
 'SELECT value->>''own_without_history'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 12, 'ZERO-SALES COVERAGE, non-vacuity: pairs with no sales at all in the window exist (52 measured 2026-07-31) - they are the ones a sales-driven view would silently drop',
 'SELECT value->>''no_sales_pairs'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P2'),
(29, 13, 'ZERO-SALES COVERAGE: every one of those pairs still carries a non-NULL phi - the view is scoped from shelf state, not driven by sales',
 'SELECT value->>''no_sales_null_phi'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 14, 'RISK 91 non-vacuity: the correct delivery_status filter matches real rows in the window',
 'SELECT value->>''sales_rows_correct_literal'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P2'),
(29, 15, 'RISK 91 TRIPWIRE: the bare ''''Success'''' literal still matches ZERO rows. That is precisely why a sigma built on it would be 0 fleet-wide with no error. If this ever goes red the vocabulary changed and every delivery_status filter must be revisited',
 'SELECT value->>''sales_rows_bare_success'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2'),
(29, 16, 'S-38 ALIAS OWNER: v_pod_product_canonical_v3 carries EXACTLY the same non-identity mapping the two velocity objects inline (one pair). A 2nd non-identity row means an alias was added in one place and not the other',
 'SELECT value->>''alias_nonidentity'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '1', true, 'P2'),
(29, 17, 'S-38 ALIAS OWNER: and that one pair is the Hunter pair the velocity objects actually use',
 'SELECT value->>''alias_hunter_present'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '1', true, 'P2'),
(29, 18, 'S-37 IN ITS NEW HOME: no dispersion row is keyed by a NON-canonical pod id. This is the exact asymmetry that made the velocity split join a raw key against a canonical one',
 'SELECT value->>''noncanonical_keys'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P2');
