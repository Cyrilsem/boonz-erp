-- PRD-110 · leg 157 · LAW 8 · S-302 · D-48 (NEW CS ASK, PARKED)
-- FIXTURE 42 seqs 61 + 63 RESTATED: both asserted live populations the fixture does not control,
-- and they went red for TWO DIFFERENT reasons. Neither is an engine regression.
--
-- ⛔ THE ENGINE IS NOT TOUCHED BY THIS MIGRATION. Cody BLOCKED the change that was drafted first
--    (`LEAST(gap*mult, hard_max)` -> `GREATEST(gap, LEAST(gap*mult, hard_max))`). See D-48 below.
--
-- THE BISECT. Fixture 42 was GREEN 85/0 at 2026-08-08 09:56Z and RED 83/2 from 12:52Z.
--
--   seq 61 (reads `pop`, computed under the LIVE params: mult 2.0, hard_max 14)
--     `cadence_breached` = 2 but `cadence_due` = 1, so `breached < due` is false. The breached set
--     is NOT a subset of the due set, which the assertion silently assumed. One machine causes it:
--     ⛔ **GRIT-1022-0100-W0** - `v_machine_base_stock_policy_v3.visit_interval_days` = **20.5**
--     (`interval_source='observed'`, median of 4 gaps; its `policy_trip_interval_days` is **30**).
--     Its breach threshold is `LEAST(20.5 x 2.0, 14)` = **14**, and at `days_since_visit` = 19 it
--     reads BREACHED while **not yet due by its own service target**. Zero machines had a cadence
--     longer than 14 days before this week, so both readings below held vacuously until now.
--
--   seq 63 (reads `out`, computed under the PLANTED params: mult 5.75, hard_max 24)
--     A DIFFERENT cause, and a much duller one: `target_due AND NOT floor_due` is empty because
--     the only target-due machine in the fleet today (NOVO-1023, gap 4, dsv 23) is also breached.
--     ⭐ Nothing structural failed. The band simply has no occupant this week. Under the plant
--     there is no inversion at all (measured: 31 rows, inverted 0, band 31) - the plant raises
--     hard_max to 24 and hides GRIT entirely, which is why the two seqs disagree about the world.
--
-- ⛔⛔ D-48 (NEW, PARKED - A CS ASK, NOT A DEFECT). TWO CS-ATTRIBUTED INTENTS NOW CONTRADICT.
--    They are mutually exclusive exactly when a machine's `gap_days` exceeds `hard_max_days`:
--      (A) seq 61's S-75 sensor: the breached set is strictly INSIDE the target-due set. Being
--          breached is a STRONGER statement than being due - that is what lets it pre-empt money.
--      (B) seq 57's own description: `var_cadence_hard_max_days` = 14 is "the absolute ceiling
--          nobody exceeds REGARDLESS OF THEIR OWN GAP".
--    D-24's ruling text (parking lot line 5047) says only "a max-days-between-visits floor that
--    forces inclusion when breached" and never settles the interaction. `LEAST` encodes (B) and
--    breaks (A); `GREATEST` would encode (A) and override (B). ⛔ **Choosing is CS's call, not the
--    loop's** - and it has teeth, because under D-44 a breached machine outranks money outside the
--    reserved slots, so GRIT-1022 currently pre-empts money while not yet due by its own policy.
--    THE ASK: does the 14-day absolute ceiling bind a machine whose own measured cadence is longer
--    than 14 days? If YES, today's behaviour is correct and (A) must be retired as a general law.
--    If NO, the threshold becomes `GREATEST(gap_days, LEAST(gap_days*mult, hard_max))` and a
--    ~monthly machine is allowed its month. ⭐ Population today: ONE machine of 31.
--
-- THE RESTATEMENT (S-272: expect_op/expect move WITH the shape of check_sql).
--    Both seqs are moved off visit-timing luck and onto STRUCTURE, and both are scoped to the
--    population where (A) and (B) do not collide - so the fixture asserts nothing D-48 will settle.
--      seq 61 -> every machine whose `gap_days <= hard_max_days` has a breach threshold STRICTLY
--        LATER than its service target, and that population is non-empty. This is what "the floor
--        is neither decorative nor collapsed back into the soft target" actually means, and unlike
--        a headcount of who happens to be overdue this week it cannot be emptied by a driver
--        turning up. ⭐ It still dies on `mult = 1.0` exactly as before: the band would collapse to
--        zero on all 30 machines. Measured 30 of 30 at leg 157.
--      seq 63 -> the same structural band is non-empty (30). Its stated job was NON-VACUITY of the
--        soft/hard distinction; a band that exists by construction discharges that job, a band that
--        happens to be occupied does not.
--      seq 86 (new) -> THE SENSOR THIS FIXTURE NEVER HAD: an inversion the ceiling does NOT
--        explain. Any row whose reported `breach_threshold_days` is below its own `gap_days`
--        while `gap_days <= hard_max_days` is an arithmetic defect with no policy reading at all.
--        Measured 0. ⛔ This is deliberately NOT a count of D-48 conflicts - those are RECORDED to
--        golden.scratch (`cad_conflict_live`, `cad_conflict_names`) and asserted by nobody, because
--        a count of live rows is precisely what S-301/S-302 say not to pin.
--
-- ⭐ WHAT IS DELIBERATELY NOT LOOSENED. seq 56 (mult = 2.0) and seq 57 (hard_max = 14) still pin
--    both dials exactly, so "collapsed back into the target" and "raised out of reach" keep their
--    direct sensors. seq 62 (the function's `cadence_floor_due` equals an INDEPENDENT recomputation,
--    machine by machine) is untouched and still passes - it is the assertion that proves the object
--    means what D-24 says, and it is deliberately left agreeing with today's `LEAST` so that the day
--    CS answers D-48 this fixture goes red until the mirror is moved with the engine.

DO $do$
DECLARE
  v_scen text;
  v_new  text;
  v_b61  text;
  v_b63  text;
  k_anchor CONSTANT text :=
    '  ''cadence_hard_max_days'',  (SELECT var_cadence_hard_max_days FROM public.refill_policy_params LIMIT 1),';
BEGIN
  SELECT scenario_sql INTO v_scen FROM golden.fixtures WHERE fixture_id = 42;
  IF v_scen IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 42 has no scenario_sql.'; END IF;

  -- S-298: exactly once, not "at least once".
  IF (length(v_scen) - length(replace(v_scen, k_anchor, ''))) / length(k_anchor) <> 1 THEN
    RAISE EXCEPTION 'REFUSED: the cadence_hard_max_days payload line is not present exactly once.';
  END IF;
  IF position('cad_agree_machines' in v_scen) > 0 THEN
    RAISE EXCEPTION 'REFUSED: fixture 42 already carries cad_agree_machines - already restated.';
  END IF;

  -- Four new measures, all taken under the LIVE params in the `pop` block (which runs BEFORE the
  -- D-44 plant). ⛔ That ordering is the whole point: the plant raises hard_max to 24 and would
  -- hide the D-48 conflict completely, so the conflict must be measured here or not at all.
  v_new := replace(v_scen, k_anchor,
    k_anchor || E'\n' ||
    '  -- leg 157 / D-48. The population where D-24''s two encoded intents do NOT collide:'          || E'\n' ||
    '  -- a machine whose own cadence is no longer than the fleet-wide absolute ceiling.'            || E'\n' ||
    '  ''cad_agree_machines'',    (SELECT count(*) FROM (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g' || E'\n' ||
    '                              CROSS JOIN (SELECT var_cadence_floor_multiple AS mult,'           || E'\n' ||
    '                                                 var_cadence_hard_max_days::numeric AS capd'    || E'\n' ||
    '                                          FROM public.refill_policy_params LIMIT 1) q'          || E'\n' ||
    '                              WHERE g.gap_days <= q.capd),'                                     || E'\n' ||
    '  -- STRUCTURAL non-vacuity: of those, the ones whose breach threshold is STRICTLY LATER than'  || E'\n' ||
    '  -- their service target. Immune to who happens to be overdue today; dies on mult = 1.0.'      || E'\n' ||
    '  ''cad_agree_band'',        (SELECT count(*) FROM (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g' || E'\n' ||
    '                              CROSS JOIN (SELECT var_cadence_floor_multiple AS mult,'           || E'\n' ||
    '                                                 var_cadence_hard_max_days::numeric AS capd'    || E'\n' ||
    '                                          FROM public.refill_policy_params LIMIT 1) q'          || E'\n' ||
    '                              WHERE g.gap_days <= q.capd'                                       || E'\n' ||
    '                                AND LEAST(g.gap_days * q.mult, q.capd) > g.gap_days),'          || E'\n' ||
    '  -- D-48 CENSUS. RECORDED FOR CS, ASSERTED BY NOBODY (S-301/S-302: never pin a live count).'   || E'\n' ||
    '  ''cad_conflict_live'',     (SELECT count(*) FROM (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g' || E'\n' ||
    '                              CROSS JOIN (SELECT var_cadence_hard_max_days::numeric AS capd'    || E'\n' ||
    '                                          FROM public.refill_policy_params LIMIT 1) q'          || E'\n' ||
    '                              WHERE g.gap_days > q.capd),'                                      || E'\n' ||
    '  ''cad_conflict_names'',    (SELECT COALESCE(string_agg(p.official_name || ''@'' || g.gap_days::text, '' | ''' || E'\n' ||
    '                                                        ORDER BY p.official_name), ''none'')'   || E'\n' ||
    '                              FROM (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g'     || E'\n' ||
    '                              JOIN public.v_machine_priority p ON p.machine_id = g.machine_id'  || E'\n' ||
    '                              CROSS JOIN (SELECT var_cadence_hard_max_days::numeric AS capd'    || E'\n' ||
    '                                          FROM public.refill_policy_params LIMIT 1) q'          || E'\n' ||
    '                              WHERE g.gap_days > q.capd),');

  IF v_new = v_scen THEN RAISE EXCEPTION 'REFUSED: scenario_sql unchanged after the replacement.'; END IF;
  IF position('cad_conflict_names' in v_new) = 0 THEN
    RAISE EXCEPTION 'REFUSED: post-image is missing cad_conflict_names.';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 42;

  -- ---- seq 61 ------------------------------------------------------------------------------
  SELECT check_sql INTO v_b61 FROM golden.assertions WHERE fixture_id = 42 AND seq = 61;
  IF v_b61 IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 42 seq 61 does not exist.'; END IF;
  IF v_b61 NOT LIKE '%cadence_breached%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 42 seq 61 does not read cadence_breached (reads: %). '
                    'It has already been restated or renumbered; re-derive before overwriting.', v_b61;
  END IF;

  UPDATE golden.assertions
     SET check_sql = 'SELECT (((value->>''cad_agree_machines'')::int > 0)
        AND ((value->>''cad_agree_band'')::int = (value->>''cad_agree_machines'')::int))::text
    FROM golden.scratch WHERE fixture_id=42 AND key=''pop''',
         expect_op = 'eq',
         expect    = 'true',
         description = 'S-75 SENSOR FOR THE SENSOR, RESTATED STRUCTURALLY (leg 157, D-48): across every machine whose own cadence is no longer than the absolute ceiling - the population where D-24''s two encoded intents do not collide - the hard floor lands STRICTLY LATER than the soft service target, on all of them, and that population is non-empty. 30 of 30 at leg 157. ⛔ This seq previously asserted 0 < cadence_breached < cadence_due over the live fleet, and went red at leg 156 because GRIT-1022-0100-W0 acquired an OBSERVED cadence of 20.5 days: its threshold LEAST(20.5 x 2.0, 14) = 14 fires at day 14, so at dsv 19 it reads BREACHED while not yet due by its own target, and the breached set stopped being a subset of the due set. Whether the 14-day ceiling should bind a machine with a longer cadence is CS decision D-48, PARKED - so this seq now asserts nothing D-48 will settle. ⭐ It keeps the failure mode it was built for: set the multiple to 1.0 and the band collapses to zero on all 30, which reds it. It also no longer depends on who happens to be overdue in any given week. seqs 56/57 still pin both dials exactly and seq 62 still checks the function against an independent recomputation machine by machine.'
   WHERE fixture_id = 42 AND seq = 61;

  -- ---- seq 63 ------------------------------------------------------------------------------
  SELECT check_sql INTO v_b63 FROM golden.assertions WHERE fixture_id = 42 AND seq = 63;
  IF v_b63 IS NULL THEN RAISE EXCEPTION 'REFUSED: fixture 42 seq 63 does not exist.'; END IF;
  IF v_b63 NOT LIKE '%cadence_floor_due%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 42 seq 63 does not read cadence_floor_due (reads: %). '
                    'It has already been restated or renumbered; re-derive before overwriting.', v_b63;
  END IF;

  UPDATE golden.assertions
     SET check_sql = 'SELECT value->>''cad_agree_band'' FROM golden.scratch WHERE fixture_id=42 AND key=''pop''',
         expect_op = 'gt',
         expect    = '0',
         description = 'NON-VACUITY OF THE WHOLE DECISION, RESTATED STRUCTURALLY (leg 157): the soft/hard distinction has a population BY CONSTRUCTION - machines whose breach threshold lands strictly later than their service target, so there is a band in which a machine is due without being breached. These are exactly the machines D-24 stops from pre-empting money. ⛔ This seq previously counted machines SITTING IN that band right now, read off the picker output under the D-44 planted params, and went red at leg 156 for the dullest possible reason: the only target-due machine in the fleet that week (NOVO-1023, gap 4, dsv 23) was also breached, so the band was momentarily unoccupied. Nothing structural had failed and no engine had changed - a driver turning up on the right day would have made it green again. A band that exists by construction discharges the non-vacuity job; a band that happens to be occupied only discharges it by luck (S-301 / S-302).'
   WHERE fixture_id = 42 AND seq = 63;

  -- ---- seq 86: the sensor this fixture never had ---------------------------------------------
  IF EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id = 42 AND seq = 86) THEN
    RAISE EXCEPTION 'REFUSED: fixture 42 seq 86 already exists - renumber before inserting.';
  END IF;

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES (42, 86,
    'AN INVERSION THE CEILING DOES NOT EXPLAIN (new at leg 157, D-48): zero rows report a breach_threshold_days BELOW their own gap_days while that gap_days is within the absolute ceiling. A threshold inside the ceiling that still fires before the machine is due is arithmetic, not policy - it has no reading under either side of D-48 and would mean the LEAST/GREATEST composition itself is wrong. ⛔ Deliberately NOT a count of D-48 conflict machines: those are RECORDED to golden.scratch as cad_conflict_live and cad_conflict_names and asserted by nobody, because pinning a live population count is exactly the defect S-301 and S-302 were raised for. Measured 0 at leg 157 (31 rows, band 31, inverted 0 under the planted params).',
    'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT'' ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key=''out''
      AND (e->''reasoning''->''cadence''->>''breach_threshold_days'')::numeric < (e->>''gap_days'')::numeric
      AND (e->>''gap_days'')::numeric <= (e->''reasoning''->''cadence''->>''hard_max_days'')::numeric) END',
    'eq', '0', true, 'P4');
END
$do$;
