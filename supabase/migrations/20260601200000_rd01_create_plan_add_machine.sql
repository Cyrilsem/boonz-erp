-- RD-01: ad-hoc plan / add-machine on refill day. Two canonical writers on machines_to_visit.
-- NOT YET APPLIED (Refill-Day batch; output-only goal — CS reviews + applies).
--
-- machines_to_visit.status already allows 'cs_added' (live constraint:
--   picked|cs_added|cs_dropped|completed|superseded), so only the add_source provenance column is new.
-- Neither RPC runs the engine (preserves the human-confirm gate, feedback_cron_keep_human_confirm).
-- Audited by the existing tg_audit_machines_to_visit. Cody: Articles 2,3,4,5,8,12,14.

ALTER TABLE public.machines_to_visit
  ADD COLUMN IF NOT EXISTS add_source text NOT NULL DEFAULT 'picker'
  CHECK (add_source IN ('picker','operator','sibling','driver_callout'));

-- ── add_machine_to_plan: insert/re-include one machine as cs_added/operator ──────────────────
CREATE OR REPLACE FUNCTION public.add_machine_to_plan(
  p_plan_date  date,
  p_machine_id uuid,
  p_confirm    boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_exists  boolean;
  v_h       public.v_machine_health_signals%ROWTYPE;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','add_machine_to_plan',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: add_machine_to_plan requires operator_admin/superadmin/warehouse';
  END IF;

  IF p_plan_date IS NULL OR p_machine_id IS NULL THEN
    RAISE EXCEPTION 'add_machine_to_plan: p_plan_date and p_machine_id required';
  END IF;

  -- E2: machine must exist and not be repurposed.
  IF NOT EXISTS (SELECT 1 FROM public.machines WHERE machine_id = p_machine_id AND repurposed_at IS NULL) THEN
    RAISE EXCEPTION 'add_machine_to_plan: machine % not found or repurposed', p_machine_id;
  END IF;

  -- E1: already in plan -> re-include (idempotent), keep picker provenance/status.
  SELECT EXISTS (SELECT 1 FROM public.machines_to_visit WHERE plan_date=p_plan_date AND machine_id=p_machine_id)
    INTO v_exists;
  IF v_exists THEN
    UPDATE public.machines_to_visit
       SET is_included  = true,
           confirmed_at = CASE WHEN p_confirm THEN COALESCE(confirmed_at, now()) ELSE confirmed_at END,
           confirmed_by = CASE WHEN p_confirm THEN COALESCE(confirmed_by, v_user_id::text) ELSE confirmed_by END,
           updated_at   = now()
     WHERE plan_date=p_plan_date AND machine_id=p_machine_id;
    RETURN jsonb_build_object('status','already_in_plan','plan_date',p_plan_date,
      'machine_id',p_machine_id,'re_included',true);
  END IF;

  -- Health snapshot (best-effort; mirrors the columns the picker writes).
  SELECT * INTO v_h FROM public.v_machine_health_signals WHERE machine_id = p_machine_id;

  INSERT INTO public.machines_to_visit(
    plan_date, machine_id, official_name, location_type, venue_group, building_id,
    dead_slot_pct, days_since_visit, empty_shelf_pct, active_intent_count, is_ramping,
    picked_reasons, priority_score, picked_at, picked_by, status, is_included, add_source,
    confirmed_at, confirmed_by, fill_pct, hero_slot_count, expired_skus_now, expired_skus_30d,
    units_last_7d, health_tier, expired_skus_3d, expired_skus_7d, runway_days, empty_shelves_count
  ) VALUES (
    p_plan_date, p_machine_id,
    COALESCE(v_h.official_name, (SELECT official_name FROM public.machines WHERE machine_id=p_machine_id)),
    v_h.location_type, v_h.venue_group, v_h.building_id,
    v_h.dead_slot_pct, v_h.days_since_visit, v_h.empty_shelf_pct,
    COALESCE(v_h.active_intent_count,0), COALESCE(v_h.is_ramping,false),
    ARRAY['operator_added']::text[], 0, now(), v_user_id, 'cs_added', true, 'operator',
    CASE WHEN p_confirm THEN now()            ELSE NULL END,
    CASE WHEN p_confirm THEN v_user_id::text  ELSE NULL END,
    v_h.fill_pct, v_h.hero_slot_count, v_h.expired_skus_now, v_h.expired_skus_30d,
    v_h.units_last_7d, v_h.tier, v_h.expired_skus_3d, v_h.expired_skus_7d, v_h.runway_days, v_h.empty_shelves_count
  );

  RETURN jsonb_build_object('status','added','plan_date',p_plan_date,'machine_id',p_machine_id,
    'mtv_status','cs_added','add_source','operator','is_included',true,'confirmed',p_confirm);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.add_machine_to_plan(date,uuid,boolean) TO authenticated;

-- ── create_refill_plan: convenience wrapper; does NOT auto-run the engine ────────────────────
CREATE OR REPLACE FUNCTION public.create_refill_plan(
  p_plan_date   date,
  p_machine_ids uuid[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid; v_id uuid; v_added int := 0; v_reincluded int := 0; v_r jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','create_refill_plan',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN
    RAISE EXCEPTION 'forbidden: create_refill_plan requires operator_admin/superadmin/warehouse';
  END IF;
  IF p_plan_date IS NULL OR p_machine_ids IS NULL OR array_length(p_machine_ids,1) IS NULL THEN
    RAISE EXCEPTION 'create_refill_plan: p_plan_date and non-empty p_machine_ids required';
  END IF;

  -- E5: one bad id raises inside add_machine_to_plan -> whole call rolls back (atomic).
  FOREACH v_id IN ARRAY p_machine_ids LOOP
    v_r := public.add_machine_to_plan(p_plan_date, v_id, true);
    IF v_r->>'status' = 'added' THEN v_added := v_added + 1; ELSE v_reincluded := v_reincluded + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object('status','ok','plan_date',p_plan_date,
    'machines', array_length(p_machine_ids,1), 'added', v_added, 're_included', v_reincluded,
    'note','engine NOT auto-run; run build_draft_for_confirmed to build the draft (confirm gate preserved)');
END;
$function$;
GRANT EXECUTE ON FUNCTION public.create_refill_plan(date,uuid[]) TO authenticated;
