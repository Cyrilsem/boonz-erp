-- Refill reliability / WS7 - enriched pending reader (Stock + 7d sales). STATUS: DRAFT - NOT APPLIED.
--
-- Problem (PRD WS7): the RefillPlanningTab pending view reads refill_plan_output directly, but stitch writes
-- current_stock=0 and sold_7d=0 into those rows (they are placeholders), so the Stock and 7d columns always
-- render 0/0. Fix: a read-only reader that enriches each pending row with LIVE shelf stock (v_live_shelf_stock,
-- same join get_pod_refill_draft uses) and 7-day sales (v_sales_history_attributed). The FE points the pending
-- load at this RPC; the existing Stock and 7d columns then show real numbers.
--
-- Read-only SQL STABLE function (Cody fast-path: no writes; RLS enforced via the underlying tables/views).

CREATE OR REPLACE FUNCTION public.get_refill_plan_output_enriched(p_plan_date date)
 RETURNS TABLE(
   machine_name text, machine_priority int, shelf_code text, pod_product_name text,
   boonz_product_name text, action text, quantity int, current_stock int, max_stock int,
   smart_target int, tier text, global_score numeric, sold_7d int, fill_pct numeric,
   comment text, operator_status text
 )
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    rpo.machine_name,
    COALESCE(rpo.machine_priority, 5)                  AS machine_priority,
    rpo.shelf_code,
    rpo.pod_product_name,
    rpo.boonz_product_name,
    rpo.action,
    rpo.quantity::int                                  AS quantity,
    COALESCE(lss.current_stock, 0)::int                AS current_stock,
    COALESCE(lss.max_stock, 0)::int                    AS max_stock,
    rpo.smart_target::int                              AS smart_target,
    rpo.tier,
    rpo.global_score::numeric                          AS global_score,
    COALESCE(s7.sold_7d, 0)::int                       AS sold_7d,
    CASE WHEN COALESCE(lss.max_stock,0) > 0
         THEN ROUND(lss.current_stock * 100.0 / lss.max_stock, 1)
         ELSE rpo.fill_pct END                         AS fill_pct,
    rpo.comment,
    rpo.operator_status
  FROM public.refill_plan_output rpo
  LEFT JOIN public.machines m
    ON m.official_name = rpo.machine_name
  LEFT JOIN public.v_live_shelf_stock lss
    ON  lss.machine_id = m.machine_id
    AND lss.slot_name  = LEFT(rpo.shelf_code, 1) || (SUBSTR(rpo.shelf_code, 2)::int)::text
  LEFT JOIN LATERAL (
    SELECT SUM(sha.qty)::int AS sold_7d
    FROM public.v_sales_history_attributed sha
    WHERE sha.machine_id = m.machine_id
      AND sha.slot_name  = LEFT(rpo.shelf_code, 1) || (SUBSTR(rpo.shelf_code, 2)::int)::text
      AND sha.transaction_date >= (p_plan_date - 7)
      AND sha.transaction_date <  p_plan_date
  ) s7 ON true
  WHERE rpo.plan_date = p_plan_date
    AND rpo.operator_status = 'pending'
  ORDER BY rpo.machine_name, rpo.shelf_code, rpo.action DESC;
$function$;
