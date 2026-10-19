-- PRD-142b A9: new products always visible. strategy_playbook_prepare kept only products with >= 30 units over
-- the 60-week series, so a product launched weeks ago (Huel: first sale 2026-10-09, 5 units) never reached the
-- playbook, the map or the table. A product whose first sale in the fact layer is under 91 days before the
-- current week is now always in scope; it lands in INCUBATE by playbook rule 3 (under 3 months). Rule 6 (under
-- 8 units: EXIT at 6 months or more, else INCUBATE) is unchanged for products 3 months or older.
-- Single-occurrence guarded replace() on the live body.
DO $do$
DECLARE v_old text; v_new text; v_find text; v_repl text;
BEGIN
  v_old  := pg_get_functiondef('public.strategy_playbook_prepare(date)'::regprocedure);
  v_find := 'prods AS (SELECT pod_product_id, population FROM pw_all GROUP BY 1, 2 HAVING sum(units) >= 30)';
  v_repl := 'prods AS (SELECT pod_product_id, population FROM pw_all GROUP BY 1, 2 HAVING sum(units) >= 30'
            || E'\n                  -- PRD-142b A9: products under 3 months old are always in scope.\n'
            || '                  OR pod_product_id IN (SELECT fn.pod_product_id FROM fact_product_machine_daily fn'
            || ' GROUP BY fn.pod_product_id HAVING min(fn.d) > v_cw - 91))';
  IF (length(v_old) - length(replace(v_old, v_find, ''))) / length(v_find) <> 1 THEN
    RAISE EXCEPTION 'A9 guard: anchor found % times', (length(v_old) - length(replace(v_old, v_find, ''))) / length(v_find);
  END IF;
  v_new := replace(v_old, v_find, v_repl);
  IF v_new = v_old THEN RAISE EXCEPTION 'A9 guard: unchanged'; END IF;
  EXECUTE v_new;
END
$do$;
