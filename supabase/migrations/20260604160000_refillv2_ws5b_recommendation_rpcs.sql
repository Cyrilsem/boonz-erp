-- Refill reliability / WS5b - recommendation translator RPCs. STATUS: DRAFT - NOT APPLIED. Cody-reviewed.
--
-- Pipeline (PRD WS5, human-in-the-loop):
--   1. Claude parses free text -> calls propose_recommendation_intent (status='proposed').
--   2. A human reviews and calls confirm_recommendation_intent (proposed->confirmed) or reject.
--   3. apply_recommendation_intent (requires confirmed) applies it:
--        boonz-level increase/decrease_weight -> apply_mix_weight_recommendation (per-machine
--          product_mapping.mix_weight, clone-from-global if needed, renormalize the pod's variants to sum 1).
--        pod-level add/remove -> returns a routing instruction to the existing swap/decommission flow
--          (no auto pod change; a human runs that flow).
--
-- product_mapping is NOT an Appendix-A protected entity (no canonical-writer trigger), but mix_weight steers
-- engine splits, so every writer here is a role-gated DEFINER setting app.via_rpc, Cody-reviewed.
-- NOTE: mix_weight is maintained here per the PRD; wiring the engine split to consume mix_weight (today the
-- pull path uses split_pct) is a separate follow-up flagged to CS, not in WS5 scope.

-- 1. propose
CREATE OR REPLACE FUNCTION public.propose_recommendation_intent(
  p_machine_id uuid, p_shelf_id uuid, p_level text, p_boonz_product_id uuid, p_pod_product_id uuid,
  p_action text, p_magnitude numeric, p_source text, p_raw_text text, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_uid uuid := (SELECT auth.uid()); v_role text; v_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','propose_recommendation_intent',true);
  SELECT role INTO v_role FROM public.user_profiles WHERE id=v_uid;
  IF v_uid IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'propose_recommendation_intent: forbidden for role %', COALESCE(v_role,'unknown'); END IF;
  IF p_level NOT IN ('boonz','pod') THEN RAISE EXCEPTION 'p_level must be boonz|pod'; END IF;
  IF p_action NOT IN ('increase_weight','decrease_weight','add','remove','set_qty') THEN
    RAISE EXCEPTION 'invalid p_action'; END IF;
  IF p_source NOT IN ('driver','cs','jojo','simran','system') THEN RAISE EXCEPTION 'invalid p_source'; END IF;
  IF p_raw_text IS NULL OR length(trim(p_raw_text)) < 3 THEN RAISE EXCEPTION 'p_raw_text required'; END IF;
  IF p_level='boonz' AND p_boonz_product_id IS NULL THEN RAISE EXCEPTION 'boonz-level intent needs p_boonz_product_id'; END IF;
  IF p_level='pod' AND p_pod_product_id IS NULL THEN RAISE EXCEPTION 'pod-level intent needs p_pod_product_id'; END IF;

  INSERT INTO public.recommendation_intents
    (machine_id, shelf_id, level, boonz_product_id, pod_product_id, action, magnitude, source, raw_text, created_by, note)
  VALUES
    (p_machine_id, p_shelf_id, p_level, p_boonz_product_id, p_pod_product_id, p_action, p_magnitude, p_source, p_raw_text, v_uid, p_note)
  RETURNING intent_id INTO v_id;
  RETURN jsonb_build_object('status','ok','intent_id',v_id,'state','proposed');
END $function$;

-- 2. confirm
CREATE OR REPLACE FUNCTION public.confirm_recommendation_intent(p_intent_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_uid uuid := (SELECT auth.uid()); v_role text; v_st text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','confirm_recommendation_intent',true);
  SELECT role INTO v_role FROM public.user_profiles WHERE id=v_uid;
  IF v_uid IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'confirm_recommendation_intent: forbidden for role %', COALESCE(v_role,'unknown'); END IF;
  SELECT status INTO v_st FROM public.recommendation_intents WHERE intent_id=p_intent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'intent % not found', p_intent_id; END IF;
  IF v_st <> 'proposed' THEN RAISE EXCEPTION 'intent % is % (must be proposed to confirm)', p_intent_id, v_st; END IF;
  UPDATE public.recommendation_intents SET status='confirmed', confirmed_by=v_uid, confirmed_at=now()
   WHERE intent_id=p_intent_id;
  RETURN jsonb_build_object('status','ok','intent_id',p_intent_id,'state','confirmed');
END $function$;

-- 3. reject
CREATE OR REPLACE FUNCTION public.reject_recommendation_intent(p_intent_id uuid, p_reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_uid uuid := (SELECT auth.uid()); v_role text; v_st text;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','reject_recommendation_intent',true);
  SELECT role INTO v_role FROM public.user_profiles WHERE id=v_uid;
  IF v_uid IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'reject_recommendation_intent: forbidden for role %', COALESCE(v_role,'unknown'); END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 5 THEN RAISE EXCEPTION 'p_reason required (>= 5 chars)'; END IF;
  SELECT status INTO v_st FROM public.recommendation_intents WHERE intent_id=p_intent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'intent % not found', p_intent_id; END IF;
  IF v_st IN ('applied','rejected') THEN RAISE EXCEPTION 'intent % already %', p_intent_id, v_st; END IF;
  UPDATE public.recommendation_intents
     SET status='rejected', note=COALESCE(note||' | ','')||'rejected: '||p_reason
   WHERE intent_id=p_intent_id;
  RETURN jsonb_build_object('status','ok','intent_id',p_intent_id,'state','rejected');
END $function$;

-- 4. core boonz-level apply: per-machine product_mapping.mix_weight + renormalize the pod's variants to 1.0
CREATE OR REPLACE FUNCTION public.apply_mix_weight_recommendation(
  p_machine_id uuid, p_shelf_id uuid, p_boonz_product_id uuid, p_delta numeric)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid()); v_role text;
  v_pod uuid; v_old numeric; v_new numeric; v_sum numeric; v_n int;
  v_before jsonb; v_after jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','apply_mix_weight_recommendation',true);
  SELECT role INTO v_role FROM public.user_profiles WHERE id=v_uid;
  IF v_uid IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'apply_mix_weight_recommendation: forbidden for role %', COALESCE(v_role,'unknown'); END IF;
  IF p_machine_id IS NULL OR p_boonz_product_id IS NULL OR p_delta IS NULL THEN
    RAISE EXCEPTION 'p_machine_id, p_boonz_product_id, p_delta required'; END IF;

  SELECT pod_product_id INTO v_pod FROM public.product_mapping
   WHERE boonz_product_id=p_boonz_product_id AND status='Active'
     AND (machine_id=p_machine_id OR machine_id IS NULL)
   ORDER BY (machine_id=p_machine_id) DESC NULLS LAST, is_global_default DESC LIMIT 1;
  IF v_pod IS NULL THEN RAISE EXCEPTION 'no Active mapping for boonz % (machine %)', p_boonz_product_id, p_machine_id; END IF;

  -- ensure all Active boonz variants of this pod have a machine-scoped row (clone from global where missing)
  INSERT INTO public.product_mapping
    (pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, mix_weight, source_of_supply, avg_cost)
  SELECT g.pod_product_id, g.boonz_product_id, p_machine_id, g.split_pct, false, 'Active', g.mix_weight, g.source_of_supply, g.avg_cost
    FROM public.product_mapping g
   WHERE g.pod_product_id=v_pod AND g.machine_id IS NULL AND g.status='Active'
     AND NOT EXISTS (SELECT 1 FROM public.product_mapping m
                      WHERE m.pod_product_id=v_pod AND m.boonz_product_id=g.boonz_product_id
                        AND m.machine_id=p_machine_id AND m.status='Active');

  SELECT jsonb_object_agg(boonz_product_id::text, mix_weight) INTO v_before
    FROM public.product_mapping WHERE pod_product_id=v_pod AND machine_id=p_machine_id AND status='Active';

  SELECT mix_weight INTO v_old FROM public.product_mapping
   WHERE pod_product_id=v_pod AND boonz_product_id=p_boonz_product_id AND machine_id=p_machine_id AND status='Active'
   FOR UPDATE;
  v_new := GREATEST(0, COALESCE(v_old,0) + p_delta);
  UPDATE public.product_mapping SET mix_weight=v_new, updated_at=now()
   WHERE pod_product_id=v_pod AND boonz_product_id=p_boonz_product_id AND machine_id=p_machine_id AND status='Active';

  SELECT SUM(mix_weight), COUNT(*) INTO v_sum, v_n
    FROM public.product_mapping WHERE pod_product_id=v_pod AND machine_id=p_machine_id AND status='Active';
  IF v_sum IS NULL OR v_sum = 0 THEN
    UPDATE public.product_mapping SET mix_weight = ROUND(1.0/NULLIF(v_n,0),4), updated_at=now()
     WHERE pod_product_id=v_pod AND machine_id=p_machine_id AND status='Active';
  ELSE
    UPDATE public.product_mapping SET mix_weight = ROUND(mix_weight / v_sum, 4), updated_at=now()
     WHERE pod_product_id=v_pod AND machine_id=p_machine_id AND status='Active';
  END IF;

  SELECT jsonb_object_agg(boonz_product_id::text, mix_weight) INTO v_after
    FROM public.product_mapping WHERE pod_product_id=v_pod AND machine_id=p_machine_id AND status='Active';

  RETURN jsonb_build_object('status','ok','machine_id',p_machine_id,'pod_product_id',v_pod,
    'boonz_product_id',p_boonz_product_id,'old_weight',v_old,'new_weight_pre_norm',v_new,
    'weights_before',v_before,'weights_after',v_after);
END $function$;

-- 5. apply a CONFIRMED intent (ties apply to the human-confirm gate)
CREATE OR REPLACE FUNCTION public.apply_recommendation_intent(p_intent_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := (SELECT auth.uid()); v_role text;
  r public.recommendation_intents%ROWTYPE; v_delta numeric; v_res jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','apply_recommendation_intent',true);
  SELECT role INTO v_role FROM public.user_profiles WHERE id=v_uid;
  IF v_uid IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'apply_recommendation_intent: forbidden for role %', COALESCE(v_role,'unknown'); END IF;

  SELECT * INTO r FROM public.recommendation_intents WHERE intent_id=p_intent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'intent % not found', p_intent_id; END IF;
  IF r.status <> 'confirmed' THEN
    RAISE EXCEPTION 'intent % is % (must be confirmed to apply)', p_intent_id, r.status; END IF;

  IF r.level = 'pod' THEN
    -- pod-level (add/remove a shelf product) routes to the existing swap/decommission flow; not auto-applied.
    UPDATE public.recommendation_intents
       SET apply_result=jsonb_build_object('routed_to','swap_decommission_flow','reason','pod-level change is a planogram action')
     WHERE intent_id=p_intent_id;
    RETURN jsonb_build_object('status','routed','intent_id',p_intent_id,'route','swap_decommission_flow',
      'message','Pod-level recommendation. Run the swap/decommission flow manually; intent left confirmed.');
  END IF;

  IF r.action NOT IN ('increase_weight','decrease_weight') THEN
    RAISE EXCEPTION 'boonz-level apply supports increase_weight|decrease_weight only (got %)', r.action; END IF;
  v_delta := CASE WHEN r.action='increase_weight' THEN abs(COALESCE(r.magnitude,0))
                  ELSE -abs(COALESCE(r.magnitude,0)) END;

  v_res := public.apply_mix_weight_recommendation(r.machine_id, r.shelf_id, r.boonz_product_id, v_delta);

  UPDATE public.recommendation_intents
     SET status='applied', applied_at=now(), apply_result=v_res
   WHERE intent_id=p_intent_id;
  RETURN jsonb_build_object('status','ok','intent_id',p_intent_id,'state','applied','result',v_res);
END $function$;
