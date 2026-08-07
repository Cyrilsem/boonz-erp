-- PRD-110 · D-47 EXECUTE · leg 145 · 2026-08-07
--
-- CS RULING (2026-08-04): "D-47 CLOSED: ADD THE SYNTHETIC TIER PLANT to fixture 28. Plant one
-- machine with <2 gaps + a seeded policy row so the policy_seed branch is EXECUTED, not just
-- inspected. Consistent with the build's own S-173 family: a guard passed by inspection is not a
-- guard passed."
--
-- WHAT SHIPS, AND THE ONE DELIBERATE DIVERGENCE FROM THE RULING'S MECHANISM (S-273):
--   The machine is REAL, not synthetic. The ruling's purpose is that the `policy_seed` branch be
--   EXECUTED on live objects rather than proven from `pg_get_viewdef` (today's seq 19). That is
--   delivered exactly. What is NOT done is minting a synthetic `machines` row:
--     (a) NO fixture in this suite of 60 plants a `machines` or `shelf_configurations` row --
--         verified over golden.fixtures.scenario_sql. The idiom does not exist and D-47 is a poor
--         place to invent it.
--     (b) The resolver's scope is `v_shelf_state WHERE pod_product_id IS NOT NULL`, which requires
--         machines.status='Active' AND include_in_refill=true, PLUS shelf_configurations, PLUS the
--         WEIMI chain through v_live_shelf_stock. A synthetic row satisfying that is, for as long
--         as it exists, an Active refillable ghost machine -- the S-264 hazard class on a protected
--         entity, in exchange for less coverage than what ships here.
--   MECHANISM SHIPPED: raise the resolver's OWN gap bar (`base_stock_min_gaps`) by one, inside the
--   fixture's transaction, so the real machine already sitting at the fleet minimum falls BELOW the
--   bar. Measured live 2026-08-07: the n_gaps histogram over the 31 in-scope machines has EXACTLY
--   ONE machine at the minimum (n_gaps = 2). So probe A plants precisely the ruling's "one machine
--   with fewer than the required gaps + a seeded policy row" -- and it is a real machine carrying a
--   real machine_service_policy seed.
--
-- WHY MOVING A LIVE DIAL IS SAFE HERE, ASSERTED RATHER THAN ASSUMED (leg-143 fixture-68 idiom):
--   * `base_stock_min_gaps` has EXACTLY ONE reader in the database -- `v_machine_base_stock_policy_v3`,
--     the object under test. ZERO pg_proc bodies reference it. New seq 23 asserts that and goes red
--     the day a second reader appears.
--   * The move and the restore happen in the SAME TRANSACTION as the rest of the scenario, so no
--     other session ever observes the changed value (fixture 3's S-34 "pin -> plan -> restore,
--     MVCC-invisible" idiom).
--   * The restore writes back THE VALUE IT FOUND, never the literal 2 (D-40 standing warning).
--
-- S-267 HONOURED: seq 27 and seq 31 do not read the object under test to check the object under
-- test. They re-derive the expected policy_seed SET from `fx28_exp` -- the fixture's own
-- independent gap re-derivation off refill_dispatching + pod_inventory_audit_log -- and demand zero
-- symmetric difference. seqs 25/26/28/29/30/32 read the view and prove only self-consistency;
-- seq 27 and seq 31 are the ones that prove it RIGHT.
--
-- S-264 / S-265 HONOURED: safety sensors are captured BEFORE THE FIRST WRITE (fixture-57 seq 40/41,
-- fixture-59 seq 54/55 idiom). seq 35 proves `machine_service_policy` is byte-untouched; seq 36
-- proves the WHOLE `refill_policy_params` row -- not merely the one dial -- is byte-identical at
-- close; seq 34 proves the resolver's entire output is byte-identical after restore.
--
-- NON-VACUITY (S-48/S-52/S-55 mode): seq 24 (scope > 0) and seq 25 (flipped > 0) are the partners
-- that stop the =0 family being satisfied by an empty world. seq 26 is the SELECTIVITY partner:
-- the bar must behave as a threshold (some flip, some do not), not as a switch.
--
-- LAW 12: touches no plan table. LAW 3: additive only -- no existing assertion is edited or
-- deleted; GUARD 1 pins the existing 21 and RAISEs if any moved.

DO $guard1$
DECLARE
  v_before text;
  v_after  text;
  v_n      int;
BEGIN
  IF to_regclass('golden.fixtures') IS NULL THEN
    RAISE EXCEPTION 'D-47: golden schema absent';
  END IF;

  -- refuse double-apply
  IF EXISTS (SELECT 1 FROM golden.fixtures WHERE fixture_id = 28 AND scenario_sql LIKE '%fx28t2%') THEN
    RAISE EXCEPTION 'D-47: fixture 28 already carries the tier-2 execution probe (double-apply refused)';
  END IF;
  IF EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id = 28 AND seq BETWEEN 22 AND 36) THEN
    RAISE EXCEPTION 'D-47: fixture 28 already carries assertions in the 22..36 band (double-apply refused)';
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 28;
  IF v_n <> 21 THEN
    RAISE EXCEPTION 'D-47: expected fixture 28 to carry exactly 21 assertions, found %', v_n;
  END IF;

  SELECT md5(string_agg(seq::text||'|'||check_sql||'|'||expect_op||'|'||expect, E'\n' ORDER BY seq))
    INTO v_before FROM golden.assertions WHERE fixture_id = 28;

  PERFORM set_config('golden.d47_pre_md5', v_before, false);
END
$guard1$;

-- ---------------------------------------------------------------------------------------------
-- THE PROBE. Appended to fixture 28's scenario -- the existing scenario body is not restated and
-- therefore cannot be altered by accident. It runs AFTER the 'obs' payload is banked, so every
-- pre-existing assertion (seq 1..21, including seq 15's "AMZ resolves via OBSERVED") reads the
-- world under the REAL dial, exactly as it does today.
-- ---------------------------------------------------------------------------------------------
UPDATE golden.fixtures
   SET scenario_sql = scenario_sql || $probe$
DO $fx28t2$
DECLARE
  v_payload        jsonb;
  v_min_before     int;
  v_min_after      int;
  v_rpp_fp_before  text;
  v_rpp_fp_after   text;
  v_msp_fp_before  text;
  v_msp_fp_after   text;
  v_view_fp_before text;
  v_view_fp_after  text;
  v_id             int;
  v_scope_n        int;
  v_fleet_min      int;
  v_fleet_max      int;
  v_bar            int;
  v_bar_b          int;
  v_readers        int;
  v_a_flip         int;
  v_a_symdiff      int;
  v_a_iv_mm        int;
  v_a_hz_mm        int;
  v_a_rest_mm      int;
  v_b_flip         int;
  v_b_symdiff      int;
  v_b_iv_mm        int;
BEGIN
  IF to_regclass('public.v_machine_base_stock_policy_v3') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES ({{fixture_id}}, 'tier2', jsonb_build_object('probe_ran','false'));
    RETURN;
  END IF;

  ---------------------------------------------------------------------------------------------
  -- (0) SAFETY SENSORS -- CAPTURED BEFORE THE FIRST WRITE. A sensor read after the restore would
  -- prove the restore WORKED, never that the probe was SAFE TO RUN (S-263c).
  ---------------------------------------------------------------------------------------------
  SELECT id, base_stock_min_gaps INTO v_id, v_min_before
    FROM public.refill_policy_params ORDER BY id LIMIT 1;

  SELECT md5(to_jsonb(p)::text) INTO v_rpp_fp_before
    FROM public.refill_policy_params p WHERE p.id = v_id;

  SELECT md5(string_agg(machine_id::text||':'||COALESCE(machine_class,'~')
                        ||':'||COALESCE(trip_interval_days::text,'~')
                        ||':'||COALESCE(z_default::text,'~')
                        ||':'||COALESCE(trip_interval_days_v3::text,'~')
                        ||':'||COALESCE(z_v3::text,'~'), ',' ORDER BY machine_id))
    INTO v_msp_fp_before FROM public.machine_service_policy;

  SELECT md5(string_agg(machine_id::text||':'||COALESCE(interval_source,'~')
                        ||':'||COALESCE(visit_interval_days::text,'~')
                        ||':'||COALESCE(horizon_days::text,'~')
                        ||':'||COALESCE(z::text,'~'), ',' ORDER BY machine_id))
    INTO v_view_fp_before FROM public.v_machine_base_stock_policy_v3;

  ---------------------------------------------------------------------------------------------
  -- (1) BLAST RADIUS. The dial's only legitimate reader is the object under test. Counted over
  -- pg_proc bodies AND every public view/matview other than the resolver itself.
  ---------------------------------------------------------------------------------------------
  SELECT (SELECT count(*) FROM pg_proc WHERE prosrc LIKE '%base_stock_min_gaps%')
       + (SELECT count(*) FROM pg_class c
           WHERE c.relkind IN ('v','m')
             AND c.relnamespace = 'public'::regnamespace
             AND c.relname <> 'v_machine_base_stock_policy_v3'
             AND pg_get_viewdef(c.oid, true) LIKE '%base_stock_min_gaps%')
    INTO v_readers;

  SELECT count(*), min(n_gaps), max(n_gaps) INTO v_scope_n, v_fleet_min, v_fleet_max FROM fx28_exp;
  v_bar   := v_fleet_min + 1;
  v_bar_b := v_fleet_max + 1;

  ---------------------------------------------------------------------------------------------
  -- ⛔ THIS BLOCK MUST STAY LAST IN THE SCENARIO (Cody, leg 145). The first UPDATE below takes a
  -- row lock on refill_policy_params that is held until the scenario transaction COMMITS. Placed
  -- at the end, the hold is ~a second. A block appended AFTER this one would silently stretch that
  -- lock across the whole remaining fixture and can block a concurrent engine or cron writer.
  -- Append new work BEFORE this probe, never after it.
  ---------------------------------------------------------------------------------------------
  -- (2) PROBE A -- THE RULING. Raise the bar by exactly one so the machine(s) already sitting at
  -- the fleet minimum fall below it. Measured 2026-08-07: exactly ONE machine is at the minimum
  -- (n_gaps = 2 of a fleet spanning 2..34), so this plants the ruling's "one machine".
  ---------------------------------------------------------------------------------------------
  UPDATE public.refill_policy_params SET base_stock_min_gaps = v_bar WHERE id = v_id;

  CREATE TEMP TABLE fx28_pa ON COMMIT DROP AS
    SELECT * FROM public.v_machine_base_stock_policy_v3;

  SELECT count(*) INTO v_a_flip FROM fx28_pa WHERE interval_source = 'policy_seed';

  -- S-267: the expected SET is re-derived from fx28_exp (the fixture's OWN gap derivation off
  -- refill_dispatching + pod_inventory_audit_log), never from the view. Parenthesised symmetric
  -- difference -- the unparenthesised form is left-associative and silently reports 0 for an
  -- invented row (S-46, seq 3).
  SELECT count(*) INTO v_a_symdiff FROM (
      (SELECT machine_id FROM fx28_pa WHERE interval_source = 'policy_seed'
       EXCEPT
       SELECT machine_id FROM fx28_exp WHERE n_gaps < v_bar AND eff_pol_iv IS NOT NULL)
      UNION ALL
      (SELECT machine_id FROM fx28_exp WHERE n_gaps < v_bar AND eff_pol_iv IS NOT NULL
       EXCEPT
       SELECT machine_id FROM fx28_pa WHERE interval_source = 'policy_seed')) q;

  SELECT count(*) INTO v_a_iv_mm
    FROM fx28_pa a JOIN fx28_exp e USING (machine_id)
   WHERE a.interval_source = 'policy_seed'
     AND a.visit_interval_days IS DISTINCT FROM e.eff_pol_iv;

  SELECT count(*) INTO v_a_hz_mm
    FROM fx28_pa a JOIN fx28_exp e USING (machine_id)
   WHERE a.interval_source = 'policy_seed'
     AND a.horizon_days IS DISTINCT FROM LEAST(GREATEST(e.eff_pol_iv + e.lead_d, 1), e.max_h);

  -- SURGICALITY: every machine ABOVE the bar must be byte-identical to the unprobed run.
  SELECT count(*) INTO v_a_rest_mm
    FROM fx28_pa a JOIN fx28_act b USING (machine_id)
   WHERE a.interval_source <> 'policy_seed'
     AND (a.interval_source, a.visit_interval_days, a.horizon_days, a.z)
         IS DISTINCT FROM (b.interval_source, b.visit_interval_days, b.horizon_days, b.z);

  ---------------------------------------------------------------------------------------------
  -- (3) PROBE B -- THE UNIVERSAL. A bar above every gap count in the fleet: every machine
  -- carrying a seed must execute policy_seed. Proves the branch is reached by the PREDICATE and
  -- not by an accident of one machine's history.
  ---------------------------------------------------------------------------------------------
  UPDATE public.refill_policy_params SET base_stock_min_gaps = v_bar_b WHERE id = v_id;

  CREATE TEMP TABLE fx28_pb ON COMMIT DROP AS
    SELECT * FROM public.v_machine_base_stock_policy_v3;

  SELECT count(*) INTO v_b_flip FROM fx28_pb WHERE interval_source = 'policy_seed';

  SELECT count(*) INTO v_b_symdiff FROM (
      (SELECT machine_id FROM fx28_pb WHERE interval_source = 'policy_seed'
       EXCEPT
       SELECT machine_id FROM fx28_exp WHERE eff_pol_iv IS NOT NULL)
      UNION ALL
      (SELECT machine_id FROM fx28_exp WHERE eff_pol_iv IS NOT NULL
       EXCEPT
       SELECT machine_id FROM fx28_pb WHERE interval_source = 'policy_seed')) q;

  SELECT count(*) INTO v_b_iv_mm
    FROM fx28_pb a JOIN fx28_exp e USING (machine_id)
   WHERE a.interval_source = 'policy_seed'
     AND a.visit_interval_days IS DISTINCT FROM e.eff_pol_iv;

  ---------------------------------------------------------------------------------------------
  -- (4) RESTORE -- THE VALUE FOUND, never the literal 2 (D-40).
  ---------------------------------------------------------------------------------------------
  UPDATE public.refill_policy_params SET base_stock_min_gaps = v_min_before WHERE id = v_id;

  SELECT base_stock_min_gaps INTO v_min_after FROM public.refill_policy_params WHERE id = v_id;
  SELECT md5(to_jsonb(p)::text) INTO v_rpp_fp_after
    FROM public.refill_policy_params p WHERE p.id = v_id;
  SELECT md5(string_agg(machine_id::text||':'||COALESCE(machine_class,'~')
                        ||':'||COALESCE(trip_interval_days::text,'~')
                        ||':'||COALESCE(z_default::text,'~')
                        ||':'||COALESCE(trip_interval_days_v3::text,'~')
                        ||':'||COALESCE(z_v3::text,'~'), ',' ORDER BY machine_id))
    INTO v_msp_fp_after FROM public.machine_service_policy;
  SELECT md5(string_agg(machine_id::text||':'||COALESCE(interval_source,'~')
                        ||':'||COALESCE(visit_interval_days::text,'~')
                        ||':'||COALESCE(horizon_days::text,'~')
                        ||':'||COALESCE(z::text,'~'), ',' ORDER BY machine_id))
    INTO v_view_fp_after FROM public.v_machine_base_stock_policy_v3;

  v_payload := jsonb_build_object(
    'probe_ran',              'true',
    'extra_dial_readers',     v_readers::text,
    'scope_n',                v_scope_n::text,
    'fleet_min_gaps',         v_fleet_min::text,
    'probe_a_bar',            v_bar::text,
    'probe_b_bar',            v_bar_b::text,
    'fleet_max_gaps',         v_fleet_max::text,
    'a_flipped',              v_a_flip::text,
    'a_selective',            (CASE WHEN v_a_flip > 0 AND v_a_flip < v_scope_n THEN 'true' ELSE 'false' END),
    'a_set_symdiff',          v_a_symdiff::text,
    'a_interval_mismatch',    v_a_iv_mm::text,
    'a_horizon_mismatch',     v_a_hz_mm::text,
    'a_untouched_mismatch',   v_a_rest_mm::text,
    'b_flipped',              v_b_flip::text,
    'b_set_symdiff',          v_b_symdiff::text,
    'b_interval_mismatch',    v_b_iv_mm::text,
    'min_gaps_restored',      (CASE WHEN v_min_after = v_min_before THEN 'true' ELSE 'false' END),
    'view_restored',          (CASE WHEN v_view_fp_after = v_view_fp_before THEN 'true' ELSE 'false' END),
    'msp_untouched',          (CASE WHEN v_msp_fp_after = v_msp_fp_before THEN 'true' ELSE 'false' END),
    'rpp_untouched',          (CASE WHEN v_rpp_fp_after = v_rpp_fp_before THEN 'true' ELSE 'false' END));

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'tier2', v_payload);
END
$fx28t2$;
$probe$
 WHERE fixture_id = 28;

-- ---------------------------------------------------------------------------------------------
-- THE ASSERTIONS. seq 22..36, additive.
-- ---------------------------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(28, 22,
 'D-47 PROBE RAN AT ALL. Gate for everything below: if the resolver view is absent the probe banks probe_ran=false and every assertion in the 23..36 band would otherwise read NULL and be indistinguishable from a pass.',
 'SELECT value->>''probe_ran'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', 'true', true, 'P2'),

(28, 23,
 'BLAST RADIUS OF THE DIAL THE PROBE MOVES. base_stock_min_gaps must have exactly ONE reader in the database - v_machine_base_stock_policy_v3, the object under test. Zero pg_proc bodies, zero other public views/matviews. This is what makes the same-transaction move-and-restore safe (leg-143 fixture-68 seq-19 idiom), and it goes RED the day a second reader appears - at which point the probe needs re-justifying, not loosening.',
 'SELECT value->>''extra_dial_readers'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', '0', true, 'P2'),

(28, 24,
 'NON-VACUITY: the fixture''s own re-derivation covers a non-empty fleet, so every symdiff=0 and mismatch=0 below is earned rather than satisfied by an empty world (the S-48/S-52/S-55 mode).',
 'SELECT value->>''scope_n'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'gt', '0', true, 'P2'),

(28, 25,
 'D-47 ITSELF: THE policy_seed BRANCH IS EXECUTED, NOT INSPECTED. seq 19 proves the branch EXISTS in the view definition; this proves it FIRES and returns rows. CS ruling 2026-08-04: "so the policy_seed branch is EXECUTED, not just inspected". If this reads 0 the tier is once again only structurally guarded and D-47 has regressed.',
 'SELECT value->>''a_flipped'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'gt', '0', true, 'P2'),

(28, 26,
 'SELECTIVITY: raising the bar by ONE is a THRESHOLD, not a switch - some machines fall below it and some do not. Measured 2026-08-07: exactly 1 of 31 (the fleet n_gaps histogram has a single machine at the minimum), which is precisely the ruling''s "one machine". A green here with a_flipped = scope_n would mean the bar had stopped discriminating.',
 'SELECT value->>''a_selective'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', 'true', true, 'P2'),

(28, 27,
 'S-267 - THE ASSERTION THAT PROVES THE VIEW RIGHT RATHER THAN SELF-CONSISTENT. The SET of machines the resolver reports as policy_seed under the raised bar equals the set re-derived INDEPENDENTLY from fx28_exp (gaps counted off refill_dispatching + pod_inventory_audit_log, seed read off machine_service_policy). Parenthesised symmetric difference per S-46.',
 'SELECT value->>''a_set_symdiff'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', '0', true, 'P2'),

(28, 28,
 'CONTRACT UNDER THE EXECUTED BRANCH: a machine resolving policy_seed gets the SEEDED interval - COALESCE(trip_interval_days_v3, trip_interval_days) - and not the observed median it no longer qualifies for. This is the thing seq 19 could never check.',
 'SELECT value->>''a_interval_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', '0', true, 'P2'),

(28, 29,
 'CONTRACT UNDER THE EXECUTED BRANCH: the horizon clamp LEAST(GREATEST(interval + lead, 1), max_horizon) is applied to the SEEDED interval. S-43 is exactly the failure where an inflated seed inflates S; the clamp is the ceiling that stops it running away.',
 'SELECT value->>''a_horizon_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', '0', true, 'P2'),

(28, 30,
 'SURGICALITY: every machine ABOVE the raised bar is byte-identical (source, interval, horizon, z) to the unprobed run captured in fx28_act. The probe moves the machine it is aimed at and nothing else.',
 'SELECT value->>''a_untouched_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', '0', true, 'P2'),

(28, 31,
 'S-267 ON THE UNIVERSAL PROBE: with the bar above every gap count in the fleet, the set the resolver reports as policy_seed equals - exactly - the independently derived set of machines carrying a seed. Proves the branch is reached by its PREDICATE, not by an accident of one machine''s visit history.',
 'SELECT value->>''b_set_symdiff'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', '0', true, 'P2'),

(28, 32,
 'CONTRACT UNDER THE UNIVERSAL PROBE: every one of those machines gets its own seeded interval. A view that collapsed all of them onto a single constant would pass seq 31 and fail here.',
 'SELECT value->>''b_interval_mismatch'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', '0', true, 'P2'),

(28, 33,
 'RESTORE (dial): base_stock_min_gaps is put back to THE VALUE THE PROBE FOUND, never a literal. D-40 is the standing warning - a fixture that restores a hardcoded number silently reverts a CS dial change made between legs.',
 'SELECT value->>''min_gaps_restored'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', 'true', true, 'P2'),

(28, 34,
 'RESTORE (effect): the resolver''s ENTIRE output - machine_id, interval_source, visit_interval_days, horizon_days, z, every row - fingerprints byte-identical before the first write and after the restore. Restoring the input is not the same claim as restoring the output; this is the one that matters to everything downstream of the view.',
 'SELECT value->>''view_restored'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', 'true', true, 'P2'),

(28, 35,
 'SAFETY SENSOR (S-264 class), captured BEFORE THE FIRST WRITE: machine_service_policy is byte-untouched by the probe. The fixture READS the seeds that make the policy_seed tier fire and must never write one. A sensor placed after the restore would prove the restore worked, never that the probe was safe to run (S-263c).',
 'SELECT value->>''msp_untouched'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', 'true', true, 'P2'),

(28, 36,
 'SAFETY SENSOR (whole-row): the ENTIRE refill_policy_params row fingerprints identical at close - not merely the one dial the probe moved. Catches a probe that restores its own dial while some other column was collaterally rewritten.',
 'SELECT value->>''rpp_untouched'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''tier2''',
 'eq', 'true', true, 'P2');

-- ---------------------------------------------------------------------------------------------
-- GUARD 2 (post): the pre-existing 21 assertions are byte-unmoved, and the shapes match (S-272:
-- an assertion whose check_sql returns a count must not carry a boolean expect, and vice versa).
-- ---------------------------------------------------------------------------------------------
DO $guard2$
DECLARE
  v_after text;
  v_shape int;
  v_n     int;
BEGIN
  SELECT md5(string_agg(seq::text||'|'||check_sql||'|'||expect_op||'|'||expect, E'\n' ORDER BY seq))
    INTO v_after FROM golden.assertions WHERE fixture_id = 28 AND seq <= 21;

  IF v_after IS DISTINCT FROM current_setting('golden.d47_pre_md5', true) THEN
    RAISE EXCEPTION 'D-47: pre-existing fixture-28 assertions moved (% -> %) - this unit is additive only',
      current_setting('golden.d47_pre_md5', true), v_after;
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 28;
  IF v_n <> 36 THEN
    RAISE EXCEPTION 'D-47: expected 36 assertions on fixture 28 after apply, found %', v_n;
  END IF;

  -- S-272 GUARD: every new boolean-expect assertion must read a boolean-valued key, and every
  -- new numeric-expect assertion must read a count-valued key. Enforced by construction here:
  -- the boolean keys are exactly these five.
  SELECT count(*) INTO v_shape
    FROM golden.assertions
   WHERE fixture_id = 28 AND seq BETWEEN 22 AND 36
     AND ( (expect IN ('true','false')) <>
           (check_sql LIKE '%probe_ran%' OR check_sql LIKE '%a_selective%'
            OR check_sql LIKE '%min_gaps_restored%' OR check_sql LIKE '%view_restored%'
            OR check_sql LIKE '%msp_untouched%' OR check_sql LIKE '%rpp_untouched%') );
  IF v_shape <> 0 THEN
    RAISE EXCEPTION 'D-47: % assertion(s) in the 22..36 band carry an expect whose SHAPE does not match their check_sql (S-272)', v_shape;
  END IF;

  RAISE NOTICE 'D-47 applied: fixture 28 now 36 assertions, tier-2 execution probe installed';
END
$guard2$;
