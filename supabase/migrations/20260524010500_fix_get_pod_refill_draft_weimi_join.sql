-- Fix multi-cabinet WEIMI JOIN in get_pod_refill_draft.
-- PRD: docs/prd-multi-cabinet-join-fix.md
-- Root cause: SPLIT_PART(lss.aisle_code, '-', 2) = sc.shelf_code only strips the cabinet prefix,
--   which (a) never produces a B-prefix so all B-side shelves match nothing, (b) is off-by-one for
--   the slot index inside aisle_code, and (c) fan-outs when two cabinets share an aisle suffix.
-- Fix: switch to the slot_name JOIN already used by engine_add_pod v10:
--   lss.slot_name = LEFT(sc.shelf_code, 1) || (SUBSTR(sc.shelf_code, 2)::int)::text
-- Affected: only get_pod_refill_draft (verified via pg_proc ILIKE scan — no other function
--   carries the broken SPLIT_PART(aisle_code,'-',2) = shelf_code pattern).
-- Forward-only (Article 12): CREATE OR REPLACE preserves the function identity and return type
--   established by phaseF_proc_edit_po_line_audit (PRD-001).

CREATE OR REPLACE FUNCTION public.get_pod_refill_draft(
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
SECURITY INVOKER
SET search_path = public, pg_temp
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
    (prp.reasoning->>'velocity_30d')::numeric         AS velocity_30d,
    prp.reasoning->>'signal'                          AS signal,
    prp.reasoning->>'clamp_reason'                    AS clamp_reason,
    prp.source_origin::text,
    prp.linked_intent_id IS NOT NULL                  AS has_intent,
    prp.linked_intent_id                              AS intent_id,
    prp.status,
    prp.reasoning,
    prp.edited_at,
    prp.edited_by,
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
    -- Multi-cabinet-safe JOIN: shelf_code 'A06' → 'A6'; 'B09' → 'B9'; 'B11' → 'B11'.
    -- Mirrors the JOIN inside engine_add_pod v10 (slot_lifecycle CTE) so the writer and the
    -- reader resolve WEIMI rows the same way. SPLIT_PART(aisle_code,'-',2) is destructive
    -- for multi-cabinet machines and must not be reintroduced.
    AND lss.slot_name = LEFT(sc.shelf_code, 1)
                     || (SUBSTR(sc.shelf_code, 2)::int)::text
  WHERE prp.plan_date = p_plan_date
  ORDER BY m.official_name, sc.shelf_code;
$function$;

GRANT EXECUTE ON FUNCTION public.get_pod_refill_draft(date)
  TO authenticated, anon, service_role, PUBLIC;
