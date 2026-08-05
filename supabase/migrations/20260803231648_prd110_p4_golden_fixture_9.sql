-- PRD-110 P4 - golden fixture 9: the repack that froze a machine (NOOK 2026-07-20).
--
-- LAW 1 clause 2: the incident is not closed until this is green. It is the LAST
-- thing between here and the P4 gate.
--
-- WHAT THE INCIDENT WAS, RECONSTRUCTED FROM PRODUCTION AND NOT FROM MEMORY.
--   NOOK-1019-0200-B1, 2026-07-20. 12 dispatch rows pushed at 03:07:43, one more
--   at 04:34:20. The packing UI failed - the live skip_reason still reads
--   'other: Packing is not saving'. A repack was run. All 10 rows that were
--   packed=true came back with return_reason='superseded_by_repack' and
--   filled_quantity=0; the 3 never-packed rows were untouched. All 11
--   refill_plan_output rows were reset and ZERO fresh dispatch rows were ever
--   created. The machine was refilled by hand, and the only record of it is three
--   'adjust-NOOK-1019-0200-B1-...-2026-07-20' rows in pod_inventory_audit_log.
--   ⛔ All 10 superseded_by_repack rows in the entire fleet's history are this one
--   machine on this one date, and the frozen state is STILL LIVE: those 11 plan
--   rows sit approved + dispatched=false with no dispatch rows to serve them, and
--   repack can never run again for that date.
--
-- ⛔ THE INCIDENT IS THREE DEFECTS, NOT ONE, AND THIS FIXTURE PINS ALL THREE.
--   S-191  repack_machine admits 'warehouse'; push_plan_to_dispatch refuses it. The
--          packing role - the one that HITS "Packing is not saving" - passes
--          repack's gate, has every packed row returned and every plan row reset,
--          and then the re-push RAISES. There is no savepoint, so the returns and
--          resets are already applied when it reports push_failed.
--   S-192  return_dispatch_line sets dispatched=true, and repack refuses when
--          anything is dispatched. The first repack's OWN returns permanently
--          block every retry. There is no second attempt, ever.
--   S-193  ⛔ THE WORST ONE. Run as operator_admin, with every permission it needs,
--          repack returns status='ok' and creates ZERO fresh rows. The returned row
--          still holds the (machine, shelf, product, action, date) key, so push
--          treats the plan line as already served, moves 0 lines and re-stamps
--          dispatched=true. The machine gets nothing, the plan believes it was
--          dispatched, and the RPC reports success.
--
-- ⭐ AND THE RECOVERY PROPERTY IS REAL - S-196, AND IT IS THE POINT OF THE FIXTURE.
--   log_manual_refill asked for 10 units the warehouse does not have returns
--   status='ok', writes the full 10 to the pod, decrements 0, and flags a
--   shortfall. The LOG path records physical truth and never strands the operator.
--   That is what saved NOOK on the night, by hand, and it is the exact counterpart
--   of the ANTI-PATTERN "forcing a dispatch state at night instead of the LOG path".
--
-- ⛔ THIS FIXTURE ASSERTS THE SYSTEM AS IT STANDS, DEFECTS INCLUDED. That is
--    deliberate. D-43 (may 'warehouse' repack at all?) is an open CS policy
--    question and nothing waits on it. When the fix lands, assertions 1-2 and
--    16-28 are the ones that go red, and updating them IS the proof the fix
--    landed. ⛔ Do NOT "repair" this fixture by loosening those assertions.
--
-- ⛔ AND IT FOUND A FOURTH DEFECT BY RUNNING - S-197, section 7. The legacy RPC
--    tier sets app.via_rpc/app.rpc_name and never restores them. Because
--    unskip_dispatch_line is on enforce_canonical_dispatch_write's allowlist, a
--    NO-OP call to it leaves the session holding a valid allowlisted pair, and the
--    very same raw UPDATE that was logged as a bypass one statement earlier is
--    invisible one statement later. Proven with a control, by attempt, per S-177.
--
-- HOW IT LEAVES NOTHING (the fixture-18/26 mechanism, reused deliberately).
--   The whole scenario is one plpgsql subtransaction ended by
--   RAISE EXCEPTION 'FX09_ROLLBACK'. Rows vanish; plpgsql VARIABLES survive.
--   Everything the assertions read is captured into s_* variables BEFORE the
--   unwind and written to golden.scratch after it. ⭐ Unlike fixtures 18/26 this
--   one burns NO sequence: no PO is minted, so a run is completely inert.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (
  9,
  'The repack that froze a machine: a repack started by the packing role half-completes (rows returned, plan reset, nothing re-pushed) and can never be retried because its own returns count as dispatched - and even on the fully authorised path it reports ok while creating zero fresh dispatch rows, leaving the plan believing it was dispatched. The operator is not stranded only because log_manual_refill records the physical refill regardless of what the warehouse can cover.',
  'LIVE 2026-07-20, NOOK-1019-0200-B1. Packing UI failed (skip_reason: "other: Packing is not saving"), a repack returned all 10 packed rows with superseded_by_repack, reset all 11 plan rows, created zero fresh dispatch rows, and locked itself out of any retry. The machine was refilled by hand and the only trace is three adjust-* rows in pod_inventory_audit_log. The frozen plan rows are still live today.',
  'P4',
  DATE '2030-07-20',
$fx9body$
DO $fx9$
DECLARE
  -- ---- fixed cast (every id re-probed live this leg, LAW 13) --------------
  c_mach     uuid := '98868de9-a977-40f4-b0ea-ce787877f24a';
  -- repack_machine and log_manual_refill resolve the machine by official_name.
  -- NOT machine_number (a different value entirely); there is no machine_name column.
  c_mname    text := 'WH3_1035_0000_W0';
  -- ONE SHELF PER LEG (S-188: prevent_duplicate_unstarted_dispatch refuses a second
  -- unstarted row for the same machine/shelf/product/action/date). All six probed
  -- live this leg: zero pod_inventory rows on every one.
  c_s1 uuid := '54051154-e5f6-4f9b-9bbe-add09d88875d'; -- A01 packed, swept by repack
  c_s2 uuid := '483e5bb4-3b12-463c-a6d0-2232818446fe'; -- A02 packed, swept by repack
  c_s3 uuid := 'f2c4c372-a1e0-4d54-b7a2-d2b2d4406526'; -- A03 skipped, never packed
  c_s4 uuid := 'ed8bf941-2ef4-418d-9b38-8bf9b0803b61'; -- A04 cancelled
  c_s5 uuid := 'e475943b-3e98-4355-8ce2-8736d5c68697'; -- A05 admin repack + LOG happy
  c_s6 uuid := '1193ffb5-d6c1-4f62-a472-b6036d835c5a'; -- A06 LOG shortfall
  c_pA uuid := '00103662-15c4-47c8-9a32-26d421fa9827'; -- NRJ Nut - Trail Mix
  c_pB uuid := '8442c7aa-7c41-425e-9b0f-f2d5a3eb87c3'; -- NRJ Nut - Cashew Sesame
  -- S-195: BOTH pod_product_id AND pod_product_name, or push silently skips the
  -- line as lines_skipped_null_product and the freeze becomes unmeasurable.
  c_pp uuid := '9eb1e4f1-a47d-4bda-9090-bf0e13d1d8b9';
  c_u_wh    uuid := '7f4ecaa4-1efe-4a32-b233-35f5516f6131'; -- warehouse (the packing role)
  c_u_admin uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'; -- operator_admin
  c_central uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  c_date  date := DATE '2030-07-20'; -- the unauthorised-role replay
  c_date2 date := DATE '2030-07-21'; -- the AUTHORISED replay, on its own date

  v_d1 uuid; v_d2 uuid; v_d3 uuid; v_d4 uuid; v_e1 uuid;
  v_batch uuid; v_b0 int;
  v_bvl_before bigint; v_bvl_mid bigint; v_bvl_ctrl bigint; v_bvl_leak bigint;
  v_rep1 jsonb; v_rep2 jsonb; v_rep3 jsonb; v_push jsonb;
  v_un1 jsonb; v_un2 jsonb; v_log1 jsonb; v_log2 jsonb;
  v_rpo_mid boolean; v_rd_mid int;
  v_cancel text := 'NOT REFUSED';

  s_s191 jsonb; s_s192 jsonb; s_s193 jsonb;
  s_undo jsonb; s_log jsonb; s_leak jsonb; s_gucs jsonb;
BEGIN
  PERFORM set_config('app.rpc_name', 'golden.fixture_9', true);
  DELETE FROM golden.scratch WHERE fixture_id = 9;
  SELECT count(*) INTO v_bvl_before FROM public.bypass_violation_log;

  BEGIN
    ------------------------------------------------------------- 1. PLANT ---
    -- via_trigger for the plant ONLY. enforce_canonical_dispatch_write LOGS
    -- rather than blocks, so a plant without it mints bypass_violation_log rows
    -- - and leaving it set for the whole run would MASK the guard on every leg
    -- below. It is cleared the moment the plant is done, which is what makes
    -- the bvl assertions mean anything.
    PERFORM set_config('app.via_trigger', 'true', true);

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_s1, c_pA, c_date, 'Refill', 2, c_central, 'FX09 packed A01','wh',c_central)
    RETURNING dispatch_id INTO v_d1;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_s2, c_pA, c_date, 'Refill', 3, c_central, 'FX09 packed A02','wh',c_central)
    RETURNING dispatch_id INTO v_d2;

    -- the never-packed line, carrying the incident's VERBATIM live skip_reason
    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id, skipped, skip_reason)
    VALUES (c_mach, c_s3, c_pA, c_date, 'Refill', 1, c_central, 'FX09 never packed A03','wh',c_central,
            true, 'other: Packing is not saving')
    RETURNING dispatch_id INTO v_d3;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id, cancelled, cancelled_at, skip_reason)
    VALUES (c_mach, c_s4, c_pA, c_date, 'Refill', 1, c_central, 'FX09 cancelled A04','wh',c_central,
            true, now(), 'FX09 cancelled by operator')
    RETURNING dispatch_id INTO v_d4;

    INSERT INTO public.refill_dispatching
      (machine_id, shelf_id, boonz_product_id, dispatch_date, action, quantity,
       from_warehouse_id, comment, source_kind, source_warehouse_id)
    VALUES (c_mach, c_s5, c_pA, c_date2, 'Refill', 2, c_central, 'FX09 admin repack A05','wh',c_central)
    RETURNING dispatch_id INTO v_e1;

    -- S-194: packed=true DEMANDS pack_outcome in the SAME statement
    -- (chk_packed_requires_outcome, NOT VALID but still re-checked on UPDATE),
    -- and the promotion must be an UPDATE and never part of the INSERT
    -- (trg_conserve_split_qty is BEFORE INSERT on packed=true and decrements siblings).
    UPDATE public.refill_dispatching
       SET packed = true, pack_outcome = 'packed'::public.pack_outcome_enum
     WHERE dispatch_id IN (v_d1, v_d2, v_e1);

    INSERT INTO public.refill_plan_output
      (plan_date, machine_name, machine_id, shelf_id, shelf_code, boonz_product_id,
       pod_product_id, pod_product_name, boonz_product_name, action, quantity, operator_status, dispatched)
    VALUES (c_date, c_mname, c_mach, c_s1, 'A01', c_pA, c_pp, 'NRJ Nut',
       (SELECT boonz_product_name FROM public.boonz_products WHERE product_id=c_pA),
       'Refill', 2, 'approved', true);

    INSERT INTO public.refill_plan_output
      (plan_date, machine_name, machine_id, shelf_id, shelf_code, boonz_product_id,
       pod_product_id, pod_product_name, boonz_product_name, action, quantity, operator_status, dispatched)
    VALUES (c_date2, c_mname, c_mach, c_s5, 'A05', c_pA, c_pp, 'NRJ Nut',
       (SELECT boonz_product_name FROM public.boonz_products WHERE product_id=c_pA),
       'Refill', 2, 'approved', true);

    -- S-190 + S-189: log_manual_refill's FEFO filter is
    -- expiration_date >= p_refill_date AND NOT quarantined. On a 2030 date every
    -- real batch of this product is expired, and quarantined is a GENERATED column
    -- that is TRUE whenever provenance_reason IS NULL - so a plant that omits
    -- provenance is Active, in-date, positive and STILL invisible to FEFO.
    -- 'snapshot' is the only honest provenance that also avoids quarantining
    -- without needing a fabricated source_event_id.
    PERFORM set_config('app.provenance_reason','snapshot',true);
    INSERT INTO public.warehouse_inventory
      (boonz_product_id, warehouse_stock, expiration_date, status, batch_id,
       snapshot_date, warehouse_id, provenance_reason, wh_location)
    VALUES (c_pA, 5, DATE '2031-06-30','Active','FX09-PLANT', CURRENT_DATE, c_central,'snapshot','FX09')
    RETURNING wh_inventory_id, warehouse_stock INTO v_batch, v_b0;

    PERFORM set_config('app.provenance_reason','',true);
    PERFORM set_config('app.via_trigger','',true);

    -------------------- 2. S-193: THE AUTHORISED PATH FREEZES SILENTLY ------
    -- operator_admin has every permission repack needs. It still creates nothing,
    -- and it still says ok. This leg runs FIRST, on its own date, so nothing here
    -- can be blamed on the role gate that S-191 is about.
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_admin), true);
    v_rep3 := public.repack_machine(c_mname, c_date2, 'FX09 admin repack completes');
    SELECT dispatched INTO v_rpo_mid FROM public.refill_plan_output WHERE plan_date=c_date2;
    SELECT count(*) INTO v_rd_mid FROM public.refill_dispatching WHERE dispatch_date=c_date2;
    -- the re-push the operator would run by hand after a repack that said ok
    v_push := public.push_plan_to_dispatch(c_date2, c_mname);

    s_s193 := jsonb_build_object(
      'status',       v_rep3->>'status',
      'returned',     v_rep3->>'returned_count',
      'reset',        v_rep3->>'plan_rows_reset',
      'fresh',        v_rep3->>'fresh_dispatch_rows_created',
      'rpo_mid',      v_rpo_mid,
      'rd_mid',       v_rd_mid,
      'rd_total',     (SELECT count(*)::int FROM public.refill_dispatching WHERE dispatch_date=c_date2),
      'rd_fresh',     (SELECT count(*)::int FROM public.refill_dispatching
                        WHERE dispatch_date=c_date2 AND returned=false),
      'push_lines',   v_push->>'lines_pushed',
      'push_nullprod',v_push->>'lines_skipped_null_product',
      'rpo_after',    (SELECT bool_and(dispatched) FROM public.refill_plan_output WHERE plan_date=c_date2));

    ------------- 3. S-191: THE PACKING ROLE HALF-COMPLETES THE REPACK -------
    PERFORM set_config('request.jwt.claims',
      format('{"sub":"%s","role":"authenticated"}', c_u_wh), true);
    v_rep1 := public.repack_machine(c_mname, c_date, 'FX09 packing is not saving');

    s_s191 := jsonb_build_object(
      'status',   v_rep1->>'status',
      'error',    v_rep1->>'error',
      'message',  v_rep1->>'message',
      'returned', v_rep1->>'returned_count',
      'failed',   v_rep1->>'failed_returns',
      'reset',    v_rep1->>'plan_rows_reset',
      'fresh',    v_rep1->>'fresh_dispatch_rows_created',
      'd1_ret',   (SELECT returned FROM public.refill_dispatching WHERE dispatch_id=v_d1),
      'd1_rr',    (SELECT return_reason FROM public.refill_dispatching WHERE dispatch_id=v_d1),
      'd1_fq',    (SELECT filled_quantity::int FROM public.refill_dispatching WHERE dispatch_id=v_d1),
      'd1_po',    (SELECT pack_outcome::text FROM public.refill_dispatching WHERE dispatch_id=v_d1),
      'd1_disp',  (SELECT dispatched FROM public.refill_dispatching WHERE dispatch_id=v_d1),
      'd3_ret',   (SELECT returned FROM public.refill_dispatching WHERE dispatch_id=v_d3),
      'd4_ret',   (SELECT returned FROM public.refill_dispatching WHERE dispatch_id=v_d4),
      'rpo_frozen',(SELECT bool_and(dispatched) FROM public.refill_plan_output WHERE plan_date=c_date),
      'rd_total', (SELECT count(*)::int FROM public.refill_dispatching WHERE dispatch_date=c_date));

    ---------------------- 4. S-192: THE PERMANENT LOCKOUT -------------------
    v_rep2 := public.repack_machine(c_mname, c_date, 'FX09 second attempt');
    s_s192 := jsonb_build_object(
      'status',  v_rep2->>'status',
      'error',   v_rep2->>'error',
      'message', v_rep2->>'message',
      'count',   v_rep2->>'dispatched_count');

    ------------------------------ 5. THE UNDO WINDOW ------------------------
    v_un1 := public.unskip_dispatch_line(v_d3, c_u_wh);
    v_un2 := public.unskip_dispatch_line(v_d3, c_u_wh);
    BEGIN
      PERFORM public.unskip_dispatch_line(v_d4, c_u_wh);
    EXCEPTION WHEN OTHERS THEN v_cancel := SQLERRM;
    END;

    s_undo := jsonb_build_object(
      'st1',    v_un1->>'status',
      'prev',   v_un1->>'previous_skip_reason',
      'st2',    v_un2->>'status',
      'msg2',   v_un2->>'message',
      'skipped',(SELECT skipped FROM public.refill_dispatching WHERE dispatch_id=v_d3),
      'incl',   (SELECT include FROM public.refill_dispatching WHERE dispatch_id=v_d3),
      'reason', (SELECT skip_reason FROM public.refill_dispatching WHERE dispatch_id=v_d3),
      'cancel', v_cancel);

    ------------------- 6. S-196: THE LOG PATH IS THE RECOVERY ---------------
    v_log1 := public.log_manual_refill(c_mname, c_central, c_date,
      jsonb_build_array(jsonb_build_object('boonz_product_id', c_pA, 'qty', 3,
        'shelf_code','A05','expiration_date','2031-06-30')),
      'FX09 manual refill after frozen dispatch');

    -- the headline: MORE than the warehouse holds
    v_log2 := public.log_manual_refill(c_mname, c_central, c_date,
      jsonb_build_array(jsonb_build_object('boonz_product_id', c_pB, 'qty', 10,
        'shelf_code','A06','expiration_date','2031-06-30')),
      'FX09 shortfall - WH cannot cover');

    s_log := jsonb_build_object(
      'st1',        v_log1->>'status',
      'to_pod1',    v_log1->>'total_units_to_pod',
      'dec1',       v_log1->>'total_wh_decremented',
      'warn1_null', (v_log1->'shortfall_warning' = 'null'::jsonb),
      'batch_before', v_b0,
      'batch_after',(SELECT warehouse_stock::int FROM public.warehouse_inventory WHERE wh_inventory_id=v_batch),
      'st2',        v_log2->>'status',
      'to_pod2',    v_log2->>'total_units_to_pod',
      'dec2',       v_log2->>'total_wh_decremented',
      'short2',     (v_log2->'details'->0->>'wh_shortfall'),
      'warn2',      v_log2->>'shortfall_warning',
      'pod_rows',   (SELECT count(*)::int FROM public.pod_inventory WHERE machine_id=c_mach),
      'pial',       (SELECT count(*)::int FROM public.pod_inventory_audit_log
                      WHERE reference_id = 'manual-refill-'||c_mname||'-'||c_date::text));

    -- nothing above this line may have tripped the canonical-writer guard
    SELECT count(*) INTO v_bvl_mid FROM public.bypass_violation_log;

    ---------- 7. S-197: THE LEAKED GUC OPENS THE WRITER GATE (by attempt) ---
    -- S-177 discipline: prove a guard's state by attempting the write, never by
    -- reading the predicate. The control is what makes this non-vacuous - the
    -- SAME raw UPDATE is logged as a bypass before the RPC and not after it.
    PERFORM set_config('app.via_rpc',  '', true);
    PERFORM set_config('app.rpc_name', 'golden.fixture_9', true);
    UPDATE public.refill_dispatching SET comment='FX09 leak control raw' WHERE dispatch_id=v_d3;
    SELECT count(*) INTO v_bvl_ctrl FROM public.bypass_violation_log;

    -- v_d3 is ALREADY unskipped, so this call returns noop and changes nothing.
    -- It still sets app.via_rpc/app.rpc_name at its first line and never restores them.
    PERFORM public.unskip_dispatch_line(v_d3, c_u_wh);
    UPDATE public.refill_dispatching SET comment='FX09 leak after noop rpc' WHERE dispatch_id=v_d3;
    SELECT count(*) INTO v_bvl_leak FROM public.bypass_violation_log;

    s_leak := jsonb_build_object(
      'clean_run',   (v_bvl_mid - v_bvl_before)::int,
      'control',     (v_bvl_ctrl - v_bvl_mid)::int,
      'after_noop',  (v_bvl_leak - v_bvl_ctrl)::int,
      'leaked_rpc',  COALESCE(current_setting('app.via_rpc', true), '<unset>'),
      'leaked_name', COALESCE(current_setting('app.rpc_name', true), '<unset>'));

    --------------------------- 8. Article 4: GUC hygiene --------------------
    PERFORM set_config('request.jwt.claims','',true);
    s_gucs := jsonb_build_object(
      'via_trig', COALESCE(current_setting('app.via_trigger', true), '<unset>'),
      'prov_after_log', COALESCE(current_setting('app.provenance_reason', true), '<unset>'));

    ------------------------------------------------------------ 9. unwind ---
    RAISE EXCEPTION 'FX09_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'FX09_ROLLBACK' THEN RAISE; END IF;
  END;

  PERFORM set_config('app.via_trigger', '', true);
  PERFORM set_config('app.via_rpc', '', true);
  PERFORM set_config('app.provenance_reason', '', true);
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (9, 's191', s_s191),
    (9, 's192', s_s192),
    (9, 's193', s_s193),
    (9, 'undo', s_undo),
    (9, 'log',  s_log),
    (9, 'leak', s_leak),
    (9, 'gucs', s_gucs),
    (9, 'residue', jsonb_build_object(
       'rd',  (SELECT count(*) FROM public.refill_dispatching
                WHERE dispatch_date IN (c_date, c_date2) AND comment LIKE 'FX09%'),
       'rpo', (SELECT count(*) FROM public.refill_plan_output WHERE plan_date IN (c_date, c_date2)),
       'wh',  (SELECT count(*) FROM public.warehouse_inventory WHERE wh_location='FX09'),
       'pod', (SELECT count(*) FROM public.pod_inventory WHERE machine_id=c_mach),
       'pial',(SELECT count(*) FROM public.pod_inventory_audit_log
                WHERE reference_id LIKE 'manual-refill-'||c_mname||'-2030%'),
       'bvl', (SELECT count(*) FROM public.bypass_violation_log) - v_bvl_before));
END
$fx9$;
$fx9body$,
  'One subtransaction, rolled back by RAISE FX09_ROLLBACK; assertions read golden.scratch written from plpgsql variables that survive the unwind. Leaves ZERO rows in refill_dispatching, refill_plan_output, warehouse_inventory, pod_inventory, pod_inventory_audit_log and bypass_violation_log. Burns NO sequence - no PO is minted - so a run is completely inert. Two 2030 plan dates (LAW 12): 2030-07-20 is the unauthorised-role replay, 2030-07-21 the authorised one, kept apart so nothing on the authorised date can be blamed on the role gate. ~3-5 s.',
  true,
  'passing'
)
ON CONFLICT (fixture_id) DO UPDATE SET
  name            = EXCLUDED.name,
  source_incident = EXCLUDED.source_incident,
  phase_required  = EXCLUDED.phase_required,
  plan_date       = EXCLUDED.plan_date,
  scenario_sql    = EXCLUDED.scenario_sql,
  notes           = EXCLUDED.notes,
  enabled         = EXCLUDED.enabled,
  baseline_status = EXCLUDED.baseline_status;

DELETE FROM golden.assertions WHERE fixture_id = 9;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
SELECT 9, t.seq, t.descr, t.sql, t.op, t.expect, true, 'P4'
FROM (VALUES

-- A. THE ROOT CAUSE, READ OUT OF THE CATALOG (S-191) -------------------------
(1,'⛔ S-191, HALF ONE: repack_machine ADMITS the warehouse role. Read from prosrc, so the root cause is pinned in the source and not only in behaviour. ⛔ When D-43 is executed this is one of the two assertions that must change, and changing it IS the proof the fix landed.',
 $q$SELECT (prosrc LIKE '%IN (''warehouse'',''operator_admin'',''superadmin'',''manager'')%')::text FROM pg_proc WHERE proname='repack_machine'$q$,'eq','true'),
(2,'⛔ S-191, HALF TWO, AND THE WHOLE INCIDENT IS IN THE GAP BETWEEN THEM: push_plan_to_dispatch''s role list does NOT contain warehouse. repack calls push. So the one role that hits "Packing is not saving" is authorised to START a repack it is not authorised to FINISH.',
 $q$SELECT (prosrc LIKE '%ARRAY[''operator_admin'',''superadmin'',''manager'']%')::text FROM pg_proc WHERE proname='push_plan_to_dispatch'$q$,'eq','true'),
(3,'exactly ONE overload of repack_machine - a second would be a silent fork of the recovery path',
 $q$SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='repack_machine'$q$,'eq','1'),
(4,'repack_machine is SECURITY DEFINER with search_path pinned (Article 4)',
 $q$SELECT (prosecdef::text||'|'||COALESCE(array_to_string(proconfig,','),'<none>')) FROM pg_proc WHERE oid='public.repack_machine(text,date,text)'::regprocedure$q$,'eq','true|search_path=public, pg_temp'),
(5,'⛔ S-192''s MECHANISM, in the catalog: return_dispatch_line stamps dispatched=true. That single line is why a repack can never be retried - the returns it makes are indistinguishable, to the next repack, from a real dispatch.',
 $q$SELECT (prosrc ~ 'dispatched\s*=\s*true')::text FROM pg_proc WHERE proname='return_dispatch_line'$q$,'eq','true'),

-- B. S-193: THE AUTHORISED PATH FREEZES, AND REPORTS SUCCESS -----------------
(6,'⛔ THE WORST DEFECT OF THE THREE, AND THE ONE TO REMEMBER. Run as operator_admin - every permission repack needs - the RPC reports status=ok.',
 $q$SELECT (value->>'status') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','ok'),
(7,'...having returned the packed row...',
 $q$SELECT (value->>'returned') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','1'),
(8,'...and reset the plan row...',
 $q$SELECT (value->>'reset') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','1'),
(9,'⛔ ...AND CREATED ZERO FRESH DISPATCH ROWS. A success payload with nothing behind it. This is the number the operator never sees.',
 $q$SELECT (value->>'fresh') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','0'),
(10,'exactly one dispatch row remains on the date...',
 $q$SELECT (value->>'rd_total') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','1'),
(11,'⛔ ...and NONE of them are fresh - the only row on the date is the RETURNED one, which still occupies the (machine, shelf, product, action, date) key. That squatting row is the whole mechanism.',
 $q$SELECT (value->>'rd_fresh') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','0'),
(12,'⛔ and the plan row is back to dispatched=true the instant repack returns - so the plan believes it was served by a dispatch row that does not exist',
 $q$SELECT (value->>'rpo_mid') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','true'),
(13,'the re-push an operator would run by hand after an ok repack moves ZERO lines',
 $q$SELECT (value->>'push_lines') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','0'),
(14,'⛔ S-195, AND IT IS WHAT MAKES ASSERTION 13 MEAN THE FREEZE. A plant with a NULL pod_product_id makes push report lines_skipped_null_product and move nothing - INDISTINGUISHABLE from the real freeze. Leg 107 nearly recorded a false root cause on exactly that. This pins the zero-push to the real cause by proving no line was skipped for a missing product.',
 $q$SELECT (value->>'push_nullprod') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','0'),
(15,'...and after the push the plan still reads dispatched. Nothing anywhere in the system now says this machine was missed.',
 $q$SELECT (value->>'rpo_after') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$q$,'eq','true'),

-- C. S-191: THE HALF-COMPLETION -------------------------------------------
(16,'⛔ THE ROOT CAUSE, REPRODUCED. The packing role starts the repack and the RPC ends in error...',
 $q$SELECT (value->>'status') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','error'),
(17,'...named push_failed',
 $q$SELECT (value->>'error') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','push_failed'),
(18,'...because the caller lacks the role push demands, and the message says so in as many words',
 $q$SELECT (value->>'message') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'contains','lacks required role'),
(19,'⛔ AND THE DEFECT IS NOT THE ERROR - IT IS WHAT SURVIVED IT. Two packed rows were already RETURNED when the error was raised. There is no savepoint.',
 $q$SELECT (value->>'returned') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','2'),
(20,'⭐ and every one of those returns SUCCEEDED - this is not a partial-failure story, it is a fully-completed destructive half followed by a refused constructive half',
 $q$SELECT (value->>'failed') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','0'),
(21,'...the plan row was already reset...',
 $q$SELECT (value->>'reset') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','1'),
(22,'...and zero fresh rows were created. Production''s 2026-07-20 signature is exactly this: 11 rows reset, 0 rows created.',
 $q$SELECT (value->>'fresh') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','0'),
(23,'the packed line is returned',
 $q$SELECT (value->>'d1_ret') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','true'),
(24,'⭐ ...carrying return_reason=superseded_by_repack, which is the marker that let this incident be reconstructed at all: all 10 such rows in the fleet''s entire history are NOOK on 2026-07-20',
 $q$SELECT (value->>'d1_rr') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','superseded_by_repack'),
(25,'...with filled_quantity zeroed, so the pack is undone as well as the dispatch',
 $q$SELECT (value->>'d1_fq') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','0'),
(26,'...and pack_outcome moved to returned',
 $q$SELECT (value->>'d1_po') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','returned'),
(27,'⛔ THE FROZEN STATE, PINNED. The plan row is left dispatched=false with no dispatch row that will ever serve it. This is not hypothetical: 11 rows in exactly this state have been sitting in production since 2026-07-20.',
 $q$SELECT (value->>'rpo_frozen') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','false'),
(28,'...and the dispatch table still holds only the four planted rows - the repack added nothing to replace what it returned',
 $q$SELECT (value->>'rd_total') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','4'),

-- D. REPACK SWEEPS packed=true AND NOTHING ELSE -----------------------------
(29,'⭐ the never-packed skipped line is UNTOUCHED by the repack - it sweeps packed=true only, which is why NOOK''s 3 unpacked rows survived while its 10 packed ones did not',
 $q$SELECT (value->>'d3_ret') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','false'),
(30,'...and so is the cancelled line',
 $q$SELECT (value->>'d4_ret') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$q$,'eq','false'),

-- E. S-192: THE PERMANENT LOCKOUT ------------------------------------------
(31,'⛔ THE SECOND REPACK IS REFUSED, AND THE REASON IS THE FIRST REPACK''S OWN RETURNS. There is no retry after a half-completion - not that day, not ever.',
 $q$SELECT (value->>'error') FROM golden.scratch WHERE fixture_id=9 AND key='s192'$q$,'eq','cannot_repack_after_dispatch'),
(32,'...as an error, not a noop',
 $q$SELECT (value->>'status') FROM golden.scratch WHERE fixture_id=9 AND key='s192'$q$,'eq','error'),
(33,'⛔ ...and the dispatched_count it refuses on is EXACTLY the two rows the first repack returned. Nothing was ever really dispatched; return_dispatch_line just says so.',
 $q$SELECT (value->>'count') FROM golden.scratch WHERE fixture_id=9 AND key='s192'$q$,'eq','2'),
(34,'...and the operator is told a dispatch happened, which is the opposite of what happened',
 $q$SELECT (value->>'message') FROM golden.scratch WHERE fixture_id=9 AND key='s192'$q$,'contains','already dispatched'),

-- F. THE UNDO WINDOW: unskip_dispatch_line ---------------------------------
(35,'a skipped line can be re-activated',
 $q$SELECT (value->>'st1') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'eq','unskipped'),
(36,'...clearing skipped...',
 $q$SELECT (value->>'skipped') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'eq','false'),
(37,'...and restoring include',
 $q$SELECT (value->>'incl') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'eq','true'),
(38,'⭐ ...while PRESERVING skip_reason on the row. The reason a line was skipped is evidence, not state: "other: Packing is not saving" is the only reason the 2026-07-20 incident is legible at all. ⛔ Do not let a later leg clear it on unskip.',
 $q$SELECT (value->>'reason') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'eq','other: Packing is not saving'),
(39,'...and echoing it back to the caller, so a UI can show what it just undid',
 $q$SELECT (value->>'prev') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'eq','other: Packing is not saving'),
(40,'⭐ a second unskip is a NOOP, not an error - a double tap on a packing screen is an ordinary human action',
 $q$SELECT (value->>'st2') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'eq','noop'),
(41,'...and it says why rather than returning a bare status',
 $q$SELECT (value->>'msg2') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'contains','not skipped or excluded'),
(42,'⛔ but a CANCELLED line RAISES. Skip is reversible from packing; cancellation is a decision made elsewhere and packing may not quietly undo it.',
 $q$SELECT (value->>'cancel') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'contains','is CANCELLED'),
(43,'...and the refusal names cancellation as the thing that cannot be reversed, rather than leaking a bare constraint failure',
 $q$SELECT (value->>'cancel') FROM golden.scratch WHERE fixture_id=9 AND key='undo'$q$,'contains','cannot be reversed'),

-- G. S-196: THE LOG PATH IS THE RECOVERY, AND IT NEVER BLOCKS ---------------
(44,'the LOG path records a refill the frozen dispatch could not deliver',
 $q$SELECT (value->>'st1') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','ok'),
(45,'...3 units reach the pod...',
 $q$SELECT (value->>'to_pod1') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','3'),
(46,'...3 come out of the warehouse...',
 $q$SELECT (value->>'dec1') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','3'),
(47,'...and no shortfall is flagged, because there was none',
 $q$SELECT (value->>'warn1_null') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','true'),
(48,'⭐ and the debit is REAL, not nominal: the planted batch moved 5 to 2. ⛔ S-190/S-189 are why the fixture plants its own batch - at a 2030 refill date every real batch of this product is expired to the FEFO filter, and a plant without provenance_reason would be quarantined and invisible with the identical error message.',
 $q$SELECT (value->>'batch_after') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','2'),
(49,'⛔ THE HEADLINE, AND THE PROPERTY THAT SAVED NOOK ON THE NIGHT. Asked to record 10 units the warehouse does not have, log_manual_refill returns ok. It does not refuse, and it does not silently shrink the number.',
 $q$SELECT (value->>'st2') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','ok'),
(50,'⛔ all 10 units reach the pod, because 10 units are physically in the machine and that is a fact the system does not get a vote on',
 $q$SELECT (value->>'to_pod2') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','10'),
(51,'⭐ ...and ZERO are debited from a warehouse that never held them. ⛔ The alternative - debiting anyway - is the phantom-mint class this programme has spent legs killing.',
 $q$SELECT (value->>'dec2') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','0'),
(52,'⭐ the discrepancy is NAMED rather than swallowed, so a human count can settle it. LAW 5''s spirit on the recovery path: nothing goes missing quietly.',
 $q$SELECT (value->>'warn2') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'contains','physical count may be needed'),
(53,'...and quantified - 10 short, not merely "short"',
 $q$SELECT (value->>'short2') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','10'),
(54,'both refills land as pod_inventory rows - the machine''s state is corrected even though the dispatch pipeline is frozen',
 $q$SELECT (value->>'pod_rows') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','2'),
(55,'⭐ ...each audited under the manual-refill-<machine>-<date> reference. On the real incident this reference family (and its adjust-* sibling) is the ONLY surviving record that the machine was ever filled.',
 $q$SELECT (value->>'pial') FROM golden.scratch WHERE fixture_id=9 AND key='log'$q$,'eq','2'),

-- H. S-197: A NO-OP RPC LEAVES THE CANONICAL-WRITER GATE OPEN ---------------
(56,'⭐ FIRST, THE BASELINE THAT MAKES THE REST HONEST: not one leg above tripped enforce_canonical_dispatch_write. app.via_trigger is cleared the moment the plant ends, so the guard is armed for the whole scenario rather than masked by the harness.',
 $q$SELECT (value->>'clean_run') FROM golden.scratch WHERE fixture_id=9 AND key='leak'$q$,'eq','0'),
(57,'⭐ THE CONTROL, and without it the next assertion proves nothing: a raw UPDATE on refill_dispatching with no RPC context IS logged as a bypass. The guard works.',
 $q$SELECT (value->>'control') FROM golden.scratch WHERE fixture_id=9 AND key='leak'$q$,'eq','1'),
(58,'⛔ S-197: THE IDENTICAL RAW UPDATE IS INVISIBLE ONE STATEMENT LATER. Between them sits a single unskip_dispatch_line call that returned noop and changed nothing - it set app.via_rpc/app.rpc_name on its first line and never restored them. ⛔ Proven by ATTEMPT, per S-177, never by reading the predicate.',
 $q$SELECT (value->>'after_noop') FROM golden.scratch WHERE fixture_id=9 AND key='leak'$q$,'eq','0'),
(59,'the leaked flag survives the call',
 $q$SELECT (value->>'leaked_rpc') FROM golden.scratch WHERE fixture_id=9 AND key='leak'$q$,'eq','true'),
(60,'⛔ ...paired with a name that is ON the allowlist, which is the half that turns a cosmetic leak into an open gate',
 $q$SELECT (value->>'leaked_name') FROM golden.scratch WHERE fixture_id=9 AND key='leak'$q$,'eq','unskip_dispatch_line'),
(61,'⭐ ...and the two halves meet here: unskip_dispatch_line really is in enforce_canonical_dispatch_write''s allowlist. Read from the catalog so the finding does not rest on the scenario''s own bookkeeping.',
 $q$SELECT (prosrc LIKE '%''unskip_dispatch_line''%')::text FROM pg_proc WHERE proname='enforce_canonical_dispatch_write'$q$,'eq','true'),
(62,'⚠️ the same tier leaks provenance: after log_manual_refill returns, app.provenance_reason still reads manual_adjust, so the next protected write inherits a provenance it did not choose (the PRD-016B leak class). ⛔ Contrast the P4.4b tier, which restores all three - fixture 26 seq 76-78.',
 $q$SELECT (value->>'prov_after_log') FROM golden.scratch WHERE fixture_id=9 AND key='gucs'$q$,'eq','manual_adjust'),
(63,'⭐ the harness''s own app.via_trigger IS cleared before the RPC legs, which is what assertion 56 is measuring against',
 $q$SELECT (value->>'via_trig') FROM golden.scratch WHERE fixture_id=9 AND key='gucs'$q$,'eq',''),

-- I. RESIDUE: LAW 12 AND S-124 ---------------------------------------------
(64,'⛔ ZERO refill_dispatching residue on either 2030 plan date (LAW 12 / S-124: fixture residue has landed on this exact protected table before)',
 $q$SELECT (value->>'rd') FROM golden.scratch WHERE fixture_id=9 AND key='residue'$q$,'eq','0'),
(65,'⛔ ZERO refill_plan_output residue - a surviving approved plan row on a 2030 date would be picked up by the nightly pipeline',
 $q$SELECT (value->>'rpo') FROM golden.scratch WHERE fixture_id=9 AND key='residue'$q$,'eq','0'),
(66,'⛔ ZERO warehouse_inventory residue. This fixture PLANTS a batch, and phantom WH stock is pickable by the live FEFO binder within minutes.',
 $q$SELECT (value->>'wh') FROM golden.scratch WHERE fixture_id=9 AND key='residue'$q$,'eq','0'),
(67,'⛔ ZERO pod_inventory residue - this is the protected table log_manual_refill writes, and phantom units on a live shelf would be sized against by the next plan',
 $q$SELECT (value->>'pod') FROM golden.scratch WHERE fixture_id=9 AND key='residue'$q$,'eq','0'),
(68,'ZERO pod_inventory_audit_log residue on the append-only log',
 $q$SELECT (value->>'pial') FROM golden.scratch WHERE fixture_id=9 AND key='residue'$q$,'eq','0'),
(69,'⛔ ZERO bypass_violation_log residue - the fixture DELIBERATELY mints one bypass row as its control (seq 57), so this is also the proof that the deliberate one rolled back with everything else',
 $q$SELECT (value->>'bvl') FROM golden.scratch WHERE fixture_id=9 AND key='residue'$q$,'eq','0'),
(70,'⭐ and the proof is independent of the scenario''s own bookkeeping: no FX09-marked dispatch row exists on either 2030 date right now, read live at assertion time',
 $q$SELECT count(*)::text FROM public.refill_dispatching WHERE dispatch_date IN (DATE '2030-07-20', DATE '2030-07-21') AND comment LIKE 'FX09%'$q$,'eq','0'),
(71,'⭐ likewise no plan row survives on either 2030 date, read live',
 $q$SELECT count(*)::text FROM public.refill_plan_output WHERE plan_date IN (DATE '2030-07-20', DATE '2030-07-21')$q$,'eq','0'),
(72,'⭐ likewise no planted warehouse batch survives anywhere in the table, read live',
 $q$SELECT count(*)::text FROM public.warehouse_inventory WHERE wh_location='FX09'$q$,'eq','0'),
(73,'⭐ and no manual-refill audit row survives on a 2030 date, read live',
 $q$SELECT count(*)::text FROM public.pod_inventory_audit_log WHERE reference_id LIKE 'manual-refill-WH3_1035_0000_W0-2030%'$q$,'eq','0')

) AS t(seq, descr, sql, op, expect);
