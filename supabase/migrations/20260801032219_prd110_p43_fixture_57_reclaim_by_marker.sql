SET LOCAL statement_timeout = '120s';

-- PRD-110 fixture 57 reclaim hardening.
--
-- ⛔ THE INCIDENT (leg 85): fixture 57's reclaim was scoped by MACHINE
--    (`DELETE ... WHERE machine_id = mA`). Its anchor machine collided with the
--    one fixtures 55/56 anchor on, so its first committed run deleted THEIR
--    ledger rows, proposals and all 7 pins - the counters the pointer flags as
--    "UNMOVED and they MUST stay so". Re-running 55 and 56 restored everything
--    (both are reclaim-and-recreate by marker, so they are self-healing), but
--    the fixture must never be able to do that again.
--
-- ⭐ THE RULE: a fixture reclaims by ITS OWN MARKER, never by a shared anchor.
--    A machine is shared state; a marker is not. Both scopes are now ANDed, and
--    the anchor selection additionally refuses any machine already carrying
--    non-miner feedback or any pin at all - so a future fixture that takes this
--    machine makes fixture 57 RAISE at setup instead of eating its rows.
DO $fix$
DECLARE
  v_sql text;
  v_old_reclaim text;
  v_new_reclaim text;
  v_old_anchor  text;
  v_new_anchor  text;
  v_n int;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 57;
  IF v_sql IS NULL THEN RAISE EXCEPTION 'fixture 57 has no scenario to amend'; END IF;

  v_old_reclaim :=
    '  DELETE FROM public.planning_pins_v3      WHERE machine_id = mA;' || E'\n' ||
    '  DELETE FROM public.feedback_proposals_v3 WHERE machine_id = mA;' || E'\n' ||
    '  DELETE FROM public.feedback_ledger_v3    WHERE machine_id = mA;';

  v_new_reclaim :=
    '  -- ⛔ BY MARKER *AND* MACHINE. Machine alone once ate fixtures 55/56 rows.' || E'\n' ||
    '  DELETE FROM public.planning_pins_v3 p' || E'\n' ||
    '   WHERE p.machine_id = mA' || E'\n' ||
    '     AND p.proposal_id IN (SELECT proposal_id FROM public.feedback_proposals_v3' || E'\n' ||
    '                            WHERE trigger_reason LIKE ''WS-H2 recurring%'');' || E'\n' ||
    '  DELETE FROM public.feedback_proposals_v3' || E'\n' ||
    '   WHERE machine_id = mA AND trigger_reason LIKE ''WS-H2 recurring%'';' || E'\n' ||
    '  DELETE FROM public.feedback_ledger_v3' || E'\n' ||
    '   WHERE machine_id = mA AND channel = ''miner'';';

  v_n := (length(v_sql) - length(replace(v_sql, v_old_reclaim, ''))) / length(v_old_reclaim);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'reclaim anchor matched % times, expected exactly 1 - refusing to substitute blind', v_n;
  END IF;
  v_sql := replace(v_sql, v_old_reclaim, v_new_reclaim);

  v_old_anchor :=
    '   GROUP BY sc.machine_id HAVING count(*) >= 4' || E'\n' ||
    '   ORDER BY sc.machine_id LIMIT 1;';

  v_new_anchor :=
    '     AND NOT EXISTS (SELECT 1 FROM public.feedback_ledger_v3 f' || E'\n' ||
    '                      WHERE f.machine_id = sc.machine_id AND f.channel <> ''miner'')' || E'\n' ||
    '     AND NOT EXISTS (SELECT 1 FROM public.planning_pins_v3 pp' || E'\n' ||
    '                      WHERE pp.machine_id = sc.machine_id)' || E'\n' ||
    '   GROUP BY sc.machine_id HAVING count(*) >= 4' || E'\n' ||
    '   ORDER BY sc.machine_id LIMIT 1;';

  v_n := (length(v_sql) - length(replace(v_sql, v_old_anchor, ''))) / length(v_old_anchor);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'anchor-selection anchor matched % times, expected exactly 1', v_n;
  END IF;
  v_sql := replace(v_sql, v_old_anchor, v_new_anchor);

  IF v_sql LIKE '%DELETE FROM public.feedback_ledger_v3    WHERE machine_id = mA;%' THEN
    RAISE EXCEPTION 'substitution left the unscoped reclaim behind';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_sql WHERE fixture_id = 57;
END $fix$;
