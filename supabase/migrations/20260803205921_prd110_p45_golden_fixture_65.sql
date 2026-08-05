-- PRD-110 leg 101 — golden fixture 65: the P4.5 scoreboard.
-- Every measurement is taken into golden.scratch by the scenario, then the scenario
-- DELETES its own synthetic 2030 rows, so the fixture cannot pollute
-- v_scoreboard_health_v3's streak (which reads max(metric_date)).
-- Assertions read scratch only, except the four that deliberately probe LIVE state
-- (reachability, streak, grain, cron).

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, notes, enabled)
VALUES (65,
  'P4.5 scoreboard: every metric is either a real value or an explicit, reasoned refusal — and every "count of a bad thing" detector is proven able to see one',
  'PRD-110 BUILD SPEC line 105 (P4.5). Built leg 101. During the first backfill the vacuity map exposed a defect in this fixture''s own subject: composition_confidence_avg was gated on "p_metric_date = today Dubai", but the only caller that ever runs (cron 47, 02:45 Dubai) computes Dubai-YESTERDAY, so the metric could never once be produced. That is the S-173/S-174 class — a value that can never be reached is the same defect as a green that can never be red. Seq 23 is the permanent tripwire for it.',
  'P0', DATE '2030-03-07',
  'Scenario measures into scratch then cleans up its own 2030 rows. Seq 8 is the positive control for the vacuity CHECK (it must ACCEPT a legitimate vacuous row, or seq 6/7 would pass for the trivial reason that the constraint refuses everything). Seq 10 is the positive control for the expired_sold_incidents detector, run inside a deliberately rolled-back subtransaction so inventory_events (cron 44''s table) is left byte-untouched.',
  true)
ON CONFLICT (fixture_id) DO UPDATE
  SET name = EXCLUDED.name, source_incident = EXCLUDED.source_incident,
      plan_date = EXCLUDED.plan_date, notes = EXCLUDED.notes, enabled = EXCLUDED.enabled;

UPDATE golden.fixtures SET scenario_sql = $scn$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- Belt and braces: clear any synthetic rows a previous run of this fixture left behind.
DELETE FROM public.scoreboard_daily_v3 WHERE metric_date = {{plan_date}};

DO $do$
DECLARE
  v_d          date := {{plan_date}};
  v_n1         int;  v_n2 int;  v_keys int; v_wmape int; v_nosrc int;
  v_before     int;  v_after int;
  v_ck_novalue text := 'accepted'; v_ck_novac text := 'accepted'; v_ck_ok text := 'refused';
  v_ck_tag1    text := 'accepted'; v_ck_tag2 text := 'accepted';
  v_m uuid; v_s uuid; v_b uuid;
BEGIN
  -- ---- run the writer twice: idempotency is part of the contract
  PERFORM public.compute_scoreboard_day_v3(v_d);
  SELECT count(*) INTO v_n1 FROM public.scoreboard_daily_v3 WHERE metric_date = v_d;
  PERFORM public.compute_scoreboard_day_v3(v_d);
  SELECT count(*) INTO v_n2 FROM public.scoreboard_daily_v3 WHERE metric_date = v_d;

  SELECT count(DISTINCT metric_key), count(*) FILTER (WHERE metric_key = 'wmape'),
         count(*) FILTER (WHERE source_object IS NULL OR btrim(source_object) = '')
    INTO v_keys, v_wmape, v_nosrc
  FROM public.scoreboard_daily_v3 WHERE metric_date = v_d;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'synth', jsonb_build_object(
    'n_run1', v_n1, 'n_run2', v_n2, 'n_keys', v_keys, 'n_wmape', v_wmape, 'n_no_source', v_nosrc));

  -- ---- CHECK ck_scoreboard_vacuity: it must refuse both silent shapes...
  BEGIN
    INSERT INTO public.scoreboard_daily_v3
      (metric_date, metric_key, metric_value, unit, is_vacuous, vacuous_reason, source_object)
    VALUES (v_d, 'osa_a_shelves', NULL, 'ratio', false, NULL, 'probe');
    EXCEPTION WHEN check_violation THEN v_ck_novalue := 'refused';
  END;
  BEGIN
    INSERT INTO public.scoreboard_daily_v3
      (metric_date, metric_key, metric_value, unit, is_vacuous, vacuous_reason, source_object)
    VALUES (v_d, 'waste_pct', 0.5, 'ratio', true, 'because', 'probe');
    EXCEPTION WHEN check_violation THEN v_ck_novac := 'refused';
  END;
  -- ...and it must ACCEPT a legitimate vacuous row, or the two above would pass
  -- for the trivial reason that the constraint refuses everything (S-173).
  BEGIN
    INSERT INTO public.scoreboard_daily_v3
      (metric_date, scope_ref, metric_key, metric_value, unit, is_vacuous, vacuous_reason, source_object)
    VALUES (v_d, 'PROBE', 'waste_pct', NULL, 'ratio', true, 'probe_reason', 'probe');
    v_ck_ok := 'accepted';
    EXCEPTION WHEN check_violation THEN v_ck_ok := 'refused';
  END;
  -- ---- CHECK ck_scoreboard_engine_tag, both directions
  BEGIN
    INSERT INTO public.scoreboard_daily_v3
      (metric_date, scope_ref, metric_key, engine_tag, metric_value, unit, source_object)
    VALUES (v_d, 'PROBE2', 'osa_a_shelves', 'v3', 0.5, 'ratio', 'probe');
    EXCEPTION WHEN check_violation THEN v_ck_tag1 := 'refused';
  END;
  BEGIN
    INSERT INTO public.scoreboard_daily_v3
      (metric_date, scope_ref, metric_key, engine_tag, metric_value, unit, source_object)
    VALUES (v_d, 'PROBE3', 'wmape', NULL, 0.5, 'ratio', 'probe');
    EXCEPTION WHEN check_violation THEN v_ck_tag2 := 'refused';
  END;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'checks', jsonb_build_object(
    'novalue', v_ck_novalue, 'novac', v_ck_novac, 'legit_vacuous', v_ck_ok,
    'tag_on_non_wmape', v_ck_tag1, 'wmape_without_tag', v_ck_tag2));

  -- ---- POSITIVE CONTROL for expired_sold_incidents.
  -- A count-of-a-bad-thing that reads 0 forever is indistinguishable from a broken
  -- detector. Seed one real incident, prove the metric moves 0 -> 1, then roll the
  -- seed back so inventory_events (owned by cron 44) is left untouched.
  SELECT machine_id, shelf_id, boonz_product_id INTO v_m, v_s, v_b
  FROM public.shelf_composition LIMIT 1;

  SELECT metric_value::int INTO v_before
  FROM public.scoreboard_daily_v3
  WHERE metric_date = v_d AND metric_key = 'expired_sold_incidents' AND scope_ref = 'ALL';

  BEGIN
    INSERT INTO public.inventory_events
      (ts, machine_id, shelf_id, boonz_product_id, qty_delta, kind, source_ref, note)
    VALUES (v_d::timestamptz + interval '9 hours', v_m, v_s, v_b, -1,
            'expired_sold_incident', 'golden-fixture-65', 'positive control, rolled back');
    PERFORM public.compute_scoreboard_day_v3(v_d);
    SELECT metric_value::int INTO v_after
    FROM public.scoreboard_daily_v3
    WHERE metric_date = v_d AND metric_key = 'expired_sold_incidents' AND scope_ref = 'ALL';
    RAISE EXCEPTION 'golden_fixture_65_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'golden_fixture_65_rollback' THEN RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'expired_control', jsonb_build_object(
    'before', COALESCE(v_before, -1), 'after', COALESCE(v_after, -1),
    'events_left_for_date', (SELECT count(*) FROM public.inventory_events
                             WHERE kind = 'expired_sold_incident' AND ts::date = v_d)));

  -- ---- grant + RLS surface, read back whole (S-140)
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'acl', jsonb_build_object(
    'fn_public',   (SELECT count(*) FROM pg_proc p, aclexplode(p.proacl) a
                    WHERE p.proname = 'compute_scoreboard_day_v3' AND a.grantee = 0),
    'fn_anon',     (SELECT has_function_privilege('anon', p.oid, 'EXECUTE')
                    FROM pg_proc p WHERE p.proname = 'compute_scoreboard_day_v3'),
    'tbl_public',  (SELECT count(*) FROM pg_class c, aclexplode(c.relacl) a
                    WHERE c.relname = 'scoreboard_daily_v3' AND a.grantee = 0),
    'tbl_anon',    has_table_privilege('anon', 'public.scoreboard_daily_v3', 'SELECT'),
    'view_anon',   has_table_privilege('anon', 'public.v_scoreboard_daily_v3', 'SELECT'),
    'tbl_acl',     (SELECT relacl::text FROM pg_class WHERE relname = 'scoreboard_daily_v3'),
    'auth_insert', has_table_privilege('authenticated', 'public.scoreboard_daily_v3', 'INSERT'),
    'rls',         (SELECT relrowsecurity FROM pg_class WHERE relname = 'scoreboard_daily_v3'),
    'n_policies',  (SELECT count(*) FROM pg_policies WHERE tablename = 'scoreboard_daily_v3')));

  -- ---- clean up every synthetic row this fixture created
  DELETE FROM public.scoreboard_daily_v3 WHERE metric_date = v_d;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'cleanup', jsonb_build_object(
    'rows_left', (SELECT count(*) FROM public.scoreboard_daily_v3 WHERE metric_date = v_d)));
END
$do$;
$scn$
WHERE fixture_id = 65;

DELETE FROM golden.assertions WHERE fixture_id = 65;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

(65, 1, 'NON-VACUITY: the writer produced all ten fleet rows (9 metrics, wmape twice). If this is 0 every grant/idempotency assertion below would pass over an empty set',
 $q$SELECT value->>'n_run1' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'synth'$q$, 'eq', '10', 'P0'),
(65, 2, 'All nine distinct metric_keys of BUILD SPEC line 105 are present',
 $q$SELECT value->>'n_keys' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'synth'$q$, 'eq', '9', 'P0'),
(65, 3, 'wmape is emitted once per engine (v3 and v19) so the shadow comparison has both sides',
 $q$SELECT value->>'n_wmape' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'synth'$q$, 'eq', '2', 'P0'),
(65, 4, 'IDEMPOTENT: a second run of the same date upserts in place and does not duplicate (STRESS S4 shape)',
 $q$SELECT value->>'n_run2' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'synth'$q$, 'eq', '10', 'P0'),
(65, 5, 'Article 16 traceability: every row records the canonical object it consumed',
 $q$SELECT value->>'n_no_source' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'synth'$q$, 'eq', '0', 'P0'),

(65, 6, 'ANTI-VACUITY CHECK refuses a metric that claims to be real but carries no value — the silent-zero shape that S-132 is about',
 $q$SELECT value->>'novalue' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'checks'$q$, 'eq', 'refused', 'P0'),
(65, 7, 'ANTI-VACUITY CHECK refuses a metric that claims to be vacuous while carrying a value',
 $q$SELECT value->>'novac' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'checks'$q$, 'eq', 'refused', 'P0'),
(65, 8, '⭐ POSITIVE CONTROL for seq 6/7 (S-173): the same constraint must ACCEPT a legitimate vacuous row. Without this, seq 6 and 7 would both pass if the constraint simply refused every insert',
 $q$SELECT value->>'legit_vacuous' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'checks'$q$, 'eq', 'accepted', 'P0'),
(65, 9, 'engine_tag is refused on a non-wmape metric (a stray tag would silently split the upsert key)',
 $q$SELECT value->>'tag_on_non_wmape' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'checks'$q$, 'eq', 'refused', 'P0'),
(65, 10, 'wmape is refused without an engine_tag (an untagged wmape row could not be attributed to v3 or v19)',
 $q$SELECT value->>'wmape_without_tag' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'checks'$q$, 'eq', 'refused', 'P0'),

(65, 11, 'expired_sold_incidents reads 0 before the control incident is seeded',
 $q$SELECT value->>'before' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'expired_control'$q$, 'eq', '0', 'P0'),
(65, 12, '⭐ POSITIVE CONTROL (S-173): seed ONE real expired_sold_incident event and the metric moves to 1. A count-of-a-bad-thing that sits at 0 forever is indistinguishable from a detector that cannot see anything — this proves it can',
 $q$SELECT value->>'after' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'expired_control'$q$, 'eq', '1', 'P0'),
(65, 13, 'The control was rolled back: inventory_events (cron 44 owns it) carries no fixture rows for the synthetic date',
 $q$SELECT value->>'events_left_for_date' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'expired_control'$q$, 'eq', '0', 'P0'),

(65, 14, 'No PUBLIC EXECUTE grant on the writer (D-42 shape; anon is a member of PUBLIC so revoking anon alone is not enough)',
 $q$SELECT value->>'fn_public' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', '0', 'P0'),
(65, 15, 'anon cannot EXECUTE the writer',
 $q$SELECT value->>'fn_anon' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', 'false', 'P0'),
(65, 16, 'No PUBLIC grant on the base table (Supabase ALTER DEFAULT PRIVILEGES grants new public tables at CREATE time)',
 $q$SELECT value->>'tbl_public' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', '0', 'P0'),
(65, 17, 'anon cannot SELECT the base table',
 $q$SELECT value->>'tbl_anon' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', 'false', 'P0'),
(65, 18, 'anon cannot SELECT the dashboard view',
 $q$SELECT value->>'view_anon' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', 'false', 'P0'),
(65, 19, 'authenticated cannot INSERT: the GRANT layer agrees with the RLS layer. The first apply left authenticated holding Supabase default arwdDxtm and only RLS stood in the way',
 $q$SELECT value->>'auth_insert' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', 'false', 'P0'),
(65, 20, 'S-140: the WHOLE relacl string, read back — authenticated holds exactly r, anon and PUBLIC hold nothing',
 $q$SELECT value->>'tbl_acl' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq',
 '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres,authenticated=r/postgres}', 'P0'),
(65, 21, 'RLS is enabled on the table (Article 2)',
 $q$SELECT value->>'rls' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', 'true', 'P0'),
(65, 22, 'Exactly one policy exists and it is the SELECT policy — no write policy has been added since',
 $q$SELECT value->>'n_policies' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'acl'$q$, 'eq', '1', 'P0'),

(65, 23, '⛔ REACHABILITY TRIPWIRE: at least one date must carry a NON-vacuous composition_confidence_avg. Shipped gated on "= today Dubai" while the only caller (cron 47) computes Dubai-YESTERDAY, so it could never be produced once. A metric that can never be reached is the same defect as a green that can never go red (S-173/S-174)',
 $q$SELECT count(*)::text FROM public.scoreboard_daily_v3
    WHERE metric_key = 'composition_confidence_avg' AND NOT is_vacuous$q$, 'gte', '1', 'P0'),
(65, 24, 'P4 GATE: the scoreboard is populated for at least 7 consecutive days',
 $q$SELECT days_in_latest_streak::text FROM public.v_scoreboard_health_v3$q$, 'gte', '7', 'P0'),
(65, 25, 'osa_a_shelves and stockout_rate are measured over DIFFERENT populations (slots vs machines), so the pair is not 1-x of itself. Their denominators must differ on a real date',
 $q$SELECT (o.denominator > s.denominator)::text
    FROM public.scoreboard_daily_v3 o JOIN public.scoreboard_daily_v3 s
      ON s.metric_date = o.metric_date AND s.metric_key = 'stockout_rate' AND s.scope_ref = 'ALL'
    WHERE o.metric_key = 'osa_a_shelves' AND o.scope_ref = 'ALL' AND NOT o.is_vacuous AND NOT s.is_vacuous
    ORDER BY o.metric_date DESC LIMIT 1$q$, 'eq', 'true', 'P0'),
(65, 26, 'The fixture cleaned up every synthetic 2030 row, so it cannot corrupt the health streak it asserts on in seq 24',
 $q$SELECT value->>'rows_left' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'cleanup'$q$, 'eq', '0', 'P0'),
(65, 27, 'Article 11: the nightly job exists, is active, and calls the RPC rather than inline SQL',
 $q$SELECT (active AND command LIKE '%compute_scoreboard_day_v3%')::text FROM cron.job
    WHERE jobname = 'prd110_p45_scoreboard_daily_0245_dubai'$q$, 'eq', 'true', 'P0'),
(65, 28, 'The nightly job computes the day that has CLOSED, not the day in progress — a half-finished day would report a false OSA and a false revenue',
 $q$SELECT (command LIKE '%- 1%')::text FROM cron.job
    WHERE jobname = 'prd110_p45_scoreboard_daily_0245_dubai'$q$, 'eq', 'true', 'P0');
