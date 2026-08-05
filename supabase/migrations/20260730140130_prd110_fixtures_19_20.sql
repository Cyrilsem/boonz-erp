-- PRD-110 P1.4 acceptance fixtures 19 + 20 (LAW 1: fixture-first debt repaid).
-- Every mutation runs inside a plpgsql subtransaction that is ROLLED BACK; the
-- observations travel out through the RAISE EXCEPTION message and are then
-- written to golden.scratch. Residue in the three append-only P1.4 tables is
-- therefore ZERO and the fixtures are repeatable (stress-suite S7).
-- Cody-required residue assertions ride on both fixtures (seq 95-98): the
-- rollback is load-bearing, so it is asserted, not merely observed.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, scenario_sql, notes, enabled)
VALUES (19, 'Co-managed venue fill', 'VOX / WS-J2', 'P1', DATE '2030-01-20', 'passing', $scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'df_open',    (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'ev',         (SELECT count(*) FROM public.inventory_events),
  'comp',       (SELECT count(*) FROM public.shelf_composition),
  'anom',       (SELECT count(*) FROM public.inventory_anomalies),
  'classified', (SELECT count(*) FROM public.machines WHERE operating_model IS NOT NULL));
DO $fx19$
DECLARE v_m uuid; v_fm uuid; v_pod uuid; v_venue uuid; v_wh uuid; v_payload jsonb; v_guard text;
BEGIN
  SELECT machine_id INTO v_m  FROM public.machines WHERE official_name = 'MPMCC-1058-0000-R0';
  SELECT machine_id INTO v_fm FROM public.machines WHERE official_name = 'ADDMIND-1007-0000-W0';
  -- Soft Drinks Mix on MPMCC-1058 carries BOTH a venue edge (Pepsi Regular) and a
  -- boonz_wh edge (Coca Cola Zero). Same machine, same pod: sourcing is the ONLY variable.
  v_pod   := 'cc6cc9ca-d88d-412d-8178-331c33962e89';
  v_venue := 'bf1b69d4-cfb7-4f49-bf3a-8f229e184644';
  v_wh    := '02644904-0298-4d60-bcaa-a9067cf5e803';
  BEGIN
    v_payload := jsonb_build_object(
      'model_live_null',   (SELECT (operating_model IS NULL)::text FROM public.machines WHERE machine_id = v_m),
      'src_venue',         public.resolve_product_sourcing_v3(v_m, v_pod, v_venue),
      'src_wh',            public.resolve_product_sourcing_v3(v_m, v_pod, v_wh),
      'disp_unclassified', public._estimator_rise_disposition_v3(v_m, v_pod, v_venue));

    PERFORM public.set_machine_operating_model_v3(v_m,'co_managed',
      'golden fixture 19: simulate co_managed to prove the venue-fill branch (rolled back)');

    v_payload := v_payload || jsonb_build_object(
      'disp_venue_co', public._estimator_rise_disposition_v3(v_m, v_pod, v_venue),
      'disp_wh_co',    public._estimator_rise_disposition_v3(v_m, v_pod, v_wh));

    BEGIN
      PERFORM public.set_machine_operating_model_v3(v_m,'fully_managed',
        'golden fixture 19: containment probe, the guard must refuse this (rolled back)');
      v_guard := 'NOT_REFUSED';
    EXCEPTION WHEN others THEN v_guard := 'REFUSED';
    END;

    PERFORM public.set_machine_operating_model_v3(v_fm,'fully_managed',
      'golden fixture 19: simulate fully_managed to prove the non-co_managed branch (rolled back)');

    v_payload := v_payload || jsonb_build_object(
      'guard_fully_managed_on_venue_machine', v_guard,
      'src_fallback_fully_managed', public.resolve_product_sourcing_v3(v_fm, v_pod, v_venue),
      'disp_fully_managed',         public._estimator_rise_disposition_v3(v_fm, v_pod, v_venue),
      'events_in_txn', (SELECT count(*) FROM public.inventory_events)::text);
    RAISE EXCEPTION 'GP19:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP19:%' THEN v_payload := substring(SQLERRM from 'GP19:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx19$;
$scenario$,
'Asserts BOTH branches of the venue-fill rule through _estimator_rise_disposition_v3 rather than through live machine state, because machines.operating_model is NULL fleet-wide until D-07 is applied. The co_managed classification is simulated via the canonical writer inside a rolled-back subtransaction, so D-07 stays parked (seq 98 proves it).', true);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(19,1,'premise: operating_model is NULL on the target machine (D-07 parked)',
 $a$SELECT value->>'model_live_null' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','true','P1'),
(19,2,'sourcing edge: Pepsi Regular on MPMCC-1058 resolves venue',
 $a$SELECT value->>'src_venue' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','venue','P1'),
(19,3,'sourcing edge: Coca Cola Zero on the SAME pod resolves boonz_wh',
 $a$SELECT value->>'src_wh' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','boonz_wh','P1'),
(19,4,'D-07 dormancy: unclassified machine gives the fail-safe anomaly, never a silent auto-fill',
 $a$SELECT value->>'disp_unclassified' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','anomaly','P1'),
(19,5,'THESIS A: co_managed + venue-sourced count rise auto-attributes to venue_fill',
 $a$SELECT value->>'disp_venue_co' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','venue_fill','P1'),
(19,6,'THESIS B: same machine, same pod, boonz-sourced product -> anomaly (isolates sourcing)',
 $a$SELECT value->>'disp_wh_co' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','anomaly','P1'),
(19,7,'venue product on a fully_managed machine -> anomaly (isolates operating model)',
 $a$SELECT value->>'disp_fully_managed' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','anomaly','P1'),
(19,8,'fail-safe points at CONSTRAINED: unknown edge on fully_managed resolves boonz_wh',
 $a$SELECT value->>'src_fallback_fully_managed' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','boonz_wh','P1'),
(19,9,'containment: classifying a venue-edge machine fully_managed is REFUSED by the guard',
 $a$SELECT value->>'guard_fully_managed_on_venue_machine' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','REFUSED','P1'),
(19,10,'fixture 19 writes no inventory events at all',
 $a$SELECT value->>'events_in_txn' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(19,90,'S-08 tripwire: open driver_feedback count unchanged by the fixture',
 $a$SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved=false) = (SELECT (value->>'df_open')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(19,95,'RESIDUE: inventory_events row count unchanged (rollback held)',
 $a$SELECT ((SELECT count(*) FROM public.inventory_events) = (SELECT (value->>'ev')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(19,96,'RESIDUE: shelf_composition row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.shelf_composition) = (SELECT (value->>'comp')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(19,97,'RESIDUE: inventory_anomalies row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.inventory_anomalies) = (SELECT (value->>'anom')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(19,98,'RESIDUE: D-07 still parked - operating_model classification count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.machines WHERE operating_model IS NOT NULL) = (SELECT (value->>'classified')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1');

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, scenario_sql, notes, enabled)
VALUES (20, 'Expired never assumed sold', 'CS iron rule', 'P1', DATE '2030-01-21', 'passing', $scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'df_open', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'ev',      (SELECT count(*) FROM public.inventory_events),
  'comp',    (SELECT count(*) FROM public.shelf_composition),
  'anom',    (SELECT count(*) FROM public.inventory_anomalies));
DO $fx20$
DECLARE
  v_sa uuid; v_sb uuid; v_pa uuid; v_pb uuid; v_ca numeric; v_cb numeric;
  v_exp date := CURRENT_DATE - 10; v_ok date := CURRENT_DATE + 60;
  v_est jsonb; v_estb jsonb; v_payload jsonb; v_w3 text; v_w4 text;
BEGIN
  SELECT sc.shelf_id INTO v_sa FROM public.shelf_configurations sc
    JOIN public.machines m ON m.machine_id = sc.machine_id
   WHERE m.official_name = 'NOVO-1023-0000-W0' AND sc.shelf_code = 'A10';
  SELECT sc.shelf_id INTO v_sb FROM public.shelf_configurations sc
    JOIN public.machines m ON m.machine_id = sc.machine_id
   WHERE m.official_name = 'OMDCW-1021-0100-W0' AND sc.shelf_code = 'A09';
  SELECT current_stock INTO v_ca FROM public.v_shelf_state WHERE shelf_id = v_sa;
  SELECT current_stock INTO v_cb FROM public.v_shelf_state WHERE shelf_id = v_sb;
  SELECT pm.boonz_product_id INTO v_pa FROM public.product_mapping pm
    JOIN public.v_shelf_state ss ON ss.pod_product_id = pm.pod_product_id
   WHERE ss.shelf_id = v_sa AND pm.status='Active' AND COALESCE(pm.split_pct,0) > 0
   ORDER BY pm.boonz_product_id LIMIT 1;
  SELECT pm.boonz_product_id INTO v_pb FROM public.product_mapping pm
    JOIN public.v_shelf_state ss ON ss.pod_product_id = pm.pod_product_id
   WHERE ss.shelf_id = v_sb AND pm.status='Active' AND COALESCE(pm.split_pct,0) > 0
   ORDER BY pm.boonz_product_id LIMIT 1;
  BEGIN
    -- E3: sellable bucket = the WEIMI count, plus a 6-unit EXPIRED bucket on the SAME
    -- product. Belief therefore exceeds the sensor by 6 and the estimator must take
    -- all 6 from the sellable bucket. expiry_bucket is part of composition IDENTITY.
    PERFORM public.record_inventory_event_v3(v_sa, v_pa, v_ca, 'load', v_ok,  'golden_fx20', 'E3 sellable bucket');
    PERFORM public.record_inventory_event_v3(v_sa, v_pa, 6,    'load', v_exp, 'golden_fx20', 'E3 expired bucket');
    -- E5: belief is ALL expired and exceeds the sensor by 12. Sellable belief is zero,
    -- so nothing may be consumed; the shortfall must be REPORTED.
    PERFORM public.record_inventory_event_v3(v_sb, v_pb, v_cb + 12, 'load', v_exp, 'golden_fx20', 'E5 all-expired belief');

    v_est  := public.estimate_shelf_composition_v3(v_sa, false);
    v_estb := public.estimate_shelf_composition_v3(v_sb, false);
    -- drive shelf B below the auto-action floor to prove the OTHER gate branch
    PERFORM public.decay_composition_confidence_v3(v_sb, 0.30, 'golden fixture 20: below the auto-action floor');

    v_payload := jsonb_build_object(
      'a_expired_after',   (SELECT est_qty FROM public.shelf_composition WHERE shelf_id=v_sa AND expiry_bucket=v_exp)::text,
      'a_sellable_after',  (SELECT est_qty FROM public.shelf_composition WHERE shelf_id=v_sa AND expiry_bucket=v_ok)::text,
      'a_sellable_expect', (v_ca - 6)::text,
      'a_dd_vs_expired',   (SELECT count(*) FROM public.inventory_events WHERE shelf_id=v_sa AND kind='derived_decrement' AND expiry_date=v_exp)::text,
      'a_events_written',  v_est->>'events_written',
      'a_unalloc',         v_est->>'unallocatable_residuals',
      'b_expired_after',   (SELECT est_qty FROM public.shelf_composition WHERE shelf_id=v_sb AND expiry_bucket=v_exp)::text,
      'b_expired_expect',  (v_cb + 12)::text,
      'b_dd_events',       (SELECT count(*) FROM public.inventory_events WHERE shelf_id=v_sb AND kind='derived_decrement')::text,
      'b_unalloc',         v_estb->>'unallocatable_residuals',
      'b_anom_kind',       (SELECT kind FROM public.inventory_anomalies WHERE shelf_id=v_sb ORDER BY detected_at DESC LIMIT 1),
      'b_anom_residual',   (SELECT detail->>'residual_units' FROM public.inventory_anomalies WHERE shelf_id=v_sb ORDER BY detected_at DESC LIMIT 1),
      'a_action',          (SELECT action FROM public.v_expiry_action_queue WHERE shelf_id=v_sa AND expiry_bucket=v_exp),
      'b_action',          (SELECT action FROM public.v_expiry_action_queue WHERE shelf_id=v_sb AND expiry_bucket=v_exp),
      'future_bucket_rows',(SELECT count(*) FROM public.v_expiry_action_queue WHERE shelf_id=v_sa AND expiry_bucket=v_ok)::text);

    -- The IRON RULE is an ASYMMETRY, not a lock: it must bind assumptions
    -- WITHOUT blocking human events. Both directions are asserted.
    BEGIN
      PERFORM public.record_inventory_event_v3(v_sa, v_pa, -1, 'derived_decrement', v_exp, 'golden_fx20', 'W3 must be refused');
      v_w3 := 'NOT_REFUSED';
    EXCEPTION WHEN others THEN v_w3 := 'REFUSED';
    END;
    BEGIN
      PERFORM public.record_inventory_event_v3(v_sa, v_pa, -6, 'write_off', v_exp, 'golden_fx20', 'W4 human write-off must succeed');
      v_w4 := 'ALLOWED';
    EXCEPTION WHEN others THEN v_w4 := 'REFUSED';
    END;

    v_payload := v_payload || jsonb_build_object(
      'w3_derived_decrement_on_expired', v_w3,
      'w4_write_off_on_expired', v_w4,
      'a_expired_after_writeoff', (SELECT est_qty FROM public.shelf_composition WHERE shelf_id=v_sa AND expiry_bucket=v_exp)::text);
    RAISE EXCEPTION 'GP20:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP20:%' THEN v_payload := substring(SQLERRM from 'GP20:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx20$;
$scenario$,
'Ports leg-8 dry-tests E3 + E5 + W3 + W4 in intent. Belief-driven: the scenario sets composition ABOVE the live WEIMI count rather than writing WEIMI, so the estimator sees a genuine drop with no synthetic sensor data. Also asserts both branches of the P1.4 auto-action gate via v_expiry_action_queue.', true);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(20,1,'E3 IRON RULE: the expired bucket survives a 6-unit derived drop UNTOUCHED',
 $a$SELECT value->>'a_expired_after' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','6','P1'),
(20,2,'E3: the sellable bucket absorbed the entire drop',
 $a$SELECT ((value->>'a_sellable_after') = (value->>'a_sellable_expect'))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','true','P1'),
(20,3,'E3: zero derived_decrement events against the expired bucket - never even attempted',
 $a$SELECT value->>'a_dd_vs_expired' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(20,4,'E3: exactly one allocation event (single sellable bucket took it all)',
 $a$SELECT value->>'a_events_written' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1','P1'),
(20,5,'E3: a fully explained drop raises NO spurious anomaly',
 $a$SELECT value->>'a_unalloc' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(20,6,'E5: belief is all-expired and below the sensor - expired est_qty unchanged, nothing consumed',
 $a$SELECT ((value->>'b_expired_after') = (value->>'b_expired_expect'))::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','true','P1'),
(20,7,'E5: zero derived_decrement events on the all-expired shelf',
 $a$SELECT value->>'b_dd_events' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(20,8,'E5: the unabsorbable shortfall is REPORTED, not eaten',
 $a$SELECT value->>'b_unalloc' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','1','P1'),
(20,9,'E5: anomaly kind is negative_delta_unallocatable',
 $a$SELECT value->>'b_anom_kind' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','negative_delta_unallocatable','P1'),
(20,10,'E5: the anomaly carries the exact residual unit count (12)',
 $a$SELECT value->>'b_anom_residual' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','12','P1'),
(20,11,'W3: a derived_decrement naming the known-expired bucket is REFUSED',
 $a$SELECT value->>'w3_derived_decrement_on_expired' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','REFUSED','P1'),
(20,12,'W4 (the other direction): a human write_off on that SAME expired bucket is ALLOWED',
 $a$SELECT value->>'w4_write_off_on_expired' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','ALLOWED','P1'),
(20,13,'W4: the human event actually cleared the expired bucket to 0',
 $a$SELECT value->>'a_expired_after_writeoff' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(20,14,'auto-action gate: confidence >= 0.7 proposes auto_write_off',
 $a$SELECT value->>'a_action' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','auto_write_off','P1'),
(20,15,'auto-action gate: confidence below the floor degrades to a verify_task, never an auto write-off',
 $a$SELECT value->>'b_action' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','verify_task','P1'),
(20,16,'a FUTURE-dated bucket never enters the expiry action queue',
 $a$SELECT value->>'future_bucket_rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='obs'$a$,'eq','0','P1'),
(20,90,'S-08 tripwire: open driver_feedback count unchanged by the fixture',
 $a$SELECT ((SELECT count(*) FROM public.driver_feedback WHERE resolved=false) = (SELECT (value->>'df_open')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(20,95,'RESIDUE: inventory_events row count unchanged (append-only ledger untouched)',
 $a$SELECT ((SELECT count(*) FROM public.inventory_events) = (SELECT (value->>'ev')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(20,96,'RESIDUE: shelf_composition row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.shelf_composition) = (SELECT (value->>'comp')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1'),
(20,97,'RESIDUE: inventory_anomalies row count unchanged',
 $a$SELECT ((SELECT count(*) FROM public.inventory_anomalies) = (SELECT (value->>'anom')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='before'))::text$a$,'eq','true','P1');
