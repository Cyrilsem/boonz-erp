-- PRD-110 leg 22 · golden harness only (no protected entity, no DEFINER, no RLS).
--
-- WHY: fixture 19 computed 'events_in_txn' as an ABSOLUTE count of public.inventory_events.
-- That read 0 only because the table was globally empty while D-08 was parked. CS-approved
-- cron 44 fired its first live run 2026-07-30 18:40 UTC and legitimately wrote 31 rows, so
-- seq 10 ("fixture 19 writes no inventory events at all") went red on a TRUE statement about
-- the fixture and a FALSE statement about the table.
--
-- The description was always a DELTA claim. This makes the implementation match it, using the
-- house pattern fixture 21 already uses. expect stays 0 -- the assertion is strictly stronger,
-- because it now survives a busy ledger, which is the ledger's designed state from today on.
--
-- Cody: capture v_ev_before INSIDE the inner rollback-envelope BEGIN, not beside the
-- golden.scratch 'before' insert -- under READ COMMITTED a concurrent cron-44 commit between
-- those two points would reintroduce the flake in a rarer, harder-to-bisect form.

DO $mig$
DECLARE
  v_old text;
  v_new text;
  v_decl_old  text := 'DECLARE v_m uuid; v_fm uuid; v_pod uuid; v_venue uuid; v_wh uuid; v_payload jsonb; v_guard text;';
  v_decl_new  text := 'DECLARE v_m uuid; v_fm uuid; v_pod uuid; v_venue uuid; v_wh uuid; v_payload jsonb; v_guard text; v_ev_before bigint;';
  v_cap_old   text := E'  BEGIN\n    v_payload := jsonb_build_object(\n      ''model_live_null'',';
  v_cap_new   text := E'  BEGIN\n    -- delta baseline, captured before the first write in this envelope (leg 22)\n    v_ev_before := (SELECT count(*) FROM public.inventory_events);\n    v_payload := jsonb_build_object(\n      ''model_live_null'',';
  v_calc_old  text := '''events_in_txn'', (SELECT count(*) FROM public.inventory_events)::text);';
  v_calc_new  text := '''events_in_txn'', ((SELECT count(*) FROM public.inventory_events) - v_ev_before)::text);';
BEGIN
  SELECT scenario_sql INTO v_old FROM golden.fixtures WHERE fixture_id = 19;
  IF v_old IS NULL THEN RAISE EXCEPTION 'fixture 19 not found'; END IF;

  -- Guard each replace: a silent no-op would leave the fixture looking fixed and still broken.
  IF position(v_decl_old in v_old) = 0 THEN RAISE EXCEPTION 'GUARD 1 no-op: DECLARE line not found verbatim'; END IF;
  IF position(v_cap_old  in v_old) = 0 THEN RAISE EXCEPTION 'GUARD 2 no-op: inner BEGIN anchor not found verbatim'; END IF;
  IF position(v_calc_old in v_old) = 0 THEN RAISE EXCEPTION 'GUARD 3 no-op: events_in_txn absolute count not found verbatim'; END IF;

  v_new := replace(replace(replace(v_old, v_decl_old, v_decl_new), v_cap_old, v_cap_new), v_calc_old, v_calc_new);

  IF v_new = v_old THEN RAISE EXCEPTION 'GUARD 4: text unchanged after all three replaces'; END IF;
  IF position(v_calc_old in v_new) > 0 THEN RAISE EXCEPTION 'GUARD 5: absolute count still present after replace'; END IF;
  IF position('v_ev_before bigint' in v_new) = 0 THEN RAISE EXCEPTION 'GUARD 6: declaration missing'; END IF;
  IF position('v_ev_before := (SELECT count(*) FROM public.inventory_events);' in v_new) = 0 THEN RAISE EXCEPTION 'GUARD 7: capture missing'; END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 19;
END
$mig$;

UPDATE golden.assertions
   SET description = 'fixture 19 writes no inventory events (IN-TXN DELTA vs a baseline captured inside the envelope, never an absolute table count)'
 WHERE fixture_id = 19 AND seq = 10;
