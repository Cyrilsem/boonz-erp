-- PRD-015 Phase C / C1 (AC#8) — launch-readiness guard for new products.
-- Read-only (SECURITY INVOKER): returns ready/blocked with the specific missing pieces:
--   (a) product_mapping global-default rows for the pod product sum to 100% split, AND
--   (b) every expected WEIMI name resolves (product_name_conventions row OR case-insensitive
--       direct match to a pod_products / boonz_products canonical name).
-- WIRING: the launch tooling (boonz-pico-upstream) calls this BEFORE inserting a launch
-- planned_swaps row and rejects on blocked. No blanket BEFORE INSERT trigger on planned_swaps
-- (that table has multiple legitimate non-launch insert sources, e.g. driver-rec swaps, which a
-- 100%-mapping trigger would wrongly block). Default per PRD Open Q#2 = hard-block at the caller.
-- NOT YET APPLIED.

CREATE OR REPLACE FUNCTION public.assert_product_launch_ready(
  p_pod_product_id      uuid,
  p_expected_weimi_names text[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
DECLARE
  v_total_pct numeric;
  v_missing   text[];
  v_nm        text;
BEGIN
  IF p_pod_product_id IS NULL THEN RAISE EXCEPTION 'p_pod_product_id required'; END IF;

  -- (a) mapping completeness: global-default Active rows must sum to 100%
  SELECT COALESCE(SUM(split_pct), 0) INTO v_total_pct
  FROM public.product_mapping
  WHERE pod_product_id = p_pod_product_id
    AND is_global_default = true
    AND status = 'Active';

  -- (b) every expected WEIMI name must resolve
  v_missing := ARRAY[]::text[];
  IF p_expected_weimi_names IS NOT NULL THEN
    FOREACH v_nm IN ARRAY p_expected_weimi_names LOOP
      IF NULLIF(TRIM(v_nm), '') IS NULL THEN CONTINUE; END IF;
      IF NOT (
        EXISTS (SELECT 1 FROM public.product_name_conventions c
                 WHERE lower(c.original_name) = lower(v_nm) OR lower(c.official_name) = lower(v_nm))
        OR EXISTS (SELECT 1 FROM public.pod_products pp WHERE lower(pp.pod_product_name) = lower(v_nm))
        OR EXISTS (SELECT 1 FROM public.boonz_products bp WHERE lower(bp.boonz_product_name) = lower(v_nm))
      ) THEN
        v_missing := array_append(v_missing, v_nm);
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'pod_product_id',       p_pod_product_id,
    'ready',                (v_total_pct = 100 AND array_length(v_missing, 1) IS NULL),
    'mapping_split_pct',    v_total_pct,
    'mapping_ok',           (v_total_pct = 100),
    'unresolved_weimi_names', to_jsonb(v_missing),
    'reason', CASE
      WHEN v_total_pct <> 100 AND array_length(v_missing,1) IS NOT NULL
        THEN 'blocked: mapping not 100% AND unresolved WEIMI names'
      WHEN v_total_pct <> 100 THEN format('blocked: product_mapping global split is %s%%, must be 100%%', v_total_pct)
      WHEN array_length(v_missing,1) IS NOT NULL THEN 'blocked: unresolved WEIMI names (add product_name_conventions rows)'
      ELSE 'ready'
    END
  );
END $function$;
GRANT EXECUTE ON FUNCTION public.assert_product_launch_ready(uuid, text[]) TO authenticated;
