-- PRD-110 · D-31 · leg 152
-- FIXTURE 72 — RED BASELINE, applied and fired BEFORE the convergence migration (LAW 1).
--
-- D-31 ruling (CS 2026-08-01): "CONVERGE the price cascade into ONE canonical unit-value
-- object; both consumers read it."
--
-- THE TWO CONSUMERS, RE-DERIVED FROM THE CATALOGUE AND NOT FROM THE PARKING LOT (S-280).
--    The scoping note in the parking lot names two objects. A `prosrc ILIKE '%recommended_
--    selling_price%'` grep returns FIVE, and it cannot tell a three-tier cascade from a
--    single-tier read. The predicate that settles it - the shape S-280 prescribes - is
--    "carries a COALESCE onto recommended_selling_price AND mentions realized":
--      · rank_machines_by_value_at_risk_v3   <- cascade (var_price_lookback_days)
--      · v_facing_performance_v3             <- cascade (fac_price_lookback_days)
--      · v_pod_margin_coverage_v3            <- COALESCE, NO realized tier. NOT a site.
--      · v_shelf_audit_prompts               <- COALESCE, NO realized tier. NOT a site.
--      · find_substitutes_for_shelf_v3       <- names the column only.  NOT a site.
--    Two sites, exactly as the ruling says - but the grep would have said five and the
--    leg-68 note would have been taken on trust. seq 9 pins the predicate, not the count.
--
-- THE PARKING LOT'S PREMISE IS FALSE, AND THAT IS THIS UNIT'S HEADLINE (S-288).
--    D-31 and METRICS_REGISTRY line 751 both record the second copy as harmless because it
--    was "copied verbatim so the two objects cannot disagree about what a unit is worth
--    (S-94)". It is NOT verbatim. The two copies read DIFFERENT DIALS:
--      · rank_machines_by_value_at_risk_v3 -> refill_policy_params.var_price_lookback_days
--      · v_facing_performance_v3           -> refill_policy_params.fac_price_lookback_days
--    Both read 90 today, so the copies agree BY COINCIDENCE OF TWO DIAL VALUES, not by
--    construction. The day CS turns either dial the two objects disagree about what a unit
--    is worth and nothing anywhere would say so. seq 5 is that sensor.
--
--    Which is also why the canonical object takes the lookback as a PARAMETER instead of
--    reading one dial. Converging the ARITHMETIC is a refactor; converging the two POLICY
--    DIALS into one would silently retire a dial CS owns, and that is not this unit's to
--    make. seqs 13/14 pin that each consumer still passes its OWN dial.
--
-- THE ONE-SCAN ROLLUP, AND WHY IT IS EXACT RATHER THAN CLOSE.
--    Each consumer scans the 90-day sales window TWICE today - once grouped by
--    (machine, pod), once by (pod). The canonical object groups ONCE into (machine, pod)
--    sums and derives the fleet tier by summing those sums:
--        fleet = SUM(sum_paid) / SUM(sum_qty)   ==   SUM(paid) / SUM(qty)
--    identical because summation is associative, NOT because the numbers happen to match.
--    The HAVING is applied INDEPENDENTLY AT EACH GRAIN, never before the rollup: a
--    (machine, pod) group with sum(qty) <= 0 is excluded from the machine tier but must
--    still contribute to the fleet total, exactly as the two-scan form does. Live today
--    that population is 0 rows (seq 6) - so the distinction is INERT, and it is written
--    this way precisely so it cannot rot into a defect the day a refund lands.
--
-- THE DOMAIN TRAP, MEASURED NOT ASSUMED.
--    The obvious grid for the canonical object is machines x pod_products. Live, ONE pod
--    carries realized sales and is NOT in pod_products - so that grid would silently drop
--    a machine-pod price the inline cascade returns today. The grid is therefore the UNION
--    of (machines x pod_products), (machines x pods-with-fleet-prices) and the realized
--    (machine, pod) pairs themselves. seq 7 is the premise sensor for that pod and seq 19
--    proves the canonical object still covers it.
--
-- THIS FIXTURE WRITES NOTHING. The cascade is a pure read over live state, so there is no
--    plant, no subtransaction, no RAISE and no DELETE against any protected table. Every
--    assertion is a PROPERTY or an INVARIANCE (S-257), and the premise sensors fail LOUDLY
--    and by name if live data ever stops supplying the case (S-274).
--
-- S-267: every equivalence below is measured against the LEGACY FORMULA TRANSCRIBED
--    LITERALLY from the two live bodies - never by re-reading the object under test.
-- S-266: golden.scratch is written at the END, in one statement, never mid-scenario.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  72,
  'D-31: one canonical definition of what a unit is worth. The three-tier price cascade (realized machine-pod -> realized fleet-pod -> recommended_selling_price) was written inline in two objects - rank_machines_by_value_at_risk_v3, which turns it into money at risk, and v_facing_performance_v3, which turns it into revenue per facing. It now lives in one object both read. The two copies were recorded as harmless because they were "verbatim"; they are not - they read DIFFERENT lookback dials and agreed only because both dials read 90. The canonical object takes the lookback as a PARAMETER so the convergence does not silently retire a policy dial CS owns.',
  'D-31 (CS 2026-08-01) - raised by Cody at the leg-68 v_facing_performance_v3 review - Article 16 debt recorded at METRICS_REGISTRY line 751',
  'P3',
  DATE '2030-06-19',
  true,
  'failing_expected',
  'Leg 152. RED baseline applied and fired before 20260808150500. Structural seqs 8-14 and equivalence seqs 15-21 are red until the convergence lands; premise seqs 1-7 and invariance seqs 22-24 are green on BOTH sides - a refactor that changes behaviour is not a refactor (fixture 71 seq 22 / fixture 70 seq 21 idiom).',
$fx72$
DO $do$
DECLARE
  c_lb_var      int;
  c_lb_fac      int;

  v_rank_src    text;
  v_vfp_def     text;
  v_canon_src   text := '';

  -- premise
  v_mp_rows     int := -1;
  v_fleet_rows  int := -1;
  v_rsp_pods    int := -1;
  v_orphan_pods int := -1;
  v_nonpos_grp  int := -1;

  -- structure
  v_canon_n     int := -1;
  v_canon_vol   text := 'absent';
  v_canon_acl   int := -1;
  v_canon_rows  int := -1;
  v_inline_n    int := -1;
  v_vfp_refs    int := -1;
  v_rank_refs   int := -1;
  v_vfp_dial    text := 'absent';
  v_rank_dial   text := 'absent';
  v_vfp_inline  int := -1;
  v_rank_inline int := -1;

  -- equivalence
  v_mp_cmp      int := -1;
  v_mp_bad      int := -1;
  v_fl_cmp      int := -1;
  v_fl_bad      int := -1;
  v_bs_cmp      int := -1;
  v_bs_bad      int := -1;
  v_orphan_ok   text := 'absent';
  v_rollup_bad  int := -1;

  -- residue
  v_law12       int := -1;
  v_via_trig    text := 'absent';
  v_via_rpc     text := 'absent';

  s_premise jsonb := '{}'::jsonb;
  s_struct  jsonb := '{}'::jsonb;
  s_equiv   jsonb := '{}'::jsonb;
  s_residue jsonb := '{}'::jsonb;
BEGIN
  DELETE FROM golden.scratch WHERE fixture_id = 72;

  SELECT var_price_lookback_days, fac_price_lookback_days
    INTO c_lb_var, c_lb_fac
    FROM public.refill_policy_params LIMIT 1;

  ---------------------------------------------------------------- 0. SOURCES --
  SELECT p.prosrc INTO v_rank_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rank_machines_by_value_at_risk_v3';

  SELECT pg_get_viewdef(c.oid, true) INTO v_vfp_def
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'v_facing_performance_v3';

  SELECT COALESCE(p.prosrc, '') INTO v_canon_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'pod_unit_value_v3';
  v_canon_src := COALESCE(v_canon_src, '');

  ------------------------------------------------- 1. THE LEGACY FORMULA (S-267) --
  -- Transcribed literally from the two live bodies. Everything downstream is measured
  -- against THIS, never against the object under test. Built at the var dial; the fac
  -- dial reads the same value today (seq 5 is the sensor for the day it does not).
  CREATE TEMP TABLE _legacy_base ON COMMIT DROP AS
    SELECT v.machine_id, v.pod_product_id,
           sum(sh.paid_amount) AS sum_paid,
           sum(sh.qty)         AS sum_qty
      FROM public.v_sales_history_resolved v
      JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
     WHERE v.transaction_date >= CURRENT_DATE - c_lb_var
     GROUP BY 1, 2;

  CREATE TEMP TABLE _legacy_mp ON COMMIT DROP AS
    SELECT machine_id, pod_product_id, sum_paid / NULLIF(sum_qty, 0) AS unit_price
      FROM _legacy_base WHERE sum_qty > 0;

  -- The fleet tier the LEGACY way: a SECOND independent scan of the same window.
  CREATE TEMP TABLE _legacy_fleet ON COMMIT DROP AS
    SELECT v.pod_product_id, sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
      FROM public.v_sales_history_resolved v
      JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
     WHERE v.transaction_date >= CURRENT_DATE - c_lb_var
     GROUP BY 1
    HAVING sum(sh.qty) > 0;

  ------------------------------------------------------------- 2. PREMISES --
  SELECT count(*) INTO v_mp_rows    FROM _legacy_mp;
  SELECT count(*) INTO v_fleet_rows FROM _legacy_fleet;
  SELECT count(*) INTO v_rsp_pods   FROM public.pod_products WHERE recommended_selling_price > 0;
  SELECT count(*) INTO v_nonpos_grp FROM _legacy_base WHERE sum_qty <= 0;

  SELECT count(*) INTO v_orphan_pods FROM (
    SELECT DISTINCT pod_product_id FROM _legacy_base
    EXCEPT
    SELECT pod_product_id FROM public.pod_products) q;

  ------------------------------------------- 3. STRUCTURE (catalogue, no writes) --
  SELECT count(*) INTO v_canon_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'pod_unit_value_v3';

  SELECT COALESCE(p.provolatile::text || '|' || p.prosecdef::text, 'absent') INTO v_canon_vol
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'pod_unit_value_v3';
  v_canon_vol := COALESCE(v_canon_vol, 'absent');

  -- S-268: naming anon EXPLICITLY. A bare REVOKE ... FROM PUBLIC does not remove
  -- Supabase's schema default privileges, so counting only PUBLIC would read clean
  -- while anon still held EXECUTE.
  IF v_canon_n > 0 THEN
    SELECT count(*) INTO v_canon_acl
      FROM pg_proc p, aclexplode(p.proacl) a
     WHERE p.proname = 'pod_unit_value_v3'
       AND p.pronamespace = 'public'::regnamespace
       AND a.privilege_type = 'EXECUTE'
       AND (a.grantee = 0 OR a.grantee = COALESCE(
              (SELECT oid FROM pg_roles WHERE rolname = 'anon'), -1));
  ELSE
    v_canon_acl := -1;
  END IF;

  -- THE S-280 PREDICATE, standing as a sensor rather than a one-off scoping query.
  -- Counts every function/view in public that still carries the THREE-TIER cascade
  -- inline - a COALESCE onto recommended_selling_price AND a realized tier - excluding
  -- the canonical object itself. 2 before the convergence, 0 after. This is what stops
  -- a future object from quietly growing a third copy.
  SELECT count(*) INTO v_inline_n FROM (
    SELECT p.proname AS obj, p.prosrc AS body
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
       AND p.proname <> 'pod_unit_value_v3'
    UNION ALL
    SELECT c.relname, pg_get_viewdef(c.oid, true)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('v','m')
  ) s
  -- ⛔ {0,200}, NOT {0,400}: Postgres POSIX regex caps a repetition count at 255
  -- (RE_DUP_MAX) and raises "invalid repetition count(s)" above it. Found by the S-287
  -- dry run - the migration APPLIED cleanly and the SCENARIO was what failed.
  WHERE s.body ~* 'COALESCE\s*\([^;]{0,200}recommended_selling_price'
    AND s.body ~* 'realized_fleet_pod';

  v_vfp_refs    := (SELECT count(*) FROM regexp_matches(v_vfp_def,  'pod_unit_value_v3', 'g'));
  v_rank_refs   := (SELECT count(*) FROM regexp_matches(v_rank_src, 'pod_unit_value_v3', 'g'));
  v_vfp_inline  := (SELECT count(*) FROM regexp_matches(v_vfp_def,  'realized_fleet_pod', 'g'));
  v_rank_inline := (SELECT count(*) FROM regexp_matches(v_rank_src, 'realized_fleet_pod', 'g'));

  -- Each consumer must still pass its OWN dial. If a future edit points both at one
  -- dial, a policy dial CS owns has been retired by a refactor and these go red.
  IF v_vfp_def ~* 'pod_unit_value_v3\s*\(\s*[a-z_.]*fac_price_lookback_days'
     THEN v_vfp_dial := 'fac_price_lookback_days';
  ELSIF v_vfp_def ~* 'pod_unit_value_v3' THEN v_vfp_dial := 'other';
  END IF;

  IF v_rank_src ~* 'pod_unit_value_v3\s*\(\s*[a-z_.]*var_price_lookback_days'
     THEN v_rank_dial := 'var_price_lookback_days';
  ELSIF v_rank_src ~* 'pod_unit_value_v3' THEN v_rank_dial := 'other';
  END IF;

  --------------------------------------------------------- 4. EQUIVALENCE --
  -- Late-bound: the canonical object does not exist on the RED side, so this whole
  -- block is skipped and the counters stay at -1 rather than raising. A scenario that
  -- RAISEs rolls back its own scratch DELETE and reports GREEN off the previous
  -- snapshot (S-266) - the exact failure this guard exists to avoid.
  IF v_canon_n > 0 THEN
    EXECUTE format(
      'CREATE TEMP TABLE _canon ON COMMIT DROP AS
         SELECT machine_id, pod_product_id, unit_price, price_basis
           FROM public.pod_unit_value_v3(%s)', c_lb_var);

    SELECT count(*) INTO v_canon_rows FROM _canon;

    -- (a) machine-pod tier: every realized machine-pod price the legacy formula
    --     produces must come back byte-identical from the canonical object.
    SELECT count(*), count(*) FILTER (WHERE c.unit_price IS DISTINCT FROM l.unit_price)
      INTO v_mp_cmp, v_mp_bad
      FROM _legacy_mp l
      JOIN _canon c ON c.machine_id = l.machine_id AND c.pod_product_id = l.pod_product_id;

    -- (b) fleet tier: compared where the machine tier is ABSENT, which is the only
    --     place the cascade can actually select it.
    SELECT count(*), count(*) FILTER (WHERE c.unit_price IS DISTINCT FROM f.unit_price)
      INTO v_fl_cmp, v_fl_bad
      FROM _canon c
      JOIN _legacy_fleet f ON f.pod_product_id = c.pod_product_id
      LEFT JOIN _legacy_mp l ON l.machine_id = c.machine_id AND l.pod_product_id = c.pod_product_id
     WHERE l.machine_id IS NULL;

    -- (c) the CASCADE itself: price_basis recomputed from the legacy tiers and
    --     compared row for row across the canonical object's whole domain.
    SELECT count(*), count(*) FILTER (WHERE c.price_basis IS DISTINCT FROM expected)
      INTO v_bs_cmp, v_bs_bad
      FROM (
        SELECT c.machine_id, c.pod_product_id, c.price_basis,
               CASE WHEN l.unit_price IS NOT NULL THEN 'realized_machine_pod'
                    WHEN f.unit_price IS NOT NULL THEN 'realized_fleet_pod'
                    WHEN pp.recommended_selling_price > 0 THEN 'recommended_price'
                    ELSE 'none' END AS expected
          FROM _canon c
          LEFT JOIN _legacy_mp    l  ON l.machine_id = c.machine_id AND l.pod_product_id = c.pod_product_id
          LEFT JOIN _legacy_fleet f  ON f.pod_product_id = c.pod_product_id
          LEFT JOIN public.pod_products pp ON pp.pod_product_id = c.pod_product_id
      ) c;

    -- (d) the domain trap: the pod that carries realized sales and is NOT in
    --     pod_products is still covered, at every machine that sold it.
    SELECT CASE WHEN count(*) = 0 THEN 'no_orphan'
                WHEN count(*) FILTER (WHERE cov) = count(*) THEN 'yes'
                ELSE 'no' END
      INTO v_orphan_ok
      FROM (
        SELECT EXISTS (SELECT 1 FROM _canon c
                        WHERE c.machine_id = b.machine_id
                          AND c.pod_product_id = b.pod_product_id) AS cov
          FROM (SELECT DISTINCT machine_id, pod_product_id FROM _legacy_base) b
         WHERE b.pod_product_id NOT IN (SELECT pod_product_id FROM public.pod_products)
      ) q;

    -- (e) the one-scan rollup is EXACT: the fleet tier derived by summing the
    --     (machine, pod) sums equals the fleet tier from an independent second scan,
    --     on every pod. Associativity, proven rather than asserted.
    SELECT count(*) INTO v_rollup_bad FROM (
      SELECT r.pod_product_id
        FROM (SELECT pod_product_id, sum(sum_paid) / NULLIF(sum(sum_qty), 0) AS up
                FROM _legacy_base GROUP BY 1 HAVING sum(sum_qty) > 0) r
        FULL JOIN _legacy_fleet f ON f.pod_product_id = r.pod_product_id
       WHERE r.up IS DISTINCT FROM f.unit_price
    ) q;
  END IF;

  ------------------------------------------------------------- 5. RESIDUE --
  SELECT (SELECT count(*) FROM public.refill_plan_output   WHERE plan_date = DATE '2030-06-19')
       + (SELECT count(*) FROM public.refill_plan_output_shadow WHERE plan_date = DATE '2030-06-19')
    INTO v_law12;

  v_via_trig := COALESCE(NULLIF(current_setting('app.via_trigger', true), ''), '<unset>');
  v_via_rpc  := COALESCE(NULLIF(current_setting('app.via_rpc',     true), ''), '<unset>');

  ------------------------------------------------------------- 6. SCRATCH --
  s_premise := jsonb_build_object(
    'mp_rows', v_mp_rows, 'fleet_rows', v_fleet_rows, 'rsp_pods', v_rsp_pods,
    'orphan_pods', v_orphan_pods, 'nonpos_groups', v_nonpos_grp,
    'lb_var', c_lb_var, 'lb_fac', c_lb_fac,
    'dials_equal', CASE WHEN c_lb_var = c_lb_fac THEN 'yes' ELSE 'no' END);

  s_struct := jsonb_build_object(
    'canon_objects', v_canon_n, 'canon_volatility', v_canon_vol,
    'canon_anon_or_public_exec', v_canon_acl, 'canon_rows', v_canon_rows,
    'inline_cascade_sites', v_inline_n,
    'vfp_refs_canon', v_vfp_refs, 'rank_refs_canon', v_rank_refs,
    'vfp_inline_cascade', v_vfp_inline, 'rank_inline_cascade', v_rank_inline,
    'vfp_dial', v_vfp_dial, 'rank_dial', v_rank_dial);

  s_equiv := jsonb_build_object(
    'mp_compared', v_mp_cmp, 'mp_mismatch', v_mp_bad,
    'fleet_compared', v_fl_cmp, 'fleet_mismatch', v_fl_bad,
    'basis_compared', v_bs_cmp, 'basis_mismatch', v_bs_bad,
    'orphan_covered', v_orphan_ok, 'rollup_mismatch', v_rollup_bad);

  s_residue := jsonb_build_object(
    'law12', v_law12, 'via_trigger', v_via_trig, 'via_rpc', v_via_rpc);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (72, 'premise', s_premise),
    (72, 'struct',  s_struct),
    (72, 'equiv',   s_equiv),
    (72, 'residue', s_residue);
END $do$;
$fx72$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ============================== PREMISES — live data must keep supplying the case (S-274) ==============================
(72, 1, 'D-31 premise: the 90-day window supplies a non-empty REALIZED MACHINE-POD population. This fixture plants nothing - the cascade is a pure read - so if sales ever stopped, every equivalence assertion below would compare an empty set and pass vacuously. It fails HERE and by name instead. Measured at leg 152: 720 machine-pod prices.',
 'SELECT COALESCE((SELECT value->>''mp_rows'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'gte', '100', true, 'P3'),
(72, 2, 'D-31 premise: the REALIZED FLEET-POD tier is non-empty too. Tier 2 is the middle rung of the cascade and seq 17 compares it; without this sensor a fleet-tier regression would hide behind an empty join. Measured at leg 152: 111 pods.',
 'SELECT COALESCE((SELECT value->>''fleet_rows'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'gte', '10', true, 'P3'),
(72, 3, 'D-31 premise: the RECOMMENDED-PRICE tier is non-empty - pod_products carries pods with recommended_selling_price > 0. Tier 3 is the fallback the cascade lands on for everything unsold, and seq 18 discriminates it only if it is populated.',
 'SELECT COALESCE((SELECT value->>''rsp_pods'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'gte', '10', true, 'P3'),
(72, 4, 'D-31 DOMAIN TRAP premise: at least one pod carries realized sales and is NOT in pod_products. ⛔ This is why the canonical object cannot be built on the obvious machines x pod_products grid - that grid would silently drop a machine-pod price the inline cascade returns today. Measured at leg 152: exactly 1 such pod. If this ever reads 0 the trap has gone latent and seq 19 stops discriminating.',
 'SELECT COALESCE((SELECT value->>''orphan_pods'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'gte', '1', true, 'P3'),
(72, 5, 'D-31 S-288 SENSOR - THE PREMISE THE PARKING LOT GOT WRONG. The two inline copies were recorded as harmless because they were "copied verbatim so the two objects cannot disagree about unit value" (S-94, METRICS_REGISTRY line 751). They are NOT verbatim: rank_machines_by_value_at_risk_v3 reads var_price_lookback_days and v_facing_performance_v3 reads fac_price_lookback_days. They agree today only because both dials read the same number. ⛔ This assertion states that coincidence OUT LOUD. The day it goes red, the two consumers are pricing a unit differently and seqs 13/14 are what keep that legal instead of silent.',
 'SELECT COALESCE((SELECT value->>''dials_equal'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'eq', 'yes', true, 'P3'),
(72, 6, 'D-31 premise: no (machine, pod) sales group in the window has sum(qty) <= 0. The canonical object applies the HAVING independently at each grain precisely so such a group would be excluded from the machine tier yet still contribute to the fleet total - the two-scan behaviour. Live that population is 0, so the distinction is INERT and seq 20 cannot discriminate it. ⛔ The day a refund makes this non-zero, seq 20 becomes the assertion that proves the rollup still matches, and it will already be in place.',
 'SELECT COALESCE((SELECT value->>''nonpos_groups'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'eq', '0', true, 'P3'),
(72, 7, 'D-31 premise: the lookback dial the legacy transcription uses is a real positive number read from refill_policy_params, not a hardcoded 90. A fixture that hardcoded the window would stop testing the live cascade the moment CS turned the dial.',
 'SELECT COALESCE((SELECT value->>''lb_var'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'gte', '1', true, 'P3'),

-- ============================== STRUCTURE — red until the convergence lands ==============================
(72, 8, 'D-31 STRUCTURE: exactly one canonical unit-value object exists in public. This is the ruling''s literal demand - "converge the price cascade into ONE canonical unit-value object".',
 'SELECT COALESCE((SELECT value->>''canon_objects'' FROM golden.scratch WHERE fixture_id=72 AND key=''struct''),''absent'')', 'eq', '1', true, 'P3'),
(72, 9, 'D-31 S-280 STANDING PREDICATE - the assertion that stops a THIRD copy. Counts every function and view in public (excluding the canonical object) that still carries the three-tier cascade inline, identified by SHAPE - a COALESCE reaching recommended_selling_price AND a realized_fleet_pod tier - not by a name grep. ⛔ A name grep returns FIVE objects here and cannot tell a cascade from a single-tier read; v_pod_margin_coverage_v3 and v_shelf_audit_prompts COALESCE onto the same column and are NOT sites. Reads 2 before the convergence, 0 after, and goes red the day anyone pastes the cascade anywhere again.',
 'SELECT COALESCE((SELECT value->>''inline_cascade_sites'' FROM golden.scratch WHERE fixture_id=72 AND key=''struct''),''absent'')', 'eq', '0', true, 'P3'),
(72, 10, 'D-31 LAW 4 PIN (fixture 42 seq 51 idiom): the canonical object is STABLE and SECURITY INVOKER, so Postgres itself enforces that a read-only price object can never write and never escalates privilege. A convergence that centralises what a unit is worth must not also centralise a definer.',
 'SELECT COALESCE((SELECT value->>''canon_volatility'' FROM golden.scratch WHERE fixture_id=72 AND key=''struct''),''absent'')', 'eq', 's|false', true, 'P3'),
(72, 11, 'D-31 S-268 GRANT PIN: zero EXECUTE grants on the canonical object for anon or for PUBLIC, with anon named EXPLICITLY rather than inferred from a REVOKE. ⛔ S-268: a bare REVOKE ALL ... FROM PUBLIC does not remove Supabase''s schema default privileges, so counting PUBLIC alone reads clean while anon still holds EXECUTE - which is exactly the exposure D-30 had to be executed for.',
 'SELECT COALESCE((SELECT value->>''canon_anon_or_public_exec'' FROM golden.scratch WHERE fixture_id=72 AND key=''struct''),''absent'')', 'eq', '0', true, 'P3'),
(72, 12, 'D-31 STRUCTURE: v_facing_performance_v3 no longer carries the cascade inline (zero realized_fleet_pod occurrences) and references the canonical object exactly once. Both halves matter - deleting the copy without reading the canonical object would be a deletion, not a convergence.',
 'SELECT COALESCE((SELECT (value->>''vfp_inline_cascade'')||''/''||(value->>''vfp_refs_canon'') FROM golden.scratch WHERE fixture_id=72 AND key=''struct''),''absent'')', 'eq', '0/1', true, 'P3'),
(72, 13, 'D-31 DIAL PRESERVATION (v_facing_performance_v3): the view passes its OWN dial, fac_price_lookback_days, into the canonical object. ⛔ The canonical object takes the lookback as a PARAMETER rather than reading one dial precisely so that converging the arithmetic does not retire a policy dial CS owns. The day someone "simplifies" this to a single shared dial, this goes red and the change gets the Article-16 review that collapsing two policy dials deserves - the role fixture 70 seq 27 plays for D-28 and fixture 71 seq 21 for D-27.',
 'SELECT COALESCE((SELECT value->>''vfp_dial'' FROM golden.scratch WHERE fixture_id=72 AND key=''struct''),''absent'')', 'eq', 'fac_price_lookback_days', true, 'P3'),
(72, 14, 'D-31 DIAL PRESERVATION (rank_machines_by_value_at_risk_v3): the picker passes var_price_lookback_days, and it no longer carries the cascade inline while referencing the canonical object exactly once. Read with seq 13 this is the whole point of the parameterised shape.',
 'SELECT COALESCE((SELECT (value->>''rank_dial'')||'' ''||(value->>''rank_inline_cascade'')||''/''||(value->>''rank_refs_canon'') FROM golden.scratch WHERE fixture_id=72 AND key=''struct''),''absent'')', 'eq', 'var_price_lookback_days 0/1', true, 'P3'),

-- ============================== EQUIVALENCE — the numbers, against the legacy formula (S-267) ==============================
(72, 15, 'D-31 EQUIVALENCE (tier 1, population): the canonical object is compared against the legacy machine-pod formula on the FULL live population, not a sample. Non-vacuity for seq 16 - a comparison of zero rows would report zero mismatches. Measured at leg 152: 720 rows compared.',
 'SELECT COALESCE((SELECT value->>''mp_compared'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'gte', '100', true, 'P3'),
(72, 16, 'D-31 EQUIVALENCE (tier 1): ZERO machine-pod prices differ from the legacy formula transcribed literally from the two live bodies. IS DISTINCT FROM, so a NULL that became a number is a mismatch rather than a silent pass. A refactor that changes behaviour is not a refactor.',
 'SELECT COALESCE((SELECT value->>''mp_mismatch'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'eq', '0', true, 'P3'),
(72, 17, 'D-31 EQUIVALENCE (tier 2): ZERO fleet-tier prices differ, compared only where the machine tier is ABSENT - which is the only place in the cascade tier 2 can actually be selected. ⛔ Comparing tier 2 everywhere would compare a value the cascade never returns and would pass while the live answer was wrong.',
 'SELECT COALESCE((SELECT value->>''fleet_mismatch'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'eq', '0', true, 'P3'),
(72, 18, 'D-31 EQUIVALENCE (the cascade itself): price_basis is recomputed from the legacy tiers and compared row for row across the canonical object''s entire domain - ZERO disagreements. This is the assertion that proves the ORDER of the three rungs survived, which no per-tier price comparison can see: a cascade that preferred the fleet price over the machine price would pass seqs 16 and 17 and fail here.',
 'SELECT COALESCE((SELECT value->>''basis_mismatch'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'eq', '0', true, 'P3'),
(72, 19, 'D-31 DOMAIN TRAP proven closed: every (machine, pod) pair that carries realized sales for a pod NOT in pod_products is still covered by the canonical object. ⛔ The natural machines x pod_products grid would have dropped these silently - the cascade would return a price today and NULL tomorrow, with no error anywhere. seq 4 is the premise that keeps this discriminating.',
 'SELECT COALESCE((SELECT value->>''orphan_covered'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'eq', 'yes', true, 'P3'),
(72, 20, 'D-31 THE ONE-SCAN ROLLUP IS EXACT: the fleet tier derived by summing the per-(machine, pod) sums equals the fleet tier from a second independent scan of the window, on EVERY pod - zero disagreements, FULL JOINed so a pod present on one side only is a mismatch rather than an unjoined row. This is what licenses the canonical object to scan the 90-day window ONCE where each consumer scans it twice.',
 'SELECT COALESCE((SELECT value->>''rollup_mismatch'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'eq', '0', true, 'P3'),
(72, 21, 'D-31 EQUIVALENCE (population, cascade): the price_basis comparison at seq 18 covers the canonical object''s whole domain and that domain is large - machines x pods plus the realized pairs. Non-vacuity for seq 18, stated as a number rather than trusted.',
 'SELECT COALESCE((SELECT value->>''basis_compared'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'gte', '5000', true, 'P3'),

-- ============================== INVARIANCE / RESIDUE — green BEFORE and AFTER ==============================
(72, 22, 'D-31 LAW 12: the fixture''s synthetic 2030 plan_date holds zero rows across the live and shadow plan tables after the run. The cascade is declared a pure read; this MEASURES that the fixture wrote nothing rather than trusting the declaration.',
 'SELECT COALESCE((SELECT value->>''law12'' FROM golden.scratch WHERE fixture_id=72 AND key=''residue''),''absent'')', 'eq', '0', true, 'P3'),
(72, 23, 'D-31 residue: app.via_trigger does not leak out of the fixture. Nothing here writes to a protected table, so it must never have been set in the first place.',
 'SELECT COALESCE((SELECT value->>''via_trigger'' FROM golden.scratch WHERE fixture_id=72 AND key=''residue''),''absent'')', 'eq', '<unset>', true, 'P3'),
(72, 24, 'D-31 residue: app.via_rpc does not leak out of the fixture either. The scenario reads the catalogue and live sales and creates nothing beyond ON COMMIT DROP temp tables, so a run can never leave a half-built object behind.',
 'SELECT COALESCE((SELECT value->>''via_rpc'' FROM golden.scratch WHERE fixture_id=72 AND key=''residue''),''absent'')', 'eq', '<unset>', true, 'P3');
