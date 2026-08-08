-- PRD-112 unit 5 — golden fixture 112
--
-- "Driver substitutes flavor on a packed line; day-close acknowledge closes
-- inventory" — the 2026-08-08 VOXMCC-1005 Coconut incident, encoded.
--
-- golden.render derives the fixture date as DATE '2030-01-01' + fixture_id, so
-- fixture 112 runs on 2030-04-23. No other fixture uses that date.
--
-- PRODUCTION WRITE BOUNDS (PRD §6):
--   * Every planted row is on the synthetic 2030 date. Nothing on a live date.
--   * The fixture NEVER deletes a protected row. Re-runs plant fresh rows rather
--     than resetting old ones, so no DELETE and no guard gymnastics are needed.
--   * The pod_inventory write, the guard probes, the anon probe and the
--     closed-day probe all run inside subtransactions that are deliberately
--     rolled back. PL/pgSQL variables survive the rollback, so the evidence is
--     kept while the write is not.
--
-- The fixture must be able to go RED. Seq 14-17 are the tripwires: they prove
-- the guards this PRD routed around still refuse everyone else, and that the
-- RPC's own refusals are reachable rather than decorative.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, scenario_sql, notes)
VALUES (
  112,
  'PRD-112: the driver substitutes a flavor on a packed+picked_up line and is never blocked; the day-close acknowledge is what moves machine stock, once. The venue-sourced clean path binds the VOX sentinel and flags nothing; the actual Coconut line (no sentinel for that flavor) and a Boonz line with zero warehouse stock are both ACCEPTED and flagged rather than refused. Acknowledge credits pod_inventory exactly once and a second acknowledge writes nothing. The packed-row guard still refuses every writer that is not registered, and the duplicate-unstarted-row guard is byte-untouched.',
  'PRD-112 §1 - live incident 2026-08-08, VOXMCC-1005-0201-B0. Plan said Fade Fit Dark Choc / Hazelnut / PB / Salted Caramel; the venue only had Coconut. FE add-row hit the duplicate guard, the packed-row guard blocked the edit, and resolution required CS intervention mid-route.',
  'P0',
  '2030-04-23',
  true,
  'passing',
$fx$
DO $do$
DECLARE
  v_fx        int  := 112;
  v_date      date := {{plan_date}};
  v_machine   uuid := '148c4fcf-b794-43f0-a2a8-e6f17605b045'; -- VOXMCC-1005-0201-B0, co_managed / VOX
  v_driver    uuid := 'bddaec3c-fe18-40db-93e4-8ca543819519'; -- field_staff
  v_cs        uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'; -- operator_admin
  v_shelf_a   uuid := '40d794c6-fa25-4e9f-afe2-fb267bf443e8'; -- A01
  v_shelf_b   uuid := '3f881ec7-350e-4745-9731-64612c5cfc37'; -- A02
  v_shelf_c   uuid := '8ca35afb-6daa-45e6-bc77-ff28d148c567'; -- A03
  v_shelf_d   uuid := '48907909-7b0c-438b-8183-95ceaf1b4b81'; -- A04
  v_dark      uuid := 'e475225d-b69a-45ce-8191-6482adf4d64e'; -- Fade Fit - Dark Chocolate (planned)
  v_hazel     uuid := '432ab931-10bb-45fb-8186-420f153905ec'; -- Fade Fit - Hazelnut  (VOX sentinel exists)
  v_coconut   uuid := '6d1b2a6b-28ea-402b-9e19-1f658eb17766'; -- Fade Fit - Coconut   (NO VOX sentinel) <- the incident
  v_nostock   uuid := '0a9016bc-5755-4dc8-82f8-79a3e911ab6f'; -- Barebells Cookies&Cream, zero WH stock
  v_wh_mcc    uuid := '4fcfb52c-271f-4aa7-a373-3495e3271cd3';
  v_pod_dark  uuid;
  v_pod_name  text;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid;
  v_res_a jsonb; v_res_b jsonb; v_res_c jsonb;
  v_ack1 jsonb := NULL; v_ack2 jsonb := NULL;
  v_pod_before numeric := 0; v_pod_after numeric := 0;
  v_guard_probe text := 'NOT_RUN';
  v_dup_probe   text := 'NOT_RUN';
  v_anon_probe  text := 'NOT_RUN';
  v_past_probe  text := 'NOT_RUN';
  v_ev_a uuid;
BEGIN
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_driver, 'role', 'authenticated')::text, false);

  SELECT pm.pod_product_id INTO v_pod_dark
  FROM public.product_mapping pm
  WHERE pm.boonz_product_id = v_dark AND pm.status = 'Active'
    AND (pm.machine_id = v_machine OR pm.machine_id IS NULL)
  ORDER BY (pm.machine_id = v_machine) DESC NULLS LAST, pm.is_global_default DESC
  LIMIT 1;
  SELECT pp.pod_product_name INTO v_pod_name
    FROM public.pod_products pp WHERE pp.pod_product_id = v_pod_dark;

  -- ── plant. app.via_trigger keeps the canonical-writer guard quiet for the
  --    harness itself; it is cleared immediately so the RPC under test has to
  --    satisfy that guard on its OWN name, not on a leaked one.
  PERFORM set_config('app.via_trigger', 'true', true);

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     filled_quantity, packed, picked_up, item_added, include, pack_outcome,
     source_origin, source_kind, source_warehouse_id, from_warehouse_id, comment)
  VALUES
    (v_machine, v_shelf_a, v_pod_dark, v_dark, v_date, 'Refill', 6, 6, true, true, false, true,
     'packed', 'vox_at_venue', 'unknown', NULL, NULL, 'golden fixture 112 line A (venue, clean path)')
  RETURNING dispatch_id INTO v_a;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     filled_quantity, packed, picked_up, item_added, include, pack_outcome,
     source_origin, source_kind, source_warehouse_id, from_warehouse_id, comment)
  VALUES
    (v_machine, v_shelf_b, v_pod_dark, v_dark, v_date, 'Refill', 4, 4, true, true, false, true,
     'packed', 'vox_at_venue', 'unknown', NULL, NULL, 'golden fixture 112 line B (the Coconut incident)')
  RETURNING dispatch_id INTO v_b;

  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     filled_quantity, packed, picked_up, item_added, include, pack_outcome,
     source_origin, source_kind, source_warehouse_id, from_warehouse_id, comment)
  VALUES
    (v_machine, v_shelf_c, v_pod_dark, v_dark, v_date, 'Refill', 5, 5, true, true, false, true,
     'packed', 'warehouse', 'wh', v_wh_mcc, v_wh_mcc, 'golden fixture 112 line C (boonz, no stock)')
  RETURNING dispatch_id INTO v_c;

  -- line D exists only to prove the closed-day refusal is reachable. Left
  -- unpacked so the probe can move its date inside a rolled-back subtransaction.
  INSERT INTO public.refill_dispatching
    (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
     filled_quantity, packed, picked_up, item_added, include,
     source_origin, source_kind, source_warehouse_id, from_warehouse_id, comment)
  VALUES
    (v_machine, v_shelf_d, v_pod_dark, v_dark, v_date, 'Refill', 3, 3, false, false, false, true,
     'warehouse', 'wh', v_wh_mcc, v_wh_mcc, 'golden fixture 112 line D (closed-day probe)')
  RETURNING dispatch_id INTO v_d;

  -- the rpo row PRD §4.2 requires be kept in sync
  INSERT INTO public.refill_plan_output
    (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name, action, quantity,
     dispatch_id, machine_id, shelf_id, pod_product_id, boonz_product_id, dispatched)
  VALUES
    (v_date, 'VOXMCC-1005-0201-B0', 'A01', v_pod_name, 'Fade Fit - Dark Chocolate', 'Refill', 6,
     v_a, v_machine, v_shelf_a, v_pod_dark, v_dark, true);

  PERFORM set_config('app.via_trigger', '', true);

  -- ── the three substitutions ───────────────────────────────────────────────
  BEGIN
    v_res_a := public.driver_substitute_dispatch_line(
      v_a, v_hazel, 6, 'venue had different flavor', v_driver, 'venue');
  EXCEPTION WHEN OTHERS THEN v_res_a := jsonb_build_object('error', SQLERRM); END;

  BEGIN
    v_res_b := public.driver_substitute_dispatch_line(
      v_b, v_coconut, 4, 'venue only had Coconut', v_driver, 'venue');
  EXCEPTION WHEN OTHERS THEN v_res_b := jsonb_build_object('error', SQLERRM); END;

  BEGIN
    v_res_c := public.driver_substitute_dispatch_line(
      v_c, v_nostock, 5, 'out of stock, spot bought nothing', v_driver, NULL);
  EXCEPTION WHEN OTHERS THEN v_res_c := jsonb_build_object('error', SQLERRM); END;

  -- ── tripwire: an UNREGISTERED writer must still be refused on a packed line ──
  BEGIN
    PERFORM set_config('app.rpc_name',    'not_a_registered_writer', true);
    PERFORM set_config('app.via_trigger', 'true', true);
    UPDATE public.refill_dispatching SET boonz_product_id = v_coconut WHERE dispatch_id = v_a;
    v_guard_probe := 'NOT_BLOCKED';
    RAISE EXCEPTION 'GOLDEN112_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'GOLDEN112_ROLLBACK' THEN v_guard_probe := SQLERRM; END IF;
  END;
  PERFORM set_config('app.via_trigger', '', true);

  -- ── tripwire: the duplicate-unstarted-row guard still fires ────────────────
  BEGIN
    PERFORM set_config('app.via_trigger', 'true', true);
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
       filled_quantity, packed, picked_up, include, source_origin, source_kind)
    VALUES (v_machine, v_shelf_d, v_pod_dark, v_hazel, v_date, 'Refill', 1, 0, false, false, true,
            'warehouse', 'unknown');
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, pod_product_id, boonz_product_id, dispatch_date, action, quantity,
       filled_quantity, packed, picked_up, include, source_origin, source_kind)
    VALUES (v_machine, v_shelf_d, v_pod_dark, v_hazel, v_date, 'Refill', 1, 0, false, false, true,
            'warehouse', 'unknown');
    v_dup_probe := 'NOT_BLOCKED';
    RAISE EXCEPTION 'GOLDEN112_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'GOLDEN112_ROLLBACK' THEN v_dup_probe := SQLERRM; END IF;
  END;
  PERFORM set_config('app.via_trigger', '', true);

  -- ── tripwire: anonymous is refused BY NAME, not silently allowed ───────────
  BEGIN
    PERFORM set_config('request.jwt.claims', '', false);
    PERFORM public.driver_substitute_dispatch_line(v_d, v_coconut, 1, 'anon probe', NULL, NULL);
    v_anon_probe := 'NOT_BLOCKED';
    RAISE EXCEPTION 'GOLDEN112_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'GOLDEN112_ROLLBACK' THEN v_anon_probe := SQLERRM; END IF;
  END;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_driver, 'role', 'authenticated')::text, false);

  -- ── tripwire: a closed day cannot be substituted ───────────────────────────
  -- The date must be behind the REAL clock, not behind the synthetic 2030 fixture
  -- date. First cut used 2029-01-01, which is still in the future of today and so
  -- proved nothing; the tripwire caught it.
  BEGIN
    PERFORM set_config('app.via_trigger', 'true', true);
    UPDATE public.refill_dispatching SET dispatch_date = DATE '2020-01-01' WHERE dispatch_id = v_d;
    PERFORM set_config('app.via_trigger', '', true);
    PERFORM public.driver_substitute_dispatch_line(v_d, v_coconut, 1, 'closed day probe', v_driver, NULL);
    v_past_probe := 'NOT_BLOCKED';
    RAISE EXCEPTION 'GOLDEN112_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'GOLDEN112_ROLLBACK' THEN v_past_probe := SQLERRM; END IF;
  END;
  PERFORM set_config('app.via_trigger', '', true);

  -- ── day close: CS acknowledges, stock moves ONCE ───────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_cs, 'role', 'authenticated')::text, false);

  SELECT e.id INTO v_ev_a
  FROM public.day_close_events e
  WHERE e.dispatch_id = v_a AND e.kind = 'substitution'
  ORDER BY e.created_at DESC LIMIT 1;

  SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_pod_before
  FROM public.pod_inventory pi
  WHERE pi.machine_id = v_machine AND pi.shelf_id = v_shelf_a
    AND pi.boonz_product_id = v_hazel AND pi.status = 'Active';

  BEGIN
    v_ack1 := public.acknowledge_day_close_event(v_ev_a, 'golden 112 first acknowledge');

    SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_pod_after
    FROM public.pod_inventory pi
    WHERE pi.machine_id = v_machine AND pi.shelf_id = v_shelf_a
      AND pi.boonz_product_id = v_hazel AND pi.status = 'Active';

    v_ack2 := public.acknowledge_day_close_event(v_ev_a, 'golden 112 second acknowledge');
    RAISE EXCEPTION 'GOLDEN112_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'GOLDEN112_ROLLBACK' THEN
      v_ack1 := COALESCE(v_ack1, jsonb_build_object('error', SQLERRM));
    END IF;
  END;

  DELETE FROM golden.scratch WHERE fixture_id = v_fx;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (v_fx, 'ids',         jsonb_build_object('a', v_a, 'b', v_b, 'c', v_c, 'd', v_d, 'event_a', v_ev_a)),
    (v_fx, 'res_a',       COALESCE(v_res_a, 'null'::jsonb)),
    (v_fx, 'res_b',       COALESCE(v_res_b, 'null'::jsonb)),
    (v_fx, 'res_c',       COALESCE(v_res_c, 'null'::jsonb)),
    (v_fx, 'ack1',        COALESCE(v_ack1,  'null'::jsonb)),
    (v_fx, 'ack2',        COALESCE(v_ack2,  'null'::jsonb)),
    (v_fx, 'pod_delta',   jsonb_build_object('before', v_pod_before, 'after', v_pod_after,
                                             'delta', v_pod_after - v_pod_before)),
    (v_fx, 'probes',      jsonb_build_object('packed_guard', v_guard_probe, 'dup_guard', v_dup_probe,
                                             'anon', v_anon_probe, 'closed_day', v_past_probe));

  -- ── residue: leave the writer GUCs as we found them ───────────────────────
  -- golden.run_all runs every fixture in ONE transaction, and these GUCs are
  -- transaction-local, so a fixture that calls an RPC and walks away leaves
  -- app.via_rpc='true' set for whatever runs next. Fixtures 18, 26, 67, 71 and 74
  -- each assert that nothing leaked into them. Fixture 112 sorts last today, so
  -- it could not poison them - but that is an accident of its id, not hygiene.
  PERFORM set_config('app.via_rpc',  '', true);
  PERFORM set_config('app.rpc_name', '', true);
END
$do$;
$fx$,
  'PRD-112 acceptance 1-6. Re-runs plant fresh rows on the synthetic date rather than deleting old ones - this fixture never removes a protected row. The pod_inventory write and all four probes run in deliberately rolled-back subtransactions.'
)
ON CONFLICT (fixture_id) DO UPDATE
  SET name = EXCLUDED.name, source_incident = EXCLUDED.source_incident,
      phase_required = EXCLUDED.phase_required, plan_date = EXCLUDED.plan_date,
      enabled = EXCLUDED.enabled, baseline_status = EXCLUDED.baseline_status,
      scenario_sql = EXCLUDED.scenario_sql, notes = EXCLUDED.notes;


DELETE FROM golden.assertions WHERE fixture_id = 112;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(112, 1, 'A venue-line substitution on a packed+picked_up line returns ok (acceptance 1)',
 $a$SELECT (value->>'ok') FROM golden.scratch WHERE fixture_id=112 AND key='res_a'$a$, 'eq', 'true', true, 'P0'),

(112, 2, 'The planned product is preserved in original_boonz_product_id, so settlement still reads the plan (PRD 4.4)',
 $a$SELECT rd.original_boonz_product_id::text FROM public.refill_dispatching rd
    WHERE rd.dispatch_id = ((SELECT value->>'a' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid$a$,
 'eq', 'e475225d-b69a-45ce-8191-6482adf4d64e', true, 'P0'),

(112, 3, 'The line now carries the flavor the driver actually filled',
 $a$SELECT rd.boonz_product_id::text FROM public.refill_dispatching rd
    WHERE rd.dispatch_id = ((SELECT value->>'a' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid$a$,
 'eq', '432ab931-10bb-45fb-8186-420f153905ec', true, 'P0'),

(112, 4, 'The audit comment names both products and the reason',
 $a$SELECT rd.comment FROM public.refill_dispatching rd
    WHERE rd.dispatch_id = ((SELECT value->>'a' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid$a$,
 'contains', 'SUBSTITUTED by driver: Fade Fit - Dark Chocolate -> Fade Fit - Hazelnut (venue had different flavor)', true, 'P0'),

(112, 5, 'A venue flavor that HAS a VOX sentinel batch is not flagged - flavor freedom does not mean flagging everything',
 $a$SELECT rd.needs_review::text FROM public.refill_dispatching rd
    WHERE rd.dispatch_id = ((SELECT value->>'a' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid$a$,
 'eq', 'false', true, 'P0'),

(112, 6, 'The linked rpo row follows the dispatch row, so FE boards do not diverge (PRD 4.2)',
 $a$SELECT rpo.boonz_product_name FROM public.refill_plan_output rpo
    WHERE rpo.dispatch_id = ((SELECT value->>'a' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid$a$,
 'eq', 'Fade Fit - Hazelnut', true, 'P0'),

(112, 7, 'The 08-08 Coconut line is ACCEPTED, not refused - the driver is never blocked',
 $a$SELECT (value->>'ok') FROM golden.scratch WHERE fixture_id=112 AND key='res_b'$a$, 'eq', 'true', true, 'P0'),

(112, 8, 'Coconut has no VOX sentinel, so the line is flagged rather than silently bound',
 $a$SELECT rd.review_reason FROM public.refill_dispatching rd
    WHERE rd.dispatch_id = ((SELECT value->>'b' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid$a$,
 'eq', 'substitution_stock_unverified', true, 'P0'),

(112, 9, 'The flagged line raises its own Gap row in Day Close, not just a filter over Changes',
 $a$SELECT count(*)::text FROM public.day_close_events e
    WHERE e.dispatch_id = ((SELECT value->>'b' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid
      AND e.kind = 'stock_unverified'$a$,
 'eq', '1', true, 'P0'),

(112, 10, 'A Boonz-sourced substitution with zero warehouse stock is accepted and flagged (acceptance 2)',
 $a$SELECT (value->>'ok') || '/' || (SELECT rd.review_reason FROM public.refill_dispatching rd
      WHERE rd.dispatch_id = ((SELECT value->>'c' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid)
   FROM golden.scratch WHERE fixture_id=112 AND key='res_c'$a$,
 'eq', 'true/substitution_stock_unverified', true, 'P0'),

(112, 11, 'Every substitution surfaces in Day Close immediately (acceptance 3, first half)',
 $a$SELECT count(*)::text FROM public.v_day_close_events e
    WHERE e.kind='substitution' AND e.dispatch_id IN (
      ((SELECT value->>'a' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid,
      ((SELECT value->>'b' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid,
      ((SELECT value->>'c' FROM golden.scratch WHERE fixture_id=112 AND key='ids'))::uuid)$a$,
 'eq', '3', true, 'P0'),

(112, 12, 'Acknowledge writes pod_inventory through the adjust_pod_inventory merge path',
 $a$SELECT (value->>'pod_action') FROM golden.scratch WHERE fixture_id=112 AND key='ack1'$a$,
 'eq', 'adjusted', true, 'P0'),

(112, 13, 'The merge credits exactly what the driver filled - six units, once, not twice',
 $a$SELECT (value->>'delta') FROM golden.scratch WHERE fixture_id=112 AND key='pod_delta'$a$,
 'eq', '6', true, 'P0'),

(112, 14, 'A second acknowledge is idempotent: it reports the first one and writes no stock (acceptance 3)',
 $a$SELECT (value->>'already_acknowledged') FROM golden.scratch WHERE fixture_id=112 AND key='ack2'$a$,
 'eq', 'true', true, 'P0'),

(112, 15, 'TRIPWIRE: an unregistered writer is STILL refused on a packed line - the bypass is one named writer, not a hole',
 $a$SELECT (value->>'packed_guard') FROM golden.scratch WHERE fixture_id=112 AND key='probes'$a$,
 'contains', 'Cannot change boonz_product_id on a packed dispatch line', true, 'P0'),

(112, 16, 'TRIPWIRE: the duplicate-unstarted-row guard still fires (acceptance 5)',
 $a$SELECT (value->>'dup_guard') FROM golden.scratch WHERE fixture_id=112 AND key='probes'$a$,
 'contains', 'Duplicate unstarted dispatch row', true, 'P0'),

(112, 17, 'TRIPWIRE: anonymous is refused BY NAME, not short-circuited past the role gate (D-41/D-42 class)',
 $a$SELECT (value->>'anon') FROM golden.scratch WHERE fixture_id=112 AND key='probes'$a$,
 'contains', 'anonymous caller refused', true, 'P0'),

(112, 18, 'TRIPWIRE: a closed day cannot be substituted - the date rule is reachable, not decorative',
 $a$SELECT (value->>'closed_day') FROM golden.scratch WHERE fixture_id=112 AND key='probes'$a$,
 'contains', 'closed day cannot be substituted', true, 'P0'),

(112, 19, 'TRIPWIRE: day_close_events is not writable by authenticated (Article 3 / S-308)',
 $a$SELECT count(*)::text FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name='day_close_events'
      AND grantee='authenticated' AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')$a$,
 'eq', '0', true, 'P0'),

(112, 20, 'TRIPWIRE: prevent_duplicate_unstarted_dispatch is byte-identical to its pre-PRD-112 body (acceptance 5)',
 $a$SELECT md5(prosrc) FROM pg_proc WHERE proname='prevent_duplicate_unstarted_dispatch'$a$,
 'eq', 'b11581fe9540b3a12c67bf6d4d25d0fc', true, 'P0'),

(112, 21, 'RESIDUE: this fixture leaves app.via_rpc unset. run_all is one transaction and these GUCs are transaction-local, so a fixture that walks away with via_rpc set disarms the canonical-writer guard for whatever runs next (the S-197 class fixtures 18/26/67/71/74 each assert against).',
 $a$SELECT COALESCE(NULLIF(current_setting('app.via_rpc', true), ''), 'UNSET')$a$,
 'eq', 'UNSET', true, 'P0');
