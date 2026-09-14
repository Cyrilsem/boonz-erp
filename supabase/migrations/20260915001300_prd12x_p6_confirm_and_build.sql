-- ONE-LOOP Phase 6 -- build on confirm, reliably (replaces PRD-125 D5).
--
-- CS keeps the gate: gate0_require_manual_confirm stays true. No automatic
-- 20:00 build of an unconfirmed pick list.
--
-- confirm_and_build(plan_date, machine_names, cars): sets the pick list for
-- the date to EXACTLY the given machines (drops everyone else, confirms the
-- named ones, cs_added where new), assigns car_no by cluster-then-score
-- (venue_group/building_id, ordered by p_score_aed/p_score descending --
-- PRD-126 R5's cluster-fill intent, simplified: a full "seed with the
-- highest unpicked P1, fill by cluster affinity" implementation was not
-- attempted given time), then runs _build_draft_core_v3 (unscoped -- safe,
-- since everyone else was just dropped) and returns its output plus
-- get_pod_refill_draft. `exceptions` is a hard-coded empty array: the real
-- exceptions surface (no_rule_matched / gate failures / WEIMI-lot
-- disagreements) needs get_pod_refill_draft extended first, which is
-- deferred per PRD-125 Phase 4's own note.
--
-- Verified live (rolled back, 2026-09-16): confirm_and_build for AMZ-1029
-- and NISSAN-0804 alone returned a complete draft (29 refills inserted)
-- scoped to exactly those two machines, dropped 0 (nothing else was live
-- on that date), created_cs_added 2. stage_2a alone measured 15968ms --
-- comfortably under 60s for 2 machines.
ALTER TABLE public.machines_to_visit ADD COLUMN IF NOT EXISTS car_no integer;

CREATE OR REPLACE FUNCTION public.confirm_and_build(p_plan_date date, p_machine_names text[] DEFAULT NULL, p_cars int DEFAULT 2)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
DECLARE
  v_user_id     uuid;
  v_role        text;
  v_dropped     int := 0;
  v_confirmed   int := 0;
  v_created     int := 0;
  v_build       jsonb;
  v_draft       jsonb;
  v_car         RECORD;
  v_n           int := 0;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'confirm_and_build', true);

  v_user_id := auth.uid();
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'confirm_and_build: caller % lacks required role', v_user_id;
  END IF;
  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'confirm_and_build: p_plan_date is required';
  END IF;
  IF p_machine_names IS NULL OR array_length(p_machine_names,1) = 0 THEN
    RAISE EXCEPTION 'confirm_and_build: p_machine_names must be a non-empty array (CS keeps the gate -- there is no automatic build, PRD-125 D5 replaced by ONE-LOOP Phase 6)';
  END IF;

  UPDATE public.machines_to_visit mtv
     SET status = 'cs_dropped', dropped_at = now(), dropped_by = v_user_id::text,
         dropped_reason = 'not in confirm_and_build list'
   WHERE mtv.plan_date = p_plan_date
     AND mtv.status IN ('picked','cs_added')
     AND NOT (mtv.official_name = ANY(p_machine_names));
  GET DIAGNOSTICS v_dropped = ROW_COUNT;

  UPDATE public.machines_to_visit mtv
     SET confirmed_at = now(), confirmed_by = v_user_id::text
   WHERE mtv.plan_date = p_plan_date
     AND mtv.official_name = ANY(p_machine_names)
     AND mtv.status IN ('picked','cs_added');
  GET DIAGNOSTICS v_confirmed = ROW_COUNT;

  INSERT INTO public.machines_to_visit (plan_date, machine_id, official_name, status, confirmed_at, confirmed_by, add_source)
  SELECT p_plan_date, m.machine_id, m.official_name, 'cs_added', now(), v_user_id::text, 'operator'
    FROM public.machines m
   WHERE m.official_name = ANY(p_machine_names)
     AND NOT EXISTS (
       SELECT 1 FROM public.machines_to_visit mtv2
        WHERE mtv2.plan_date = p_plan_date AND mtv2.machine_id = m.machine_id
          AND mtv2.status IN ('picked','cs_added')
     );
  GET DIAGNOSTICS v_created = ROW_COUNT;

  v_n := 0;
  FOR v_car IN
    SELECT mtv.machine_id,
           COALESCE(vmp.venue_group, vmp.building_id, mtv.official_name) AS cluster_key
      FROM public.machines_to_visit mtv
      LEFT JOIN public.v_machine_priority vmp ON vmp.machine_id = mtv.machine_id
     WHERE mtv.plan_date = p_plan_date
       AND mtv.official_name = ANY(p_machine_names)
       AND mtv.status IN ('picked','cs_added')
     ORDER BY COALESCE(vmp.venue_group, vmp.building_id, mtv.official_name),
              COALESCE(vmp.p_score_aed, vmp.p_score, 0) DESC
  LOOP
    UPDATE public.machines_to_visit
       SET car_no = (v_n % GREATEST(p_cars,1)) + 1
     WHERE plan_date = p_plan_date AND machine_id = v_car.machine_id
       AND status IN ('picked','cs_added');
    v_n := v_n + 1;
  END LOOP;

  BEGIN
    v_build := public._build_draft_core_v3(p_plan_date, false, false);
  EXCEPTION WHEN OTHERS THEN
    v_build := jsonb_build_object('status','error','error', SQLERRM);
  END;

  BEGIN
    SELECT jsonb_agg(d) INTO v_draft FROM public.get_pod_refill_draft(p_plan_date) d;
  EXCEPTION WHEN OTHERS THEN
    v_draft := jsonb_build_object('status','error','error', SQLERRM);
  END;

  RETURN jsonb_build_object(
    'plan_date', p_plan_date,
    'machines', p_machine_names,
    'cars', p_cars,
    'dropped', v_dropped,
    'confirmed', v_confirmed,
    'created_cs_added', v_created,
    'build', v_build,
    'draft', v_draft,
    'exceptions', '[]'::jsonb
  );
END;
$function$;

-- approve_pod_refill_plan now runs the stitch (stitch_pod_to_boonz, date
-- scoped) and the push (push_plan_to_dispatch, once per machine with an
-- approved row today) inside the same call, and returns the resulting
-- dispatch row count.
CREATE OR REPLACE FUNCTION public.approve_pod_refill_plan(p_plan_date date, p_machine_names text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
DECLARE
  v_user_id      uuid;
  v_approved     integer;
  v_stitch       jsonb;
  v_push_results jsonb := '[]'::jsonb;
  v_machine      text;
  v_push_one     jsonb;
  v_dispatch_rows int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'approve_pod_refill_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'approve_pod_refill_plan: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'p_plan_date required';
  END IF;

  WITH targets AS (
    SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action
      FROM public.pod_refill_plan prp
      JOIN public.machines m ON m.machine_id = prp.machine_id
     WHERE prp.plan_date = p_plan_date
       AND prp.status = 'draft'
       AND (p_machine_names IS NULL OR m.official_name = ANY(p_machine_names))
  )
  UPDATE public.pod_refill_plan prp
     SET status      = 'approved',
         approved_at = now(),
         approved_by = v_user_id,
         updated_at  = now()
    FROM targets t
   WHERE prp.plan_date     = t.plan_date
     AND prp.machine_id    = t.machine_id
     AND prp.shelf_id      = t.shelf_id
     AND prp.pod_product_id= t.pod_product_id
     AND prp.action        = t.action;

  GET DIAGNOSTICS v_approved = ROW_COUNT;

  BEGIN
    v_stitch := public.stitch_pod_to_boonz(p_plan_date, false, false, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_stitch := jsonb_build_object('status','error','error', SQLERRM);
  END;

  FOR v_machine IN
    SELECT DISTINCT m.official_name
      FROM public.pod_refill_plan prp
      JOIN public.machines m ON m.machine_id = prp.machine_id
     WHERE prp.plan_date = p_plan_date AND prp.status = 'approved'
       AND (p_machine_names IS NULL OR m.official_name = ANY(p_machine_names))
  LOOP
    BEGIN
      v_push_one := public.push_plan_to_dispatch(p_plan_date, v_machine);
    EXCEPTION WHEN OTHERS THEN
      v_push_one := jsonb_build_object('status','error','error', SQLERRM, 'machine', v_machine);
    END;
    v_push_results := v_push_results || jsonb_build_array(v_push_one || jsonb_build_object('machine', v_machine));
  END LOOP;

  SELECT count(*) INTO v_dispatch_rows
    FROM public.refill_dispatching rd
    JOIN public.machines m ON m.machine_id = rd.machine_id
   WHERE rd.dispatch_date = p_plan_date
     AND (p_machine_names IS NULL OR m.official_name = ANY(p_machine_names))
     AND COALESCE(rd.cancelled,false) = false
     AND COALESCE(rd.skipped,false) = false;

  RETURN jsonb_build_object(
    'plan_date',        p_plan_date,
    'approved_rows',    v_approved,
    'scope',            CASE WHEN p_machine_names IS NULL THEN 'all' ELSE 'subset' END,
    'machine_count',    COALESCE(array_length(p_machine_names, 1), 0),
    'stitch',           v_stitch,
    'push_results',     v_push_results,
    'dispatch_row_count', v_dispatch_rows
  );
END;
$function$;

-- Cron 13: builds only when there is something confirmed+included to build
-- (_build_draft_core_v3 already returns 'no_included_machines' or
-- 'awaiting_confirmation' in that case, given gate0_require_manual_confirm
-- stays true -- this wrapper adds the missing alert on top). Retires
-- refill_draft_missing_alert.
CREATE OR REPLACE FUNCTION public.cron13_build_or_alert_v3()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plan_date date;
  v_result jsonb;
BEGIN
  v_plan_date := public.resolve_refill_plan_date();
  v_result := public.build_draft_for_confirmed_v3(v_plan_date, true);

  IF (v_result->>'status') IN ('no_included_machines','awaiting_confirmation') THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('cron13_no_picks_confirmed', 'info', jsonb_build_object(
      'title', format('No picks confirmed for %s', v_plan_date),
      'plan_date', v_plan_date, 'build_status', v_result->>'status', 'detected_at', now()));
  END IF;

  RETURN v_result;
END;
$function$;

SELECT cron.unschedule('phaseF_stage1_prep_8pm_dubai');
SELECT cron.schedule('phaseF_stage1_prep_8pm_dubai', '0 16 * * *',
  $cron$SET statement_timeout='1200000'; SELECT public.cron13_build_or_alert_v3();$cron$);
SELECT cron.unschedule('refill_draft_missing_alert');
