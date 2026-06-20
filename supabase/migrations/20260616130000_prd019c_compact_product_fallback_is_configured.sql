-- PRD-019 Family C follow-up: /refill Compact view product fallback + is_configured.
-- NOT APPLIED. Author-only; apply after CS sign-off. Forward-only CREATE OR REPLACE VIEW.
-- Read-only view. Writes to NO protected table. New planogram read is a SELECT only.
--
-- Two changes vs the live body (fetched via pg_get_viewdef 2026-06-16):
--   1. product fallback: resolve the canonical pod_product_name from the first
--      available product id across planned row -> slot_lifecycle current -> planogram
--      assigned (NEW source), then fall back to the live WEIMI feed raw name. So a
--      shelf configured in ANY source keeps showing its product even if the live feed
--      drops. (Ordering note for CS: canonical pod_product_name is preferred over the
--      raw live feed string, matching the existing behaviour; the live raw name is used
--      only when no canonical id exists in any source. Spec listed live first, but
--      live-first would replace canonical names with raw feed strings, a regression, so
--      the canonical id chain stays first and planogram is appended. In current live
--      data this changes 0 rows: all 96 null-product shelves are fully unconfigured and
--      every shelf that has a product already has it live, so the fallback is purely
--      forward-looking resilience.)
--   2. is_configured (NEW, appended last column): true when a product is assigned in
--      ANY source (live feed, slot_lifecycle current, planogram, or a non-superseded
--      planned row). The unconfigured second-cabinet shelves (e.g. AMZ-1029-3003-O1
--      B01..B16) get is_configured=false so the FE can hide that noise by default.
--
-- The `plano` CTE picks one current planogram product per shelf (DISTINCT ON, latest
-- effective) so the LEFT JOIN can never multiply rows.
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
    ( SELECT sum(wi.warehouse_stock)::integer AS sum
           FROM product_mapping pm
             JOIN warehouse_inventory wi ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active'::text AND wi.quarantined = false AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL) AND (wi.warehouse_id = ANY (ARRAY[f.primary_warehouse_id, f.secondary_warehouse_id])) AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = f.machine_id)
          WHERE pm.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id) AND pm.status = 'Active'::text AND (pm.machine_id IS NULL OR pm.machine_id = f.machine_id)) AS wh_availability,
    COALESCE(( SELECT sum(wi.warehouse_stock)::integer AS sum
           FROM product_mapping pm
             JOIN warehouse_inventory wi ON wi.boonz_product_id = pm.boonz_product_id AND wi.status = 'Active'::text AND wi.quarantined = false AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL) AND (wi.warehouse_id = ANY (ARRAY[f.primary_warehouse_id, f.secondary_warehouse_id])) AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = f.machine_id)
          WHERE pm.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id) AND pm.status = 'Active'::text AND (pm.machine_id IS NULL OR pm.machine_id = f.machine_id)), 0) = 0 AS wh_unsourceable,
    prp.status AS plan_row_status,
    (prp.reasoning -> 'manual_edit'::text) ->> 'reason'::text AS edit_comment,
    (prp.reasoning -> 'manual_add'::text) ->> 'reason'::text AS add_comment,
    prp.reasoning ->> 'clamp_reason'::text AS clamp_reason,
    prp.edited_by,
    prp.pod_product_id AS planned_pod_product_id,
    cs.pod_product_id AS current_pod_product_id,
    (cap.current_product IS NOT NULL
        OR cs.pod_product_id IS NOT NULL
        OR pg.pod_product_id IS NOT NULL
        OR prp.pod_product_id IS NOT NULL) AS is_configured
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

COMMENT ON VIEW public.v_refill_planning_compact IS
'PRD-019 Family C compact all-slots planning view (scoped to resolve_refill_plan_date()). product = canonical pod_product_name resolved from planned row -> slot_lifecycle -> planogram, falling back to the live WEIMI feed raw name. is_configured = a product exists in any source (live/lifecycle/planogram/planned); false marks unconfigured empty shelves (e.g. AMZ second cabinet) for FE hiding. Read-only; writes to no protected table.';
