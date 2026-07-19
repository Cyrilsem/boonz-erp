-- ROLLBACK PRE-IMAGE (Batch 4 / RC-07) — VERBATIM live body captured 2026-07-18 from eizcexopcuoycuosittm
-- object: repack_machine(text,date,text)
-- md5(pg_get_functiondef) = e6a7d13f41e5876bf5dacd9f9eee0447
-- restore via: CREATE OR REPLACE (same signature)
CREATE OR REPLACE FUNCTION public.repack_machine(p_machine_name text, p_dispatch_date date DEFAULT NULL::date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role      text;
  v_machine_id       uuid;
  v_today            date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  v_target_date      date;
  v_returned_count   int := 0;
  v_failed_returns   int := 0;
  v_resets_done      int := 0;
  v_pushed           int := 0;
  v_dispatched_count int := 0;
  v_row              record;
  v_push_result      jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','repack_machine',true);
  PERFORM set_config('app.mutation_reason',
    format('repack_machine: %s for %s (reason: %s)',
           p_machine_name,
           COALESCE(p_dispatch_date, (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date),
           COALESCE(p_reason,'none')),
    true);

  -- Caller role guard
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RETURN jsonb_build_object('status','error','error','Insufficient role');
  END IF;

  v_target_date := COALESCE(p_dispatch_date, v_today);

  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: ' || p_machine_name);
  END IF;

  -- 🛑 Dispatch gate: refuse repack if ANY row for this (machine, date) is dispatched=true.
  -- Once the bag has been dispatched, returning stock to the warehouse is no longer accurate.
  SELECT COUNT(*) INTO v_dispatched_count
  FROM refill_dispatching
  WHERE machine_id    = v_machine_id
    AND dispatch_date = v_target_date
    AND dispatched    = true;

  IF v_dispatched_count > 0 THEN
    RETURN jsonb_build_object(
      'status','error',
      'error','cannot_repack_after_dispatch',
      'message', format('Cannot repack %s for %s — %s row(s) already dispatched.',
                        p_machine_name, v_target_date, v_dispatched_count),
      'dispatched_count', v_dispatched_count,
      'machine', p_machine_name,
      'dispatch_date', v_target_date
    );
  END IF;

  -- Step 1: Return stock & mark each packed-not-picked-up row terminal
  FOR v_row IN
    SELECT dispatch_id, shelf_id, boonz_product_id, action
    FROM refill_dispatching
    WHERE machine_id    = v_machine_id
      AND dispatch_date = v_target_date
      AND packed        = true
      AND picked_up     = false
      AND returned      = false
      AND item_added    = false
    ORDER BY created_at
  LOOP
    BEGIN
      PERFORM public.return_dispatch_line(v_row.dispatch_id, 'superseded_by_repack');
      v_returned_count := v_returned_count + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed_returns := v_failed_returns + 1;
      RAISE WARNING 'repack_machine: return_dispatch_line failed for %, error: %',
        v_row.dispatch_id, SQLERRM;
    END;
  END LOOP;

  -- Step 2: Reset matching plan rows so push_plan_to_dispatch can re-mirror.
  -- Only reset rows whose 1:1 matching dispatch row is now terminal AND not received.
  UPDATE refill_plan_output rpo
  SET dispatched = false
  WHERE rpo.plan_date        = v_target_date
    AND rpo.machine_name     = p_machine_name
    AND rpo.operator_status  = 'approved'
    AND rpo.dispatched       = true
    AND NOT EXISTS (
      -- skip plan rows whose dispatch was successfully received (item_added=true)
      SELECT 1
      FROM refill_dispatching rd
      JOIN machines m ON m.machine_id = rd.machine_id
      LEFT JOIN shelf_configurations sc ON sc.shelf_id = rd.shelf_id
      WHERE m.official_name = rpo.machine_name
        AND rd.dispatch_date = rpo.plan_date
        AND COALESCE(sc.shelf_code,'') = COALESCE(rpo.shelf_code,'')
        AND rd.item_added = true
    );
  GET DIAGNOSTICS v_resets_done = ROW_COUNT;

  -- Step 3: Push the plan rows fresh
  IF v_resets_done > 0 THEN
    v_push_result := public.push_plan_to_dispatch(p_machine_name, v_target_date);
    v_pushed := COALESCE((v_push_result->>'lines_pushed')::int, 0);
  END IF;

  RETURN jsonb_build_object(
    'status',           'ok',
    'machine',          p_machine_name,
    'dispatch_date',    v_target_date,
    'returned_count',   v_returned_count,
    'failed_returns',   v_failed_returns,
    'plan_rows_reset',  v_resets_done,
    'fresh_dispatch_rows_created', v_pushed,
    'reason',           p_reason
  );
END;
$function$

