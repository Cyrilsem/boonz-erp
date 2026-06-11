-- PRD: Refill Engine Emergency Fix — Phase 3 (P2)
-- FR-008: get_pod_refill_draft — add wh_avail column (NULL = no WH data; 0 = confirmed empty)
-- FR-009: NOTE — already satisfied by Phase 1 (FR-002). Variant distribution in stitch_pod_to_boonz
-- defaults to product_mapping-based even-split. No WH-weighted code remains in the line-generation path;
-- no opt-in p_wh_weighted_split parameter needed until WH-weighted logic is re-introduced as a separate feature.
-- Constitutional articles: 12 (forward-only), 13 (DROP justified — read-only helper, additive column only).

-- DROP+CREATE required because PostgreSQL CREATE OR REPLACE FUNCTION cannot change return-type rowtype.
-- This is a read-only SECURITY INVOKER helper consumed by RefillPlanningTab. The new column (wh_avail)
-- is additive; existing column order is preserved so positional consumers don't break.
DROP FUNCTION IF EXISTS public.get_pod_refill_draft(date);

CREATE FUNCTION public.get_pod_refill_draft(
  p_plan_date date DEFAULT (CURRENT_DATE + 1)
) RETURNS TABLE(
  plan_date     date,
  machine_id    uuid,
  machine_name  text,
  shelf_id      uuid,
  shelf_code    text,
  pod_product_id   uuid,
  pod_product_name text,
  action        text,
  qty           integer,
  current_stock integer,
  max_stock     integer,
  fill_pct      numeric,
  velocity_30d  numeric,
  signal        text,
  clamp_reason  text,
  source_origin text,
  has_intent    boolean,
  intent_id     uuid,
  status        text,
  reasoning     jsonb,
  edited_at     timestamp with time zone,
  edited_by     text,
  wh_avail      integer
)
LANGUAGE sql
STABLE
AS $function$
  SELECT
    prp.plan_date,
    prp.machine_id,
    m.official_name                                   AS machine_name,
    prp.shelf_id,
    sc.shelf_code,
    prp.pod_product_id,
    pp.pod_product_name,
    prp.action,
    prp.qty,
    lss.current_stock,
    lss.max_stock,
    ROUND(lss.fill_pct::numeric, 1)                   AS fill_pct,
    (prp.reasoning->>'velocity_30d')::numeric          AS velocity_30d,
    prp.reasoning->>'signal'                           AS signal,
    prp.reasoning->>'clamp_reason'                     AS clamp_reason,
    prp.source_origin::text,
    prp.linked_intent_id IS NOT NULL                   AS has_intent,
    prp.linked_intent_id                               AS intent_id,
    prp.status,
    prp.reasoning,
    prp.edited_at,
    prp.edited_by,
    -- v2 FR-008: SUM of warehouse_stock across all active product_mapping variants for this pod_product.
    -- NULL when no warehouse_inventory rows are mapped (no data); 0 when rows exist but all have 0 stock (confirmed empty).
    (
      SELECT SUM(wi.warehouse_stock)::int
      FROM public.product_mapping pm
      JOIN public.warehouse_inventory wi
        ON wi.boonz_product_id = pm.boonz_product_id
       AND wi.status = 'Active'
       AND wi.quarantined = false
      WHERE pm.pod_product_id = prp.pod_product_id
        AND pm.status = 'Active'
        AND (pm.machine_id IS NULL OR pm.machine_id = prp.machine_id)
    ) AS wh_avail
  FROM pod_refill_plan prp
  JOIN machines m              ON m.machine_id       = prp.machine_id
  JOIN shelf_configurations sc ON sc.shelf_id        = prp.shelf_id
  JOIN pod_products pp         ON pp.pod_product_id  = prp.pod_product_id
  LEFT JOIN v_live_shelf_stock lss
    ON  lss.machine_id = prp.machine_id
    AND SPLIT_PART(lss.aisle_code, '-', 2) = sc.shelf_code
  WHERE prp.plan_date = p_plan_date
  ORDER BY m.official_name, sc.shelf_code;
$function$;

GRANT EXECUTE ON FUNCTION public.get_pod_refill_draft(date) TO authenticated, anon, service_role, PUBLIC;
