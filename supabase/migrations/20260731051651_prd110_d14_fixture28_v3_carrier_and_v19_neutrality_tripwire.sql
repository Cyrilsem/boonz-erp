-- PRD-110 leg 42 · L42-U1 migration C of D
-- Fixture 28 must mirror the D-14 carrier ladder BEFORE the data lands (LAW 1, fixture first),
-- and it gains the tripwire that keeps the v19 columns honest for every future leg.
-- Surgical replace() with per-anchor pre-guards (L33-3 house pattern) - the 150-line scenario is
-- never retyped, so it cannot be silently truncated.
BEGIN;

DO $c$
DECLARE
  s      text;
  s0     text;
  n      int;
  -- anchors
  a_decl CONSTANT text := E'  v_manual_ev    bigint;\n';
  a_rder CONSTANT text := E'           msp.trip_interval_days::numeric AS pol_iv, msp.z_default,\n';
  a_lad1 CONSTANT text := E'                THEN CASE WHEN msp.trip_interval_days IS NOT NULL THEN ''policy_seed''\n';
  a_lad2 CONSTANT text := E'                          WHEN msp.trip_interval_days IS NOT NULL  THEN ''policy_seed''\n';
  a_expi CONSTANT text := E'                           WHEN ''policy_seed'' THEN r.pol_iv\n';
  a_expz CONSTANT text := E'         COALESCE(r.z_default, r.z_mid) AS exp_z\n';
  a_zvoc CONSTANT text := E'         count(*) FILTER (WHERE z_source IS NULL OR z_source NOT IN (''machine_service_policy'',''param_z_mid'')),\n';
  a_pay  CONSTANT text := E'  v_payload := jsonb_build_object(\n';
  a_tail CONSTANT text := E'    ''manual_evidence_machines'', v_manual_ev::text);\n';
BEGIN
  SELECT scenario_sql INTO s FROM golden.fixtures WHERE fixture_id = 28;
  IF s IS NULL THEN RAISE EXCEPTION 'C: fixture 28 not found'; END IF;
  s0 := s;

  -- PRE-GUARD: every anchor must occur EXACTLY once (a missing or duplicated anchor means the
  -- scenario drifted and a blind replace would corrupt it).
  FOR n IN
    SELECT 1 FROM (VALUES (a_decl,'decl'),(a_rder,'rder'),(a_lad1,'lad1'),(a_lad2,'lad2'),
                          (a_expi,'expi'),(a_expz,'expz'),(a_zvoc,'zvoc'),(a_pay,'pay'),(a_tail,'tail')) v(t,nm)
     WHERE (length(s) - length(replace(s, v.t, ''))) / NULLIF(length(v.t),0) <> 1
  LOOP
    RAISE EXCEPTION 'C: anchor guard failed - an anchor is missing or duplicated in fixture 28';
  END LOOP;

  -- 1. declarations
  s := replace(s, a_decl, a_decl ||
       E'  v_tier3        int;\n  v_tiers        int;\n  v_v19_z        bigint;\n  v_v19_trip     bigint;\n');

  -- 2. re-derivation carries the effective (override-aware) policy interval and z_v3
  s := replace(s, a_rder, a_rder ||
       E'           COALESCE(msp.trip_interval_days_v3, msp.trip_interval_days)::numeric AS eff_pol_iv,\n           msp.z_v3,\n');

  -- 3. both ladder branches test the EFFECTIVE policy interval
  s := replace(s, a_lad1,
       E'                THEN CASE WHEN COALESCE(msp.trip_interval_days_v3, msp.trip_interval_days) IS NOT NULL THEN ''policy_seed''\n');
  s := replace(s, a_lad2,
       E'                          WHEN COALESCE(msp.trip_interval_days_v3, msp.trip_interval_days) IS NOT NULL  THEN ''policy_seed''\n');

  -- 4. the policy tier sizes on the effective interval; pol_iv stays RAW so seq 11 is untouched
  s := replace(s, a_expi, E'                           WHEN ''policy_seed'' THEN r.eff_pol_iv\n');

  -- 5. z precedence mirrors the view: v3 carrier -> seed -> param
  s := replace(s, a_expz, E'         COALESCE(r.z_v3, r.z_default, r.z_mid) AS exp_z\n');

  -- 6. z_source vocabulary widens by exactly one value
  s := replace(s, a_zvoc,
       E'         count(*) FILTER (WHERE z_source IS NULL OR z_source NOT IN (''machine_service_policy'',''machine_service_policy_v3'',''param_z_mid'')),\n');

  -- 7. new measurements
  s := replace(s, a_pay,
       E'  -- STRUCTURAL tier-3 guard. After D-14c no in-scope machine exercises param_default on live\n'
    || E'  -- data, so the tier''s continued existence is proven from the view definition instead of\n'
    || E'  -- from an accident of AMZ-1046''s visit history.\n'
    || E'  SELECT CASE WHEN pg_get_viewdef(''public.v_machine_base_stock_policy_v3''::regclass, true) LIKE ''%param_default%''\n'
    || E'               AND pg_get_viewdef(''public.v_machine_base_stock_policy_v3''::regclass, true) LIKE ''%def_iv%''\n'
    || E'              THEN 1 ELSE 0 END INTO v_tier3;\n\n'
    || E'  SELECT count(DISTINCT interval_source) INTO v_tiers FROM fx28_act;\n\n'
    || E'  -- v19 NEUTRALITY. The base columns are what the LIVE engine_add_pod / rank_slot_suitability\n'
    || E'  -- / v_sizeup_candidates read. D-14 was applied to the _v3 carrier precisely so these stay\n'
    || E'  -- frozen (LAW 12). If either drifts, production sizing moved.\n'
    || E'  SELECT count(*) FILTER (WHERE z_default <> 1.65),\n'
    || E'         count(*) FILTER (WHERE (machine_class, trip_interval_days)\n'
    || E'                                NOT IN ((''busy'',12),(''standard'',21),(''backup'',30)))\n'
    || E'    INTO v_v19_z, v_v19_trip\n'
    || E'    FROM public.machine_service_policy;\n\n'
    || a_pay);

  -- 8. payload
  s := replace(s, a_tail,
       E'    ''manual_evidence_machines'', v_manual_ev::text,\n'
    || E'    ''view_tier3_present'',  v_tier3::text,\n'
    || E'    ''tiers_exercised'',     v_tiers::text,\n'
    || E'    ''v19_z_default_drift'', v_v19_z::text,\n'
    || E'    ''v19_trip_seed_drift'', v_v19_trip::text);\n');

  -- POST-GUARD: every edit present, nothing lost
  IF s = s0 THEN RAISE EXCEPTION 'C: scenario unchanged - all replaces were no-ops'; END IF;
  IF position('eff_pol_iv' in s) = 0
     OR position('COALESCE(r.z_v3, r.z_default, r.z_mid)' in s) = 0
     OR position('machine_service_policy_v3' in s) = 0
     OR position('view_tier3_present' in s) = 0
     OR position('v19_z_default_drift' in s) = 0
     OR position('v19_trip_seed_drift' in s) = 0
     OR position('tiers_exercised' in s) = 0
  THEN RAISE EXCEPTION 'C: post-guard - an expected edit is missing'; END IF;
  IF (length(s) - length(replace(s, 'trip_interval_days_v3', ''))) / length('trip_interval_days_v3') <> 3
  THEN RAISE EXCEPTION 'C: expected exactly 3 references to trip_interval_days_v3'; END IF;
  IF length(s) <= length(s0) THEN RAISE EXCEPTION 'C: scenario shrank - refusing'; END IF;

  UPDATE golden.fixtures SET scenario_sql = s WHERE fixture_id = 28;
END
$c$;

-- seq 14 / 15: AMZ-1046 stops being the tier-3 witness once D-14c seeds it.
UPDATE golden.assertions SET description =
 'THIRD TIER STILL RESOLVES: AMZ-1046-2406-O1 (16 pod-bound shelves) resolves to exactly one row. Until D-14c it was also the only witness that the param_default tier fires; that duty moved to seq 18 (structural) + seq 19 (non-vacuity)'
 WHERE fixture_id = 28 AND seq = 14;

UPDATE golden.assertions SET expect = 'policy_seed', description =
 'D-14c (CS 2026-07-31): AMZ-1046-2406-O1 now has a real machine_service_policy row, so with observed_n_gaps=1 < base_stock_min_gaps=2 it resolves via the POLICY tier, not param_default. Was ''param_default'' until 2026-07-31; re-phased, not deleted. If this ever reads ''observed'' the machine finally has a measurable cadence and the seeded row should be revisited'
 WHERE fixture_id = 28 AND seq = 15;

UPDATE golden.assertions SET description =
 'LAW 6: z_source NAMES its origin (machine_service_policy_v3 for a D-14 carrier override, machine_service_policy for a raw seed, param_z_mid for the fallback)'
 WHERE fixture_id = 28 AND seq = 9;

-- new assertions
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 28, 18,
 'STRUCTURAL TIER-3 GUARD: the param_default branch still exists in the canonical resolver. After D-14c no in-scope machine exercises it on live data, so silent removal would be invisible until the next policy-less machine starved (the D-13 / S-45 class of failure)',
 'SELECT value->>''view_tier3_present'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
 'eq', '1', true, (SELECT phase_required FROM golden.assertions WHERE fixture_id=28 AND seq=10)
UNION ALL SELECT 28, 19,
 'NON-VACUITY (S-29): seq 10''s whole-fleet contract is exercised on at least TWO distinct interval tiers. A one-tier population would make it a much weaker statement than it reads',
 'SELECT value->>''tiers_exercised'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
 'gte', '2', true, (SELECT phase_required FROM golden.assertions WHERE fixture_id=28 AND seq=10)
UNION ALL SELECT 28, 20,
 'LAW 12 / v19 NEUTRALITY (z): machine_service_policy.z_default is still 1.65 on every row. This column feeds the LIVE engine_add_pod whenever an item margin IS NULL (243 of 544 pod-bound shelves, 2026-07-31). D-14b was applied to z_v3 for exactly this reason. ⚠️ When CS flips the parked v19 propagation this goes RED ON PURPOSE - re-phase it, never delete it',
 'SELECT value->>''v19_z_default_drift'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
 'eq', '0', true, (SELECT phase_required FROM golden.assertions WHERE fixture_id=28 AND seq=10)
UNION ALL SELECT 28, 21,
 'LAW 12 / v19 NEUTRALITY (interval): machine_service_policy.trip_interval_days still holds the 2026-06-21 tertile seed on every row (busy 12 / standard 21 / backup 30). It feeds the LIVE engine_add_pod, rank_slot_suitability and v_sizeup_candidates. AMZ-1046''s D-14c row carries 21, which is v19''s OWN hardcoded fallback, so the seed row is provably neutral. ⚠️ Goes RED ON PURPOSE when CS flips the parked propagation - re-phase, never delete',
 'SELECT value->>''v19_trip_seed_drift'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
 'eq', '0', true, (SELECT phase_required FROM golden.assertions WHERE fixture_id=28 AND seq=10);

DO $g$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM golden.assertions WHERE fixture_id=28;
  IF n <> 21 THEN RAISE EXCEPTION 'C: expected 21 assertions on fixture 28, got %', n; END IF;
  SELECT count(*) INTO n FROM golden.assertions WHERE fixture_id=28 AND seq=15 AND expect='policy_seed';
  IF n <> 1 THEN RAISE EXCEPTION 'C: seq 15 not re-phased'; END IF;
END
$g$;

COMMIT;
