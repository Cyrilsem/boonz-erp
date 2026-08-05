-- PRD-110 P2.2c — FIXTURE FIRST (LAW 1).
-- Re-express fixture 14 seq 46 from the P2.1 cover-days contract to the P2.2c base-stock
-- contract, and add the provenance / non-vacuity / anti-degeneracy tripwires that make the
-- new sizing path provable rather than merely present.
-- seq 46 is RE-PHASED, never deleted (the S-47 / D-16 house rule).
DO $mig$
BEGIN

  -- 1) seq 46: same S-13 intent (every rate is a CALENDAR-DAY rate; no /30, no *30 anywhere
  --    in the chain), now expressed against the base-stock identity that actually sizes the
  --    line: cover_units = ceil(mu*H + z*sigma*sqrt(H)).
  UPDATE golden.assertions SET
    description = 'v3 SIZING UNIT CONTRACT (S-13, re-phased at P2.2c): cover_units = ceil(velocity_effective_daily x horizon_days + z x sigma_daily_shelf x sqrt(horizon_days)). Every rate in that identity is a DAILY rate by construction - any /30 or x30 anywhere in the chain reds this. Was expressed against days_cover until P2.2c, when horizon_days replaced it as the sizing horizon.',
    check_sql = $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (prs.reasoning->>'cover_units')::int
             IS DISTINCT FROM ceil((prs.reasoning->>'velocity_effective_daily')::numeric
                                     * (prs.reasoning->>'horizon_days')::numeric
                                   + (prs.reasoning->>'z')::numeric
                                     * (prs.reasoning->>'sigma_daily_shelf')::numeric
                                     * sqrt((prs.reasoning->>'horizon_days')::numeric))::int)::text END$q$
  WHERE fixture_id = 14 AND seq = 46;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'P2.2c: fixture 14 seq 46 not found - refusing to proceed on a wrong premise';
  END IF;

  -- 2) new tripwires. Deleted first so the migration is re-runnable.
  DELETE FROM golden.assertions WHERE fixture_id = 14 AND seq IN (50,51,52,53,54,55,56,57);

  INSERT INTO golden.assertions
    (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES

  (14, 50,
   'P2.2c LAW 5: every sized line NAMES its planning horizon. horizon_source must be one of the two recognised values - a quantity may never move on an unnamed horizon.',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND COALESCE(prs.reasoning->>'horizon_source','')
             NOT IN ('base_stock_policy_v3','days_cover_arg_fallback'))::text END$q$,
   'eq', '0', true, 'P2'),

  (14, 51,
   'P2.2c LAW 5: every sized line NAMES its dispersion basis. sigma_source must be one of the three recognised values - a safety term may never come from an unnamed sigma.',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND COALESCE(prs.reasoning->>'sigma_source','')
             NOT IN ('phi_x_sqrt_velocity_instock_pod_split_by_shelf_share',
                     'no_dispersion_row','no_instock_split'))::text END$q$,
   'eq', '0', true, 'P2'),

  (14, 52,
   'P2.2c PROVENANCE: the horizon and z stamped on every line are EXACTLY the ones v_machine_base_stock_policy_v3 publishes for that machine. Any drift means the engine recomputed a policy term instead of reading the canonical resolver.',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
        JOIN public.v_machine_base_stock_policy_v3 b ON b.machine_id = prs.machine_id
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND ((prs.reasoning->>'z')::numeric            IS DISTINCT FROM b.z
           OR (prs.reasoning->>'horizon_days')::numeric IS DISTINCT FROM b.horizon_days))::text END$q$,
   'eq', '0', true, 'P2'),

  (14, 53,
   'P2.2c ANTI-VACUITY + D-14/D-16 TRIPWIRE: z is read from the v3 policy VIEW, never from the deliberately-stale machine_service_policy base column. At least one line must carry a z that DIFFERS from that machine z_default, otherwise seq 52 would pass even if the engine read the wrong column.',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
        JOIN public.machine_service_policy m ON m.machine_id = prs.machine_id
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (prs.reasoning->>'z')::numeric IS DISTINCT FROM m.z_default)::text END$q$,
   'gt', '0', true, 'P2'),

  (14, 54,
   'P2.2c SPLIT BOUND: a shelf share of the pod sigma can never EXCEED the pod sigma itself. sigma_daily_shelf <= phi x sqrt(velocity_instock_pod) on every measured line - catches an inverted or unnormalised split weight.',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND prs.reasoning->>'sigma_source' = 'phi_x_sqrt_velocity_instock_pod_split_by_shelf_share'
         AND (prs.reasoning->>'sigma_daily_shelf')::numeric
             > (prs.reasoning->>'phi')::numeric
               * sqrt((prs.reasoning->>'velocity_instock_pod')::numeric) + 1e-9)::text END$q$,
   'eq', '0', true, 'P2'),

  (14, 55,
   'P2.2c NON-VACUITY: the z x sigma safety term actually BINDS on this fixture. At least one line must carry safety_term > 0, otherwise base-stock has silently collapsed to bare mu x H and every shelf lost its safety stock with no error (the exact class LAW 5 forbids, and RISK 91 in miniature).',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (prs.reasoning->>'safety_term')::numeric > 0)::text END$q$,
   'gt', '0', true, 'P2'),

  (14, 56,
   'P2.2c S-43 DEGENERACY TRIPWIRE: sizing must not have degenerated into "fill every shelf to capacity". If EVERY line clamps to fill_to_cap the engine looks healthy - no error, no qty-0, no anomalous clamp_reason - while having stopped modelling demand at all. This is the assertion S-43 said was missing.',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT CASE WHEN count(*) = 0 THEN 'no_lines'
                  WHEN count(*) FILTER (WHERE clamp_reason = 'fill_to_cap') < count(*) THEN 'PASS'
                  ELSE 'DEGENERATE_ALL_FILL_TO_CAP' END
        FROM public.pod_refills_shadow WHERE run_id = golden.v3_run_id({{fixture_id}})) END$q$,
   'eq', 'PASS', true, 'P2'),

  (14, 57,
   'P2.2c: p_days_cover was RE-ROLED, not orphaned. It remains required and validated, it still echoes verbatim into pod_refills_shadow.days_cover (so shadow-vs-v19 diffing stays comparable), and it remains the tier-3 horizon fallback. The harness calls this fixture with 7.',
   $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (prs.days_cover IS DISTINCT FROM 7
           OR (prs.reasoning->>'days_cover_arg')::int IS DISTINCT FROM 7))::text END$q$,
   'eq', '0', true, 'P2');

END
$mig$;
