-- Refill System v2 / Phase 0 step 1 (B1) — draft-missing alert.
--
-- THE BUG: the 8pm Dubai cron (job 13, phaseF_stage1_prep_8pm_dubai) calls
-- build_draft_for_confirmed(CURRENT_DATE+1). That function returns a jsonb status of
-- 'draft_ready' | 'awaiting_confirmation' | 'no_included_machines' | error. pg_cron logs
-- ALL of these as "succeeded / 1 row" because the function did not raise. So when nobody
-- confirms the picked machines during the day, NO draft is produced and nobody is told.
-- Ops discovers the empty plan the next morning.
--
-- THE FIX (this migration): a second cron at 16:15 UTC (= 20:15 Dubai), 15 min after the
-- builder, that checks whether refill_plan_output actually has rows for CURRENT_DATE+1. If
-- not, it writes ONE monitoring_alerts finding with the precise reason (recomputed read-only
-- from machines_to_visit, mirroring _assert_gate_zero / build_draft_for_confirmed), deduped
-- per plan_date per day. This does NOT auto-confirm machines (PRD-015 human-gate rule stands);
-- it makes the silent no-op loud so ops can confirm before EOD.
--
-- Canonical: SECURITY DEFINER, sets app.via_rpc/app.rpc_name (Article 4), writes only
-- monitoring_alerts (NOT a protected entity), cron calls the RPC (Article 11). Mirrors the
-- already-approved cron_unmatched_weimi_alert. NOT YET APPLIED.

CREATE OR REPLACE FUNCTION public.cron_refill_draft_missing_alert()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id   uuid := (SELECT auth.uid());
  v_caller    text;
  v_target    date := CURRENT_DATE + 1;
  v_rows      int;
  v_picked    int;
  v_confirmed int;
  v_included  int;
  v_reason    text;
  v_inserted  int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cron_refill_draft_missing_alert', true);

  -- Cron-context guard: pg_cron/service_role (no auth.uid) proceeds; an authenticated
  -- caller must be manager-class. Mirrors cron_unmatched_weimi_alert.
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_caller FROM public.user_profiles WHERE id = v_user_id;
    IF v_caller IS NULL OR v_caller NOT IN ('operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'cron_refill_draft_missing_alert: forbidden for role %', COALESCE(v_caller,'unknown');
    END IF;
  END IF;

  -- Did the 8pm builder actually produce a plan for tomorrow?
  SELECT COUNT(*) INTO v_rows
  FROM public.refill_plan_output
  WHERE plan_date = v_target;

  IF v_rows > 0 THEN
    RETURN jsonb_build_object('status','ok','plan_date',v_target,
      'refill_plan_output_rows',v_rows,'inserted',0);
  END IF;

  -- No draft. Recompute the reason read-only, same predicates the builder uses.
  SELECT
    COUNT(*) FILTER (WHERE status = 'picked'),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL
                     AND COALESCE(is_included, true) = true)
  INTO v_picked, v_confirmed, v_included
  FROM public.machines_to_visit
  WHERE plan_date = v_target;

  v_reason := CASE
    WHEN COALESCE(v_picked,0) = 0                       THEN 'no_machines_picked'
    WHEN COALESCE(v_confirmed,0) < COALESCE(v_picked,0) THEN 'awaiting_confirmation'
    WHEN COALESCE(v_included,0) = 0                     THEN 'no_included_machines'
    ELSE 'engine_produced_no_rows'
  END;

  -- Dedupe: one finding per plan_date per calendar day.
  INSERT INTO public.monitoring_alerts (source, severity, payload)
  SELECT 'refill_draft_missing', 'critical',
    jsonb_build_object(
      'plan_date',      v_target,
      'reason',         v_reason,
      'machines_picked',    COALESCE(v_picked,0),
      'machines_confirmed', COALESCE(v_confirmed,0),
      'machines_included',  COALESCE(v_included,0),
      'action_needed',  CASE v_reason
        WHEN 'awaiting_confirmation' THEN 'Picked machines are unconfirmed. Confirm them in /refill so the 8pm builder can run, then re-run build_draft_for_confirmed.'
        WHEN 'no_machines_picked'    THEN 'The 6am picker selected no machines for tomorrow. Check pick_machines_for_refill (job 14).'
        WHEN 'no_included_machines'  THEN 'All confirmed machines are excluded (is_included=false). Include at least one in /refill.'
        ELSE 'Machines confirmed and included, but the engine produced 0 rows. Check engine_add_pod / engine_swap_pod for errors.'
      END,
      'detected_at',    now())
  WHERE NOT EXISTS (
    SELECT 1 FROM public.monitoring_alerts a
    WHERE a.source = 'refill_draft_missing'
      AND (a.payload->>'plan_date') = v_target::text
      AND a.created_at::date = CURRENT_DATE
  );
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN jsonb_build_object('status','draft_missing','plan_date',v_target,
    'reason',v_reason,'refill_plan_output_rows',0,
    'machines_picked',COALESCE(v_picked,0),'machines_confirmed',COALESCE(v_confirmed,0),
    'machines_included',COALESCE(v_included,0),'inserted',v_inserted,'ran_at',now());
END $function$;
GRANT EXECUTE ON FUNCTION public.cron_refill_draft_missing_alert() TO authenticated;

-- 16:15 UTC = 20:15 Dubai, 15 min after the 8pm builder (job 13 @ 16:00 UTC).
SELECT cron.schedule('refill_draft_missing_alert', '15 16 * * *',
  'SELECT public.cron_refill_draft_missing_alert();');
