-- PRD-110 · D-31 · leg 152
-- FIXTURE 72 RESTATED — the RED baseline's own dry run found a premise that was measuring
-- the wrong thing, and this states what is actually true instead of loosening the sensor.
--
-- ⛔ WHAT THE DRY RUN FOUND (S-287 earning its keep a second time in one leg). The
--    convergence dry run came back 22/2 with scenario_error <null>, red on seq 19
--    ('no_orphan') and seq 20 (2). Both reds had ONE root cause, and it was in the FIXTURE,
--    not in the convergence:
--
--    v_sales_history_resolved leaves 15 of the 720 (machine, pod) groups in the live
--    90-day window UNRESOLVED — pod_product_id IS NULL, carrying 110 units and AED 1,904
--    of real revenue. Measured, not inferred.
--
--    · seq 4 counted DISTINCT pod_product_id INCLUDING NULL and read 1. It was written to
--      mean "one pod carries realized sales and is missing from pod_products". That pod
--      DOES NOT EXIST: the true count of non-NULL orphan pods is ZERO. The premise was
--      reading the NULL group and calling it an orphan.
--    · seq 19 then asked "is the orphan covered?" using NOT IN over that NULL — and NOT IN
--      against a NULL yields NULL, never true, so the set was empty and it answered
--      'no_orphan'. ⛔ It was not discriminating anything, in either direction.
--    · seq 20's FULL JOIN is keyed on pod_product_id, and NULL = NULL is never true, so the
--      NULL group appeared unmatched on BOTH sides and read as 2 mismatches. An artefact of
--      the join key. The rollup arithmetic never disagreed.
--
-- ⭐ THE HONEST RESTATEMENT, AND IT DOES NOT WEAKEN A SINGLE SENSOR (S-272 — the SHAPE
--    moves with the expect, fixture-54 doctrine — a fixture MAKES its premises):
--    · seq 4 flips gte 1 -> eq 0 and now STATES the true fact: there is no orphan pod, so
--      the union grid's third arm is a LATENT guard. Saying so out loud is worth more than
--      a premise that was accidentally green.
--    · seq 19 stops asking about an empty set and asks the load-bearing question over the
--      FULL realized population instead: is EVERY (machine, pod) pair with a realized price
--      in the canonical object's domain? 705 pairs, and seq 26 pins that it is 705 and not 0.
--    · seq 20 keeps its FULL JOIN — a pod on one side only must still be a mismatch — and
--      restricts both sides to non-NULL pods so it measures the rollup and not the join key.
--    · seq 25 is NEW and is the one the whole discovery earned: the canonical object emits
--      ZERO NULL-pod rows, where the inline copies carried 15 machine-pod groups and one
--      NULL "fleet pod" (which is why the legacy fleet tier reads 111 pods and not 110).
--      Every one of those was UNREACHABLE — both consumers join the tier on pod_product_id.
--    · seq 27 is NEW and is a DRIFT sensor, not an invariant: unresolved sales groups stay
--      under 30. ⛔ Deliberately lte and not eq/gte — the day the resolver is FIXED that is
--      good news and must not red golden, and the day unresolved revenue GROWS it must.
--
-- ⛔ THE 15 UNRESOLVED GROUPS ARE NAMED, NOT FIXED (LAW 10). AED 1,904 of revenue over 90
--    days attributed to no pod is a resolver question, not a price-cascade question, and
--    fixing it here would be scope drift. It is recorded in the parking lot.
--
-- The scenario is edited by SEVEN counted substitutions on the byte-exact stored text, with
-- the pre-image md5 pinned as a hard RAISE (the leg-150/151 guard, S-284/S-287).

DO $guard$
DECLARE v_md5 text;
BEGIN
  SELECT md5(scenario_sql) INTO v_md5 FROM golden.fixtures WHERE fixture_id = 72;
  IF v_md5 IS NULL THEN
    RAISE EXCEPTION 'D-31 REFUSES: fixture 72 does not exist';
  END IF;
  IF v_md5 <> 'ec4242761a4fdcc2fd5a1db281feb5f0' THEN
    RAISE EXCEPTION 'D-31 REFUSES: fixture 72 scenario pre-image md5 is % but this unit was written against ec4242761a4fdcc2fd5a1db281feb5f0', v_md5;
  END IF;
END $guard$;

UPDATE golden.fixtures SET scenario_sql = $fx72b$
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
  v_null_groups int := -1;
  v_null_fleet  int := -1;

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
  v_pairs_cov   int := -1;
  v_canon_null  int := -1;

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

  -- RESTATED leg 152 (S-272). The original counted DISTINCT pod including NULL and read
  -- 1, and that 1 was the UNRESOLVED group, not an orphan pod. Live truth: ZERO pods carry
  -- realized sales and sit outside pod_products, so the union grid's third arm is a LATENT
  -- guard rather than a load-bearing one, and seq 4 now says so instead of implying the
  -- opposite.
  SELECT count(*) INTO v_orphan_pods FROM (
    SELECT DISTINCT pod_product_id FROM _legacy_base WHERE pod_product_id IS NOT NULL
    EXCEPT
    SELECT pod_product_id FROM public.pod_products) q;

  -- What was actually there: sales the resolver could not attribute to any pod.
  SELECT count(*) INTO v_null_groups FROM _legacy_base  WHERE pod_product_id IS NULL;
  SELECT count(*) INTO v_null_fleet  FROM _legacy_fleet WHERE pod_product_id IS NULL;

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
    -- RESTATED leg 152 (S-272): the SHAPE moved. It asked "is the orphan covered?" over a
    -- set that is empty, and NOT IN over a NULL made it answer 'no_orphan' rather than
    -- discriminating anything. It now asks the load-bearing question over the FULL realized
    -- population: is every (machine, pod) pair that has a realized price in the canonical
    -- object's domain? 705 pairs, not 0.
    SELECT CASE WHEN count(*) = 0 THEN 'empty'
                WHEN count(*) FILTER (WHERE cov) = count(*) THEN 'yes'
                ELSE 'no' END,
           count(*)
      INTO v_orphan_ok, v_pairs_cov
      FROM (
        SELECT EXISTS (SELECT 1 FROM _canon c
                        WHERE c.machine_id = b.machine_id
                          AND c.pod_product_id = b.pod_product_id) AS cov
          FROM (SELECT DISTINCT machine_id, pod_product_id
                  FROM _legacy_base WHERE pod_product_id IS NOT NULL) b
      ) q;

    -- The canonical object carries NO unreachable NULL-pod rows, where the legacy formula
    -- carried 15 machine-pod groups and one fleet "pod" that no consumer could ever join to.
    SELECT count(*) INTO v_canon_null FROM _canon WHERE pod_product_id IS NULL;

    -- (e) the one-scan rollup is EXACT: the fleet tier derived by summing the
    --     (machine, pod) sums equals the fleet tier from an independent second scan,
    --     on every pod. Associativity, proven rather than asserted.
    -- RESTATED leg 152: both sides restricted to NON-NULL pods. The FULL JOIN is keyed on
    -- pod_product_id and NULL = NULL is never true, so the NULL group appeared as unmatched
    -- on BOTH sides and read as 2 mismatches - an artefact of the join key, not a rollup
    -- disagreement. ⛔ The FULL JOIN itself is KEPT: a pod present on one side only must
    -- still be a mismatch, which is the property this assertion exists for.
    SELECT count(*) INTO v_rollup_bad FROM (
      SELECT r.pod_product_id
        FROM (SELECT pod_product_id, sum(sum_paid) / NULLIF(sum(sum_qty), 0) AS up
                FROM _legacy_base WHERE pod_product_id IS NOT NULL
               GROUP BY 1 HAVING sum(sum_qty) > 0) r
        FULL JOIN (SELECT * FROM _legacy_fleet WHERE pod_product_id IS NOT NULL) f
               ON f.pod_product_id = r.pod_product_id
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
    'null_pod_groups', v_null_groups, 'null_fleet_rows', v_null_fleet,
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
    'orphan_covered', v_orphan_ok, 'rollup_mismatch', v_rollup_bad,
    'realized_pairs_checked', v_pairs_cov, 'canon_null_pod_rows', v_canon_null);

  s_residue := jsonb_build_object(
    'law12', v_law12, 'via_trigger', v_via_trig, 'via_rpc', v_via_rpc);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (72, 'premise', s_premise),
    (72, 'struct',  s_struct),
    (72, 'equiv',   s_equiv),
    (72, 'residue', s_residue);
END $do$;
$fx72b$
WHERE fixture_id = 72;

DO $post$
DECLARE v_md5 text;
BEGIN
  SELECT md5(scenario_sql) INTO v_md5 FROM golden.fixtures WHERE fixture_id = 72;
  IF v_md5 <> '6b63ce236e28db187c28491451af456c' THEN
    RAISE EXCEPTION 'D-31 POST-GUARD: fixture 72 scenario post-image md5 is %, expected 6b63ce236e28db187c28491451af456c', v_md5;
  END IF;
END $post$;

-- ============================== RESTATEMENTS (never deletions) ==============================
UPDATE golden.assertions SET
  expect_op = 'eq', expect = '0',
  description = 'D-31 premise, RESTATED leg 152 (S-272 — the SHAPE moved, gte 1 -> eq 0): ZERO pods carry realized sales while sitting outside pod_products. ⛔ The original read 1 and was taken to mean an orphan pod existed; it was counting DISTINCT pod_product_id INCLUDING NULL, and the 1 was the UNRESOLVED group (15 machine-pod groups, 110 units, AED 1,904 over 90 days — recorded at seq 27), not an orphan. The canonical object''s grid is still built as a UNION that would cover an orphan, so this is a LATENT guard and this assertion says so out loud rather than implying the case is live. The day it reads non-zero, seq 19 becomes discriminating and the grid arm becomes load-bearing.'
WHERE fixture_id = 72 AND seq = 4;

UPDATE golden.assertions SET
  expect_op = 'eq', expect = 'yes',
  description = 'D-31 DOMAIN COVERAGE, RESTATED leg 152: EVERY (machine, pod) pair carrying a realized price is inside the canonical object''s domain — 705 pairs, none missing. ⛔ The original asked "is the orphan covered?" over a set built with NOT IN against a NULL, which yields NULL and never true: the set was EMPTY and the assertion answered ''no_orphan'', discriminating nothing in either direction. It now asks the load-bearing question over the full realized population instead of a hypothetical one, and seq 26 pins that the population is 705 rather than 0.'
WHERE fixture_id = 72 AND seq = 19;

UPDATE golden.assertions SET
  description = 'D-31 THE ONE-SCAN ROLLUP IS EXACT, RESTATED leg 152: the fleet tier derived by summing the per-(machine, pod) sums equals the fleet tier from a second independent scan, on EVERY non-NULL pod — zero disagreements, still FULL JOINed so a pod present on one side only is a mismatch rather than an unjoined row. ⛔ Both sides are now restricted to non-NULL pods: the join key is pod_product_id and NULL = NULL is never true, so the unresolved group appeared unmatched on BOTH sides and read as 2 mismatches. That was an artefact of the join key — the rollup arithmetic never disagreed, which the restatement proves rather than assumes. This is what licenses the canonical object to scan the window ONCE where each consumer scans it twice.'
WHERE fixture_id = 72 AND seq = 20;

-- ============================== NEW ==============================
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(72, 25, 'D-31 UNREACHABLE ROWS REMOVED — the assertion the dry-run discovery earned. The canonical object emits ZERO rows with a NULL pod_product_id. ⛔ The inline copies carried 15 NULL-pod machine-pod groups PLUS one NULL "fleet pod" — which is exactly why the legacy fleet tier reads 111 pods and not 110 — and every one of them was UNREACHABLE, because both consumers join the price tiers on pod_product_id and NULL = NULL is never true. Excluding them is equivalence-preserving by construction, not a filter with an opinion: no price any consumer could ever read changes.',
 'SELECT COALESCE((SELECT value->>''canon_null_pod_rows'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'eq', '0', true, 'P3'),
(72, 26, 'D-31 non-vacuity for seq 19: the realized (machine, pod) population that seq 19 checks for coverage is large and stated as a number rather than trusted. Measured at leg 152: 705 pairs. ⛔ Without this, seq 19 would report ''yes'' over an empty set — which is precisely the failure mode the original seq 19 shipped with.',
 'SELECT COALESCE((SELECT value->>''realized_pairs_checked'' FROM golden.scratch WHERE fixture_id=72 AND key=''equiv''),''absent'')', 'gte', '500', true, 'P3'),
(72, 27, 'D-31 DRIFT SENSOR (not an invariant): v_sales_history_resolved leaves fewer than 30 (machine, pod) sales groups in the window unattributed to any pod. Measured at leg 152: 15 groups, 110 units, AED 1,904 over 90 days. ⛔ Stated as lte and DELIBERATELY not as eq or gte — the day the resolver is fixed that is good news and must not red golden, and the day unresolved revenue GROWS it must. ⏸️ The 15 groups are NAMED, NOT FIXED (LAW 10): unattributed revenue is a resolver question, not a price-cascade question, and closing it inside a convergence unit would be scope drift.',
 'SELECT COALESCE((SELECT value->>''null_pod_groups'' FROM golden.scratch WHERE fixture_id=72 AND key=''premise''),''absent'')', 'lte', '30', true, 'P3');
