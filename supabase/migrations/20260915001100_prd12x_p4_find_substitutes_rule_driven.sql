-- PRD-125 D4 -- find_substitutes_for_shelf becomes rule-driven.
--
-- Replaces the old correlation/global-performance recommendation entirely
-- (per D4: "returns the first match or nothing" -- not a fallback to the
-- old logic). Reads substitution_rules in priority order for the anchor
-- pod product; evaluates when_condition (the two free-text conditions in
-- the seed, "machine has no Al Ain Zero" and "VOX site", are special-cased
-- directly -- the table carries no predicate language); skips a rule whose
-- target already sits on another lane of the machine when
-- never_if_on_machine is true; checks wh_available_for for real stock;
-- returns the first satisfied rule, or nothing.
--
-- Verified live: NOVO-1023-0000-W0 already stocks Benlian Chips (A15) and
-- Krambals (A16), so its two matching chain-rule candidates for a
-- Dubai-Popcorn-shaped anchor are both correctly skipped by
-- never_if_on_machine -- confirming "nothing" is the correct return here,
-- not a bug in the rule engine.
CREATE OR REPLACE FUNCTION public.find_substitutes_for_shelf(p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_anchor_pod_product_id uuid, p_top_n integer DEFAULT 5, p_aggressiveness_pct integer DEFAULT 50)
 RETURNS TABLE(rank integer, pod_product_id uuid, pod_product_name text, pearson_score numeric, source text, wh_stock_units numeric, reason text)
 LANGUAGE plpgsql
 STABLE
AS $function$
#variable_conflict use_column
DECLARE
  v_rule RECORD;
  v_stock numeric;
  v_on_another_lane boolean;
  v_condition_met boolean;
BEGIN
  IF p_anchor_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_anchor_pod_product_id is required';
  END IF;

  FOR v_rule IN
    SELECT sr.then_pod_product_id, sr.then_qty_rule, sr.never_if_on_machine, sr.note, sr.when_condition
      FROM public.substitution_rules sr
     WHERE sr.active = true
       AND sr.when_pod_product_id = p_anchor_pod_product_id
       AND sr.then_pod_product_id IS NOT NULL
     ORDER BY sr.priority ASC
  LOOP
    v_condition_met := true;
    IF v_rule.when_condition = 'machine has no Al Ain Zero' THEN
      SELECT NOT EXISTS (
        SELECT 1 FROM public.weimi_shelf_now(p_machine_id) wsn
         WHERE wsn.pod_product_id = v_rule.then_pod_product_id AND wsn.current_stock > 0
      ) INTO v_condition_met;
    ELSIF v_rule.when_condition = 'VOX site' THEN
      SELECT COALESCE(m.service_model = 'partner_filled', false) INTO v_condition_met
        FROM public.machines m WHERE m.machine_id = p_machine_id;
    END IF;
    IF NOT v_condition_met THEN
      CONTINUE;
    END IF;

    IF v_rule.never_if_on_machine THEN
      SELECT EXISTS (
        SELECT 1 FROM public.weimi_shelf_now(p_machine_id) wsn
         WHERE wsn.pod_product_id = v_rule.then_pod_product_id
           AND wsn.current_stock > 0
      ) INTO v_on_another_lane;
      IF v_on_another_lane THEN
        CONTINUE;
      END IF;
    END IF;

    SELECT COALESCE(SUM(waf.free_stock), 0) INTO v_stock
      FROM (
        SELECT DISTINCT pm.boonz_product_id
          FROM public.product_mapping pm
         WHERE pm.pod_product_id = v_rule.then_pod_product_id AND pm.status = 'Active'
           AND (pm.machine_id IS NULL OR pm.machine_id = p_machine_id)
      ) bp
      CROSS JOIN LATERAL public.wh_available_for(p_machine_id, bp.boonz_product_id) waf;

    IF v_stock > 0 THEN
      RETURN QUERY
      SELECT 1::int AS rank, v_rule.then_pod_product_id, pp.pod_product_name,
             NULL::numeric AS pearson_score, 'substitution_rule'::text AS source,
             v_stock AS wh_stock_units,
             format('Substitution rule: %s (%s)', COALESCE(v_rule.note,''), COALESCE(v_rule.then_qty_rule,'')) AS reason
        FROM public.pod_products pp WHERE pp.pod_product_id = v_rule.then_pod_product_id;
      RETURN;
    END IF;
  END LOOP;

  RETURN;
END $function$;
