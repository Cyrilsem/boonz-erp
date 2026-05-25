-- PRD-Phase-G v2 A.5: narrow eod_auto_release_unpicked sweep to actions that
-- actually moved stock at pack time. Case-sensitive IN-list matches the
-- pack_dispatch_line short-circuit exactly: ('Refill','Add New','Add').
-- Other variants (REMOVE, Machine To Warehouse, REFILL upper, ADD NEW upper,
-- MOVE, etc.) all short-circuit in pack with no WH decrement, so sweeping
-- them via return_dispatch_line creates phantom WH credits (the bug).
-- After CREATE OR REPLACE lands, re-enable cron job 9 atomically.
-- Cody-approved against Articles 1, 4, 11, 12. Applied to prod 2026-05-25.

CREATE OR REPLACE FUNCTION public.eod_auto_release_unpicked()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_today        date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  v_released     int  := 0;
  v_failed       int  := 0;
  v_failed_ids   uuid[] := ARRAY[]::uuid[];
  v_row          record;
  v_result       jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','eod_auto_release_unpicked',true);
  PERFORM set_config('app.mutation_reason',
    format('eod_auto_release_unpicked sweep for %s', v_today),
    true);

  FOR v_row IN
    SELECT dispatch_id
    FROM refill_dispatching
    WHERE dispatch_date = v_today
      AND packed       = true
      AND picked_up    = false
      AND returned     = false
      AND item_added   = false
      AND action       IN ('Refill','Add New','Add')
    ORDER BY created_at ASC
  LOOP
    BEGIN
      v_result   := public.return_dispatch_line(v_row.dispatch_id, 'auto_release_unpicked_eod');
      v_released := v_released + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed     := v_failed + 1;
      v_failed_ids := v_failed_ids || v_row.dispatch_id;
      RAISE WARNING 'eod_auto_release_unpicked: failed to release %, error: %',
        v_row.dispatch_id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status',     'ok',
    'run_date',   v_today,
    'released',   v_released,
    'failed',     v_failed,
    'failed_ids', v_failed_ids
  );
END;
$function$;

SELECT cron.alter_job(job_id := 9::bigint, active := true);
