-- PRD-110 leg 118 - fixture 42 seq 60: SELF-SUPPLY THE `|breached| < capacity` PRECONDITION
-- (D-44 engineering remedy, independent of the ruling)
--
-- THE RED. Round 0 (stress_run b7051cfb) closed 58/58 fixtures, 2085/2085 assertions, ONE fail:
-- fixture 42 seq 60, the CS D-24 acceptance test verbatim - "VOXMCC-1005-0201-B0 carries value
-- at risk and IS SELECTED within capacity".
--
-- RE-DERIVED LIVE THIS LEG, NOT TAKEN FROM THE POINTER (LAW 13). At 2026-08-04 02:2x UTC the
-- picker returns: ranks 1-11 ALL cadence_floor_due (BREACHED), NINE of them carrying 0.00 AED;
-- effective day capacity is 6 (rank 6 cum_minutes 456.5 <= 480, rank 7 would be 539);
-- VOXMCC-1005 sits at rank 12 with 1036.49 AED, selection_reason `below_day_capacity`.
--
-- ⭐ THE ENGINE IS NOT WRONG. It obeys D-24 exactly - seq 31/32/35/40 green, picker md5 pins
-- 49/50/51 green. What moved is the FLEET: the breached population grew past a whole driver day
-- (S-213: the writer is the UTC clock, and it never cleans up). ⛔ NOTHING IN THE PICKER IS
-- TOUCHED HERE - `rank_machines_by_value_at_risk_v3` is byte-identical after this migration, and
-- whether the breached rule should be capped is CS's call, parked as D-44.
--
-- ⛔ seq 60 IS NOT LOOSENED. Its check_sql, expect_op and expect are UNCHANGED by this migration
-- (guarded below). Weakening it is the S-48/S-52/S-55 vacuity mode burned four times.
--
-- THE DEFECT IS IN THE FIXTURE, AND IT IS A MISSING PRECONDITION. seq 60 asserts an OUTCOME that
-- silently presupposes `|breached| < day capacity` - if the hard floor alone fills the day, no
-- money rule can ever place a machine, and the acceptance test fails bare with no named cause.
-- Per S-204 ("never pin an assertion on a population you do not write") the fixture must SUPPLY
-- that precondition instead of inheriting it from live fleet drift. This is the leg-114/115 idiom.
--
-- ── HOW THE PRECONDITION IS SUPPLIED ────────────────────────────────────────────────────────
-- The breached set is defined by two params: dsv >= LEAST(gap * floor_multiple, hard_max_days).
-- The plant DERIVES both from the fleet rather than hardcoding them:
--   floor_multiple := GREATEST(dsv/gap of M_CAD, live multiple)   -- M_CAD breaches by equality
--   hard_max_days  := GREATEST(max(dsv) + 1,     live hard max)   -- so LEAST() never binds
-- so the breached set becomes exactly {m : dsv/gap >= dsv/gap of M_CAD} - by construction
-- non-empty (it contains M_CAD, which fixture 42 anchors seq 34/35 on) and, on any fleet where
-- M_CAD is the most overdue machine, exactly ONE. Both GREATEST() clamps make the plant a
-- TIGHTENING and never a loosening: it can only ever SHRINK the breached set, never invent a
-- breach. Assertion 69 pins that direction; assertion 71 pins non-emptiness.
--
-- ⭐ THE TEST STILL DISCRIMINATES - THIS IS NOT VACUITY. Under the planted params ~10 machines
-- remain SOFT cadence_target_due with 0.00 AED. Under the PRE-D-24 rule (where target_due sorted
-- above money) every one of them would still outrank VOXMCC-1005 and seq 60 would still be false.
-- The plant removes the capacity starvation; it does NOT remove the money-vs-cadence contest.
--
-- ── DRY-PROVEN READ-ONLY BEFORE WRITING (rollback probe, S6 idiom: DO block ending in RAISE) ──
--   mult 2.0 -> 4.75 · hard 14 -> 21 · rho_mcad 4.75 · max_dsv 20 · breached 11 -> 1 · eff_cap 5
--   rank 1 NOVO-1023      breached=true  sel=true  why=cadence_floor   (seq 34/35 preserved)
--   rank 2 VOXMCC-1005    breached=false sel=true  why=value_at_risk   ⭐ seq 60 GREEN
--   ranks 3-7 selected on value_at_risk; rank 8 OMDCW below_day_capacity (seq 39 still binding)
--   params verified back at 2.0 / 14 after the probe rolled back.
--
-- ── BLAST RADIUS OF THE PLANT: MEASURED, AND IT IS THE SMALLEST IN THE BUILD SO FAR ─────────
--   a. `refill_policy_params` carries ZERO triggers (verified live this leg).
--   b. The ONLY object in the entire database reading var_cadence_floor_multiple or
--      var_cadence_hard_max_days is `rank_machines_by_value_at_risk_v3` itself (pg_proc scan +
--      view-definition scan, both live this leg). No view, no engine, no cron, no RPC reads them.
--   c. That function is STABLE / SECURITY INVOKER and WRITES NOTHING (pinned by seq 51), and it
--      is advisory only - Gate 0 stays manual (LAW 11, pinned by seq 48).
--   So the entire consequence of the ~50 s plant window is that a CONCURRENT call to a read-only
--   advisory ranking would return a different order. No writer, no protected entity, no state.
--   ⛔ This is strictly smaller than fixture 8's WEIMI plant (leg 114), which borrowed real
--   shelf state that the ADD engine sizes against.
--   d. run_fixture wraps the whole scenario in BEGIN/EXCEPTION WHEN OTHERS, so any error
--      anywhere rolls the plant back with everything else.
--   e. The restore writes the BANKED values back and re-reads the table for equality; assertion
--      75 pins the scratch verdict and assertion 76 re-reads the TABLE itself after the run.
--
-- ── WHY THE PLANT SITS BETWEEN 'pop' AND 'breach' (the one placement that works) ─────────────
--   seq 56/57 assert the params are at their DEFAULTS 2.0 / 14, reading the 'pop' snapshot.
--   seq 62 asserts the function's cadence_floor_due matches the fixture's independent 'breach'
--   recomputation, machine by machine.
--   So 'pop' must be taken BEFORE the plant (it is the live/unplanted world, and it doubles as
--   the D-44 live sensor), while 'breach' AND the function call must both be AFTER it (same
--   world, so seq 62 stays a real cross-check rather than a guaranteed mismatch).
--   Verified: no assertion cross-checks pop.cadence_breached against the function output, and
--   pop.mtop_breached / pop.mcad_breached are read by NO assertion (all 67 check_sql scanned).
--
-- ── THE D-44 SENSOR (the second half of the parking-lot remedy) ──────────────────────────────
-- Scratch key 'd44' records, every single run: the live params, the planted params, the LIVE
-- breached count, the planted breached count, the modelled effective day capacity, and the
-- boolean d44_starving. Assertions 72/73 carry the live numbers into golden.runs.detail.actual
-- on every run, so the next recurrence NAMES its cause instead of seq 60 failing bare.
-- ⛔ eff_cap_model is a deliberately CONSERVATIVE lower bound (it charges inter-cluster travel
-- to every machine, so it read 5 where the picker actually seated 6-7). Conservative is the safe
-- direction: it makes assertion 70 STRICTER, never laxer.
--
-- NOT TOUCHED: the picker body, any engine, any RPC, any flag, any cron, any protected table,
-- seq 60's check_sql/expect_op/expect, and any existing assertion (only INSERTs below).
-- LAW 12: fixture 42's plan_date 2030-02-12 is unchanged and nothing is planted on any plan date.

-- ── 1. scenario_sql: PLANT between the 'pop' snapshot and the 'breach' recomputation ────────
UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
         '-- Per-machine INDEPENDENT breach verdict, so seq 62 can prove the function''s cadence_floor_due',
$PLANT$-- ── SELF-SUPPLY PLANT for seq 60 (leg 118, D-44 engineering remedy) ─────────────
-- seq 60 asserts M_TOP is SELECTED. That silently presupposes the breached set leaves room in
-- the day: when |breached| >= capacity the hard floor fills the day alone and NO money rule can
-- ever seat a machine. The live fleet crossed that line (11 breached vs a capacity of 6, nine of
-- the 11 carrying 0.00 AED). Per S-204 the fixture SUPPLIES the precondition rather than
-- inheriting it from fleet drift.
-- ⛔ Both params are clamped with GREATEST() against their live values, so this can only ever
-- SHRINK the breached set - it can never invent a breach. It is a TIGHTENING (assertion 69).
-- ⛔ The ONLY reader of these two params anywhere in the database is the read-only advisory
-- picker itself; refill_policy_params carries no triggers. Restored + verified below.
DO $fx42plant$
DECLARE
  v_mult_live numeric; v_hard_live int;
  v_mult_new  numeric; v_hard_new  int;
  v_rho_mcad  numeric; v_max_dsv numeric; v_avg_lines numeric;
  v_cap int; v_daymin numeric; v_svc numeric; v_pack numeric; v_inter numeric;
  v_eff_cap int; v_br_live int; v_br_planted int; v_planted int := 0;
BEGIN
  -- ⛔ SERIALIZE THE BORROW. Two concurrent fixture-42 runs would otherwise interleave as
  -- bank(live) / plant / bank(PLANTED) / restore(live) / restore(PLANTED) and leave the planted
  -- values in place PERMANENTLY - the one way this idiom can corrupt live policy. The lock is
  -- transaction-scoped, so it spans plant -> picker -> restore and releases itself even on error.
  PERFORM pg_advisory_xact_lock(1100042);

  SELECT var_cadence_floor_multiple, var_cadence_hard_max_days,
         var_driver_day_minutes, var_service_minutes_per_machine,
         var_pack_minutes_per_line, var_travel_minutes_inter_cluster
    INTO v_mult_live, v_hard_live, v_daymin, v_svc, v_pack, v_inter
    FROM public.refill_policy_params LIMIT 1;
  SELECT driver_capacity INTO v_cap FROM public.pick_urgency_params LIMIT 1;

  -- The universe and the gap are taken from f42_shelf + the Article 16 canonical visit clock,
  -- i.e. EXACTLY the join the per-machine breach block below and the function under test use.
  -- ⛔ Do NOT write the scratch key in quotes anywhere in this payload: the guard counts the
  -- quoted form to prove the breach recomputation survived, and a comment would inflate it.
  SELECT h.days_since_visit::numeric / NULLIF(g.gap_days, 0)
    INTO v_rho_mcad
    FROM public.v_machine_health_signals h
    JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id
   WHERE h.machine_id = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04';

  SELECT max(h.days_since_visit)::numeric
    INTO v_max_dsv
    FROM public.v_machine_health_signals h
    JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id;

  IF v_rho_mcad IS NULL OR v_max_dsv IS NULL THEN
    RAISE EXCEPTION 'leg118: M_CAD overdue ratio or fleet max dsv is NULL - the plant cannot be derived';
  END IF;

  -- GREATEST() against the live value in BOTH directions: tightening only, never a loosening.
  v_mult_new := GREATEST(v_rho_mcad, v_mult_live);
  v_hard_new := GREATEST(ceil(v_max_dsv + 1)::int, v_hard_live);

  SELECT count(*) INTO v_br_live
    FROM public.v_machine_health_signals h
    JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id
   WHERE h.days_since_visit >= LEAST(g.gap_days * v_mult_live, v_hard_live::numeric);

  SELECT count(*) INTO v_br_planted
    FROM public.v_machine_health_signals h
    JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id
   WHERE h.days_since_visit >= LEAST(g.gap_days * v_mult_new, v_hard_new::numeric);

  -- Modelled day capacity, computed from the params and the live line counts - never from the
  -- function under test. Charges inter-cluster travel to EVERY machine, so it is a conservative
  -- LOWER bound on how many machines a day can seat. Conservative makes assertion 70 stricter.
  SELECT avg(n) INTO v_avg_lines
    FROM (SELECT sum(is_refill_line) n FROM f42_shelf GROUP BY machine_id) z;
  v_eff_cap := LEAST(v_cap, floor(v_daymin / NULLIF(v_svc + v_inter + v_pack * v_avg_lines, 0))::int);

  UPDATE public.refill_policy_params
     SET var_cadence_floor_multiple = v_mult_new,
         var_cadence_hard_max_days  = v_hard_new;
  GET DIAGNOSTICS v_planted = ROW_COUNT;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'd44', jsonb_build_object(
    'mult_live',        v_mult_live,
    'hard_live',        v_hard_live,
    'mult_planted',     v_mult_new,
    'hard_planted',     v_hard_new,
    'rho_mcad',         round(v_rho_mcad, 4),
    'max_dsv',          v_max_dsv,
    'planted_rows',     v_planted,
    'breached_live',    v_br_live,
    'breached_planted', v_br_planted,
    'eff_cap_model',    v_eff_cap,
    'd44_starving',     (v_br_live >= v_eff_cap),
    'restored',         false))
  ON CONFLICT (fixture_id, key) DO UPDATE
    SET value = EXCLUDED.value, written_at = now();
END
$fx42plant$;

-- Per-machine INDEPENDENT breach verdict, so seq 62 can prove the function's cadence_floor_due$PLANT$)
 WHERE fixture_id = 42;

-- ── 2. scenario_sql: RESTORE immediately after the function call, verified byte-identical ───
UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
         'SELECT {{fixture_id}}, ''mtv_after'', to_jsonb((SELECT count(*) FROM public.machines_to_visit));',
$RESTORE$-- ── RESTORE the two banked cadence params, immediately after the picker ran ────
-- Wholesale write-back of the BANKED values rather than "set them back to 2.0 and 14": the
-- banked value cannot drift from what was actually there, so equality is decidable rather than
-- inferred. Assertion 75 pins this verdict; assertion 76 independently re-reads the TABLE.
DO $fx42restore$
DECLARE
  v_bak jsonb; v_ok boolean := false; v_n int := 0;
BEGIN
  SELECT value INTO v_bak FROM golden.scratch
   WHERE fixture_id = {{fixture_id}} AND key = 'd44';

  IF v_bak IS NOT NULL AND v_bak ? 'mult_live' AND v_bak ? 'hard_live' THEN
    UPDATE public.refill_policy_params
       SET var_cadence_floor_multiple = (v_bak->>'mult_live')::numeric,
           var_cadence_hard_max_days  = (v_bak->>'hard_live')::int;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    SELECT (var_cadence_floor_multiple = (v_bak->>'mult_live')::numeric
        AND var_cadence_hard_max_days  = (v_bak->>'hard_live')::int)
      INTO v_ok
      FROM public.refill_policy_params LIMIT 1;
  END IF;

  UPDATE golden.scratch
     SET value = value || jsonb_build_object('restored',      COALESCE(v_ok, false),
                                             'restored_rows', v_n),
         written_at = now()
   WHERE fixture_id = {{fixture_id}} AND key = 'd44';
END
$fx42restore$;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'mtv_after', to_jsonb((SELECT count(*) FROM public.machines_to_visit));$RESTORE$)
 WHERE fixture_id = 42;

-- ── 3. FAIL-LOUD GUARD: replace() is SILENT on a missed needle (leg 112/113 tool lesson) ────
DO $guard118$
DECLARE
  v_s text;
  v_chk text; v_op text; v_exp text;
BEGIN
  SELECT scenario_sql INTO v_s FROM golden.fixtures WHERE fixture_id = 42;

  IF position('$fx42plant$'   in v_s) = 0 THEN RAISE EXCEPTION 'leg118: plant block did not land';   END IF;
  IF position('$fx42restore$' in v_s) = 0 THEN RAISE EXCEPTION 'leg118: restore block did not land'; END IF;

  -- each block present exactly once (open+close = 2 occurrences of the tag)
  IF (length(v_s) - length(replace(v_s, '$fx42plant$', ''))) / length('$fx42plant$') <> 2 THEN
    RAISE EXCEPTION 'leg118: plant block is not present exactly once';
  END IF;
  IF (length(v_s) - length(replace(v_s, '$fx42restore$', ''))) / length('$fx42restore$') <> 2 THEN
    RAISE EXCEPTION 'leg118: restore block is not present exactly once';
  END IF;

  -- the 'breach' recomputation must survive exactly once, and the picker exactly twice + limit3
  IF (length(v_s) - length(replace(v_s, '''breach''', ''))) / length('''breach''') <> 1 THEN
    RAISE EXCEPTION 'leg118: the breach recomputation block was damaged';
  END IF;
  -- ⛔ MEASURED, NOT ASSUMED: the picker NAME occurs 4x - three real calls plus the
  -- `pg_proc WHERE proname = ...` existence guard that lets the RED baseline report missing
  -- evidence instead of aborting. Count the CALL form so the existence guard cannot mask a
  -- lost call (and so adding a comment mentioning the function never reds this).
  IF (length(v_s) - length(replace(v_s, 'FROM public.rank_machines_by_value_at_risk_v3(', '')))
     / length('FROM public.rank_machines_by_value_at_risk_v3(') <> 3 THEN
    RAISE EXCEPTION 'leg118: expected exactly 3 picker calls (out, out_again, out_limit3)';
  END IF;

  -- ⛔ THE ORDER IS THE WHOLE DESIGN: 'pop' (live world, seq 56/57) BEFORE the plant;
  --    'breach' AND the picker AFTER it (same world, so seq 62 stays a real cross-check);
  --    the restore AFTER the picker.
  IF NOT (position('''pop''' in v_s) < position('$fx42plant$' in v_s)) THEN
    RAISE EXCEPTION 'leg118: the pop snapshot is not taken BEFORE the plant (seq 56/57 would red)';
  END IF;
  IF NOT (position('$fx42plant$' in v_s) < position('''breach''' in v_s)) THEN
    RAISE EXCEPTION 'leg118: the breach recomputation is not AFTER the plant (seq 62 would red)';
  END IF;
  IF NOT (position('''breach''' in v_s) < position('FROM public.rank_machines_by_value_at_risk_v3(' in v_s)) THEN
    RAISE EXCEPTION 'leg118: the picker is not called AFTER the breach recomputation';
  END IF;
  IF NOT (position('FROM public.rank_machines_by_value_at_risk_v3(' in v_s) < position('$fx42restore$' in v_s)) THEN
    RAISE EXCEPTION 'leg118: the restore is not AFTER the picker call';
  END IF;

  -- ⛔ seq 60 IS NOT LOOSENED. Pin its three fields byte-for-byte.
  SELECT check_sql, expect_op, expect INTO v_chk, v_op, v_exp
    FROM golden.assertions WHERE fixture_id = 42 AND seq = 60;
  IF v_op <> 'eq' OR v_exp <> 'true'
     OR position('148c4fcf-b794-43f0-a2a8-e6f17605b045' in v_chk) = 0
     OR position('selected' in v_chk) = 0 THEN
    RAISE EXCEPTION 'leg118: seq 60 was altered - this migration must never touch the acceptance test';
  END IF;
END
$guard118$;

-- ── 4. assertions 68-76 (max(seq) for fixture 42 was 67, taken UNFILTERED) ───────────────────
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (42, 68,
  'PLANT LANDED: the self-supplied cadence precondition reached the one refill_policy_params row. 0 or -1 means the plant never ran and seq 60 below is running on an unplanted fleet - read it as "no precondition", not as "the picker regressed"',
  'SELECT COALESCE((SELECT value->>''planted_rows'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''-1'')',
  'eq', '1', true, 'P3'),
 (42, 69,
  'THE PLANT IS A TIGHTENING, NEVER A LOOSENING: both planted params are >= their live values, so the plant can only SHRINK the breached set and can never invent a breach. ⛔ This is what stops the self-supply from becoming the S-48/S-52/S-55 vacuity mode - a fixture that could LOWER the floor could manufacture any outcome it liked',
  'SELECT COALESCE((SELECT (((value->>''mult_planted'')::numeric >= (value->>''mult_live'')::numeric) AND ((value->>''hard_planted'')::numeric >= (value->>''hard_live'')::numeric))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''MISSING'')',
  'eq', 'true', true, 'P3'),
 (42, 70,
  'THE PRECONDITION seq 60 SILENTLY PRESUPPOSED, NOW WITNESSED: under the planted params the breached set is strictly smaller than the modelled day capacity, so the hard floor leaves room and the money rule can actually seat a machine. When this is false, seq 60 CANNOT pass no matter how correct the picker is',
  'SELECT COALESCE((SELECT ((value->>''breached_planted'')::int < (value->>''eff_cap_model'')::int)::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''MISSING'')',
  'eq', 'true', true, 'P3'),
 (42, 71,
  'NON-VACUITY OF THE SELF-SUPPLY: the planted breached set is still NON-EMPTY. ⛔ If the plant ever switched the hard floor off entirely, seq 34/35 (M_CAD breaches and outranks M_TOP) would become untestable and seq 60 would pass for the wrong reason. It contains M_CAD by construction',
  'SELECT COALESCE((SELECT value->>''breached_planted'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''-1'')',
  'gte', '1', true, 'P3'),
 (42, 72,
  'D-44 LIVE SENSOR - THE NUMBER, RECORDED EVERY RUN: how many machines have breached the cadence floor under the REAL, unplanted params. ⭐ Its `actual` is the diagnostic golden.runs.detail preserves; read it against seq 73 whenever seq 60 is investigated. -1 means the sensor itself is missing',
  'SELECT COALESCE((SELECT value->>''breached_live'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''-1'')',
  'gte', '0', true, 'P3'),
 (42, 73,
  'D-44 LIVE SENSOR - THE OTHER NUMBER: the modelled effective day capacity, a deliberately CONSERVATIVE lower bound (inter-cluster travel charged to every machine). seq 72 >= this value IS the D-44 starvation state: the breached floor alone consumes the driver day and zero-value overdue machines crowd out money',
  'SELECT COALESCE((SELECT value->>''eff_cap_model'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''-1'')',
  'gt', '0', true, 'P3'),
 (42, 74,
  'D-44 SENSOR IS SELF-CONSISTENT: the recorded d44_starving flag equals the comparison of its own two recorded numbers. A sensor that reports a verdict its own inputs contradict is worse than no sensor - this is what stops the flag from silently decoupling from seq 72/73',
  'SELECT COALESCE((SELECT ((value->>''d44_starving'')::boolean = (((value->>''breached_live'')::int) >= ((value->>''eff_cap_model'')::int)))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''MISSING'')',
  'eq', 'true', true, 'P3'),
 (42, 75,
  'NO RESIDUE (scratch verdict): the two banked cadence params were written back and re-read equal immediately after the picker ran. This fixture BORROWS two policy numbers and gives them back - a false here means live policy is left falsified and must be repaired from golden.scratch key ''d44'' -> mult_live / hard_live',
  'SELECT COALESCE((SELECT value->>''restored'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''false'')',
  'eq', 'true', true, 'P3'),
 (42, 76,
  'NO RESIDUE (independent TABLE read, not the scratch verdict): after the whole scenario completed, refill_policy_params itself still carries the banked values. ⭐ seq 75 asks the restore block whether it succeeded; THIS asks the table. Only the pair can distinguish a real restore from a lying one',
  'SELECT COALESCE((SELECT (((SELECT var_cadence_floor_multiple FROM public.refill_policy_params LIMIT 1) = (value->>''mult_live'')::numeric) AND ((SELECT var_cadence_hard_max_days FROM public.refill_policy_params LIMIT 1) = (value->>''hard_live'')::int))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''d44''),''MISSING'')',
  'eq', 'true', true, 'P3');
