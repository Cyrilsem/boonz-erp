-- PRD-110 P1.4 acceptance fixtures 21 + 22. Same rolled-back-subtransaction
-- discipline as 19/20: zero residue in the append-only ledger, repeatable.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, scenario_sql, notes, enabled)
VALUES (21, 'Driver confirm collapse', 'WS-J2', 'P1', DATE '2030-01-22', 'passing', $scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'df_open', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'ev',      (SELECT count(*) FROM public.inventory_events),
  'comp',    (SELECT count(*) FROM public.shelf_composition),
  'anom',    (SELECT count(*) FROM public.inventory_anomalies));
DO $fx21$
DECLARE
  v_s uuid; v_p1 uuid; v_p2 uuid; v_p3 uuid;
  v_ids uuid[]; v_ev_before int; v_conf jsonb; v_payload jsonb;
BEGIN
  SELECT sc.shelf_id INTO v_s FROM public.shelf_configurations sc
    JOIN public.machines m ON m.machine_id = sc.machine_id
   WHERE m.official_name = 'MC-2004-0100-O1' AND sc.shelf_code = 'B09';
  SELECT array_agg(x) INTO v_ids FROM (
    SELECT pm.boonz_product_id x FROM public.product_mapping pm
      JOIN public.v_shelf_state ss ON ss.pod_product_id = pm.pod_product_id
     WHERE ss.shelf_id = v_s AND pm.status='Active' AND COALESCE(pm.split_pct,0) > 0
     GROUP BY pm.boonz_product_id ORDER BY pm.boonz_product_id LIMIT 3) q;
  v_p1 := v_ids[1]; v_p2 := v_ids[2]; v_p3 := v_ids[3];
  BEGIN
    -- a drifted estimate: three believed buckets and low confidence
    PERFORM public.record_inventory_event_v3(v_s, v_p1, 10, 'load', NULL, 'golden_fx21', 'believed A');
    PERFORM public.record_inventory_event_v3(v_s, v_p2, 7,  'load', NULL, 'golden_fx21', 'believed B');
    PERFORM public.record_inventory_event_v3(v_s, v_p3, 3,  'load', NULL, 'golden_fx21', 'believed C - driver will NOT report it');
    PERFORM public.decay_composition_confidence_v3(v_s, 0.6, 'golden fixture 21: drift before the collapse');

    v_ev_before := (SELECT count(*) FROM public.inventory_events WHERE shelf_id = v_s);
    v_ids := ARRAY(SELECT event_id FROM public.inventory_events WHERE shelf_id = v_s);

    v_conf := public.driver_confirm_shelf_v3(v_s,
      jsonb_build_array(jsonb_build_object('boonz_product_id', v_p1, 'qty', 6),
                        jsonb_build_object('boonz_product_id', v_p2, 'qty', 4)),
      'golden fixture 21: driver-confirmed corrected mix');

    v_payload := jsonb_build_object(
      'p1_after',        (SELECT est_qty FROM public.shelf_composition WHERE shelf_id=v_s AND boonz_product_id=v_p1 AND expiry_bucket IS NULL)::text,
      'p2_after',        (SELECT est_qty FROM public.shelf_composition WHERE shelf_id=v_s AND boonz_product_id=v_p2 AND expiry_bucket IS NULL)::text,
      'p3_after',        (SELECT est_qty FROM public.shelf_composition WHERE shelf_id=v_s AND boonz_product_id=v_p3 AND expiry_bucket IS NULL)::text,
      'min_conf_after',  (SELECT min(confidence) FROM public.shelf_composition WHERE shelf_id=v_s)::text,
      'buckets_zeroed',  v_conf->>'buckets_zeroed',
      'events_written',  v_conf->>'events_written',
      'events_appended', ((SELECT count(*) FROM public.inventory_events WHERE shelf_id=v_s) - v_ev_before)::text,
      'history_preserved', (SELECT count(*) FROM public.inventory_events WHERE shelf_id=v_s AND event_id = ANY(v_ids))::text,
      'history_expected',  v_ev_before::text,
      'incidents',       v_conf->>'expired_sold_incidents');
    RAISE EXCEPTION 'GP21:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP21:%' THEN v_payload := substring(SQLERRM from 'GP21:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx21$;
$scenario$,
'Ports leg-8 dry-tests W6 + W8. Also pins the risk-18 guard at the confirm path: an UNKNOWN (NULL) expiry bucket that shrinks is a plain driver_confirm, NOT an expired_sold_incident - NULL means unknown, which is sellable.', true);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(21,1,'W6: composition snaps to the driver-reported qty (10 -> 6)',
 $a$SELECT value->>'p1_after' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','6','P1'),
(21,2,'W6: second bucket snaps too (7 -> 4)',
 $a$SELECT value->>'p2_after' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','4','P1'),
(21,3,'a believed bucket the driver did NOT report is zeroed, not left standing',
 $a$SELECT value->>'p3_after' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(21,4,'exactly one bucket was zeroed',
 $a$SELECT value->>'buckets_zeroed' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1','P1'),
(21,5,'confidence RESET to 1.0 by the collapse (was 0.4)',
 $a$SELECT value->>'min_conf_after' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1.0','P1'),
(21,6,'the collapse wrote 3 events (2 corrections + 1 zeroing)',
 $a$SELECT value->>'events_written' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','3','P1'),
(21,7,'W8: those events were APPENDED',
 $a$SELECT value->>'events_appended' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','3','P1'),
(21,8,'W8: history preserved - every pre-collapse event_id still exists (no overwrite)',
 $a$SELECT ((value->>'history_preserved') = (value->>'history_expected'))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','true','P1'),
(21,9,'risk 18: an UNKNOWN (NULL) bucket shrinking is NOT an expired_sold_incident',
 $a$SELECT value->>'incidents' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(21,90,'S-08 tripwire: open driver_feedback count unchanged by the fixture',
 $a$SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved=false) = (SELECT (value->>'df_open')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(21,95,'RESIDUE: inventory_events row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.inventory_events) = (SELECT (value->>'ev')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(21,96,'RESIDUE: shelf_composition row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.shelf_composition) = (SELECT (value->>'comp')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(21,97,'RESIDUE: inventory_anomalies row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.inventory_anomalies) = (SELECT (value->>'anom')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1');

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, scenario_sql, notes, enabled)
VALUES (22, 'Multi-SKU shelf decay', 'Chocolate Bar / WS-J2', 'P1', DATE '2030-01-23', 'passing', $scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'df_open', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'ev',      (SELECT count(*) FROM public.inventory_events),
  'comp',    (SELECT count(*) FROM public.shelf_composition),
  'anom',    (SELECT count(*) FROM public.inventory_anomalies));
DO $fx22$
DECLARE
  v_m uuid; v_s uuid; v_p1 uuid; v_p2 uuid; v_c numeric; v_ids uuid[];
  v_est jsonb; v_conf jsonb; v_after_est numeric; v_final numeric; v_thresh numeric;
  v_payload jsonb; v_i int; r record; v_p uuid; v_seeded int := 0;
BEGIN
  SELECT machine_id INTO v_m FROM public.machines WHERE official_name = 'NISSAN-0804-0000-L0';
  SELECT sc.shelf_id INTO v_s FROM public.shelf_configurations sc
   WHERE sc.machine_id = v_m AND sc.shelf_code = 'A09';
  SELECT current_stock INTO v_c FROM public.v_shelf_state WHERE shelf_id = v_s;
  SELECT composition_confidence_prompt_threshold INTO v_thresh FROM public.refill_policy_params WHERE id = 1;
  SELECT array_agg(x) INTO v_ids FROM (
    SELECT pm.boonz_product_id x FROM public.product_mapping pm
      JOIN public.v_shelf_state ss ON ss.pod_product_id = pm.pod_product_id
     WHERE ss.shelf_id = v_s AND pm.status='Active' AND COALESCE(pm.split_pct,0) > 0
     GROUP BY pm.boonz_product_id ORDER BY pm.boonz_product_id LIMIT 2) q;
  v_p1 := v_ids[1]; v_p2 := v_ids[2];
  BEGIN
    -- PART 1 - causation. Two SELLABLE buckets and a belief 4 above the sensor, so
    -- the estimator must split an unexplained drop and therefore lose confidence.
    PERFORM public.record_inventory_event_v3(v_s, v_p1, v_c, 'load', NULL, 'golden_fx22', 'multi-SKU belief A');
    PERFORM public.record_inventory_event_v3(v_s, v_p2, 4,   'load', NULL, 'golden_fx22', 'multi-SKU belief B');
    v_est := public.estimate_shelf_composition_v3(v_s, false);
    v_after_est := (SELECT min(confidence) FROM public.shelf_composition WHERE shelf_id = v_s);

    -- three further unexplained deltas with no visit
    FOR v_i IN 1..3 LOOP
      PERFORM public.decay_composition_confidence_v3(v_s, 0.15, 'golden fixture 22: further unexplained delta, no visit');
    END LOOP;
    v_final := (SELECT min(confidence) FROM public.shelf_composition WHERE shelf_id = v_s);

    v_payload := jsonb_build_object(
      'candidates',            (SELECT count(*) FROM public.shelf_composition WHERE shelf_id=v_s)::text,
      'decayed_by_estimator',  v_est->>'shelves_confidence_decayed',
      'drops_allocated',       v_est->>'count_drops_allocated',
      'estimator_events',      v_est->>'events_written',
      'conf_after_estimator',  v_after_est::text,
      'conf_after_decays',     v_final::text,
      'threshold',             v_thresh::text,
      'below_threshold',       (v_final < v_thresh)::text,
      'in_prompt_queue',       (SELECT count(*) FROM public.v_shelf_audit_prompts WHERE shelf_id=v_s)::text,
      'null_bucket_in_expiry_queue', (SELECT count(*) FROM public.v_expiry_action_queue WHERE shelf_id=v_s)::text);

    -- the collapse restores certainty and the shelf leaves the prompt queue
    v_conf := public.driver_confirm_shelf_v3(v_s,
      (SELECT jsonb_agg(jsonb_build_object('boonz_product_id', boonz_product_id, 'qty', est_qty))
         FROM public.shelf_composition WHERE shelf_id = v_s),
      'golden fixture 22: driver audit collapse restores certainty');

    v_payload := v_payload || jsonb_build_object(
      'conf_after_collapse', (SELECT min(confidence) FROM public.shelf_composition WHERE shelf_id=v_s)::text,
      'left_prompt_queue',   (SELECT count(*) FROM public.v_shelf_audit_prompts WHERE shelf_id=v_s)::text);

    -- PART 2 - the max-3-per-visit cap only means something when MORE than 3
    -- shelves are flagged, so flag every other shelf on the same machine.
    FOR r IN SELECT shelf_id, pod_product_id, current_stock FROM public.v_shelf_state
              WHERE machine_id = v_m AND pod_product_id IS NOT NULL AND current_stock > 0
                AND shelf_id <> v_s ORDER BY shelf_id
    LOOP
      SELECT pm.boonz_product_id INTO v_p FROM public.product_mapping pm
       WHERE pm.pod_product_id = r.pod_product_id AND pm.status='Active' AND COALESCE(pm.split_pct,0) > 0
       ORDER BY pm.boonz_product_id LIMIT 1;
      IF v_p IS NOT NULL THEN
        PERFORM public.record_inventory_event_v3(r.shelf_id, v_p, r.current_stock, 'load', NULL, 'golden_fx22', 'cap seed');
        PERFORM public.decay_composition_confidence_v3(r.shelf_id, 0.6, 'golden fixture 22: drive below the prompt threshold');
        v_seeded := v_seeded + 1;
      END IF;
    END LOOP;

    v_payload := v_payload || jsonb_build_object(
      'flagged_total', (SELECT count(DISTINCT sc.shelf_id) FROM public.shelf_composition sc
                          JOIN public.v_shelf_state ss ON ss.shelf_id = sc.shelf_id
                         WHERE ss.machine_id = v_m AND sc.confidence < v_thresh AND sc.est_qty > 0)::text,
      'prompts_returned', (SELECT count(*) FROM public.v_shelf_audit_prompts WHERE machine_id = v_m)::text,
      'cap',              (SELECT max_prompts_per_visit FROM public.v_shelf_audit_prompts WHERE machine_id = v_m LIMIT 1)::text,
      'max_rank',         (SELECT max(prompt_rank) FROM public.v_shelf_audit_prompts WHERE machine_id = v_m)::text,
      'ranked_desc',      (SELECT bool_and(ok)::text FROM (
                             SELECT uncertainty_value_score <= lag(uncertainty_value_score) OVER (ORDER BY prompt_rank) IS NOT FALSE ok
                               FROM public.v_shelf_audit_prompts WHERE machine_id = v_m) q));
    RAISE EXCEPTION 'GP22:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP22:%' THEN v_payload := substring(SQLERRM from 'GP22:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx22$;
$scenario$,
'Two parts. Part 1 proves CAUSATION (a real estimator drop across 2 sellable buckets costs 0.15 confidence) then drives the shelf below the prompt threshold and collapses it back to 1.0. The estimator can only run once per (shelf, WEIMI snapshot) - that idempotency key is why the remaining decays use the canonical decay writer at the same param value rather than 10 synthetic snapshots. Part 2 flags every other shelf on the machine so the max-3-per-visit cap is proven to BIND (15 flagged -> 3 returned), not merely to be satisfiable.', true);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(22,1,'a genuinely multi-SKU shelf: 2 believed buckets',
 $a$SELECT value->>'candidates' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','2','P1'),
(22,2,'the estimator saw a real drop and allocated it',
 $a$SELECT value->>'drops_allocated' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1','P1'),
(22,3,'the drop was split across BOTH sellable buckets',
 $a$SELECT value->>'estimator_events' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','2','P1'),
(22,4,'CAUSATION: a multi-candidate derived decrement costs confidence',
 $a$SELECT value->>'decayed_by_estimator' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1','P1'),
(22,5,'one unexplained delta costs exactly composition_decay_per_unexplained (1.0 -> 0.85)',
 $a$SELECT value->>'conf_after_estimator' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0.85','P1'),
(22,6,'after further unexplained deltas confidence reaches 0.40',
 $a$SELECT value->>'conf_after_decays' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0.40','P1'),
(22,7,'confidence has decayed BELOW the prompt threshold',
 $a$SELECT value->>'below_threshold' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','true','P1'),
(22,8,'the audit prompt therefore FIRES for this shelf',
 $a$SELECT value->>'in_prompt_queue' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1','P1'),
(22,9,'risk 18: NULL (unknown) expiry buckets never enter the expiry action queue',
 $a$SELECT value->>'null_bucket_in_expiry_queue' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(22,10,'the collapse restores confidence to 1.0',
 $a$SELECT value->>'conf_after_collapse' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1.0','P1'),
(22,11,'and the shelf LEAVES the prompt queue once verified',
 $a$SELECT value->>'left_prompt_queue' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(22,12,'the cap is under real pressure: more than 3 shelves are flagged',
 $a$SELECT value->>'flagged_total' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'gt','3','P1'),
(22,13,'the max-3-per-visit cap BINDS: exactly 3 prompts returned',
 $a$SELECT value->>'prompts_returned' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','3','P1'),
(22,14,'and it is the param that decides, not a hardcoded 3',
 $a$SELECT ((value->>'prompts_returned') = (value->>'cap'))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','true','P1'),
(22,15,'prompts are ranked by uncertainty x value-at-risk, highest first',
 $a$SELECT value->>'ranked_desc' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','true','P1'),
(22,90,'S-08 tripwire: open driver_feedback count unchanged by the fixture',
 $a$SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved=false) = (SELECT (value->>'df_open')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(22,95,'RESIDUE: inventory_events row count unchanged after seeding 15 shelves',
 $a$SELECT ((SELECT count(*) FROM public.inventory_events) = (SELECT (value->>'ev')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(22,96,'RESIDUE: shelf_composition row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.shelf_composition) = (SELECT (value->>'comp')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(22,97,'RESIDUE: inventory_anomalies row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.inventory_anomalies) = (SELECT (value->>'anom')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1');
