-- PRD-115 acceptance 5 - golden fixture 115.
--
-- "A plan edit during a pack is safe: what the operator removes stays removed, and
--  a machine can never read 'already packed' and 'N to resolve' at the same time."
--
-- golden.render derives the fixture date as DATE '2030-01-01' + fixture_id, so
-- fixture 115 runs on 2030-04-26. No other fixture uses that date. It reuses the
-- WH3_1035_0000_W0 cast fixture 9 established (shelves A01/A02 carry zero
-- pod_inventory rows, and v_shelf_slot_identity has no WEIMI row for that machine,
-- so assert_weimi_slot_match returns weimi_unresolved as INFO rather than blocking
-- the planted lines - weimi_slot_guard is live in 'block' mode and would otherwise
-- reject them and make every leg below vacuous).
--
-- ⛔ THE RED IS MEASURED, NOT ASSUMED. Before writing these assertions the exact
-- scenario was run against the PRE-FIX bodies (the tombstone-less
-- remove_dispatch_row, and push v11 reconstructed from v12 by reverse-splice and
-- verified against md5 5f858899eecef1e75e6ae6d00fcc1c8b), inside a rolled-back
-- subtransaction. Pre-fix it reads a01_live=1 / a01_total=2 and the tombstoned row
-- reads 'approved'; post-fix it reads a01_live=0 / a01_total=1 and 'rejected'.
-- Seq 10, 11 and 17 are the tripwires that separate them.
--
-- THE VECTOR THE TRIPWIRE CATCHES IS NOT THE OBVIOUS ONE. A removed row's plan row
-- keeps dispatched=true, so a plain re-push already skipped it and a naive fixture
-- would be green on a broken build. The live resurrection runs through
-- reset_approved_undispatched, which flips every 'approved' plan row for the
-- machine back to 'pending' AND NULLs dispatch_id, after which the next
-- approve_refill_plan wave pushes it fresh with no tombstone key left to check.
-- That is why the tripwire sits AFTER a reset + repack + third approve wave and
-- not immediately after the removal.
--
-- POSITIVE CONTROLS. Every "did not come back" assertion is paired with an A02 line
-- that DID come through the same wave (seq 7, seq 12). Without them "0 rows
-- created" is equally consistent with a push that did nothing at all.
--
-- PRODUCTION WRITE BOUNDS: the entire scenario runs inside ONE deliberately
-- rolled-back subtransaction. PL/pgSQL variables survive the rollback, so the
-- evidence is kept while the writes are not. Zero rows are left on 2030-04-26.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, scenario_sql, notes)
VALUES (
  115,
  'PRD-115: a plan edit mid-pack is safe. Removing a dispatch row TOMBSTONES its refill_plan_output parent in the same transaction (operator_status=rejected + a removed_at_dispatch_by stamp), so the row stays removed through a second approve wave, through reset_approved_undispatched, through repack_machine and through a THIRD approve wave - the exact chain that resurrected it live, because reset_approved_undispatched flips approved plan rows back to pending and NULLs dispatch_id. Both halves are proven independently: forcing the tombstoned row back to approved by raw UPDATE still yields lines_pushed=0 and lines_tombstoned=1, because push v12 reads the append-only remove edit-log entry rather than the mutable status. Paired positive controls prove each wave really pushed. Separately, a FINAL confirm that no longer closes reads needs_reconfirm rather than completed, confirm_machine_packed refuses the same state, and "already packed" + "N to resolve" is unrepresentable fleet-wide.',
  'PRD-115 §1, CS 2026-08-14 ~14:27, NISSAN-0804-0000-L0: CS re-scoped shelf A15 three times (Al Ain -> Coke Zero -> Dubai Popcorn -> Hunter) while the packer was packing. Removed Dubai Popcorn came back twice. Ops hand-set two refill_plan_output rows to rejected to stop it, then hand-closed a line and re-ran confirm_machine_packed from SQL because the machine showed BOTH "already packed for 2026-08-14" AND "Finish - 1 to resolve".',
  'P0',
  '2030-04-26',
  true,
  'passing',
$fx$
DO $do$
DECLARE
  -- fixed cast, re-probed live this leg (LAW 13). Shared with fixture 9, which
  -- runs on 2030-07-20/21 - no date overlap, so S-188
  -- (prevent_duplicate_unstarted_dispatch) cannot fire across the two.
  c_mach   uuid := '98868de9-a977-40f4-b0ea-ce787877f24a';
  c_mname  text := 'WH3_1035_0000_W0';
  c_s1     uuid := '54051154-e5f6-4f9b-9bbe-add09d88875d';  -- A01, the re-scoped shelf
  c_s2     uuid := '483e5bb4-3b12-463c-a6d0-2232818446fe';  -- A02, the positive control
  c_pA     uuid := '00103662-15c4-47c8-9a32-26d421fa9827';  -- NRJ Nut - Trail Mix
  c_pB     uuid := '8442c7aa-7c41-425e-9b0f-f2d5a3eb87c3';  -- NRJ Nut - Cashew Sesame
  -- S-195: BOTH pod_product_id AND pod_product_name, or push silently drops the
  -- line as lines_skipped_null_product and every leg below measures nothing.
  c_pp     uuid := '9eb1e4f1-a47d-4bda-9090-bf0e13d1d8b9';
  c_admin  uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';  -- operator_admin

  v_date   date := {{plan_date}};
  v_rpo1 uuid; v_rpo2 uuid; v_d1 uuid; v_d2 uuid;
  v_appr2 jsonb; v_appr3 jsonb; v_rm jsonb; v_push jsonb;
  v_reset jsonb; v_repack jsonb; v_cf1 jsonb; v_cf2 jsonb; v_cf3 jsonb;
  v_wh_before text := 'NOT_READ'; v_wh_after text := 'NOT_READ';
  v_audit_n int := -1;
  s_tomb jsonb; s_resurr jsonb; s_trip jsonb; s_reapp jsonb; s_guard jsonb; s_pack jsonb;
  v_fatal  text := 'NONE';
BEGIN
  PERFORM set_config('app.rpc_name', 'golden.fixture_115', true);
  DELETE FROM golden.scratch WHERE fixture_id = 115;

  -- Article 6 control (Cody C-6). A FINGERPRINT, not a row count: a count survives
  -- a status flip, and nothing in this scenario may touch the warehouse at all.
  SELECT md5(string_agg(wi.wh_inventory_id::text || '|' || COALESCE(wi.status,'') || '|' ||
                        COALESCE(wi.warehouse_stock::text,''), ',' ORDER BY wi.wh_inventory_id))
    INTO v_wh_before FROM public.warehouse_inventory wi;

  BEGIN
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_admin), true);

    -------------------------------------------------------------- 1. PLANT ---
    -- app.via_trigger for the PLANT only, then cleared immediately, so every RPC
    -- under test has to satisfy its guards on its own name and not on a leaked one.
    PERFORM set_config('app.via_trigger','true',true);
    INSERT INTO public.refill_plan_output
      (plan_date, machine_name, machine_id, shelf_id, shelf_code, boonz_product_id,
       pod_product_id, pod_product_name, boonz_product_name, action, quantity,
       operator_status, dispatched)
    VALUES (v_date, c_mname, c_mach, c_s1, 'A01', c_pA, c_pp, 'NRJ Nut',
       (SELECT boonz_product_name FROM public.boonz_products WHERE product_id=c_pA),
       'Refill', 2, 'pending', false)
    RETURNING id INTO v_rpo1;
    PERFORM set_config('app.via_trigger','',true);

    -- approve fires trg_refill_plan_output_approve_to_dispatch -> push (THE writer)
    PERFORM public.approve_refill_plan(v_date, ARRAY[c_mname]);
    SELECT dispatch_id INTO v_d1 FROM public.refill_plan_output WHERE id = v_rpo1;

    -------------------------------------------- 2. THE REMOVAL (§2.1) --------
    v_rm := public.remove_dispatch_row(v_d1, 'operator_admin',
              'FX115 shelf A01 re-scoped mid-pack');
    SELECT count(*) INTO v_audit_n FROM public.write_audit_log w
     WHERE w.table_name = 'refill_plan_output'
       AND w.rpc_name   = 'remove_dispatch_row'
       AND w.row_pk     = v_rpo1::text;

    s_tomb := jsonb_build_object(
      'tombstoned',  v_rm->>'plan_rows_tombstoned',
      'rpo_status',  (SELECT operator_status FROM public.refill_plan_output WHERE id=v_rpo1),
      'stamp',       (SELECT operator_comment LIKE 'removed_at_dispatch_by %'
                        FROM public.refill_plan_output WHERE id=v_rpo1),
      'rd_include',  (SELECT include FROM public.refill_dispatching WHERE dispatch_id=v_d1),
      'audit_n',     v_audit_n);

    ------------------- 3. THE SECOND APPROVE WAVE + POSITIVE CONTROL ---------
    -- A02 is a genuinely NEW pending line. It must come through; without it,
    -- "A01 did not come back" is equally consistent with a push that did nothing.
    PERFORM set_config('app.via_trigger','true',true);
    INSERT INTO public.refill_plan_output
      (plan_date, machine_name, machine_id, shelf_id, shelf_code, boonz_product_id,
       pod_product_id, pod_product_name, boonz_product_name, action, quantity,
       operator_status, dispatched)
    VALUES (v_date, c_mname, c_mach, c_s2, 'A02', c_pB, c_pp, 'NRJ Nut',
       (SELECT boonz_product_name FROM public.boonz_products WHERE product_id=c_pB),
       'Refill', 3, 'pending', false)
    RETURNING id INTO v_rpo2;
    PERFORM set_config('app.via_trigger','',true);

    v_appr2 := public.approve_refill_plan(v_date, ARRAY[c_mname]);
    PERFORM public.push_plan_to_dispatch(v_date, c_mname);   -- the manual re-push too

    s_resurr := jsonb_build_object(
      'appr2',       v_appr2->>'status',
      'a01_live',    (SELECT count(*)::int FROM public.refill_dispatching
                       WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s1
                         AND COALESCE(include,true)),
      'a01_total',   (SELECT count(*)::int FROM public.refill_dispatching
                       WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s1),
      'a02_live',    (SELECT count(*)::int FROM public.refill_dispatching
                       WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s2
                         AND COALESCE(include,true)),
      'rpo1_status', (SELECT operator_status FROM public.refill_plan_output WHERE id=v_rpo1));

    --------------------------------- 4. CODY C-2 TRIPWIRES -------------------
    -- The tombstone's durability rests on these two writers never reaching a
    -- 'rejected' row. reset_approved_undispatched is the sharper edge: it also
    -- NULLs dispatch_id, which is the ONLY key the §2.2 guard has.
    v_reset  := public.reset_approved_undispatched(v_date, ARRAY[c_mach],
                  'FX115 tripwire reset approved undispatched');
    v_repack := public.repack_machine(c_mname, v_date, 'FX115 tripwire repack machine');
    s_trip := jsonb_build_object(
      'reset_status',          v_reset->>'status',
      'repack_status',         v_repack->>'status',
      'rpo1_status_after',     (SELECT operator_status FROM public.refill_plan_output WHERE id=v_rpo1),
      'rpo1_dispatch_id_kept', (SELECT dispatch_id IS NOT NULL FROM public.refill_plan_output WHERE id=v_rpo1));

    ------------------------ 5. THE THIRD WAVE - THE ACTUAL LIVE VECTOR -------
    -- reset_approved_undispatched has just put every APPROVED row back to
    -- 'pending'. Pre-fix the tombstoned row was one of them, and THIS approve is
    -- what re-created it (a01_live 0 -> 1, a01_total 1 -> 2). Post-fix it is
    -- 'rejected', so the reset never saw it and this wave cannot revive it.
    v_appr3 := public.approve_refill_plan(v_date, ARRAY[c_mname]);
    s_reapp := jsonb_build_object(
      'appr3',       v_appr3->>'status',
      'rpo1_status', (SELECT operator_status FROM public.refill_plan_output WHERE id=v_rpo1),
      'a01_live',    (SELECT count(*)::int FROM public.refill_dispatching
                       WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s1
                         AND COALESCE(include,true)),
      'a01_total',   (SELECT count(*)::int FROM public.refill_dispatching
                       WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s1),
      'a02_live',    (SELECT count(*)::int FROM public.refill_dispatching
                       WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s2
                         AND COALESCE(include,true)));

    --------------------------- 6. §2.2 ON ITS OWN (belt, without braces) -----
    -- Force the status back to 'approved' by RAW UPDATE - the thing any widened
    -- WHERE clause or hand-run fix would do. This fires the approve trigger, so
    -- push runs twice here: once from the trigger, once explicitly for the count.
    UPDATE public.refill_plan_output
       SET operator_status='approved', dispatched=false WHERE id=v_rpo1;
    v_push := public.push_plan_to_dispatch(v_date, c_mname);
    s_guard := jsonb_build_object(
      'tombstoned', v_push->>'lines_tombstoned',
      'pushed',     v_push->>'lines_pushed',
      'version',    v_push->>'rpc_version',
      'a01_live',   (SELECT count(*)::int FROM public.refill_dispatching
                      WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s1
                        AND COALESCE(include,true)));

    ------------------------------- 7. §2.3 needs_reconfirm -------------------
    SELECT dispatch_id INTO v_d2 FROM public.refill_dispatching
     WHERE dispatch_date=v_date AND machine_id=c_mach AND shelf_id=c_s2
       AND COALESCE(include,true) LIMIT 1;

    -- S-194: packed=true DEMANDS pack_outcome in the SAME statement, and the
    -- promotion must be an UPDATE (trg_conserve_split_qty is BEFORE INSERT).
    PERFORM set_config('app.via_trigger','true',true);
    UPDATE public.refill_dispatching
       SET packed=true, pack_outcome='packed'::public.pack_outcome_enum WHERE dispatch_id=v_d2;
    PERFORM set_config('app.via_trigger','',true);
    v_cf1 := public.confirm_machine_packed(c_mname, v_date, NULL,
               'FX115 packing finished by the warehouse', true);

    -- the clean post-confirm state, read BEFORE anything drifts. Without this
    -- read taken here, seq 21 would measure the drifted state and pass vacuously.
    s_pack := jsonb_build_object(
      'cf1',         v_cf1->>'status',
      'state_first', (SELECT pack_state FROM public.v_machine_pack_status
                       WHERE machine_id=c_mach AND dispatch_date=v_date));

    -- ops unpack a line after the confirm - the incident, exactly
    PERFORM set_config('app.via_trigger','true',true);
    UPDATE public.refill_dispatching SET packed=false, pack_outcome=NULL WHERE dispatch_id=v_d2;
    PERFORM set_config('app.via_trigger','',true);

    -- the drifted state, read BEFORE anything tries to fix it
    s_pack := s_pack || jsonb_build_object(
      'state_mid',       (SELECT pack_state FROM public.v_machine_pack_status
                           WHERE machine_id=c_mach AND dispatch_date=v_date),
      'needs_mid',       (SELECT needs_reconfirm FROM public.v_machine_pack_status
                           WHERE machine_id=c_mach AND dispatch_date=v_date),
      'unresolved_mid',  (SELECT unresolved_n FROM public.v_machine_pack_status
                           WHERE machine_id=c_mach AND dispatch_date=v_date));

    -- the writer must refuse the same state the view names
    v_cf2 := public.confirm_machine_packed(c_mname, v_date, NULL,
               'FX115 finish attempt while a line is unpacked', true);

    -- finish the remaining line, then reconfirm: the state closes
    PERFORM set_config('app.via_trigger','true',true);
    UPDATE public.refill_dispatching
       SET packed=true, pack_outcome='packed'::public.pack_outcome_enum WHERE dispatch_id=v_d2;
    PERFORM set_config('app.via_trigger','',true);
    v_cf3 := public.confirm_machine_packed(c_mname, v_date, NULL,
               'FX115 reconfirm after the line was finished', true);

    s_pack := s_pack || jsonb_build_object(
      'cf2',              v_cf2->>'status',
      'cf3',              v_cf3->>'status',
      'state_final',      (SELECT pack_state FROM public.v_machine_pack_status
                            WHERE machine_id=c_mach AND dispatch_date=v_date),
      'needs_final',      (SELECT needs_reconfirm FROM public.v_machine_pack_status
                            WHERE machine_id=c_mach AND dispatch_date=v_date),
      'unresolved_final', (SELECT unresolved_n FROM public.v_machine_pack_status
                            WHERE machine_id=c_mach AND dispatch_date=v_date),
      -- FLEET-WIDE, not just this machine: the combination the incident produced
      -- must be unrepresentable everywhere, on live rows as well as planted ones.
      'impossible_pair',  (SELECT count(*)::int FROM public.v_machine_pack_status
                            WHERE pack_state='completed' AND unresolved_n > 0));

    ------------------------------------------------------------ 8. unwind ---
    RAISE EXCEPTION 'FX115_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FX115_ROLLBACK' THEN v_fatal := SQLERRM; END IF;
  END;

  PERFORM set_config('request.jwt.claims','',true);
  PERFORM set_config('app.via_trigger','',true);
  PERFORM set_config('app.via_rpc','',true);

  SELECT md5(string_agg(wi.wh_inventory_id::text || '|' || COALESCE(wi.status,'') || '|' ||
                        COALESCE(wi.warehouse_stock::text,''), ',' ORDER BY wi.wh_inventory_id))
    INTO v_wh_after FROM public.warehouse_inventory wi;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (115, 'fatal',  jsonb_build_object('err', v_fatal)),
    (115, 'tomb',   COALESCE(s_tomb,   '{}'::jsonb)),
    (115, 'resurr', COALESCE(s_resurr, '{}'::jsonb)),
    (115, 'trip',   COALESCE(s_trip,   '{}'::jsonb)),
    (115, 'reapp',  COALESCE(s_reapp,  '{}'::jsonb)),
    (115, 'guard',  COALESCE(s_guard,  '{}'::jsonb)),
    (115, 'pack',   COALESCE(s_pack,   '{}'::jsonb)),
    (115, 'wh',     jsonb_build_object('unchanged', v_wh_before = v_wh_after)),
    (115, 'residue', jsonb_build_object(
       'rpo', (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = v_date),
       'rd',  (SELECT count(*) FROM public.refill_dispatching WHERE dispatch_date = v_date),
       'cfm', (SELECT count(*) FROM public.dispatch_pack_confirmation WHERE dispatch_date = v_date)));
END
$do$;
$fx$,
  'PRD-115 acceptance 1, 2 and 5, plus Cody conditions C-2, C-3, C-4 and C-6. The whole scenario runs inside one deliberately rolled-back subtransaction and leaves zero rows on 2030-04-26. The RED was measured, not assumed: run against the pre-fix bodies (tombstone-less remove_dispatch_row + push v11 reconstructed by reverse-splice and md5-verified) it reads a01_live=1 / a01_total=2 / rpo1 approved. Seq 10, 11 and 17 are the tripwires. Seq 7 and 12 are the positive controls without which every "did not come back" assertion is vacuous.'
)
ON CONFLICT (fixture_id) DO UPDATE
  SET name = EXCLUDED.name, source_incident = EXCLUDED.source_incident,
      phase_required = EXCLUDED.phase_required, plan_date = EXCLUDED.plan_date,
      enabled = EXCLUDED.enabled, baseline_status = EXCLUDED.baseline_status,
      scenario_sql = EXCLUDED.scenario_sql, notes = EXCLUDED.notes;


DELETE FROM golden.assertions WHERE fixture_id = 115;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(115, 0, 'The scenario ran to its deliberate rollback and not into a real error - without this every count below could read 0 and be mistaken for green',
 $a$SELECT value->>'err' FROM golden.scratch WHERE fixture_id=115 AND key='fatal'$a$, 'eq', 'NONE', true, 'P0'),

(115, 1, 'ACCEPTANCE 1 (§2.1): removing a dispatch row tombstones its plan parent in the SAME call - the RPC reports exactly one plan row stamped',
 $a$SELECT value->>'tombstoned' FROM golden.scratch WHERE fixture_id=115 AND key='tomb'$a$, 'eq', '1', true, 'P0'),

(115, 2, 'The tombstoned plan row reads rejected. approved is what left it a live instruction for the next push (NISSAN-0804)',
 $a$SELECT value->>'rpo_status' FROM golden.scratch WHERE fixture_id=115 AND key='tomb'$a$, 'eq', 'rejected', true, 'P0'),

(115, 3, 'ACCEPTANCE 1: the removal stamp is on the row and is human-readable. It goes in operator_comment, never in comment - comment is engine-authored and rides onto the dispatch row',
 $a$SELECT value->>'stamp' FROM golden.scratch WHERE fixture_id=115 AND key='tomb'$a$, 'eq', 'true', true, 'P0'),

(115, 4, 'The dispatch row itself is still soft-removed (include=false), not deleted - the tombstone is additive, it did not change the removal semantics',
 $a$SELECT value->>'rd_include' FROM golden.scratch WHERE fixture_id=115 AND key='tomb'$a$, 'eq', 'false', true, 'P0'),

(115, 5, 'ARTICLE 8 (Cody C-3): the tombstone UPDATE mints exactly one write_audit_log row on refill_plan_output naming remove_dispatch_row. The table carrying an audit trigger is not proof the row lands',
 $a$SELECT value->>'audit_n' FROM golden.scratch WHERE fixture_id=115 AND key='tomb'$a$, 'eq', '1', true, 'P0'),

(115, 6, 'ACCEPTANCE 1: a second approve wave over the same machine does NOT re-create the removed row',
 $a$SELECT value->>'a01_live' FROM golden.scratch WHERE fixture_id=115 AND key='resurr'$a$, 'eq', '0', true, 'P0'),

(115, 7, 'POSITIVE CONTROL: that same wave DID push the genuinely new A02 line. Without this, "0 rows created" is equally consistent with a push that did nothing at all',
 $a$SELECT value->>'a02_live' FROM golden.scratch WHERE fixture_id=115 AND key='resurr'$a$, 'eq', '1', true, 'P0'),

(115, 8, 'TRIPWIRE (Cody C-2): reset_approved_undispatched and repack_machine both leave a tombstoned plan row alone. Both filter on operator_status=''approved''; if either WHERE is ever widened, BOTH defence layers fall at once',
 $a$SELECT value->>'rpo1_status_after' FROM golden.scratch WHERE fixture_id=115 AND key='trip'$a$, 'eq', 'rejected', true, 'P0'),

(115, 9, 'TRIPWIRE (Cody C-2): the tombstoned row KEEPS its dispatch_id. reset_approved_undispatched NULLs that column, and it is the only key the §2.2 guard has - a NULL there blinds the second layer silently',
 $a$SELECT value->>'rpo1_dispatch_id_kept' FROM golden.scratch WHERE fixture_id=115 AND key='trip'$a$, 'eq', 'true', true, 'P0'),

(115, 10, 'TRIPWIRE - THE LIVE VECTOR: after reset_approved_undispatched + repack_machine, a THIRD approve wave still does not revive the removed row. Measured pre-fix this reads 1. This is the leg that reproduces "removed popcorn came back"',
 $a$SELECT value->>'a01_live' FROM golden.scratch WHERE fixture_id=115 AND key='reapp'$a$, 'eq', '0', true, 'P0'),

(115, 11, 'TRIPWIRE: exactly ONE dispatch row has ever existed for that shelf - the removed one. Measured pre-fix this reads 2, which is the resurrection as a durable row rather than as a transient state',
 $a$SELECT value->>'a01_total' FROM golden.scratch WHERE fixture_id=115 AND key='reapp'$a$, 'eq', '1', true, 'P0'),

(115, 12, 'POSITIVE CONTROL: the third wave was not vacuous either - reset_approved_undispatched had put A02 back to pending and this wave re-served it',
 $a$SELECT value->>'a02_live' FROM golden.scratch WHERE fixture_id=115 AND key='reapp'$a$, 'eq', '1', true, 'P0'),

(115, 13, '§2.2 STANDING ALONE: forcing the tombstoned row back to operator_status=approved by raw UPDATE, push still refuses it. The guard reads the append-only remove edit-log entry, not the mutable status',
 $a$SELECT value->>'tombstoned' FROM golden.scratch WHERE fixture_id=115 AND key='guard'$a$, 'eq', '1', true, 'P0'),

(115, 14, '§2.2: and it pushes nothing as a result',
 $a$SELECT value->>'pushed' FROM golden.scratch WHERE fixture_id=115 AND key='guard'$a$, 'eq', '0', true, 'P0'),

(115, 15, '§2.2: no dispatch row is created by the forced re-approve. lines_tombstoned counting up is a report; this is the physical fact',
 $a$SELECT value->>'a01_live' FROM golden.scratch WHERE fixture_id=115 AND key='guard'$a$, 'eq', '0', true, 'P0'),

(115, 16, 'The push under test is the spliced v12 and not some other body that happened to be resident',
 $a$SELECT value->>'version' FROM golden.scratch WHERE fixture_id=115 AND key='guard'$a$, 'eq', 'v12_prd115_tombstone_guard', true, 'P0'),

(115, 17, 'ACCEPTANCE 2 TRIPWIRE (§2.3): a machine whose FINAL confirm no longer closes reads needs_reconfirm. Before this it read "completed" while the Finish button read "1 to resolve", and the only prominent exit was a destructive re-pack',
 $a$SELECT value->>'state_mid' FROM golden.scratch WHERE fixture_id=115 AND key='pack'$a$, 'eq', 'needs_reconfirm', true, 'P0'),

(115, 18, 'ACCEPTANCE 2: the count the FE renders as "M lines to finish" comes from the view, derived from v_dispatch_pack_progress - the same object confirm_machine_packed gates on (Article 16)',
 $a$SELECT (value->>'needs_mid') || '/' || (value->>'unresolved_mid')
     FROM golden.scratch WHERE fixture_id=115 AND key='pack'$a$, 'eq', 'true/1', true, 'P0'),

(115, 19, 'The state and the writer agree: confirm_machine_packed REFUSES the same condition the view calls needs_reconfirm. A state nothing enforces is decoration',
 $a$SELECT (value->>'cf1') || '/' || (value->>'cf2') || '/' || (value->>'cf3')
     FROM golden.scratch WHERE fixture_id=115 AND key='pack'$a$, 'eq', 'ok/blocked/ok', true, 'P0'),

(115, 20, 'ACCEPTANCE 2: finishing the remaining line and re-running confirm_machine_packed CLOSES the state. The re-run is idempotent, so recovery costs one tap and never a re-pack',
 $a$SELECT (value->>'state_final') || '/' || (value->>'needs_final') || '/' || (value->>'unresolved_final')
     FROM golden.scratch WHERE fixture_id=115 AND key='pack'$a$, 'eq', 'completed/false/0', true, 'P0'),

(115, 21, 'A clean final confirm still reads completed - needs_reconfirm did not swallow the happy path, and a deliberate final=false Save & come back still reads in_progress (unchanged CASE arm)',
 $a$SELECT value->>'state_first' FROM golden.scratch WHERE fixture_id=115 AND key='pack'$a$, 'eq', 'completed', true, 'P0'),

(115, 22, 'ACCEPTANCE 2, FLEET-WIDE: "already packed" AND "N to resolve" is unrepresentable. Not scoped to the fixture machine - this counts every machine/date in the view, live rows included',
 $a$SELECT value->>'impossible_pair' FROM golden.scratch WHERE fixture_id=115 AND key='pack'$a$, 'eq', '0', true, 'P0'),

(115, 23, 'ARTICLE 6 (Cody C-6): warehouse_inventory is md5-FINGERPRINT identical across the whole scenario. A row count survives a status flip; this does not. Nothing in a plan edit touches the warehouse',
 $a$SELECT value->>'unchanged' FROM golden.scratch WHERE fixture_id=115 AND key='wh'$a$, 'eq', 'true', true, 'P0'),

(115, 24, 'RESIDUE: the fixture leaves ZERO rows on its synthetic date - no plan rows, no dispatch rows, no pack confirmation. A permanently planted approved plan row would feed the real push',
 $a$SELECT (value->>'rpo') || '/' || (value->>'rd') || '/' || (value->>'cfm')
     FROM golden.scratch WHERE fixture_id=115 AND key='residue'$a$, 'eq', '0/0/0', true, 'P0'),

(115, 25, 'BYTE-IDENTITY (Cody C-4): push v12 still carries the duplicate-unstarted ON CONFLICT guard. PRD §3 requires it untouched, and a splice that drifted would drop it silently',
 $a$SELECT (position('ON CONFLICT (dispatch_date, machine_id, shelf_id, boonz_product_id, action)'
                    in pg_get_functiondef(oid)) > 0)::text
     FROM pg_proc WHERE proname='push_plan_to_dispatch'
       AND pg_get_function_identity_arguments(oid)='p_plan_date date, p_machine_name text'$a$,
 'eq', 'true', true, 'P0'),

(115, 26, 'BYTE-IDENTITY (Cody C-4): push v12 still carries the PRD-053 conservation stop-ship, and still refuses rather than logs',
 $a$SELECT (position('conservation_violation' in pg_get_functiondef(oid)) > 0)::text
     FROM pg_proc WHERE proname='push_plan_to_dispatch'
       AND pg_get_function_identity_arguments(oid)='p_plan_date date, p_machine_name text'$a$,
 'eq', 'true', true, 'P0'),

(115, 27, 'BYTE-IDENTITY (Cody C-4): push v12 still carries both RC-01 idempotency arms (§5(5a) manual-edit preserve and §5(5b) multi-wave), which is what stops the tombstone guard from being mistaken for them',
 $a$SELECT (position('RC-01 §5(5a)' in pg_get_functiondef(oid)) > 0
           AND position('RC-01 §5(5b)' in pg_get_functiondef(oid)) > 0)::text
     FROM pg_proc WHERE proname='push_plan_to_dispatch'
       AND pg_get_function_identity_arguments(oid)='p_plan_date date, p_machine_name text'$a$,
 'eq', 'true', true, 'P0'),

(115, 28, 'ARTICLE 4: remove_dispatch_row still refuses a driver and still refuses a picked-up row. The tombstone was added INSIDE those gates, not around them',
 $a$SELECT (position('remove_dispatch_row not allowed for driver' in pg_get_functiondef(oid)) > 0
           AND position('already picked up' in pg_get_functiondef(oid)) > 0)::text
     FROM pg_proc WHERE proname='remove_dispatch_row'$a$,
 'eq', 'true', true, 'P0');
