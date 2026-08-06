-- PRD-110 · D-43 + S-193 — FIXTURE 9 RE-BASED. The red banked by 20260806003000 becomes the proof.
--
-- ⛔ THIS MIGRATION CHANGES NO PRODUCTION BEHAVIOUR. It moves the sensors of fixture 9 from
-- pinning three defects to asserting the properties that replaced them, and adds the guards that
-- stop the new green being green for the wrong reason.
--
-- ⭐ THE RED IT RE-BASES IS BANKED AND RE-READABLE, not narrated: golden.runs holds a fixture-9 run
-- from immediately after 20260806003000 with 63 pass / 10 fail — seq 2, 9, 10, 11, 16, 17, 18, 22,
-- 27, 28. ⛔ Every one of those ten is a defect sensor going red because the defect is gone. The
-- run BEFORE it (73/73, same leg) is the same fixture green against the OLD functions. The PAIR is
-- the evidence, exactly as a2020a40/ef56c478 are for D-46 and 2ecddab8/ec76abd0 for D-45.
--
-- ⚠️ FOUR ASSERTIONS THAT STAYED GREEN ARE REWRITTEN ANYWAY (6, 12, 13, 15), AND THAT IS THE
-- POINT OF S-103. Each reads the same value as before and now means the opposite thing:
--   · seq 6  "reports status=ok" was the WORST defect; ok is now the correct answer.
--   · seq 12 "the plan believes it was served by a row that does not exist" — it IS served now.
--   · seq 13 "the re-push moves ZERO lines" was the freeze; zero is now idempotency.
--   · seq 15 "nothing says this machine was missed" — nothing was missed.
-- ⛔ Leaving their descriptions in place would have left the fixture green while its own text
-- described a system that no longer exists. An assertion is its description plus its expect.
--
-- ⭐ SEVEN NEW ASSERTIONS (74-80), AND FOUR OF THEM EXIST ONLY BECAUSE THE OLD ONES BECAME VACUOUS:
--   · 74/76 `rpo_bound_returned` — a plan row reading dispatched=true is TRUE under both the
--     freeze and the fix. What separates them is WHAT it is bound to. This is the real S-193 sensor.
--   · 75    `rpo_bound_n = 1` — anti-vacuity for 74: bool_or over an empty join returns false and
--     would pass 74 with no bound row at all (the S-173 sin).
--   · 77    `rd_live = 1` — the warehouse role's repack created exactly one live replacement row.
--   · 78    ⛔ S-248's STRUCTURAL GUARD: repack_roles ⊆ push_roles, computed as DATA. Once
--     `warehouse` joined push's set the two lists became IDENTICAL, so half 2's pre-flight is a
--     branch NO ROLE CAN REACH and cannot be proven by a role replay. 78 asserts the relation that
--     makes it dormant BY DESIGN rather than by accident, and goes red the day they diverge — which
--     is the exact class of defect that caused the 2026-07-20 incident. Its expect is '0|4', not
--     '0': a regexp that stops matching returns zero rows and would pass a bare '0' vacuously.
--   · 79    the pre-flight is positioned BEFORE the first destructive act (return_dispatch_line).
--     Ordering is the whole defect — a pre-flight after the return loop is not a pre-flight.
--   · 80    push gates on the named set and no longer carries the literal, so the divergence class
--     is closed at the source rather than watched.
--
-- Cody: Article 12 (forward-only; golden.* is harness metadata, not a protected entity) ·
-- Article 7 (nothing in the append-only tier is touched) · Article 14 (no new table) ·
-- Article 16 (no metric re-derived). ⛔ NO golden assertion is LOOSENED: every re-based expect is
-- still an exact equality, and the population grows by 7 (73 -> 80).

-- ---------------------------------------------------------------------------
-- 1. The scenario: bind-target evidence on both dates.
-- ---------------------------------------------------------------------------
UPDATE golden.fixtures SET scenario_sql = $fx9body$
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

    ------- 2. S-193 CLOSED: THE AUTHORISED PATH NOW RE-CREATES WHAT IT RETURNED
    -- Before leg 134 this leg was the WORST of the three defects: operator_admin has
    -- every permission repack needs, and repack still returned status='ok' having
    -- created ZERO fresh rows, because push's multi-wave idempotency probe treated the
    -- row repack had just RETURNED as one that already served the plan line. It runs
    -- FIRST, on its own date, so nothing here can be blamed on the role gate S-191 is
    -- about. It now pins the FIXED property, and 'rpo_bound_returned' is what makes
    -- 'dispatched=true' mean service rather than the freeze.
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
      -- D-43/S-193: WHAT the plan line is bound to, not merely whether it says dispatched.
      -- A plan row bound to a RETURNED dispatch row is the freeze; bound to a live one is service.
      -- Assertion 12 reads 'true' under BOTH readings, so this is what stops it being vacuous.
      'rpo_bound_returned', (SELECT COALESCE(bool_or(rd.returned), false)
                               FROM public.refill_plan_output rpo
                               JOIN public.refill_dispatching rd ON rd.dispatch_id = rpo.dispatch_id
                              WHERE rpo.plan_date = c_date2),
      'rpo_bound_n',        (SELECT count(*)::int
                               FROM public.refill_plan_output rpo
                               JOIN public.refill_dispatching rd ON rd.dispatch_id = rpo.dispatch_id
                              WHERE rpo.plan_date = c_date2),
      'rpo_after',    (SELECT bool_and(dispatched) FROM public.refill_plan_output WHERE plan_date=c_date2));

    --------- 3. D-43 EXECUTED: THE PACKING ROLE SELF-SERVES ITS OWN REPACK ---
    -- Before leg 134 this leg RAISED push_failed after returning two packed rows with
    -- no savepoint - the 2026-07-20 incident exactly. CS ruled option (a): warehouse
    -- joins push's authorised set. The destructive half is unchanged and still measured
    -- (19/20/21); what changed is that the constructive half now runs.
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
      -- D-43: the row the warehouse role's repack CREATED, counted apart from the four planted
      -- ones. Live = neither returned, nor skipped, nor cancelled. Read here, in step 3, BEFORE
      -- step 5 unskips v_d3 - move this and the number changes for a reason unrelated to D-43.
      'rd_live',  (SELECT count(*)::int FROM public.refill_dispatching
                    WHERE dispatch_date=c_date
                      AND COALESCE(returned,false)=false
                      AND COALESCE(skipped,false)=false
                      AND COALESCE(cancelled,false)=false),
      'rpo_bound_returned', (SELECT COALESCE(bool_or(rd.returned), false)
                               FROM public.refill_plan_output rpo
                               JOIN public.refill_dispatching rd ON rd.dispatch_id = rpo.dispatch_id
                              WHERE rpo.plan_date = c_date),
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
$fx9body$
WHERE fixture_id = 9;

UPDATE golden.fixtures SET name =
  'The repack that froze a machine, and the two fixes that closed it: a repack started by the packing '
  'role once half-completed (rows returned, plan reset, nothing re-pushed) and could never be retried '
  'because its own returns count as dispatched. D-43 gave the warehouse role push authorisation and a '
  'pre-flight so the destructive half can no longer outrun the constructive one; S-193 stopped a '
  'RETURNED dispatch row from squatting the plan key, so a repack now re-creates what it returned. '
  'S-192 (a repack is single-shot per machine/date, permanently) is UNCLOSED and still pinned here. '
  'The operator was never stranded only because log_manual_refill records the physical refill '
  'regardless of what the warehouse can cover.'
WHERE fixture_id = 9;

-- ---------------------------------------------------------------------------
-- 2. Re-based sensors. Ten went red; four more were green and lying.
-- ---------------------------------------------------------------------------

UPDATE golden.assertions SET
  check_sql = $c$SELECT ('warehouse' = ANY (public.push_dispatch_authorized_roles()))::text$c$,
  expect_op = 'eq', expect = 'true',
  description = $d$✅ D-43 HALF 1, EXECUTED (CS 2026-08-04, option a): `warehouse` is in push_plan_to_dispatch's authorised set, so the one role that hits "Packing is not saving" may now FINISH the repack it was always allowed to START. ⭐ Read as DATA from push_dispatch_authorized_roles(), NOT as a prosrc substring — the old form pinned a literal ARRAY[...] and would have gone green again against any re-typed list. ⛔ If this reads false, the D-43 ruling has been reverted.$d$
WHERE fixture_id=9 AND seq=2;

UPDATE golden.assertions SET
  description = $d$✅ S-193 CLOSED, AND THIS IS THE ASSERTION THAT USED TO BE THE WORST DEFECT OF THE THREE. Run as operator_admin the RPC still reports status=ok — but ok is now the true answer rather than a success payload with nothing behind it. Seq 9-11 and 74-75 are what make that difference measurable.$d$
WHERE fixture_id=9 AND seq=6;

UPDATE golden.assertions SET
  expect = '1',
  description = $d$✅ ...AND IT CREATED THE ROW IT RETURNED. This read 0 for the entire life of the defect: push's RC-01 §5(5b) multi-wave probe excluded skipped/cancelled/is_m2m rows but not `returned` ones, so the row repack had just returned still matched and the plan line was "preserved" against a dead row. ⛔ This number going back to 0 means the returned-row predicate has been dropped from push.$d$
WHERE fixture_id=9 AND seq=9;

UPDATE golden.assertions SET
  expect = '2',
  description = $d$two dispatch rows now stand on the date — the returned one (history, retained) and the fresh one that replaced it$d$
WHERE fixture_id=9 AND seq=10;

UPDATE golden.assertions SET
  expect = '1',
  description = $d$✅ ...and exactly one of them is LIVE. The returned row no longer squats the (machine, shelf, product, action, date) key, because the partial unique index and prevent_duplicate_unstarted_dispatch both already excluded returned=true — push's probe was the only place that did not, which is why the INSERT succeeds the moment the predicate agrees with them.$d$
WHERE fixture_id=9 AND seq=11;

UPDATE golden.assertions SET
  description = $d$⚠️ the plan row reads dispatched=true the instant repack returns — WHICH IT ALSO DID DURING THE FREEZE. ⛔ This assertion alone cannot tell service from the defect and never could; seq 74/75 read what the row is BOUND to, and that is the pair that means something.$d$
WHERE fixture_id=9 AND seq=12;

UPDATE golden.assertions SET
  description = $d$⭐ the re-push an operator would run by hand after an ok repack still moves ZERO lines — but for the opposite reason. It was the freeze; it is now IDEMPOTENCY: repack's own push already served the line, and a second push must not mint a duplicate on top of it.$d$
WHERE fixture_id=9 AND seq=13;

UPDATE golden.assertions SET
  description = $d$...and the plan still reads dispatched after the hand re-push. Nothing anywhere says this machine was missed, and after S-193 nothing was.$d$
WHERE fixture_id=9 AND seq=15;

UPDATE golden.assertions SET
  expect = 'ok',
  description = $d$✅ D-43 EXECUTED, MEASURED ON THE ROLE THAT REPORTED THE INCIDENT. The packing role starts the repack and the RPC completes. Before leg 134 this read 'error'. ⛔ The destructive half is UNCHANGED and still measured at 19/20/21 — what D-43 fixed is that the constructive half now runs instead of raising after it.$d$
WHERE fixture_id=9 AND seq=16;

UPDATE golden.assertions SET
  check_sql = $c$SELECT COALESCE(value->>'error','<none>') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$c$,
  expect_op = 'eq', expect = '<none>',
  description = $d$...with no error key at all. ⛔ COALESCEd to a sentinel on purpose: golden.compare(NULL,'eq',…) is false, so a bare read of a now-absent key would fail for a reason that has nothing to do with the property.$d$
WHERE fixture_id=9 AND seq=17;

UPDATE golden.assertions SET
  check_sql = $c$SELECT COALESCE(value->>'message','<none>') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$c$,
  expect_op = 'eq', expect = '<none>',
  description = $d$...and no message. The verbatim "push_plan_to_dispatch: caller 7f4ecaa4-… lacks required role" that this assertion pinned for the whole life of the incident is gone from the warehouse path.$d$
WHERE fixture_id=9 AND seq=18;

UPDATE golden.assertions SET
  expect = '1',
  description = $d$✅ ...and one fresh row was created to replace the two it returned. Production's 2026-07-20 signature was 11 rows reset and 0 rows created; this is the number that signature was made of.$d$
WHERE fixture_id=9 AND seq=22;

UPDATE golden.assertions SET
  expect = 'true',
  description = $d$✅ THE STATE THAT USED TO BE THE FREEZE. The plan row reads dispatched=true and there is now a live dispatch row behind it (seq 76/77). ⛔ It read FALSE before D-43 — dispatched=false with nothing that would ever serve it, which is the state 11 production rows sat in from 2026-07-20. ⚠️ true alone does not prove service; seq 76 is what does.$d$
WHERE fixture_id=9 AND seq=27;

UPDATE golden.assertions SET
  expect = '5',
  description = $d$...and the dispatch table holds the four planted rows plus the ONE the repack created. The old expect of 4 was the statement "the repack added nothing to replace what it returned".$d$
WHERE fixture_id=9 AND seq=28;

-- ---------------------------------------------------------------------------
-- 3. New guards (74-80). Four exist because the re-based ones became vacuous.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(9, 74,
 $d$⭐ THE REAL S-193 SENSOR, AND THE ONE TO KEEP. The plan row on the authorised date is bound to a dispatch row that is NOT returned. ⛔ dispatched=true (seq 12) reads identically under the freeze and under the fix; the bind TARGET is the only thing that separates them. Under the defect this read true — the plan was pointed at the corpse of the row repack had just returned.$d$,
 $c$SELECT (value->>'rpo_bound_returned') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$c$,
 'eq','false', true, 'P4'),
(9, 75,
 $d$⛔ ANTI-VACUITY FOR 74, AND WITHOUT IT 74 PROVES NOTHING. bool_or over an EMPTY join returns false, so a plan row bound to nothing at all would pass assertion 74 exactly like a correctly-bound one. This asserts there is a bound row to test. S-173 family: a guard passed by an empty set is not a guard passed.$d$,
 $c$SELECT (value->>'rpo_bound_n') FROM golden.scratch WHERE fixture_id=9 AND key='s193'$c$,
 'eq','1', true, 'P4'),
(9, 76,
 $d$⭐ THE SAME BIND-TARGET PROOF ON THE WAREHOUSE-ROLE DATE, which is where the production incident actually happened. The plan row is bound to a live dispatch row, not to one of the two the repack returned. ⛔ Paired with 27: 27 says the plan is dispatched, 76 says something real is behind it. Neither is sufficient alone.$d$,
 $c$SELECT (value->>'rpo_bound_returned') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$c$,
 'eq','false', true, 'P4'),
(9, 77,
 $d$⭐ EXACTLY ONE LIVE ROW STANDS ON THE INCIDENT DATE after the warehouse role's repack — neither returned, nor skipped, nor cancelled. The two packed rows it returned and the planted skipped/cancelled rows are all excluded, so this counts the replacement and nothing else. ⛔ Read in scenario step 3, BEFORE step 5 unskips v_d3; moving it changes the number for a reason that has nothing to do with D-43.$d$,
 $c$SELECT (value->>'rd_live') FROM golden.scratch WHERE fixture_id=9 AND key='s191'$c$,
 'eq','1', true, 'P4'),
(9, 78,
 $d$⛔ S-248's STRUCTURAL GUARD, AND THE ONLY HONEST WAY TO ASSERT D-43 HALF 2. Once `warehouse` joined push's set, repack_machine's gate and push's authorised set became IDENTICAL, so the pre-flight is a branch NO ROLE CAN REACH and cannot be proven by a role replay — a fixture that "passes" it by inspection is the S-173 sin. This asserts the relation instead: every role repack admits is also a role push authorises, computed as DATA. It goes red the day the two lists diverge, which is precisely the defect class that produced the 2026-07-20 incident. ⛔ The expect is '0|4', not '0': the regexp extracts repack's gate from prosrc, and a regexp that stops matching yields ZERO rows, which would pass a bare '0' vacuously. The second number is the proof the extraction still works.$d$,
 $c$SELECT (SELECT count(*) FROM (SELECT btrim(replace(unnest(string_to_array((regexp_match(prosrc,'v_caller_role NOT IN \(([^)]*)\)'))[1], ',')),'''','')) AS r FROM pg_proc WHERE proname='repack_machine') x WHERE x.r <> ALL (public.push_dispatch_authorized_roles()))::text || '|' || (SELECT count(*) FROM (SELECT unnest(string_to_array((regexp_match(prosrc,'v_caller_role NOT IN \(([^)]*)\)'))[1], ',')) AS r FROM pg_proc WHERE proname='repack_machine') y)::text$c$,
 'eq','0|4', true, 'P4'),
(9, 79,
 $d$✅ D-43 HALF 2, POSITIONALLY. The pre-flight against push_dispatch_authorized_roles() appears in repack_machine's body BEFORE the first return_dispatch_line call. ⛔ Ordering IS the defect: repack has no savepoint, so a pre-flight placed after the return loop is not a pre-flight — it is a second error message on top of an already half-completed repack. ⚠️ push lets a NULL caller (service role) through its own gate and the pre-flight mirrors that exactly; any claim that this gates "every" caller would overclaim.$d$,
 $c$SELECT (strpos(prosrc,'push_dispatch_authorized_roles()') > 0 AND strpos(prosrc,'push_dispatch_authorized_roles()') < strpos(prosrc,'return_dispatch_line'))::text FROM pg_proc WHERE proname='repack_machine'$c$,
 'eq','true', true, 'P4'),
(9, 80,
 $d$⭐ AND THE DIVERGENCE CLASS IS CLOSED AT THE SOURCE, not merely watched: push_plan_to_dispatch gates on the named set and no longer carries the literal ARRAY['operator_admin','superadmin','manager'] that seq 2 used to pin. One place writes the role set down; both functions read it.$d$,
 $c$SELECT (prosrc LIKE '%push_dispatch_authorized_roles()%' AND prosrc NOT LIKE '%ARRAY[''operator_admin'',''superadmin'',''manager'']%')::text FROM pg_proc WHERE proname='push_plan_to_dispatch'$c$,
 'eq','true', true, 'P4');
