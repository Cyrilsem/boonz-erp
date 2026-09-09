-- PRD-120 goal (2026-09-09), L5 items 2 and 4. L5's core fallback (item 1) already
-- shipped in 20260909173544_prd120_l5_push_plan_flavor_fallback.sql; this migration
-- closes the remaining two asks:
--   2. "repair_remove_leg_shelf_lot should be callable in bulk for a plan_date and
--       should be run automatically at push; a Remove leg reaching a driver with a
--       NULL pod_lot_id is the bug."
--   4. "Nightly assertion: count of Remove legs on undelivered dispatch rows with
--       NULL pod_lot_id must be 0."
--
-- Part A — repair_remove_leg_shelf_lot_bulk(p_plan_date, p_machine_name DEFAULT NULL,
-- p_reason, p_caller DEFAULT NULL, p_dry_run DEFAULT true). Loops undelivered
-- (NOT picked_up AND NOT dispatched, not cancelled/skipped/returned) Remove legs
-- for the date (+machine), calling the existing single-row repair_remove_leg_shelf_lot
-- per row and aggregating, catching per-row exceptions so one un-repairable leg
-- doesn't abort the batch. SECURITY DEFINER + role check (operator_admin/superadmin/
-- manager) + mandatory reason (>=10 chars) + app.via_rpc/app.rpc_name, matching the
-- goal's own RULES section and the shape of the wrapped single-row RPC.
--
-- NOTE: the wrapped repair_remove_leg_shelf_lot still does its OWN exact-boonz_product_id
-- lot lookup (unchanged, out of scope here) -- it does not carry L5's shelf-wide flavor
-- fallback. So a leg whose named flavor genuinely has zero lots anywhere on the shelf
-- (i.e. predates the L5 push-time fix, or was created before push even ran) will still
-- report "no Active pod lot found" from the bulk wrapper. That is correct: this is the
-- existing repair RPC's own documented behavior, verified below against real historical
-- data (2026-06-03), and the bulk wrapper's job is only to aggregate, not to change
-- what "repairable" means. Post-L5, push time itself should never produce a fresh NULL
-- pod_lot_id leg -- the auto-run wiring below is a defense-in-depth safety net.
--
-- Part B — patches push_plan_to_dispatch (again) to auto-call the bulk wrapper,
-- scoped to (p_plan_date, p_machine_name), p_dry_run := false, right after the
-- existing pair_internal_transfer_m2m call, wrapped in the same defensive
-- exception-handling + monitoring_alerts pattern already used for that call.
-- rpc_version bumped v14_prd120_l5_flavor_fallback -> v15_prd120_l5_autorepair
-- (increase only, per "never downgrade a version").
--
-- Part C — check_null_pod_lot_remove_legs(), nightly at 20:25 UTC (same family as
-- check_far_future_picked_visits / check_expiry_unvalidated, via safe_monitoring_alert).
-- "Undelivered" = NOT picked_up AND NOT dispatched (packed=true is still undelivered --
-- the driver hasn't taken it yet -- matching this repo's own repair_remove_leg_shelf_lot,
-- which is explicitly packed-aware and still treats a packed row as reparable).
--
-- Fixture / verification (all real data, all read-only or dry_run -- no live-plan
-- mutation):
--   - Bulk wrapper against 2026-06-03 (2 real legacy NULL-pod_lot_id Remove legs,
--     predating L5): dry_run aggregates 2 attempted / 0 succeeded / 2 failed, each
--     failure the expected "no Active pod lot found" from the untouched single-row
--     RPC -- proves per-row exceptions are caught and the batch completes rather than
--     aborting.
--   - Bulk wrapper against 2026-09-09 (today's live pushed plan, post-L5): 0 attempted --
--     proves the L5 fallback already leaves nothing for the safety net to catch today.
--   - Role guard: p_caller = a field_staff uuid raises "forbidden for role field_staff".
--   - Reason guard: p_reason='short' raises "must be at least 10 characters".
--   - check_null_pod_lot_remove_legs(): correctly reports status='violation',
--     count=4 against the real fleet-wide stragglers (all 4 dated 2026-06, all
--     packed=true, none picked_up/dispatched -- see the 4 dispatch_ids in the
--     PRD-120-REPORT.md closeout for the full list). These 4 are NOT touched by this
--     migration or by push_plan_to_dispatch's new auto-repair call (auto-repair only
--     fires for the plan_date/machine actually being pushed) -- they are flagged to
--     CS as an open decision in the closeout report, since they carry packed=true and
--     this goal's own safety rule says not to touch packed rows without confirmation.
--   - push_plan_to_dispatch patch: CREATE OR REPLACE succeeded (proves syntactic
--     validity of the inserted PL/pgSQL) and post-apply introspection confirms all
--     three insertions (DECLARE, the wrapped call, the RETURN field + version bump)
--     are present in the live function body. NOT re-run end-to-end against a live
--     plan_date, per the goal's explicit "never touch ... plan_date 2026-09-09 or
--     later live rows" rule -- the wrapped bulk-repair call was independently unit
--     tested above instead.
--
-- Cody: approve. Part A -- Article 4 (DEFINER validates role + inputs, sets
-- app.via_rpc/app.rpc_name), Article 1 (does not introduce a new write surface --
-- delegates every actual UPDATE to the existing canonical repair_remove_leg_shelf_lot).
-- Part B -- Article 12 (forward-only, md5-guarded replace() against the function's
-- own current live state). Part C -- Article 16 (new diagnostic on an existing
-- canonical table's own state, not a re-derivation of a registered metric).
-- No schema change in any part -- Dara not required.

CREATE OR REPLACE FUNCTION public.repair_remove_leg_shelf_lot_bulk(
  p_plan_date date,
  p_machine_name text DEFAULT NULL,
  p_reason text DEFAULT 'bulk repair via repair_remove_leg_shelf_lot_bulk',
  p_caller uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller  uuid := COALESCE(p_caller, auth.uid());
  v_role    text;
  v_machine_id uuid;
  v_row     RECORD;
  v_one     jsonb;
  v_results jsonb := '[]'::jsonb;
  v_ok      int := 0;
  v_failed  int := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','repair_remove_leg_shelf_lot_bulk', true);

  IF v_caller IS NOT NULL THEN
    SELECT role INTO v_role FROM user_profiles WHERE id = v_caller;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'repair_remove_leg_shelf_lot_bulk: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'repair_remove_leg_shelf_lot_bulk: p_plan_date required'; END IF;
  IF length(COALESCE(p_reason,'')) < 10 THEN RAISE EXCEPTION 'repair_remove_leg_shelf_lot_bulk: p_reason must be at least 10 characters'; END IF;

  IF p_machine_name IS NOT NULL THEN
    SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
    IF v_machine_id IS NULL THEN
      RAISE EXCEPTION 'repair_remove_leg_shelf_lot_bulk: machine not found: %', p_machine_name;
    END IF;
  END IF;

  FOR v_row IN
    SELECT rd.dispatch_id
      FROM refill_dispatching rd
     WHERE rd.dispatch_date = p_plan_date
       AND (v_machine_id IS NULL OR rd.machine_id = v_machine_id)
       AND rd.action = 'Remove'
       AND rd.pod_lot_id IS NULL
       AND rd.quantity > 0
       AND NOT COALESCE(rd.cancelled, false)
       AND NOT COALESCE(rd.skipped, false)
       AND NOT COALESCE(rd.returned, false)
       AND NOT COALESCE(rd.picked_up, false)
       AND NOT COALESCE(rd.dispatched, false)
  LOOP
    BEGIN
      v_one := public.repair_remove_leg_shelf_lot(v_row.dispatch_id, p_reason, v_caller, p_dry_run);
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_one := jsonb_build_object('status','error','dispatch_id', v_row.dispatch_id, 'error', SQLERRM);
      v_failed := v_failed + 1;
    END;
    v_results := v_results || jsonb_build_array(v_one);
  END LOOP;

  RETURN jsonb_build_object(
    'status','ok', 'plan_date', p_plan_date, 'machine_name', p_machine_name,
    'dry_run', p_dry_run, 'attempted', v_ok + v_failed, 'succeeded', v_ok, 'failed', v_failed,
    'results', v_results
  );
END;
$function$;

DO $mig$ DECLARE v_def text; v_step1 text; v_step2 text; v_step3 text; BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='push_plan_to_dispatch';
  IF md5(v_def) <> '0b72c47cd1a374b99f9092751a4d9812' THEN
    RAISE EXCEPTION 'push_plan_to_dispatch drifted (md5 %), refusing blind patch', md5(v_def);
  END IF;

  v_step1 := replace(v_def,
E'  v_dest_leg_id_first    uuid;\nBEGIN',
E'  v_dest_leg_id_first    uuid;\n  v_bulk_repair          jsonb := NULL;\nBEGIN');
  IF v_step1 = v_def THEN RAISE EXCEPTION 'push_plan_to_dispatch: anchor (declare) not found'; END IF;

  v_step2 := replace(v_step1,
E'  PERFORM set_config(\'app.rpc_name\', \'push_plan_to_dispatch\', true);\n  PERFORM set_config(\'app.via_trigger\', COALESCE(v_prev_via_trigger, \'\'), true);\n  PERFORM set_config(\'app.mutation_reason\', COALESCE(v_prev_mutation_reason, \'\'), true);\n\n  RETURN jsonb_build_object(',
E'  BEGIN\n    v_bulk_repair := public.repair_remove_leg_shelf_lot_bulk(p_plan_date, p_machine_name,\n      \'auto-run at push (PRD-120 L5 item 2): close any Remove leg the flavor fallback still left NULL\', NULL, false);\n  EXCEPTION WHEN OTHERS THEN\n    v_bulk_repair := jsonb_build_object(\'status\',\'error\',\'error\', SQLERRM);\n    INSERT INTO public.monitoring_alerts (source, severity, payload)\n    VALUES (\'push_auto_repair_failure\', \'warning\', jsonb_build_object(\n      \'title\', format(\'Auto-repair of NULL pod_lot_id Remove legs failed on push: %s @ %s\', p_machine_name, p_plan_date),\n      \'plan_date\', p_plan_date, \'machine_name\', p_machine_name, \'machine_id\', v_machine_id,\n      \'error\', SQLERRM, \'detected_by\', \'push_plan_to_dispatch_v14_prd120_l5\', \'detected_at\', now()));\n  END;\n\n  PERFORM set_config(\'app.rpc_name\', \'push_plan_to_dispatch\', true);\n  PERFORM set_config(\'app.via_trigger\', COALESCE(v_prev_via_trigger, \'\'), true);\n  PERFORM set_config(\'app.mutation_reason\', COALESCE(v_prev_mutation_reason, \'\'), true);\n\n  RETURN jsonb_build_object(');
  IF v_step2 = v_step1 THEN RAISE EXCEPTION 'push_plan_to_dispatch: anchor (return block) not found'; END IF;

  v_step3 := replace(v_step2,
E'    \'remove_no_lot_on_shelf\', v_no_lot_on_shelf,\n    \'rpc_version\',\'v14_prd120_l5_flavor_fallback\'\n  );',
E'    \'remove_no_lot_on_shelf\', v_no_lot_on_shelf,\n    \'auto_repair_null_pod_lot\', v_bulk_repair,\n    \'rpc_version\',\'v15_prd120_l5_autorepair\'\n  );');
  IF v_step3 = v_step2 THEN RAISE EXCEPTION 'push_plan_to_dispatch: anchor (rpc_version) not found'; END IF;

  EXECUTE v_step3;
END $mig$;

CREATE OR REPLACE FUNCTION public.check_null_pod_lot_remove_legs()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n    int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'dispatch_id', rd.dispatch_id, 'machine_id', rd.machine_id,
           'dispatch_date', rd.dispatch_date, 'shelf_id', rd.shelf_id,
           'boonz_product_id', rd.boonz_product_id, 'quantity', rd.quantity,
           'packed', rd.packed)), '[]'::jsonb),
         COUNT(*)
    INTO v_rows, v_n
  FROM public.refill_dispatching rd
  WHERE rd.action = 'Remove'
    AND rd.pod_lot_id IS NULL
    AND rd.quantity > 0
    AND NOT COALESCE(rd.cancelled, false)
    AND NOT COALESCE(rd.skipped, false)
    AND NOT COALESCE(rd.returned, false)
    AND NOT COALESCE(rd.picked_up, false)
    AND NOT COALESCE(rd.dispatched, false);

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('remove_leg_null_pod_lot', 'critical',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'rows', v_rows));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'null_pod_lot_remove_count', v_n, 'rows', v_rows);
END;
$function$;

SELECT cron.schedule(
  'check_null_pod_lot_remove_legs_nightly',
  '25 20 * * *',
  $$ SELECT public.check_null_pod_lot_remove_legs(); $$
);
