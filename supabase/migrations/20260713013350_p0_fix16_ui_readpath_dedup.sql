-- p0_fix16: fix UI read-path fan-outs (dedupe wh availability, deterministic global-default pod resolution)
CREATE OR REPLACE FUNCTION public.get_pod_refill_draft(p_plan_date date DEFAULT (CURRENT_DATE + 1))
 RETURNS TABLE(plan_date date, machine_id uuid, machine_name text, shelf_id uuid, shelf_code text, pod_product_id uuid, pod_product_name text, action text, qty integer, current_stock integer, max_stock integer, fill_pct numeric, velocity_30d numeric, signal text, clamp_reason text, source_origin text, has_intent boolean, intent_id uuid, status text, reasoning jsonb, edited_at timestamp with time zone, edited_by text, wh_avail integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
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
      SELECT SUM(wh.warehouse_stock)::int
      FROM (
        SELECT DISTINCT wi.wh_inventory_id, wi.warehouse_stock
        FROM public.product_mapping pm
        JOIN public.warehouse_inventory wi
          ON wi.boonz_product_id = pm.boonz_product_id
         AND wi.status = 'Active'
         AND wi.quarantined = false
         AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
         AND wi.warehouse_id = ANY (ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id])
         AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = prp.machine_id)
        WHERE pm.pod_product_id = prp.pod_product_id
          AND pm.status = 'Active'
          AND (pm.machine_id IS NULL OR pm.machine_id = prp.machine_id)
      ) wh
    ) AS wh_avail
  FROM pod_refill_plan prp
  JOIN machines m              ON m.machine_id       = prp.machine_id
  JOIN shelf_configurations sc ON sc.shelf_id        = prp.shelf_id
  JOIN pod_products pp         ON pp.pod_product_id  = prp.pod_product_id
  LEFT JOIN v_live_shelf_stock lss
    ON  lss.machine_id = prp.machine_id
    AND lss.slot_name = LEFT(sc.shelf_code, 1)
                     || (SUBSTR(sc.shelf_code, 2)::int)::text
  WHERE prp.plan_date = p_plan_date
    AND prp.status = 'draft'
  ORDER BY m.official_name, sc.shelf_code;
$function$
;

CREATE OR REPLACE VIEW public.v_refill_planning_compact AS
 WITH pd AS (
         SELECT resolve_refill_plan_date() AS plan_date
        ), fleet AS (
         SELECT m.machine_id,
            m.official_name,
            m.primary_warehouse_id,
            m.secondary_warehouse_id
           FROM machines m
          WHERE COALESCE(m.include_in_refill, true) = true AND (COALESCE(m.status, 'Active'::text) <> ALL (ARRAY['Inactive'::text, 'Warehouse'::text]))
        ), shelves AS (
         SELECT sc.shelf_id,
            sc.machine_id,
            sc.shelf_code,
            sc.shelf_size
           FROM shelf_configurations sc
          WHERE sc.is_phantom = false
        ), cur_slot AS (
         SELECT sl.shelf_id,
            sl.machine_id,
            sl.pod_product_id,
            sl.signal,
            sl.score,
            sl.velocity_7d,
            sl.velocity_30d
           FROM slot_lifecycle sl
          WHERE sl.archived = false AND sl.is_current = true
        ), plano AS (
         SELECT DISTINCT ON (p.shelf_id) p.shelf_id,
            p.pod_product_id
           FROM planogram p
          WHERE p.is_active = true
          ORDER BY p.shelf_id, p.effective_from DESC NULLS LAST, p.updated_at DESC NULLS LAST
        )
 SELECT pd.plan_date,
    f.machine_id,
    f.official_name AS machine_name,
    s.shelf_id,
    s.shelf_code AS slot,
    s.shelf_size AS size_class,
    COALESCE(pp.pod_product_name, cap.current_product) AS product,
    cap.current_stock,
    cap.max_stock,
    cap.headroom,
    round(
        CASE
            WHEN cap.max_stock > 0 THEN cap.current_stock::numeric * 100.0 / cap.max_stock::numeric
            ELSE 0::numeric
        END, 1) AS fill_pct,
    cs.signal AS stance,
    COALESCE(gps.global_status, '📦 Core Range'::text) AS global_badge,
    compute_local_role(COALESCE(cs.velocity_7d, 0::numeric) * 7.0, 0::numeric) AS local_badge,
    round(COALESCE(cs.velocity_7d, 0::numeric) * 7.0, 1) AS sales_7d,
    round(COALESCE(cs.score, 0::numeric), 1) AS final_score,
    prp.action AS planned_action,
    prp.qty AS planned_qty,
    ( SELECT sum(wh.warehouse_stock)::integer AS sum
           FROM ( SELECT DISTINCT wi.wh_inventory_id, wi.warehouse_stock
                   FROM product_mapping pm
                     JOIN warehouse_inventory wi ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active'::text AND wi.quarantined = false AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL) AND (wi.warehouse_id = ANY (ARRAY[f.primary_warehouse_id, f.secondary_warehouse_id])) AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = f.machine_id)
                  WHERE pm.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id) AND pm.status = 'Active'::text AND (pm.machine_id IS NULL OR pm.machine_id = f.machine_id)) wh) AS wh_availability,
    COALESCE(( SELECT sum(wh.warehouse_stock)::integer AS sum
           FROM ( SELECT DISTINCT wi.wh_inventory_id, wi.warehouse_stock
                   FROM product_mapping pm
                     JOIN warehouse_inventory wi ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active'::text AND wi.quarantined = false AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL) AND (wi.warehouse_id = ANY (ARRAY[f.primary_warehouse_id, f.secondary_warehouse_id])) AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = f.machine_id)
                  WHERE pm.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id) AND pm.status = 'Active'::text AND (pm.machine_id IS NULL OR pm.machine_id = f.machine_id)) wh), 0) = 0 AS wh_unsourceable,
    prp.status AS plan_row_status,
    (prp.reasoning -> 'manual_edit'::text) ->> 'reason'::text AS edit_comment,
    (prp.reasoning -> 'manual_add'::text) ->> 'reason'::text AS add_comment,
    prp.reasoning ->> 'clamp_reason'::text AS clamp_reason,
    prp.edited_by,
    prp.pod_product_id AS planned_pod_product_id,
    cs.pod_product_id AS current_pod_product_id,
    cap.current_product IS NOT NULL OR cs.pod_product_id IS NOT NULL OR pg.pod_product_id IS NOT NULL OR prp.pod_product_id IS NOT NULL AS is_configured
   FROM pd
     CROSS JOIN fleet f
     JOIN shelves s ON s.machine_id = f.machine_id
     LEFT JOIN cur_slot cs ON cs.shelf_id = s.shelf_id
     LEFT JOIN v_shelf_capacity cap ON cap.shelf_id = s.shelf_id
     LEFT JOIN plano pg ON pg.shelf_id = s.shelf_id
     LEFT JOIN pod_refill_plan prp ON prp.plan_date = pd.plan_date AND prp.machine_id = f.machine_id AND prp.shelf_id = s.shelf_id AND prp.status <> 'superseded'::text
     LEFT JOIN pod_products pp ON pp.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id, pg.pod_product_id)
     LEFT JOIN mv_global_product_scores gps ON lower(TRIM(BOTH FROM gps.product)) = lower(TRIM(BOTH FROM COALESCE(pp.pod_product_name, cap.current_product)))
  ORDER BY f.official_name, (round(
        CASE
            WHEN cap.max_stock > 0 THEN cap.current_stock::numeric * 100.0 / cap.max_stock::numeric
            ELSE 0::numeric
        END, 1)), s.shelf_code;

CREATE OR REPLACE VIEW public.v_warehouse_at_risk AS
 SELECT wi.wh_inventory_id,
    wi.boonz_product_id,
    wi.warehouse_id,
    w.name AS warehouse_name,
    bp.boonz_product_name,
    bp.product_category,
    bp.lifecycle_archetype,
    bp.attr_drink,
    bp.storage_temp_requirement,
    bp.product_brand,
    wi.warehouse_stock,
    wi.expiration_date,
    wi.expiration_date - CURRENT_DATE AS days_to_expiry,
        CASE
            WHEN wi.expiration_date IS NULL THEN 'no_expiry_set'::text
            WHEN wi.expiration_date < CURRENT_DATE THEN 'expired'::text
            WHEN wi.expiration_date < (CURRENT_DATE + 7) THEN 'urgent_0_7d'::text
            WHEN wi.expiration_date < (CURRENT_DATE + 30) THEN 'soon_7_30d'::text
            WHEN wi.expiration_date < (CURRENT_DATE + 60) THEN 'medium_30_60d'::text
            WHEN wi.expiration_date < (CURRENT_DATE + 90) THEN 'long_60_90d'::text
            ELSE 'safe_90d_plus'::text
        END AS urgency_bucket,
    pm.pod_product_id,
    pp.pod_product_name,
    plg.signal AS global_signal,
    plg.score AS global_score,
    plg.previous_score AS global_previous_score,
    plg.trend_component AS global_trend_component,
    plg.total_velocity_30d AS fleet_velocity_30d,
    plg.machine_count AS fleet_machine_count,
    plg.best_location_type,
    plg.worst_location_type,
    plg.local_score_distribution,
    plg.first_seen_at AS catalog_first_seen_at
   FROM warehouse_inventory wi
     JOIN warehouses w ON w.warehouse_id = wi.warehouse_id
     JOIN boonz_products bp ON bp.product_id = wi.boonz_product_id
     LEFT JOIN LATERAL ( SELECT pm0.pod_product_id
           FROM product_mapping pm0
          WHERE pm0.boonz_product_id = wi.boonz_product_id AND pm0.is_global_default = true AND pm0.status = 'Active'::text
          ORDER BY pm0.pod_product_id
         LIMIT 1) pm ON true
     LEFT JOIN pod_products pp ON pp.pod_product_id = pm.pod_product_id
     LEFT JOIN product_lifecycle_global plg ON plg.pod_product_id = pm.pod_product_id
  WHERE wi.status = 'Active'::text AND wi.warehouse_stock > 0::numeric;
