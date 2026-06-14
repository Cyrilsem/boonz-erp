-- PRD-031 WS-4: refill accuracy gate. Replaces the vacuous stitch deviation block
-- (root-cause D: variant_target===variant_final so expected>actual never fires) with a
-- real per-shelf intent-vs-dispatched gate. Article 16 metric "refill execution accuracy".
-- Canonical object: v_refill_accuracy (security_invoker, honors operator RLS on
-- refill_plan_output). Driven from pod intent LEFT JOIN dispatched so a fully-leaked
-- shelf-pod (zero output rows) is still visible. RPC get_refill_plan_accuracy returns the
-- per-line detail + a plan summary with a pass/flag/block verdict for FE + conductor.
-- No writes; the old deviation block is left verbatim (forward-only, Article 12/14). Cody
-- ⚠️->cleared (security_invoker + grants + metric registry folded in).

CREATE OR REPLACE VIEW public.v_refill_accuracy
WITH (security_invoker = true) AS
WITH intent AS (
  SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action,
         m.official_name AS machine_name, sc.shelf_code, pp.pod_product_name,
         prp.qty AS pod_intent
  FROM public.pod_refill_plan prp
  JOIN public.machines m ON m.machine_id = prp.machine_id
  JOIN public.shelf_configurations sc ON sc.shelf_id = prp.shelf_id
  JOIN public.pod_products pp ON pp.pod_product_id = prp.pod_product_id
  WHERE prp.status IN ('approved','stitched')
    AND prp.action IN ('REFILL','ADD_NEW')
),
disp AS (
  SELECT plan_date, machine_name, shelf_code, pod_product_name, action,
         SUM(quantity)::int AS dispatched_qty,
         MAX(current_stock)::int AS shelf_current_out,
         MAX(max_stock)::int     AS shelf_max_out,
         bool_or(COALESCE(comment,'') LIKE '%WH_WARNING%'
                 OR COALESCE(comment,'') LIKE '%WH_STOCK_UNKNOWN%') AS wh_short
  FROM public.refill_plan_output
  WHERE action IN ('Refill','Add New')
  GROUP BY plan_date, machine_name, shelf_code, pod_product_name, action
),
shelf_live AS (
  SELECT vls.machine_id, scfg.shelf_id, MAX(vls.current_stock)::int AS current_stock
  FROM public.v_live_shelf_stock vls
  JOIN public.shelf_configurations scfg
    ON scfg.machine_id = vls.machine_id AND scfg.is_phantom = false
   AND vls.slot_name = LEFT(scfg.shelf_code,1) || (SUBSTR(scfg.shelf_code,2)::int)::text
  GROUP BY vls.machine_id, scfg.shelf_id
),
shelf_cap AS (
  SELECT sms.shelf_id, MAX(sms.max_stock_weimi)::int AS max_stock
  FROM public.v_shelf_max_stock sms GROUP BY sms.shelf_id
)
SELECT
  i.plan_date, i.machine_id, i.shelf_id, i.pod_product_id, i.action,
  i.machine_name, i.shelf_code, i.pod_product_name,
  i.pod_intent,
  COALESCE(d.dispatched_qty,0) AS dispatched_qty,
  COALESCE(d.shelf_current_out, sl.current_stock, 0) AS shelf_current,
  COALESCE(d.shelf_max_out,     scap.max_stock,  0) AS shelf_max,
  GREATEST(COALESCE(d.shelf_max_out, scap.max_stock, 0)
           - COALESCE(d.shelf_current_out, sl.current_stock, 0), 0) AS shelf_gap,
  COALESCE(d.wh_short, false) AS wh_short,
  GREATEST(i.pod_intent - COALESCE(d.dispatched_qty,0), 0) AS shortfall,
  CASE
    WHEN COALESCE(d.dispatched_qty,0) > i.pod_intent THEN 'over'
    WHEN i.pod_intent - COALESCE(d.dispatched_qty,0) <= 1 THEN 'ok'   -- rounding tolerance
    WHEN COALESCE(d.wh_short,false) THEN 'wh_short'                   -- excused: WH genuinely out
    WHEN GREATEST(COALESCE(d.shelf_max_out, scap.max_stock,0)
                  - COALESCE(d.shelf_current_out, sl.current_stock,0), 0)
         > COALESCE(d.dispatched_qty,0) THEN 'leak'                   -- shelf room + no WH cause
    ELSE 'ok'                                                         -- shelf already at gap (Hybrid cover-floor)
  END AS status
FROM intent i
LEFT JOIN disp d
  ON d.plan_date = i.plan_date AND d.machine_name = i.machine_name
 AND d.shelf_code = i.shelf_code AND d.pod_product_name = i.pod_product_name
 AND d.action = (CASE i.action WHEN 'REFILL' THEN 'Refill' WHEN 'ADD_NEW' THEN 'Add New' END)
LEFT JOIN shelf_live sl ON sl.shelf_id = i.shelf_id AND sl.machine_id = i.machine_id
LEFT JOIN shelf_cap  scap ON scap.shelf_id = i.shelf_id;

COMMENT ON VIEW public.v_refill_accuracy IS
  'PRD-031 WS-4. Canonical metric: refill execution accuracy. Grain (plan_date,machine,shelf,pod,action). Intent-driven (LEFT JOIN dispatched) so zero-dispatch leaks are visible. status: ok|wh_short|leak|over. Sole consumers: get_refill_plan_accuracy + RefillPlanningTab.';

GRANT SELECT ON public.v_refill_accuracy TO authenticated;

CREATE OR REPLACE FUNCTION public.get_refill_plan_accuracy(p_plan_date date)
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY INVOKER
SET search_path TO 'public'
AS $function$
  WITH a AS (SELECT * FROM public.v_refill_accuracy WHERE plan_date = p_plan_date)
  SELECT jsonb_build_object(
    'plan_date', p_plan_date,
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'machine_name', machine_name, 'shelf_code', shelf_code,
        'pod_product_name', pod_product_name, 'action', action,
        'pod_intent', pod_intent, 'dispatched_qty', dispatched_qty,
        'shelf_gap', shelf_gap, 'wh_short', wh_short,
        'shortfall', shortfall, 'status', status)
        ORDER BY (status='leak') DESC, (status='over') DESC, (status='wh_short') DESC,
                 machine_name, shelf_code, pod_product_name)
      FROM a), '[]'::jsonb),
    'summary', (
      SELECT jsonb_build_object(
        'shelf_pods', COUNT(*),
        'ok',       COUNT(*) FILTER (WHERE status='ok'),
        'wh_short', COUNT(*) FILTER (WHERE status='wh_short'),
        'leak',     COUNT(*) FILTER (WHERE status='leak'),
        'over',     COUNT(*) FILTER (WHERE status='over'),
        'total_intent',     COALESCE(SUM(pod_intent),0),
        'total_dispatched', COALESCE(SUM(dispatched_qty),0),
        'total_gap',        COALESCE(SUM(shelf_gap),0),
        'intent_fill_ratio', ROUND(COALESCE(SUM(dispatched_qty)::numeric/NULLIF(SUM(pod_intent),0),0),3),
        'gap_fill_ratio',    ROUND(COALESCE(SUM(dispatched_qty)::numeric/NULLIF(SUM(shelf_gap),0),0),3),
        'verdict', CASE
                     WHEN COUNT(*) FILTER (WHERE status='leak') > 0 THEN 'block'
                     WHEN COALESCE(SUM(dispatched_qty)::numeric/NULLIF(SUM(shelf_gap),0),1) < 0.5 THEN 'flag'
                     ELSE 'pass' END)
      FROM a)
  );
$function$;

GRANT EXECUTE ON FUNCTION public.get_refill_plan_accuracy(date) TO authenticated;
