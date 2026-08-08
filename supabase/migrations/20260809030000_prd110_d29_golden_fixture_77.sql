-- PRD-110 leg 163 · D-29 · GOLDEN FIXTURE 77 (LAW 1: the fixture lands RED, before the engine)
--
-- CS RULING (verbatim, parking lot line 7276):
--   "D-29 -> YES AT CUTOVER. Nightly runner promotes stitch blocked demand for
--    v3-authoritative clusters; engine_add rows suppressed there. No double counting."
--
-- The whole rule is ONE predicate, read at the three sites in record_blocked_demand_v3 that
-- call _blocked_demand_gaps_for_source_v3:
--     public.is_cluster_authoritative_v3(g.machine_id) = (p_source = 'stitch')
-- It reads the machine-grain canonical sibling rather than restating the authority rule, so
-- Article 16 holds.
--
-- ⛔ THE DELETE IS WHERE THE DESIGN DECISION LIVES. Scoping it means a flip DELETES a flipped
--    cluster's open engine_add rows from a LIVE PROCUREMENT WORKLIST. That is the dedup CS asked
--    for and it must not be silent, so this fixture pins a SPLIT counter:
--      rows_closed_stale      - the gap genuinely went away
--      rows_closed_by_cutover - the gap is still there; the other engine now owns it
--    and a suppression witness on the read side, gaps_suppressed_by_cutover, so that a receipt
--    reading gaps_found = 0 can never be confused with "there were no gaps" (LAW 5's silent-qty-0
--    class, at receipt grain).
--
-- SCOPE SPLIT WITH FIXTURE 47: this fixture drives the ENGINE_ADD arm (the arm cron 43 runs
-- nightly in production) plus the counters and the reversibility. Fixture 47, re-baselined in
-- 20260809031000, drives the STITCH arm end-to-end through a real stitch_v3 run.
--
-- FLAG-OFF: with 0 of 10 clusters authoritative the engine_add arm is byte-identical to today
-- (keep = (false = false) = true for every machine) and gaps_suppressed_by_cutover reads 0.
-- Assertions 30/31 are that proof, driven rather than argued.
--
-- ⛔ S-317: the scenario date is ALLOCATED from the fixture id (2030-01-01 + 77 = 2030-03-19).
--    {{plan_date}} everywhere; the plan_date COLUMN is never read by the harness.
-- ⛔ S-318: the red-first baseline_status is spelled 'failing_expected'.

BEGIN;

DELETE FROM golden.assertions WHERE fixture_id = 77;
DELETE FROM golden.fixtures   WHERE fixture_id = 77;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes,
   scenario_sql)
VALUES (
  77,
  'D-29: at cutover the blocked-demand ledger has ONE owner per cluster. record_blocked_demand_v3 '
  'reads the machine-grain authority sibling at all three gap sites, so a v3-authoritative cluster''s '
  'engine_add rows are suppressed on the read AND closed on the write, while every cluster still on '
  'v19 is byte-untouched. The close is never silent: rows_closed_stale and rows_closed_by_cutover are '
  'separate counters and gaps_suppressed_by_cutover names what the read dropped. Ships FLAG-OFF - at '
  '0 authoritative clusters the engine_add arm cron 43 runs nightly is identical to today.',
  'PRD-110 D-29 (CS: "YES AT CUTOVER ... engine_add rows suppressed there. No double counting.")',
  'P4',
  DATE '2030-03-19',
  'failing_expected',
  true,
  'Engine_add arm + counters + reversibility. The stitch arm is fixture 47. Copies fixture 75''s '
  'flip device verbatim: plant settled v3 evidence so the gate says ready, flip, drive, revert - '
  'all inside a subtransaction discarded by a RAISE, so the fixture leaves NO authority residue '
  'even if it fails halfway.',
$FX77$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ── STATIC HALF: the shape of the change ────────────────────────────────────────
-- ⭐ Presence of each DISTINCT expression, never a total occurrence count (S-298: a guard that
--    refuses a correct migration is also a failure).
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'static', jsonb_build_object(
  -- Article 1: cron 43 calls this with ONE argument. The signature may not move.
  'n_sigs',        (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'),
  'nargdefaults',  (SELECT pronargdefaults FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'),
  'secdef',        (SELECT prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'),
  'searchpath',    (SELECT array_to_string(proconfig,',') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'),

  -- ⭐⭐ THE PREDICATE, at the read sites and at the DELETE classifier.
  'keep_pred',     (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                       AND p.prosrc LIKE '%is_cluster_authoritative_v3(g.machine_id) = (p_source%'),
  'del_classifier',(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                       AND p.prosrc LIKE '%is_cluster_authoritative_v3(bd.machine_id)%'),
  -- ⛔ It must read the canonical sibling, never restate the authority rule inline (Article 16).
  'no_inline_rule',(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                       AND p.prosrc LIKE '%engine_cutover_authority_v3%'),

  -- the receipt keys the split counter needs
  'k_closed_stale',  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                       WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                         AND p.prosrc LIKE '%rows_closed_stale%'),
  'k_closed_cutover',(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                       WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                         AND p.prosrc LIKE '%rows_closed_by_cutover%'),
  'k_suppressed',    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                       WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                         AND p.prosrc LIKE '%gaps_suppressed_by_cutover%'),

  -- guards that must SURVIVE the edit
  'role_gate',     (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                       AND p.prosrc LIKE '%user_profiles%' AND p.prosrc LIKE '%operator_admin%'),
  'pack_refuses',  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                       AND p.prosrc LIKE '%not implemented%'),
  'via_rpc',       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='record_blocked_demand_v3'
                       AND p.prosrc LIKE '%app.via_rpc%' AND p.prosrc LIKE '%app.rpc_name%'),
  'anon_exec',     has_function_privilege('anon','public.record_blocked_demand_v3(date,text)','EXECUTE'),

  -- ⛔ the gap sources stay read-only helpers, untouched by this unit
  'gapsrc_invoker',(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname IN
                           ('_blocked_demand_gaps_v3','_blocked_demand_gaps_stitch_v3',
                            '_blocked_demand_gaps_for_source_v3')
                       AND p.prosecdef),
  'dispatcher_md5',(SELECT md5(p.prosrc) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                     WHERE n.nspname='public' AND p.proname='_blocked_demand_gaps_for_source_v3'),

  -- FLAG-OFF, as shipped
  'clusters_on_v3',(SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3')
);

-- ── EXECUTED HALF: the suppression, actually driven ─────────────────────────────
DO $fx77$
DECLARE
  v_payload jsonb;
  v_novo    uuid := '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04';  -- the single Active NOVO machine
  v_ctl     uuid := '822d386f-e0db-4a51-b201-0731df90f393';  -- OHMYDESK control, never flipped
  v_novo_sh uuid := 'bb99e47a-0954-4ca4-9239-51ca7d2c1e8e';
  v_ctl_sh  uuid := '761f9c42-c9c6-4750-b8af-7f3564ac7496';
  v_pod     uuid;
  v_d       date := {{plan_date}};
  v_base    jsonb := '{"na":true}'::jsonb;
  v_flip    jsonb := '{"na":true}'::jsonb;
  v_after   jsonb := '{"na":true}'::jsonb;
  v_back    jsonb := '{"na":true}'::jsonb;
  v_open_novo_before int := -1;
  v_open_novo_after  int := -1;
  v_open_ctl_after   int := -1;
  v_ctl_qty_before   int := -1;
  v_ctl_qty_after    int := -1;
  v_open_novo_back   int := -1;
BEGIN
  SELECT pod_product_id INTO v_pod FROM public.engine_forecast_error_v3 LIMIT 1;
  IF v_pod IS NULL THEN
    RAISE EXCEPTION 'fixture 77 setup: engine_forecast_error_v3 is empty; the planted flip below would be vacuous';
  END IF;

  BEGIN
    -- ⛔ EVERYTHING BELOW IS DISCARDED by the RAISE at the end. Only v_payload escapes, so this
    --    fixture can never leave a cluster flipped, not even if it dies halfway.

    -- (1) Two engine_add gaps on one synthetic date: one on NOVO, one on the control.
    --     A gap is simply need_raw > qty (see _blocked_demand_gaps_v3), so this plants the
    --     shortfall directly rather than running an engine to manufacture one.
    INSERT INTO public.pod_refills
      (plan_date, machine_id, shelf_id, pod_product_id, qty, current_stock, max_stock,
       clamp_reason, reasoning)
    VALUES (v_d, v_novo, v_novo_sh, v_pod, 2, 0, 10, 'partial_wh_limited',
            jsonb_build_object('need_raw', 10, 'tagged_by','fixture77')),
           (v_d, v_ctl,  v_ctl_sh,  v_pod, 3, 0, 10, 'partial_wh_limited',
            jsonb_build_object('need_raw', 11, 'tagged_by','fixture77'));

    -- (2) FLAG-OFF FIRST. This is the state D-29 ships in and the state cron 43 runs in.
    v_base := public.record_blocked_demand_v3(v_d, 'engine_add');
    v_open_novo_before := (SELECT count(*) FROM public.blocked_demand
                            WHERE plan_date=v_d AND machine_id=v_novo AND source='engine_add'
                              AND resolved_at IS NULL);
    v_ctl_qty_before   := (SELECT qty_blocked FROM public.blocked_demand
                            WHERE plan_date=v_d AND machine_id=v_ctl AND source='engine_add'
                              AND resolved_at IS NULL);

    -- (3) Plant the settled v3 evidence for NOVO (fixture 74/75's recipe) so the gate says ready.
    --     abs_error / signed_error are GENERATED ALWAYS - the miss is engineered through the
    --     forecast: v3 off by 10 on 100 (wmape 0.10), v19 off by 40 (0.40).
    INSERT INTO public.engine_forecast_error_v3
      (plan_date, engine_tag, machine_id, pod_product_id, horizon_days, horizon_end, n_shelves,
       dc_variants, forecast_units, actual_units, actuals_settled, velocity_basis, measured_at)
    VALUES
      (DATE '2026-07-02','v3',  v_novo, v_pod, 7, DATE '2026-07-09', 1, 1, 110, 100, true, 'velocity_instock', now()),
      (DATE '2026-07-02','v19', v_novo, v_pod, 7, DATE '2026-07-09', 1, 1, 140, 100, true, 'velocity_instock', now());

    v_flip := public.flip_cluster_to_v3_v3('NOVO', 'fixture 77 drives the D-29 suppression');

    -- (4) ⭐⭐ THE SAME CALL, ONE FLIP LATER. NOVO's gap is no longer engine_add's to own.
    v_after := public.record_blocked_demand_v3(v_d, 'engine_add');
    v_open_novo_after := (SELECT count(*) FROM public.blocked_demand
                           WHERE plan_date=v_d AND machine_id=v_novo AND source='engine_add'
                             AND resolved_at IS NULL);
    v_open_ctl_after  := (SELECT count(*) FROM public.blocked_demand
                           WHERE plan_date=v_d AND machine_id=v_ctl AND source='engine_add'
                             AND resolved_at IS NULL);
    v_ctl_qty_after   := (SELECT qty_blocked FROM public.blocked_demand
                           WHERE plan_date=v_d AND machine_id=v_ctl AND source='engine_add'
                             AND resolved_at IS NULL);

    -- (5) ⭐ REVERSIBLE. revert_cluster_to_v19_v3 is never evidence-gated, and the ledger row
    --     comes straight back - a flip must not strand demand permanently.
    PERFORM public.revert_cluster_to_v19_v3('NOVO', 'fixture 77 restores the registry');
    v_back := public.record_blocked_demand_v3(v_d, 'engine_add');
    v_open_novo_back := (SELECT count(*) FROM public.blocked_demand
                          WHERE plan_date=v_d AND machine_id=v_novo AND source='engine_add'
                            AND resolved_at IS NULL);

    v_payload := jsonb_build_object(
      'base_gaps',        (v_base->>'gaps_found'),
      'base_suppressed',  (v_base->>'gaps_suppressed_by_cutover'),
      'base_ins',         (v_base->>'rows_inserted'),
      'base_clusters',    (v_base->>'clusters_on_v3'),
      'novo_before',      v_open_novo_before,
      'ctl_qty_before',   v_ctl_qty_before,
      'flip_outcome',     v_flip->>'outcome',
      'after_gaps',       (v_after->>'gaps_found'),
      'after_suppressed', (v_after->>'gaps_suppressed_by_cutover'),
      'after_closed_cut', (v_after->>'rows_closed_by_cutover'),
      'after_closed_stale',(v_after->>'rows_closed_stale'),
      'after_clusters',   (v_after->>'clusters_on_v3'),
      'novo_after',       v_open_novo_after,
      'ctl_after',        v_open_ctl_after,
      'ctl_qty_after',    v_ctl_qty_after,
      'back_gaps',        (v_back->>'gaps_found'),
      'back_suppressed',  (v_back->>'gaps_suppressed_by_cutover'),
      'back_ins',         (v_back->>'rows_inserted'),
      'back_clusters',    (v_back->>'clusters_on_v3'),
      'novo_back',        v_open_novo_back);
    RAISE EXCEPTION 'GP77:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP77:%' THEN v_payload := substring(SQLERRM from 'GP77:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx77$;

-- ── RESIDUE: the probe must have left nothing behind ────────────────────────────
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'all_v19_after',  (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine<>'v19'),
  'pr_gone',        (SELECT count(*) FROM public.pod_refills    WHERE plan_date = {{plan_date}}),
  'bd_gone',        (SELECT count(*) FROM public.blocked_demand WHERE plan_date = {{plan_date}}),
  'planted_gone',   (SELECT count(*) FROM public.engine_forecast_error_v3 WHERE plan_date = DATE '2026-07-02'),
  'audit_gone',     (SELECT count(*) FROM public.engine_cutover_audit_v3)
);
$FX77$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

-- ── the signature cron 43 depends on ────────────────────────────────────────────
(77, 1, '⛔ Article 1: record_blocked_demand_v3 keeps ONE signature, so cron 43''s by-name call cannot become ambiguous',
 $q$SELECT (value->>'n_sigs') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77, 2, '⛔ Article 1: it keeps its 1 default, so cron 43''s SINGLE-ARGUMENT call still resolves',
 $q$SELECT (value->>'nargdefaults') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77, 3, 'Still SECURITY DEFINER',
 $q$SELECT (value->>'secdef') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', 'true', 'P4'),
(77, 4, 'Still search_path-pinned',
 $q$SELECT (value->>'searchpath') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', 'search_path=public', 'P4'),

-- ── the predicate itself ────────────────────────────────────────────────────────
(77,10, '⭐⭐ THE D-29 PREDICATE is present on the READ side, keyed on the source: is_cluster_authoritative_v3(g.machine_id) = (p_source = ''stitch'')',
 $q$SELECT (value->>'keep_pred') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77,11, '⭐ The DELETE classifies its own closes by reading the authority of the row it is deleting',
 $q$SELECT (value->>'del_classifier') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77,12, '⛔ Article 16: it READS the machine-grain canonical sibling and never restates the authority rule against engine_cutover_authority_v3 inline',
 $q$SELECT (value->>'no_inline_rule') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '0', 'P4'),
(77,13, 'The receipt still carries rows_closed_stale',
 $q$SELECT (value->>'k_closed_stale') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77,14, '⭐ The receipt carries rows_closed_by_cutover, so a flip''s effect on a live procurement worklist is auditable rather than folded into "stale"',
 $q$SELECT (value->>'k_closed_cutover') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77,15, '⭐ The receipt carries gaps_suppressed_by_cutover, so gaps_found = 0 can never be mistaken for "there were no gaps" (LAW 5, at receipt grain)',
 $q$SELECT (value->>'k_suppressed') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),

-- ── guards that had to survive ──────────────────────────────────────────────────
(77,20, 'The operator_admin role gate survived the edit',
 $q$SELECT (value->>'role_gate') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77,21, '⛔ ''pack'' still REFUSES: a source with no gap source must raise, never record nothing quietly',
 $q$SELECT (value->>'pack_refuses') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77,22, 'The provenance GUCs survived the edit',
 $q$SELECT (value->>'via_rpc') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '1', 'P4'),
(77,23, '⛔ S-88 stays fixed: anon cannot EXECUTE the writer',
 $q$SELECT (value->>'anon_exec') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', 'false', 'P4'),
(77,24, 'The three gap sources stay read-only helpers: SECURITY INVOKER, never DEFINER',
 $q$SELECT (value->>'gapsrc_invoker') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '0', 'P4'),
(77,25, '⛔ The dispatcher is byte-untouched by D-29 - the predicate belongs to the writer, not to the gap source',
 $q$SELECT (value->>'dispatcher_md5') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '2b3ab311e394b9d5c794e598feb8bd5b', 'P4'),

-- ── LAW 4: it ships flag-off ────────────────────────────────────────────────────
(77,30, '⛔ LAW 4: 0 of 10 clusters are authoritative for v3 at rest',
 $q$SELECT (value->>'clusters_on_v3') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='static'$q$, 'eq', '0', 'P4'),
(77,31, '⭐⭐ FLAG-OFF IS INERT, DRIVEN NOT ARGUED: at 0 authoritative clusters the engine_add arm cron 43 runs suppresses NOTHING',
 $q$SELECT (value->>'base_suppressed') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', 'P4'),
(77,32, '...and records BOTH machines, exactly as it does today',
 $q$SELECT (value->>'base_gaps') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '2', 'P4'),
(77,33, 'Both gaps landed as ledger rows',
 $q$SELECT (value->>'base_ins') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '2', 'P4'),
(77,34, 'PREMISE: NOVO carried an open engine_add row BEFORE the flip, so the suppression below is a real removal and not an empty set',
 $q$SELECT (value->>'novo_before') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),
(77,35, 'The receipt witnesses the flag state it ran under',
 $q$SELECT (value->>'base_clusters') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', 'P4'),

-- ── the flip, and what it does ──────────────────────────────────────────────────
(77,40, 'PREMISE: the flip was accepted, so everything after it is measured on a genuinely authoritative cluster',
 $q$SELECT (value->>'flip_outcome') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', 'applied', 'P4'),
(77,41, '⭐⭐ THE SUPPRESSION: one flip later the SAME call sees ONE gap, not two - engine_add no longer owns NOVO''s demand',
 $q$SELECT (value->>'after_gaps') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),
(77,42, '⭐⭐ AND IT SAYS SO: the dropped gap is counted on the receipt, so the smaller number is explained rather than silent',
 $q$SELECT (value->>'after_suppressed') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),
(77,43, '⭐⭐ THE SPLIT COUNTER: the close is attributed to the CUTOVER, not to a gap that went away',
 $q$SELECT (value->>'after_closed_cut') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),
(77,44, '...and rows_closed_stale stays 0, so the two reasons never blur into one number',
 $q$SELECT (value->>'after_closed_stale') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', 'P4'),
(77,45, '⛔ NO DOUBLE COUNTING: NOVO''s open engine_add row is GONE from the ledger',
 $q$SELECT (value->>'novo_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', 'P4'),
(77,46, '⭐⭐ THE PARTITION: the cluster still on v19 keeps its row - a flip of ONE cluster may never touch another',
 $q$SELECT (value->>'ctl_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),
(77,47, '...and keeps it byte-for-byte at the same quantity, not merely present',
 $q$SELECT ((value->>'ctl_qty_after') = (value->>'ctl_qty_before'))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', 'true', 'P4'),
(77,48, 'The receipt witnesses the flipped state it ran under',
 $q$SELECT (value->>'after_clusters') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),

-- ── reversibility ───────────────────────────────────────────────────────────────
(77,50, '⭐ REVERSIBLE: after revert_cluster_to_v19_v3 the same call sees BOTH gaps again',
 $q$SELECT (value->>'back_gaps') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '2', 'P4'),
(77,51, '...suppressing nothing',
 $q$SELECT (value->>'back_suppressed') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', 'P4'),
(77,52, '⛔ A FLIP NEVER STRANDS DEMAND PERMANENTLY: NOVO''s ledger row comes straight back',
 $q$SELECT (value->>'novo_back') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),
(77,53, '...as a genuine re-INSERT, which is what proves the earlier close was a real DELETE and not a filtered read',
 $q$SELECT (value->>'back_ins') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '1', 'P4'),
(77,54, 'The receipt witnesses the reverted state',
 $q$SELECT (value->>'back_clusters') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$q$, 'eq', '0', 'P4'),

-- ── residue ─────────────────────────────────────────────────────────────────────
(77,60, '⛔ LAW 4 AFTER THE FACT: every cluster is back on v19 - the fixture flipped one and left none flipped',
 $q$SELECT (value->>'all_v19_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='after'$q$, 'eq', '0', 'P4'),
(77,61, 'Residue: no planted pod_refills row survived the discard',
 $q$SELECT (value->>'pr_gone') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='after'$q$, 'eq', '0', 'P4'),
(77,62, 'Residue: no ledger row survived the discard',
 $q$SELECT (value->>'bd_gone') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='after'$q$, 'eq', '0', 'P4'),
(77,63, '⛔ S-307: the planted v3 evidence is GONE - synthetic fixture rows must never become cutover evidence',
 $q$SELECT (value->>'planted_gone') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='after'$q$, 'eq', '0', 'P4'),
(77,64, 'Residue: the cutover audit log is still empty, so no real flip was recorded',
 $q$SELECT (value->>'audit_gone') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='after'$q$, 'eq', '0', 'P4');

COMMIT;
