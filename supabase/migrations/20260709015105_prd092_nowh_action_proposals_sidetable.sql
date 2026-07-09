-- PRD-092 (Option 1, side-table, Cody PASS): additive no-WH action proposals. NO engine edit.
-- compute_nowh_proposals is STANDALONE (not called by any engine); writes ONLY to the side-table.
CREATE TABLE IF NOT EXISTS public.refill_action_proposals (
  proposal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), plan_date date NOT NULL, machine_id uuid NOT NULL,
  shelf_id uuid, pod_product_id uuid, kind text NOT NULL CHECK (kind IN ('substitute','m2m','procurement')),
  detail jsonb NOT NULL DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.refill_action_proposals ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rap_select ON public.refill_action_proposals;
CREATE POLICY rap_select ON public.refill_action_proposals FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.refill_action_proposals TO authenticated, service_role;
CREATE INDEX IF NOT EXISTS idx_rap_plan ON public.refill_action_proposals (plan_date, machine_id);
CREATE OR REPLACE FUNCTION public.compute_nowh_proposals(p_plan_date date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE rec record; v_sub record; v_m2m record; v_s int:=0; v_m int:=0; v_p int:=0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true); PERFORM set_config('app.rpc_name','compute_nowh_proposals',true);
  DELETE FROM public.refill_action_proposals WHERE plan_date = p_plan_date;
  FOR rec IN SELECT DISTINCT pr.machine_id, pr.shelf_id, pr.pod_product_id FROM public.pod_refills pr
             WHERE pr.plan_date = p_plan_date AND pr.clamp_reason = 'blocked_no_wh' AND pr.pod_product_id IS NOT NULL LOOP
    SELECT fs.pod_product_id, fs.pod_product_name, fs.pearson_score, fs.wh_stock_units INTO v_sub
      FROM public.find_substitutes_for_shelf(p_plan_date, rec.machine_id, rec.shelf_id, rec.pod_product_id, 3, 50) fs
      WHERE fs.wh_stock_units >= 1 ORDER BY fs.rank LIMIT 1;
    IF FOUND THEN
      INSERT INTO public.refill_action_proposals(plan_date, machine_id, shelf_id, pod_product_id, kind, detail)
      VALUES (p_plan_date, rec.machine_id, rec.shelf_id, rec.pod_product_id, 'substitute', jsonb_build_object('substitute_pod', v_sub.pod_product_id, 'substitute_name', v_sub.pod_product_name, 'pearson_score', v_sub.pearson_score, 'wh_stock_units', v_sub.wh_stock_units)); v_s := v_s + 1;
    ELSE
      SELECT lss.machine_id, lss.current_stock INTO v_m2m FROM public.v_live_shelf_stock lss
        WHERE lss.pod_product_id = rec.pod_product_id AND lss.machine_id <> rec.machine_id AND lss.current_stock >= 2 ORDER BY lss.current_stock DESC LIMIT 1;
      IF FOUND THEN
        INSERT INTO public.refill_action_proposals(plan_date, machine_id, shelf_id, pod_product_id, kind, detail)
        VALUES (p_plan_date, rec.machine_id, rec.shelf_id, rec.pod_product_id, 'm2m', jsonb_build_object('source_machine', v_m2m.machine_id, 'source_stock', v_m2m.current_stock)); v_m := v_m + 1;
      ELSE
        INSERT INTO public.refill_action_proposals(plan_date, machine_id, shelf_id, pod_product_id, kind, detail)
        VALUES (p_plan_date, rec.machine_id, rec.shelf_id, rec.pod_product_id, 'procurement', jsonb_build_object('reason', 'no pickable substitute or M2M surplus source')); v_p := v_p + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('plan_date', p_plan_date, 'substitute', v_s, 'm2m', v_m, 'procurement', v_p, 'total', v_s+v_m+v_p);
END $fn$;
GRANT EXECUTE ON FUNCTION public.compute_nowh_proposals(date) TO authenticated, service_role;
COMMENT ON FUNCTION public.compute_nowh_proposals(date) IS 'PRD-092 (side-table): standalone blocked_no_wh -> substitute/m2m/procurement proposals in refill_action_proposals. NOT called by any engine.';
