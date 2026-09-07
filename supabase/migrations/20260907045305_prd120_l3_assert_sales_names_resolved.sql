-- PRD-120 L3(a): nightly assertion for sales names that fail to resolve to
-- a pod_product_id through v_sales_history_resolved (the canonical
-- resolution object -- exact trimmed/lowercased match, or via
-- product_name_conventions). Window: last 14 days. Ignore list: LVLUP-
-- supplied items with no pod_products mapping by design (C4 Energy Drink).
--
-- Verified live before shipping: only one currently-unresolved name exists
-- in the last 14 days -- C4 Energy Drink (11 sales / 12 units), the
-- explicitly-ignored case. The Freakin Healthy Granola Bar / Garnola /
-- Freakin Awesome Dates / Freakin Healthy Thins cases named in the PRD-120
-- goal were already fixed by product_name_conventions rows added 07 Sep,
-- before this assertion shipped -- so 0 real violations at write time,
-- exactly as expected.
--
-- Fixture proven in a rolled-back transaction: a real "Sunbites " (trailing
-- space) test sale resolves correctly (the view trims both sides) and is
-- NOT flagged; a genuinely fake "Fake Product X" test sale IS flagged as
-- the sole violation.
--
-- Cody: approve, Article 16 (reads through the canonical resolved view,
-- no inline re-derivation of the resolution logic), Article 11 (cron).
CREATE OR REPLACE FUNCTION public.assert_sales_names_resolved()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_ignore text[] := ARRAY['c4 energy drink'];
  v_violations jsonb;
  v_n int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'pod_product_name', x.pod_product_name, 'occurrences', x.n, 'units', x.units)), '[]'::jsonb),
         COUNT(*)
    INTO v_violations, v_n
  FROM (
    SELECT sh.pod_product_name, count(*) AS n, sum(sh.qty) AS units
    FROM sales_history sh
    LEFT JOIN v_sales_history_resolved r ON r.transaction_id = sh.transaction_id
    WHERE sh.transaction_date >= now() - interval '14 days'
      AND r.pod_product_id IS NULL
      AND lower(trim(sh.pod_product_name)) <> ALL(v_ignore)
    GROUP BY sh.pod_product_name
  ) x;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('sales_names_unresolved', 'warning',
      jsonb_build_object('checked_at', now(), 'violations', v_violations, 'count', v_n));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n=0 THEN 'ok' ELSE 'violation' END,
                             'unresolved_count', v_n, 'violations', v_violations);
END;
$function$;

SELECT cron.schedule('assert_sales_names_resolved_nightly', '0 21 * * *',
  $$ SELECT public.assert_sales_names_resolved(); $$);
