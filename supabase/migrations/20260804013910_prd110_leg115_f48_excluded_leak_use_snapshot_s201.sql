-- PRD-110 leg 115 - S-201: fixture 48 times out (57014) and therefore READS AS GREEN while its
-- 49 assertions never evaluate. `fixtures_evaluated = fixtures_enabled` is a precondition of any
-- full-green claim AND of S7.
--
-- ROOT CAUSE, MEASURED NOT GUESSED. public.v_facing_performance_v3 takes 23.6 s to return 525
-- rows. Fixture 48's step (2) already snapshots it ONCE into TEMP TABLE f48_perf, with the
-- comment "THE REPORT, READ EXACTLY ONCE. ~25 s; everything below reads this snapshot" - and
-- 15 later references honour that. But the step-(6) `excluded_leak` block BYPASSES the snapshot
-- and joins the LIVE view twice more.
--
-- NOTE (leg 115): S-201 named excluded_leak as THE culprit. It is A culprit, worth 48.7 s
-- measured (119.8 s -> 71.1 s), but NOT the whole one: propose_facing_changes_v3 itself does
-- CREATE TEMP TABLE _fac_perf AS SELECT * FROM v_facing_performance_v3 on EVERY call, and the
-- fixture calls it twice (the second for the idempotency re-run). See S-209.
--
-- THE FIX IS THE FIXTURE'S OWN STATED DESIGN, APPLIED WHERE IT WAS MISSED: point those two
-- joins at f48_perf. This is NOT a loosening - the temp table is `SELECT * FROM` the very same
-- view, materialised inside the same transaction, so the counts are computed over identical
-- rows. It changes no assertion, no threshold, no engine.
--
-- Verified live before writing: 'JOIN public.v_facing_performance_v3 v' occurs EXACTLY 2x; the
-- snapshot line 'SELECT * FROM public.v_facing_performance_v3;' occurs EXACTLY 1x and must
-- survive; f48_perf is already referenced 15x so it is in scope at step (6); and all four
-- columns the joins need (machine_id, pod_product_id, in_refill_universe, operating_model)
-- exist on the view and therefore on the SELECT * snapshot.
--
-- golden.* only. No protected entity, no DEFINER, no RLS, no engine body, no flag, no cron.

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
         'JOIN public.v_facing_performance_v3 v',
         'JOIN f48_perf v   -- leg 115 / S-201: the step-(2) snapshot, not a 4th live 23.6 s read')
 WHERE fixture_id = 48;

-- Fail-loud guard: replace() is SILENT on a missed needle (leg 112/113 tool lesson), and a
-- no-op UPDATE is silent the same way (leg 113). Assert the shape we intended, or roll back.
DO $g48$
DECLARE
  v_s      text;
  v_live   int;
  v_snap   int;
  v_joins  int;
BEGIN
  SELECT scenario_sql INTO v_s FROM golden.fixtures WHERE fixture_id = 48;

  v_live  := (length(v_s) - length(replace(v_s, 'v_facing_performance_v3', '')))
             / length('v_facing_performance_v3');
  v_snap  := (length(v_s) - length(replace(v_s, 'SELECT * FROM public.v_facing_performance_v3;', '')))
             / length('SELECT * FROM public.v_facing_performance_v3;');
  v_joins := (length(v_s) - length(replace(v_s, 'JOIN f48_perf v', '')))
             / length('JOIN f48_perf v');

  -- exactly ONE mention of the live view may remain, and it must be the step-(2) snapshot
  IF v_live <> 1 THEN
    RAISE EXCEPTION 'leg115/S-201: expected exactly 1 remaining v_facing_performance_v3 mention, found %', v_live;
  END IF;
  IF v_snap <> 1 THEN
    RAISE EXCEPTION 'leg115/S-201: the step-(2) snapshot line was damaged (found % copies)', v_snap;
  END IF;
  IF v_joins <> 2 THEN
    RAISE EXCEPTION 'leg115/S-201: expected 2 rewritten joins onto f48_perf, found %', v_joins;
  END IF;
  -- and the snapshot must still be created BEFORE the rewritten joins read it
  IF NOT (position('CREATE TEMP TABLE f48_perf' in v_s) < position('JOIN f48_perf v' in v_s)) THEN
    RAISE EXCEPTION 'leg115/S-201: f48_perf is read before it is created';
  END IF;
END
$g48$;
