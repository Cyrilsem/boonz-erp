-- Rollback for prd142b_a9_new_products_in_scope: restores the >= 30 units scope filter.
DO $do$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.strategy_playbook_prepare(date)'::regprocedure);
  EXECUTE replace(v, E'\n                  -- PRD-142b A9: products under 3 months old are always in scope.\n'
            || '                  OR pod_product_id IN (SELECT fn.pod_product_id FROM fact_product_machine_daily fn'
            || ' GROUP BY fn.pod_product_id HAVING min(fn.d) > v_cw - 91))', ')');
END
$do$;
