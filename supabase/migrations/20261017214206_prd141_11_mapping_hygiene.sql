-- PRD-141 item 11 (C3): mapping hygiene.
-- 1. Normalise Active split_pct to 100 per (machine_id or global, pod_product_id), largest remainder
--    in numeric(6,2). Behaviour-neutral: every consumer (stitch, spread_pod_qty,
--    estimate_shelf_composition_v3) divides by the group total, and the only absolute test anywhere is
--    split_pct > 0, which this keeps (0 stays 0, non-zero stays non-zero). Dry run: 375 rows,
--    0 groups off after, max share drift 0.0074 percentage points.
--    All-zero groups are left alone (they mean "never", PRD-141 item 10).
-- 2. Nightly report check_mapping_split_sums(): alerts when any Active group with a positive total
--    does not sum to 100. 23:40 UTC = 03:40 Dubai, outside the cron 13 / draft window.
-- 3. Promotion of machine-only SKUs to global rows is NOT applied: it adds variants on other machines,
--    so it is a CS-approved change list (docs/prds/PRD-141-mapping-hygiene-list.md).
-- Night window. Rollback: supabase/rollbacks/prd141_11_rollback.sql (restores the 375 old values).

CREATE TABLE IF NOT EXISTS public.prd141_mapping_split_backup (
  mapping_id uuid PRIMARY KEY,
  old_split_pct numeric(6,2),
  backed_up_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON public.prd141_mapping_split_backup FROM anon, public, authenticated;
GRANT SELECT ON public.prd141_mapping_split_backup TO service_role;
ALTER TABLE public.prd141_mapping_split_backup ENABLE ROW LEVEL SECURITY;

DO $norm$
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd141_11_mapping_hygiene', true);
  PERFORM set_config('app.mutation_reason', 'PRD-141 item 11: normalise Active split_pct to 100 per pod group (behaviour-neutral)', true);

  INSERT INTO public.prd141_mapping_split_backup (mapping_id, old_split_pct)
  SELECT pm.mapping_id, pm.split_pct
    FROM public.product_mapping pm
    JOIN (SELECT machine_id, pod_product_id FROM public.product_mapping WHERE status = 'Active'
           GROUP BY 1, 2 HAVING sum(COALESCE(split_pct, 0)) > 0 AND sum(split_pct) <> 100) g
      ON g.pod_product_id = pm.pod_product_id AND g.machine_id IS NOT DISTINCT FROM pm.machine_id
   WHERE pm.status = 'Active'
  ON CONFLICT (mapping_id) DO NOTHING;

  WITH g AS (SELECT machine_id, pod_product_id, sum(split_pct) tot FROM public.product_mapping WHERE status = 'Active'
              GROUP BY 1, 2 HAVING sum(COALESCE(split_pct, 0)) > 0 AND sum(split_pct) <> 100),
  raw AS (SELECT pm.mapping_id, pm.machine_id, pm.pod_product_id, COALESCE(pm.split_pct, 0) * 100.0 / g.tot AS exact
            FROM public.product_mapping pm
            JOIN g ON g.pod_product_id = pm.pod_product_id AND g.machine_id IS NOT DISTINCT FROM pm.machine_id
           WHERE pm.status = 'Active'),
  fl AS (SELECT *, floor(exact * 100) / 100 AS base, exact - floor(exact * 100) / 100 AS rem FROM raw),
  rk AS (SELECT *, row_number() OVER (PARTITION BY machine_id, pod_product_id ORDER BY rem DESC, mapping_id) AS rn,
                round((100 - sum(base) OVER (PARTITION BY machine_id, pod_product_id)) * 100)::int AS cents FROM fl)
  UPDATE public.product_mapping pm
     SET split_pct = rk.base + CASE WHEN rk.rn <= rk.cents THEN 0.01 ELSE 0 END
    FROM rk
   WHERE rk.mapping_id = pm.mapping_id;
END
$norm$;

CREATE OR REPLACE FUNCTION public.check_mapping_split_sums()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_n    int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'machine', COALESCE(m.official_name, 'GLOBAL'), 'pod', pp.pod_product_name,
           'total_split', g.tot, 'rows', g.n) ORDER BY abs(g.tot - 100) DESC), '[]'::jsonb),
         count(*)
    INTO v_rows, v_n
    FROM (SELECT machine_id, pod_product_id, sum(COALESCE(split_pct, 0)) AS tot, count(*) AS n
            FROM public.product_mapping WHERE status = 'Active'
           GROUP BY 1, 2 HAVING sum(COALESCE(split_pct, 0)) > 0 AND sum(COALESCE(split_pct, 0)) <> 100) g
    LEFT JOIN public.machines m ON m.machine_id = g.machine_id
    JOIN public.pod_products pp ON pp.pod_product_id = g.pod_product_id;

  IF v_n > 0 THEN
    PERFORM public.safe_monitoring_alert('mapping_split_sum', 'warning',
      jsonb_build_object('checked_at', now(), 'count', v_n, 'rows', v_rows,
        'title', format('%s product_mapping pod groups do not sum to 100', v_n)));
  END IF;

  RETURN jsonb_build_object('checked_at', now(), 'status', CASE WHEN v_n = 0 THEN 'ok' ELSE 'violation' END,
                            'violations', v_n, 'rows', v_rows);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.check_mapping_split_sums() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.check_mapping_split_sums() TO authenticated, service_role;

SELECT cron.schedule('prd141_mapping_split_sums_0340_dubai', '40 23 * * *', 'SELECT public.check_mapping_split_sums();');
