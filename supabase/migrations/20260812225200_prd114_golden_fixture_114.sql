-- PRD-114 acceptance 4 - golden fixture 114.
--
-- "The driver walks the machine, dispositions every expiring batch, and CS's
-- acknowledge is the only thing that moves stock."
--
-- golden.render derives the fixture date as DATE '2030-01-01' + fixture_id, so
-- fixture 114 runs on 2030-04-25. No other fixture uses that date.
--
-- ⛔ THE TWO CLOCKS ARE DIFFERENT, AND THAT IS THE POINT.
--   * `event_date` is the SYNTHETIC 2030 date, so these day_close_events can never
--     collide with a live Day Close.
--   * `expiration_date` is anchored to the REAL Dubai clock (today-30, today+3,
--     ...), because the 7-day sanity window is measured against the real date and
--     not against {{plan_date}}. PRD-113 learned this the hard way; a fixture that
--     planted 2030 expiries would find every batch OUTSIDE the window and prove
--     nothing. §4.5 of the PRD is about which ledger is read, not which clock.
--
-- PRODUCTION WRITE BOUNDS:
--   The ENTIRE scenario - every planted pod_inventory row, every tap, every
--   acknowledge, every probe - runs inside ONE deliberately rolled-back
--   subtransaction. PL/pgSQL variables survive the rollback, so the evidence is
--   kept while the writes are not. This fixture leaves ZERO rows behind, which is
--   stricter than fixture 112 (which plants durable rows on its synthetic date)
--   and is required here: a permanently planted Active, stock-bearing
--   pod_inventory row would feed v_machine_expiry_summary and the refill engine
--   with fiction on a real machine.
--
-- The fixture must be able to go RED. Seq 14-17 and 24 are the tripwires.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, scenario_sql, notes)
VALUES (
  114,
  'PRD-114: the dispatch list grows a final "Sanity checks - expired products" category. The read RPC returns EVERY stock-bearing batch inside the 7-day window at BATCH grain - including two siblings on one shelf that the canonical expiry view collapses, which is the whole reason it is allowed to read pod_inventory directly. The driver dispositions each row and one day_close_events row per batch is written, updated in place on a re-tap, never duplicated. No stock moves on a tap. CS acknowledge is what archives: Remove -> expired_writeoff, Sold -> sold_through_<date>, Exists/Skip -> nothing. A second acknowledge writes nothing. Warehouse is untouched by all four.',
  'PRD-114 s1, CS 2026-08-12: "the refill plan tells the driver what to PUT IN; nothing tells him what to CHECK". Live fleet at the time: 14 batches inside the window across 6 machines, 5 of them already expired, none of them surfaced anywhere in dispatching.',
  'P0',
  '2030-04-25',
  true,
  'passing',
$fx$
DO $do$
DECLARE
  v_fx        int  := 114;
  v_date      date := {{plan_date}};
  v_today     date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_machine   uuid := '148c4fcf-b794-43f0-a2a8-e6f17605b045';
  v_driver    uuid := 'bddaec3c-fe18-40db-93e4-8ca543819519';
  v_cs        uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  v_shelf_a   uuid := '40d794c6-fa25-4e9f-afe2-fb267bf443e8';
  v_shelf_b   uuid := '3f881ec7-350e-4745-9731-64612c5cfc37';
  v_shelf_c   uuid := '8ca35afb-6daa-45e6-bc77-ff28d148c567';
  v_shelf_d   uuid := '48907909-7b0c-438b-8183-95ceaf1b4b81';
  v_dark      uuid := 'e475225d-b69a-45ce-8191-6482adf4d64e';
  v_hazel     uuid := '432ab931-10bb-45fb-8186-420f153905ec';
  v_coconut   uuid := '6d1b2a6b-28ea-402b-9e19-1f658eb17766';
  v_nostock   uuid := '0a9016bc-5755-4dc8-82f8-79a3e911ab6f';
  v_b1 uuid; v_b2 uuid; v_b3 uuid; v_b4 uuid; v_b5 uuid; v_b6 uuid;
  r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; r4b jsonb;
  a1 jsonb; a1b jsonb; a2 jsonb; a3 jsonb; a4 jsonb;
  v_n_rows int := -1; v_n_expired int := -1; v_n_expiring int := -1;
  v_n_a01  int := -1; v_b6_in int := -1; v_red_before_amber boolean := false;
  v_b1_after text := 'NOT_READ'; v_b2_after text := 'NOT_READ'; v_b3_after text := 'NOT_READ';
  v_wh_before text := 'NOT_READ'; v_wh_after text := 'NOT_READ';
  v_residue   text := 'NOT_READ';
  v_probe_expired text := 'NOT_RUN';
  v_probe_locked  text := 'NOT_RUN';
  v_probe_anon    text := 'NOT_RUN';
  v_probe_closed  text := 'NOT_RUN';
  v_probe_dup     text := 'NOT_RUN';
  v_fatal     text := NULL;
BEGIN
  BEGIN
    -- plant. app.via_rpc satisfies trg_block_direct_pod_inventory_insert for the
    -- HARNESS; it is cleared immediately so every RPC under test has to satisfy
    -- the guard on its OWN name rather than on a leaked one.
    PERFORM set_config('app.via_rpc', 'true', true);

    INSERT INTO public.pod_inventory
      (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, status)
    VALUES (v_machine, v_shelf_a, v_dark, v_today, 4, v_today - 30, 'Active')
    RETURNING pod_inventory_id INTO v_b1;   -- RED, dispositioned Remove

    INSERT INTO public.pod_inventory
      (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, status)
    VALUES (v_machine, v_shelf_b, v_hazel, v_today, 3, v_today - 5, 'Active')
    RETURNING pod_inventory_id INTO v_b2;   -- RED, dispositioned Sold

    INSERT INTO public.pod_inventory
      (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, status)
    VALUES (v_machine, v_shelf_c, v_coconut, v_today, 6, v_today + 3, 'Active')
    RETURNING pod_inventory_id INTO v_b3;   -- AMBER, dispositioned Exists

    INSERT INTO public.pod_inventory
      (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, status)
    VALUES (v_machine, v_shelf_d, v_nostock, v_today, 2, v_today + 7, 'Active')
    RETURNING pod_inventory_id INTO v_b4;   -- AMBER (boundary day), Exists -> re-tapped to Skip

    -- THE SIBLING. Same machine, same shelf, same product as v_b1, different
    -- batch. v_machine_expiry_batches dedupes (machine, shelf, product) and MINs
    -- the expiry, so it publishes ONE of these two. The driver has to put his
    -- hands on BOTH. This row is the entire justification for Cody C-1.
    INSERT INTO public.pod_inventory
      (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, status)
    VALUES (v_machine, v_shelf_a, v_dark, v_today, 5, v_today + 2, 'Active')
    RETURNING pod_inventory_id INTO v_b5;

    -- outside the window: must never appear on the checklist
    INSERT INTO public.pod_inventory
      (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, status)
    VALUES (v_machine, v_shelf_d, v_coconut, v_today, 9, v_today + 30, 'Active')
    RETURNING pod_inventory_id INTO v_b6;

    PERFORM set_config('app.via_rpc',  '', true);
    PERFORM set_config('app.rpc_name', '', true);

    SELECT md5(string_agg(wi.wh_inventory_id::text || '|' || COALESCE(wi.status,'') || '|' ||
                          COALESCE(wi.warehouse_stock::text,''), ',' ORDER BY wi.wh_inventory_id))
      INTO v_wh_before FROM public.warehouse_inventory wi;

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_driver, 'role', 'authenticated')::text, true);

    SELECT count(*),
           count(*) FILTER (WHERE s.severity = 'expired'),
           count(*) FILTER (WHERE s.severity = 'expiring'),
           count(*) FILTER (WHERE s.pod_inventory_id IN (v_b1, v_b5)),
           count(*) FILTER (WHERE s.pod_inventory_id = v_b6)
      INTO v_n_rows, v_n_expired, v_n_expiring, v_n_a01, v_b6_in
    FROM public.get_expiry_sanity_checks(v_machine) s
    WHERE s.pod_inventory_id IN (v_b1, v_b2, v_b3, v_b4, v_b5, v_b6);

    -- Expired-first ordering, asserted as the CONTRACT rather than as "row 1 is
    -- v_b1": every red row must sort above every amber row. Stated this way it is
    -- deterministic even when the machine also carries live candidates, which is
    -- the drift that re-reds fixtures 42/46/74 every few days.
    SELECT COALESCE(max(q.rn) FILTER (WHERE q.severity = 'expired'), 0)
         < COALESCE(min(q.rn) FILTER (WHERE q.severity = 'expiring'), 2147483647)
      INTO v_red_before_amber
    FROM (SELECT s.severity, row_number() OVER () AS rn
            FROM public.get_expiry_sanity_checks(v_machine) s) q;

    r1  := public.record_expiry_check(v_b1, 'remove', v_date);
    r2  := public.record_expiry_check(v_b2, 'sold',   v_date);
    r3  := public.record_expiry_check(v_b3, 'exists', v_date);
    r4  := public.record_expiry_check(v_b4, 'exists', v_date);
    r4b := public.record_expiry_check(v_b4, 'skip',   v_date);  -- re-tap, same event

    -- C-2: the writer must leave the transaction GUCs as it found them.
    v_residue := COALESCE(NULLIF(current_setting('app.via_rpc', true), ''), 'UNSET');

    -- TRIPWIRE: an EXPIRED batch cannot be dispositioned "exists"
    BEGIN
      PERFORM public.record_expiry_check(v_b1, 'exists', v_date);
      v_probe_expired := 'NOT_BLOCKED';
    EXCEPTION WHEN OTHERS THEN v_probe_expired := SQLERRM; END;

    -- TRIPWIRE: anonymous is refused BY NAME, not short-circuited
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM public.record_expiry_check(v_b3, 'skip', v_date);
      v_probe_anon := 'NOT_BLOCKED';
    EXCEPTION WHEN OTHERS THEN v_probe_anon := SQLERRM; END;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_driver, 'role', 'authenticated')::text, true);

    -- TRIPWIRE: a closed day cannot be checked
    BEGIN
      PERFORM public.record_expiry_check(v_b3, 'skip', DATE '2020-01-01');
      v_probe_closed := 'NOT_BLOCKED';
    EXCEPTION WHEN OTHERS THEN v_probe_closed := SQLERRM; END;

    -- TRIPWIRE: the partial unique index refuses a second event for the same
    -- batch on the same date, so "one row per batch" is a guarantee rather than
    -- an intention (acceptance 2).
    BEGIN
      INSERT INTO public.day_close_events (event_date, machine_id, kind, payload, created_by)
      VALUES (v_date, v_machine, 'expiry_check',
              jsonb_build_object('pod_inventory_id', v_b1, 'outcome', 'remove'), v_cs);
      v_probe_dup := 'NOT_BLOCKED';
    EXCEPTION WHEN OTHERS THEN v_probe_dup := SQLERRM; END;

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_cs, 'role', 'authenticated')::text, true);

    a1  := public.acknowledge_day_close_event((r1->>'event_id')::uuid,  'golden 114 remove');
    a1b := public.acknowledge_day_close_event((r1->>'event_id')::uuid,  'golden 114 remove again');
    a2  := public.acknowledge_day_close_event((r2->>'event_id')::uuid,  'golden 114 sold');
    a3  := public.acknowledge_day_close_event((r3->>'event_id')::uuid,  'golden 114 exists');
    a4  := public.acknowledge_day_close_event((r4b->>'event_id')::uuid, 'golden 114 skip');

    SELECT status || '/' || COALESCE(removal_reason,'-') || '/' || COALESCE(current_stock::text,'-')
      INTO v_b1_after FROM public.pod_inventory WHERE pod_inventory_id = v_b1;
    SELECT status || '/' || COALESCE(removal_reason,'-') || '/' || COALESCE(current_stock::text,'-')
      INTO v_b2_after FROM public.pod_inventory WHERE pod_inventory_id = v_b2;
    SELECT status || '/' || COALESCE(removal_reason,'-') || '/' || COALESCE(current_stock::text,'-')
      INTO v_b3_after FROM public.pod_inventory WHERE pod_inventory_id = v_b3;

    -- TRIPWIRE: an acknowledged check is LOCKED against a further re-tap
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_driver, 'role', 'authenticated')::text, true);
    BEGIN
      PERFORM public.record_expiry_check(v_b3, 'sold', v_date);
      v_probe_locked := 'NOT_BLOCKED';
    EXCEPTION WHEN OTHERS THEN v_probe_locked := SQLERRM; END;

    -- Article 6 (Cody C-3): a FINGERPRINT, not a row count. A count survives a
    -- status flip; an md5 over status + stock does not.
    SELECT md5(string_agg(wi.wh_inventory_id::text || '|' || COALESCE(wi.status,'') || '|' ||
                          COALESCE(wi.warehouse_stock::text,''), ',' ORDER BY wi.wh_inventory_id))
      INTO v_wh_after FROM public.warehouse_inventory wi;

    RAISE EXCEPTION 'GOLDEN114_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'GOLDEN114_ROLLBACK' THEN v_fatal := SQLERRM; END IF;
  END;

  DELETE FROM golden.scratch WHERE fixture_id = v_fx;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (v_fx, 'fatal',   jsonb_build_object('err', COALESCE(v_fatal, 'NONE'))),
    (v_fx, 'read',    jsonb_build_object('n_rows', v_n_rows, 'n_expired', v_n_expired,
                                         'n_expiring', v_n_expiring, 'n_a01', v_n_a01,
                                         'b6_in_window', v_b6_in, 'red_before_amber', v_red_before_amber)),
    (v_fx, 'taps',    jsonb_build_object('remove', COALESCE(r1,'null'::jsonb),
                                         'sold',   COALESCE(r2,'null'::jsonb),
                                         'exists', COALESCE(r3,'null'::jsonb),
                                         'retap',  COALESCE(r4b,'null'::jsonb),
                                         'retap_same_event',
                                           COALESCE((r4->>'event_id') = (r4b->>'event_id'), false))),
    (v_fx, 'acks',    jsonb_build_object('remove', COALESCE(a1,'null'::jsonb),
                                         'remove_again', COALESCE(a1b,'null'::jsonb),
                                         'sold',   COALESCE(a2,'null'::jsonb),
                                         'exists', COALESCE(a3,'null'::jsonb),
                                         'skip',   COALESCE(a4,'null'::jsonb))),
    (v_fx, 'pod',     jsonb_build_object('b1', v_b1_after, 'b2', v_b2_after, 'b3', v_b3_after)),
    (v_fx, 'wh',      jsonb_build_object('before', v_wh_before, 'after', v_wh_after,
                                         'unchanged', v_wh_before = v_wh_after)),
    (v_fx, 'residue', jsonb_build_object('via_rpc_after_writer', v_residue)),
    (v_fx, 'probes',  jsonb_build_object('expired_exists', v_probe_expired,
                                         'locked_retap',   v_probe_locked,
                                         'anon',           v_probe_anon,
                                         'closed_day',     v_probe_closed,
                                         'duplicate_event', v_probe_dup));

  -- residue hygiene: run_all is ONE transaction and these GUCs are
  -- transaction-local, so a fixture that walks away with via_rpc set disarms the
  -- canonical-writer guard for whatever runs next (the S-197 class).
  PERFORM set_config('app.via_rpc',  '', true);
  PERFORM set_config('app.rpc_name', '', true);
  PERFORM set_config('request.jwt.claims', '', true);
END
$do$;
$fx$,
  'PRD-114 acceptance 1-4. The ENTIRE scenario runs inside one deliberately rolled-back subtransaction: this fixture leaves zero rows in pod_inventory and zero in day_close_events. expiration_date is anchored to the REAL Dubai clock (the 7-day window is), event_date to the synthetic 2030 date (so no live Day Close is touched). Seq 14-17 and 24 are the tripwires; seq 18-21 are Cody conditions C-3, C-5 and C-2.'
)
ON CONFLICT (fixture_id) DO UPDATE
  SET name = EXCLUDED.name, source_incident = EXCLUDED.source_incident,
      phase_required = EXCLUDED.phase_required, plan_date = EXCLUDED.plan_date,
      enabled = EXCLUDED.enabled, baseline_status = EXCLUDED.baseline_status,
      scenario_sql = EXCLUDED.scenario_sql, notes = EXCLUDED.notes;


DELETE FROM golden.assertions WHERE fixture_id = 114;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(114, 0, 'The scenario ran to its deliberate rollback and not into a real error - without this, every count below could read 0 and be mistaken for green',
 $a$SELECT value->>'err' FROM golden.scratch WHERE fixture_id=114 AND key='fatal'$a$, 'eq', 'NONE', true, 'P0'),

(114, 1, 'The checklist returns every planted batch inside the 7-day window and nothing else (acceptance 1)',
 $a$SELECT value->>'n_rows' FROM golden.scratch WHERE fixture_id=114 AND key='read'$a$, 'eq', '5', true, 'P0'),

(114, 2, 'Two batches are past expiry and are classified RED',
 $a$SELECT value->>'n_expired' FROM golden.scratch WHERE fixture_id=114 AND key='read'$a$, 'eq', '2', true, 'P0'),

(114, 3, 'Three batches are inside today..today+7 and are classified AMBER - a batch expiring on day 7 is still amber, not red',
 $a$SELECT value->>'n_expiring' FROM golden.scratch WHERE fixture_id=114 AND key='read'$a$, 'eq', '3', true, 'P0'),

(114, 4, 'GRAIN (Cody C-1): BOTH batches of the same product on the same shelf are listed. v_machine_expiry_batches dedupes (machine, shelf, product) and MINs the expiry, so building this on the canonical view would silently drop a physical pack the driver has to pick up. This assertion is why the direct pod_inventory read is granted.',
 $a$SELECT value->>'n_a01' FROM golden.scratch WHERE fixture_id=114 AND key='read'$a$, 'eq', '2', true, 'P0'),

(114, 5, 'A batch expiring in 30 days is NOT on the checklist - the window is a filter, not decoration',
 $a$SELECT value->>'b6_in_window' FROM golden.scratch WHERE fixture_id=114 AND key='read'$a$, 'eq', '0', true, 'P0'),

(114, 6, 'Every RED row sorts above every AMBER row, so the driver clears what is already expired before what is about to be',
 $a$SELECT value->>'red_before_amber' FROM golden.scratch WHERE fixture_id=114 AND key='read'$a$, 'eq', 'true', true, 'P0'),

(114, 7, 'A Remove tap on a red row is accepted and severity is decided by the BACKEND, not the client',
 $a$SELECT (value->'remove'->>'ok') || '/' || (value->'remove'->>'severity')
     FROM golden.scratch WHERE fixture_id=114 AND key='taps'$a$, 'eq', 'true/expired', true, 'P0'),

(114, 8, 'A Sold tap on a red row is accepted - Sold and Remove are the only two dispositions a red row offers',
 $a$SELECT (value->'sold'->>'ok') || '/' || (value->'sold'->>'severity')
     FROM golden.scratch WHERE fixture_id=114 AND key='taps'$a$, 'eq', 'true/expired', true, 'P0'),

(114, 9, 'An Exists tap is only ever offered on amber, and is accepted there',
 $a$SELECT (value->'exists'->>'ok') || '/' || (value->'exists'->>'severity')
     FROM golden.scratch WHERE fixture_id=114 AND key='taps'$a$, 'eq', 'true/expiring', true, 'P0'),

(114, 10, 'Re-tapping a row before acknowledge UPDATES the same event - it never writes a second one (acceptance 2)',
 $a$SELECT (value->>'retap_same_event') || '/' || (value->'retap'->>'updated')
     FROM golden.scratch WHERE fixture_id=114 AND key='taps'$a$, 'eq', 'true/true', true, 'P0'),

(114, 11, 'Acknowledge of a Remove archives the batch through the EXISTING write-off path (acceptance 3)',
 $a$SELECT (value->'remove'->>'pod_action') FROM golden.scratch WHERE fixture_id=114 AND key='acks'$a$,
 'eq', 'expired_writeoff', true, 'P0'),

(114, 12, 'The archived batch is Inactive, zeroed, and carries removal_reason expired_writeoff exactly as the PRD words it',
 $a$SELECT value->>'b1' FROM golden.scratch WHERE fixture_id=114 AND key='pod'$a$,
 'eq', 'Inactive/expired_writeoff/0', true, 'P0'),

(114, 13, 'Acknowledge of a Sold closes the batch as sold-through, dated, with no warehouse leg',
 $a$SELECT value->>'b2' FROM golden.scratch WHERE fixture_id=114 AND key='pod'$a$,
 'eq', 'Inactive/sold_through_2030-04-25/0', true, 'P0'),

(114, 14, 'TRIPWIRE: an EXPIRED batch cannot be dispositioned "exists" - it cannot stay on the shelf, and the rule lives in SQL rather than in which chips the FE renders',
 $a$SELECT value->>'expired_exists' FROM golden.scratch WHERE fixture_id=114 AND key='probes'$a$,
 'contains', 'takes sold or remove only', true, 'P0'),

(114, 15, 'TRIPWIRE: once CS has acknowledged a check the driver can no longer re-tap it',
 $a$SELECT value->>'locked_retap' FROM golden.scratch WHERE fixture_id=114 AND key='probes'$a$,
 'contains', 'is locked', true, 'P0'),

(114, 16, 'TRIPWIRE: anonymous is refused BY NAME, not short-circuited past the role gate (D-41/D-42 class)',
 $a$SELECT value->>'anon' FROM golden.scratch WHERE fixture_id=114 AND key='probes'$a$,
 'contains', 'anonymous caller refused', true, 'P0'),

(114, 17, 'TRIPWIRE: a closed day cannot be checked - settled history stays settled',
 $a$SELECT value->>'closed_day' FROM golden.scratch WHERE fixture_id=114 AND key='probes'$a$,
 'contains', 'a closed day cannot be checked', true, 'P0'),

(114, 18, 'ARTICLE 6 (Cody C-3): warehouse_inventory is FINGERPRINT-identical across all four acknowledge outcomes. A row count survives a status flip; an md5 over status + warehouse_stock does not. Nothing here credits the warehouse - an expired shelf batch never goes back, and a sold one was already revenue.',
 $a$SELECT value->>'unchanged' FROM golden.scratch WHERE fixture_id=114 AND key='wh'$a$,
 'eq', 'true', true, 'P0'),

(114, 19, 'ACL (Cody C-5): neither new function is executable by anon or PUBLIC. A new function is born EXECUTE-to-PUBLIC, so this is a control, not a formality.',
 $a$SELECT count(*)::text FROM pg_proc p
    WHERE p.proname IN ('get_expiry_sanity_checks','record_expiry_check')
      AND (has_function_privilege('anon', p.oid, 'EXECUTE')
           OR EXISTS (SELECT 1 FROM unnest(COALESCE(p.proacl, ARRAY[]::aclitem[])) a
                       WHERE a::text LIKE '=%'))$a$,
 'eq', '0', true, 'P0'),

(114, 20, 'ACL (Cody C-5): day_close_events remains unwritable by authenticated, so the FE cannot forge a disposition around record_expiry_check (Article 3 / S-308)',
 $a$SELECT count(*)::text FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name='day_close_events'
      AND grantee='authenticated' AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')$a$,
 'eq', '0', true, 'P0'),

(114, 21, 'RESIDUE (Cody C-2): record_expiry_check leaves app.via_rpc UNSET. It is a LEAF writer - it clears the GUCs on exit, which is correct at top level and would disarm a caller''s guard mid-transaction if anything ever called it as a delegate (S-160 / S-197).',
 $a$SELECT value->>'via_rpc_after_writer' FROM golden.scratch WHERE fixture_id=114 AND key='residue'$a$,
 'eq', 'UNSET', true, 'P0'),

(114, 22, 'Exists and Skip write NO stock: the amber batch is still Active with its units intact after acknowledge (acceptance 3)',
 $a$SELECT (SELECT value->'exists'->>'pod_action' FROM golden.scratch WHERE fixture_id=114 AND key='acks')
        || '/' || (SELECT value->'skip'->>'pod_action' FROM golden.scratch WHERE fixture_id=114 AND key='acks')
        || '/' || (SELECT value->>'b3' FROM golden.scratch WHERE fixture_id=114 AND key='pod')$a$,
 'eq', 'verified_no_write/skipped_no_write/Active/-/6', true, 'P0'),

(114, 23, 'A second acknowledge is idempotent: it reports the first one and writes no second archival (acceptance 3)',
 $a$SELECT (value->'remove_again'->>'already_acknowledged') FROM golden.scratch WHERE fixture_id=114 AND key='acks'$a$,
 'eq', 'true', true, 'P0'),

(114, 24, 'TRIPWIRE: the partial unique index refuses a second expiry_check event for the same batch on the same date. "One event per row" is a guarantee, not an intention - two concurrent taps cannot both insert (acceptance 2).',
 $a$SELECT value->>'duplicate_event' FROM golden.scratch WHERE fixture_id=114 AND key='probes'$a$,
 'contains', 'day_close_events_expiry_check_uniq', true, 'P0'),

(114, 25, 'The kind vocabulary admits expiry_check and the day_close_events shape is otherwise unchanged (v3-compatible)',
 $a$SELECT pg_get_constraintdef(oid) FROM pg_constraint
    WHERE conrelid='public.day_close_events'::regclass AND conname='day_close_events_kind_chk'$a$,
 'contains', 'expiry_check', true, 'P0');
