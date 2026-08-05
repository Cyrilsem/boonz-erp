-- PRD-110 · S-47 step 2 (+ S-48) · fixture 14 LAW-12 tripwires re-expressed on TRANSACTION attribution.
-- S-47: seq 92 was a GLOBAL count delta on a table live actors write; it lost the race at 03:53:50Z.
-- S-48: `created_at >= t0` cannot work - created_at DEFAULTs to now() (transaction start) while t0 is
--   a clock_timestamp() taken inside the transaction, so a fixture's own writes always have
--   created_at < t0. Proven live: fixture 14 t0 = 03:53:38.885165Z vs own writes 03:52:59.546876Z.
--   seq 93 has therefore been STRUCTURALLY VACUOUS for many legs.
-- FIX: a row VISIBLE to our snapshot whose xmin is still 'in progress' can only have been written by
--   our own transaction tree. Subtransaction-safe (xmin = pg_current_xact_id()::xid matched 1 of 2;
--   pg_xact_status matched 2 of 2 - golden.run_fixture runs scenario_sql inside BEGIN..EXCEPTION).
-- golden.run_all runs EVERY fixture in ONE transaction, so the tripwires are stated at the honest
--   grain: the SUITE may write ONLY on registered synthetic (>=2030) fixture plan_dates.
-- Harness only; no engine, no protected entity, no live plan table written.

CREATE OR REPLACE FUNCTION golden.written_by_this_txn(p_xmin xid)
RETURNS boolean
LANGUAGE sql
VOLATILE
AS $fn$
  SELECT pg_xact_status(p_xmin::text::xid8) = 'in progress'
$fn$;

COMMENT ON FUNCTION golden.written_by_this_txn(xid) IS
  'PRD-110 S-48: true when the row was written by the CURRENT transaction tree, subtransactions included. '
  'Replaces the created_at >= t0 idiom, which is structurally blind because created_at defaults to now() '
  '(transaction start) while t0 is a clock_timestamp() taken inside the transaction. VOLATILE to match '
  'pg_xact_status (provolatile=v); SECURITY INVOKER is safe because pg_xact_status has proacl = NULL.';

DO $s47_f14$
DECLARE
  v_exempt CONSTANT text :=
    $q$ AND NOT (x.plan_date >= DATE '2030-01-01'
               AND x.plan_date IN (SELECT f.plan_date FROM golden.fixtures f WHERE f.plan_date IS NOT NULL))$q$;
  v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 14 AND seq IN (91, 92, 93) AND enabled;
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'S-47 pre-guard: expected 3 enabled tripwires on fixture 14 (seq 91,92,93), found %', v_n;
  END IF;

  IF EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id = 14 AND seq = 100) THEN
    RAISE EXCEPTION 'S-47 pre-guard: fixture 14 seq 100 must be free';
  END IF;

  SELECT count(*) INTO v_n FROM golden.fixtures
   WHERE plan_date IS NOT NULL AND plan_date < DATE '2030-01-01';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'S-47 pre-guard: % fixture(s) carry a NON-synthetic plan_date; LAW 12 exemption unsafe', v_n;
  END IF;

  UPDATE golden.assertions
     SET check_sql = $chk$SELECT count(*)::text FROM public.pod_refill_plan x
 WHERE golden.written_by_this_txn(x.xmin)$chk$,
         description = 'ADR 8.3 tripwire (S-47/S-48 re-expressed): this run''s own transaction wrote ZERO rows to pod_refill_plan. Attributed by transaction, not by a global count delta, so a concurrent live writer can neither cause a false red nor mask a real write.'
   WHERE fixture_id = 14 AND seq = 91;

  UPDATE golden.assertions
     SET check_sql = $chk$SELECT count(*)::text FROM public.refill_plan_output x
 WHERE golden.written_by_this_txn(x.xmin)$chk$ || v_exempt,
         description = 'LAW 12 tripwire (S-47 fix): this run''s own transaction wrote NO refill_plan_output row on any date other than a registered synthetic (>=2030) fixture plan_date. The old form was a GLOBAL count delta and lost a race with live writers at 03:53:50Z on 2026-07-31.'
   WHERE fixture_id = 14 AND seq = 92;

  UPDATE golden.assertions
     SET check_sql = $chk$SELECT count(*)::text FROM public.pod_refills x
 WHERE golden.written_by_this_txn(x.xmin)$chk$ || v_exempt,
         description = 'LAW 12 tripwire (S-48 fix): this run''s own transaction wrote NO pod_refills row on any date other than a registered synthetic (>=2030) fixture plan_date. The previous created_at >= t0 form was STRUCTURALLY VACUOUS - created_at defaults to now() (transaction start), always earlier than the t0 clock_timestamp() taken inside the transaction.'
   WHERE fixture_id = 14 AND seq = 93;

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
  VALUES (14, 100,
    'S-48 ANTI-VACUITY SELF-TEST for seq 91/92/93: golden.written_by_this_txn must detect this run''s OWN pod_refills writes on its own synthetic plan_date. If this goes red, the three LAW-12 tripwires are BLIND, not clean - do not read their green as evidence.',
    $chk$SELECT count(*)::text FROM public.pod_refills x
 WHERE golden.written_by_this_txn(x.xmin) AND x.plan_date = {{plan_date}}$chk$,
    'gt', '0', true, 'P1', NULL);

  SELECT count(*) INTO v_n FROM golden.assertions
   WHERE fixture_id = 14 AND seq IN (91, 92, 93) AND check_sql LIKE '%written_by_this_txn%';
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'S-47 post-guard: expected 3 re-expressed tripwires, found %', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 14;
  IF v_n <> 41 THEN
    RAISE EXCEPTION 'S-47 post-guard: fixture 14 must hold 41 assertions (40 + 1), found %', v_n;
  END IF;
END $s47_f14$;
