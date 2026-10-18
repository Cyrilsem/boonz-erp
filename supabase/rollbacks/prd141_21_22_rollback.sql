-- PRD-141 items 21/22 rollback: guard back to exact-name plan resolution with no exemptions; swaps stop
-- opening relabel requests. The table and its RPCs stay (no data is lost; nothing reads it then).
DO $rb$
DECLARE v text;
BEGIN
  v := pg_get_functiondef('public.assert_weimi_slot_match(date,text,text)'::regprocedure);
  v := regexp_replace(v, ' ssi\.current_stock AS weimi_stock, rpo\.comment AS plan_comment,\n.*?AS relabel_pending,', '', 's');
  v := regexp_replace(v, '    LEFT JOIN LATERAL \(SELECT COALESCE\(\n.*?plan_pp ON true[^\n]*', '    LEFT JOIN pod_products plan_pp ON lower(trim(plan_pp.pod_product_name)) = lower(trim(rpo.pod_product_name))', 's');
  v := regexp_replace(v, '\n    -- PRD-141 item 21: a relabel is already queued.*?empty_lane_add_new_exempt''\)\);\n      CONTINUE;\n    END IF;', '', 's');
  EXECUTE v;
  v := pg_get_functiondef('public.ensure_swap_remove_leg(uuid,text,uuid,date)'::regprocedure);
  v := regexp_replace(v, '  -- PRD-141 item 22: a swap is also a WEIMI relabel to do\..*?DO NOTHING;\n\n', '', 's');
  EXECUTE v;
END $rb$;
-- FE part (Config > Machines Relabels tab, src/components/config/RelabelsTab.tsx): git revert the commit
-- "feat(prd-141): items 21 and 22 slot guard aliases and relabels" before running the SQL above.
