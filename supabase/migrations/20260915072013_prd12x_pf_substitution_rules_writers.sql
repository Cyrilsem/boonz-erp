-- ONE-LOOP-3 Job 1.8 (PRD-124): substitution_rules has RLS enabled and
-- `authenticated` holds only SELECT/REFERENCES/TRIGGER (no write grants) --
-- so the new /refill settings table needs a canonical add + deactivate
-- writer pair rather than a direct client insert/update.

CREATE OR REPLACE FUNCTION public.add_substitution_rule(
  p_when_pod_product_id uuid,
  p_then_pod_product_id uuid,
  p_priority int,
  p_when_condition text DEFAULT NULL,
  p_then_qty_rule text DEFAULT NULL,
  p_never_if_on_machine boolean DEFAULT true,
  p_note text DEFAULT NULL,
  p_caller uuid DEFAULT auth.uid()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_rule_id uuid;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'add_substitution_rule', true);

  IF v_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'forbidden: add_substitution_rule requires warehouse, operator_admin, superadmin, or manager';
  END IF;

  IF p_when_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'add_substitution_rule: p_when_pod_product_id is required';
  END IF;
  IF p_then_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'add_substitution_rule: p_then_pod_product_id is required';
  END IF;
  IF p_when_pod_product_id = p_then_pod_product_id THEN
    RAISE EXCEPTION 'add_substitution_rule: a rule cannot substitute a product for itself';
  END IF;
  IF p_priority IS NULL THEN
    RAISE EXCEPTION 'add_substitution_rule: p_priority is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pod_products WHERE pod_product_id = p_when_pod_product_id) THEN
    RAISE EXCEPTION 'add_substitution_rule: p_when_pod_product_id % not found', p_when_pod_product_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pod_products WHERE pod_product_id = p_then_pod_product_id) THEN
    RAISE EXCEPTION 'add_substitution_rule: p_then_pod_product_id % not found', p_then_pod_product_id;
  END IF;

  INSERT INTO public.substitution_rules
    (priority, when_pod_product_id, when_condition, then_pod_product_id,
     then_qty_rule, never_if_on_machine, active, note)
  VALUES
    (p_priority, p_when_pod_product_id, p_when_condition, p_then_pod_product_id,
     p_then_qty_rule, COALESCE(p_never_if_on_machine, true), true, p_note)
  RETURNING rule_id INTO v_rule_id;

  RETURN v_rule_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.deactivate_substitution_rule(
  p_rule_id uuid,
  p_caller uuid DEFAULT auth.uid()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'deactivate_substitution_rule', true);

  IF v_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'forbidden: deactivate_substitution_rule requires warehouse, operator_admin, superadmin, or manager';
  END IF;

  IF p_rule_id IS NULL THEN
    RAISE EXCEPTION 'deactivate_substitution_rule: p_rule_id is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.substitution_rules WHERE rule_id = p_rule_id) THEN
    RAISE EXCEPTION 'deactivate_substitution_rule: % not found', p_rule_id;
  END IF;

  UPDATE public.substitution_rules
     SET active = false, updated_at = now()
   WHERE rule_id = p_rule_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.add_substitution_rule(uuid, uuid, int, text, text, boolean, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_substitution_rule(uuid, uuid, int, text, text, boolean, text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.deactivate_substitution_rule(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.deactivate_substitution_rule(uuid, uuid) TO authenticated;
