-- PRD-110 · S-47 step 1 · fixture 3: premise-gate the strict floor, add the unconditional LAW-5 line.
-- Both engines are CORRECT: each emits A07 with qty=0 and clamp_reason='blocked_no_wh' because
-- MPMCC-1058 draws from WH_CENTRAL only and its McVities batch was drained by live ops.
-- seq 4 / seq 7 asserted an outcome that is only true while the warehouse happens to be stocked
-- (RISK 90 generalised). Harness only; no engine, no protected entity.

DO $s47_f3$
DECLARE
  v_premise CONSTANT text := $q$SELECT COALESCE((
      SELECT av.available_units > 0
        FROM public.v_shelf_availability_v3 av
        JOIN public.shelf_configurations sc ON sc.shelf_id = av.shelf_id
        JOIN public.machines m ON m.machine_id = sc.machine_id
       WHERE m.official_name = 'MPMCC-1058-0000-R0' AND sc.shelf_code = 'A07'
    ), false)$q$;
  v_inverse CONSTANT text := $q$SELECT COALESCE((
      SELECT av.available_units = 0
        FROM public.v_shelf_availability_v3 av
        JOIN public.shelf_configurations sc ON sc.shelf_id = av.shelf_id
        JOIN public.machines m ON m.machine_id = sc.machine_id
       WHERE m.official_name = 'MPMCC-1058-0000-R0' AND sc.shelf_code = 'A07'
    ), false)$q$;
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 3 AND seq IN (4, 7) AND expect_op = 'gt' AND expect = '0' AND enabled;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'S-47 pre-guard: expected exactly 2 enabled strict-floor assertions (f3 seq 4,7 gt 0), found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 3 AND seq IN (8, 9, 19);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'S-47 pre-guard: fixture 3 seq 8/9/19 must be free, found % existing', v_n;
  END IF;

  UPDATE golden.assertions
     SET acceptance_gate_sql =
           'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = ''engine_add_pod_v3'') AND ('
           || v_premise || ')',
         description = description
           || ' [S-47: premise-gated on v_shelf_availability_v3.available_units > 0 for A07 -'
           || ' an unstocked WH_CENTRAL now reports as expected_red, not as a false failure]'
   WHERE fixture_id = 3 AND seq = 4;

  UPDATE golden.assertions
     SET acceptance_gate_sql = v_premise,
         description = description
           || ' [S-47: premise-gated on available_units > 0. It was ungated and went red at'
           || ' 03:55:15Z 2026-07-31 because WH_CENTRAL ran out of McVities, not because v19 changed]'
   WHERE fixture_id = 3 AND seq = 7;

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
  VALUES (3, 8,
    'LAW 5 (v3, SHADOW) UNCONDITIONAL: pinned-empty A07 always receives exactly ONE line, and that line is either qty>0 or an explicit qty=0 carrying a non-empty clamp_reason. Never a silent qty-0, and never an absent line (S-47: this is the fact seq 4 can no longer carry once it is premise-gated).',
    $chk$SELECT CASE
  WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'FAIL_no_v3_run'
  ELSE COALESCE((
    SELECT CASE
      WHEN count(*) <> 1 THEN 'FAIL_line_count_' || count(*)
      WHEN bool_or(prs.qty > 0) THEN 'PASS'
      WHEN bool_or(prs.qty = 0 AND btrim(COALESCE(prs.clamp_reason, '')) <> '') THEN 'PASS'
      ELSE 'FAIL_silent_zero'
    END
      FROM public.pod_refills_shadow prs
      JOIN public.shelf_configurations sc ON sc.shelf_id = prs.shelf_id
     WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
       AND prs.plan_date = {{plan_date}}
       AND sc.shelf_code = 'A07'
  ), 'FAIL_null')
END$chk$,
    'eq', 'PASS', true, 'P2',
    'SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = ''engine_add_pod_v3'')');

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
  VALUES (3, 9,
    'LAW 5 (v19) UNCONDITIONAL: pinned-empty A07 always receives exactly ONE line from the live engine, either qty>0 or an explicit qty=0 with a non-empty clamp_reason. Ungated - this fact must hold whatever the warehouse is doing (S-47 replacement for the ungated half of seq 7).',
    $chk$SELECT COALESCE((
    SELECT CASE
      WHEN count(*) <> 1 THEN 'FAIL_line_count_' || count(*)
      WHEN bool_or(pr.qty > 0) THEN 'PASS'
      WHEN bool_or(pr.qty = 0 AND btrim(COALESCE(pr.clamp_reason, '')) <> '') THEN 'PASS'
      ELSE 'FAIL_silent_zero'
    END
      FROM public.pod_refills pr
      JOIN public.shelf_configurations sc ON sc.shelf_id = pr.shelf_id
      JOIN public.machines m ON m.machine_id = pr.machine_id
     WHERE pr.plan_date = {{plan_date}}
       AND m.official_name = 'MPMCC-1058-0000-R0'
       AND sc.shelf_code = 'A07'
  ), 'FAIL_null')$chk$,
    'eq', 'PASS', true, 'P0', NULL);

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
  VALUES (3, 19,
    'S-47: when A07 genuinely has no warehouse stock, the v19 qty=0 line must EXPLAIN it by naming the warehouse block (clamp_reason ILIKE %wh%, today blocked_no_wh). Gated on available_units = 0 so it binds only when that is the actual situation.',
    $chk$SELECT COALESCE((
    SELECT CASE
      WHEN count(*) = 0 THEN 'FAIL_no_line'
      WHEN bool_or(pr.qty > 0) THEN 'PASS_stocked_after_all'
      WHEN bool_or(pr.qty = 0 AND pr.clamp_reason ILIKE '%wh%') THEN 'PASS'
      ELSE 'FAIL_zero_not_named_wh:' || COALESCE(max(pr.clamp_reason), '<null>')
    END
      FROM public.pod_refills pr
      JOIN public.shelf_configurations sc ON sc.shelf_id = pr.shelf_id
      JOIN public.machines m ON m.machine_id = pr.machine_id
     WHERE pr.plan_date = {{plan_date}}
       AND m.official_name = 'MPMCC-1058-0000-R0'
       AND sc.shelf_code = 'A07'
  ), 'FAIL_null')$chk$,
    'contains', 'PASS', true, 'P0', v_inverse);

  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 3 AND seq IN (4, 7) AND acceptance_gate_sql IS NOT NULL;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'S-47 post-guard: seq 4 and 7 must both carry a premise gate, found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 3 AND seq IN (8, 9, 19);
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'S-47 post-guard: expected 3 new assertions on fixture 3, found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 3;
  IF v_n <> 25 THEN
    RAISE EXCEPTION 'S-47 post-guard: fixture 3 must hold 25 assertions (22 + 3), found %', v_n;
  END IF;
END $s47_f3$;
