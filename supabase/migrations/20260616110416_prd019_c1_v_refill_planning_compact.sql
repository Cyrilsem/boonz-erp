-- PRD-019 C1 (AC-C1..C4): compact all-rows planning view.
-- NOT APPLIED. Author-only; apply after CS sign-off (after A1 v_shelf_capacity).
-- One row per real shelf (all A01..A16) for every active field machine, for the
-- operational plan date (resolve_refill_plan_date(), never CURRENT_DATE). The
-- planned action+qty for that date is LEFT-joined so EVERY slot shows, including
-- ones the engine left untouched. Chat and FE read this same object (C4).
--   stock x/max, fill_pct, headroom  <- v_shelf_capacity (PRD-019 A1)
--   stance, final_score, velocity    <- slot_lifecycle (current row)
--   global badge                     <- mv_global_product_scores.global_status
--   local badge                      <- compute_local_role(velocity proxy)
--   planned action+qty, comments     <- pod_refill_plan (this plan_date)
--   wh_availability                  <- reserve-aware sellable WH stock for the
--                                       shelf product (same subquery the engine
--                                       and get_pod_refill_draft use); flags 0.
-- Default sort: fill_pct ascending (lowest fill first), machine, slot.
CREATE OR REPLACE VIEW public.v_refill_planning_compact AS
WITH pd AS (SELECT public.resolve_refill_plan_date() AS plan_date),
fleet AS (
  SELECT m.machine_id, m.official_name, m.primary_warehouse_id, m.secondary_warehouse_id
  FROM public.machines m
  WHERE COALESCE(m.include_in_refill, true) = true
    AND COALESCE(m.status, 'Active') NOT IN ('Inactive','Warehouse')
),
shelves AS (
  SELECT sc.shelf_id, sc.machine_id, sc.shelf_code, sc.shelf_size
  FROM public.shelf_configurations sc
  WHERE sc.is_phantom = false
),
cur_slot AS (
  SELECT sl.shelf_id, sl.machine_id, sl.pod_product_id, sl.signal, sl.score,
         sl.velocity_7d, sl.velocity_30d
  FROM public.slot_lifecycle sl
  WHERE sl.archived = false AND sl.is_current = true
)
SELECT
  pd.plan_date,
  f.machine_id,
  f.official_name                                   AS machine_name,
  s.shelf_id,
  s.shelf_code                                      AS slot,
  s.shelf_size                                      AS size_class,
  COALESCE(pp.pod_product_name, cap.current_product) AS product,
  cap.current_stock,
  cap.max_stock,
  cap.headroom,
  ROUND(CASE WHEN cap.max_stock > 0
             THEN cap.current_stock::numeric * 100.0 / cap.max_stock ELSE 0 END, 1) AS fill_pct,
  cs.signal                                         AS stance,
  COALESCE(gps.global_status, '📦 Core Range')      AS global_badge,
  public.compute_local_role(COALESCE(cs.velocity_7d, 0) * 7.0, 0) AS local_badge,
  ROUND(COALESCE(cs.velocity_7d, 0) * 7.0, 1)       AS sales_7d,
  ROUND(COALESCE(cs.score, 0), 1)                   AS final_score,
  prp.action                                        AS planned_action,
  prp.qty                                           AS planned_qty,
  (
    SELECT SUM(wi.warehouse_stock)::int
    FROM public.product_mapping pm
    JOIN public.warehouse_inventory wi
      ON wi.boonz_product_id = pm.boonz_product_id
     AND wi.status = 'Active'
     AND wi.quarantined = false
     AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
     AND wi.warehouse_id = ANY (ARRAY[f.primary_warehouse_id, f.secondary_warehouse_id])
     AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = f.machine_id)
    WHERE pm.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id)
      AND pm.status = 'Active'
      AND (pm.machine_id IS NULL OR pm.machine_id = f.machine_id)
  )                                                 AS wh_availability,
  (COALESCE((
    SELECT SUM(wi.warehouse_stock)::int
    FROM public.product_mapping pm
    JOIN public.warehouse_inventory wi
      ON wi.boonz_product_id = pm.boonz_product_id
     AND wi.status = 'Active' AND wi.quarantined = false
     AND (wi.expiration_date >= CURRENT_DATE OR wi.expiration_date IS NULL)
     AND wi.warehouse_id = ANY (ARRAY[f.primary_warehouse_id, f.secondary_warehouse_id])
     AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = f.machine_id)
    WHERE pm.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id)
      AND pm.status = 'Active'
      AND (pm.machine_id IS NULL OR pm.machine_id = f.machine_id)
  ), 0) = 0)                                        AS wh_unsourceable,
  prp.status                                        AS plan_row_status,
  prp.reasoning->'manual_edit'->>'reason'           AS edit_comment,
  prp.reasoning->'manual_add'->>'reason'            AS add_comment,
  prp.reasoning->>'clamp_reason'                    AS clamp_reason,
  prp.edited_by,
  prp.pod_product_id                                AS planned_pod_product_id,
  cs.pod_product_id                                 AS current_pod_product_id
FROM pd
CROSS JOIN fleet f
JOIN shelves s              ON s.machine_id = f.machine_id
LEFT JOIN cur_slot cs       ON cs.shelf_id = s.shelf_id
LEFT JOIN public.v_shelf_capacity cap ON cap.shelf_id = s.shelf_id
LEFT JOIN public.pod_refill_plan prp
       ON prp.plan_date = pd.plan_date
      AND prp.machine_id = f.machine_id
      AND prp.shelf_id   = s.shelf_id
      AND prp.status <> 'superseded'
LEFT JOIN public.pod_products pp ON pp.pod_product_id = COALESCE(prp.pod_product_id, cs.pod_product_id)
LEFT JOIN public.mv_global_product_scores gps
       ON LOWER(TRIM(gps.product)) = LOWER(TRIM(COALESCE(pp.pod_product_name, cap.current_product)))
ORDER BY f.official_name,
         ROUND(CASE WHEN cap.max_stock > 0
                    THEN cap.current_stock::numeric * 100.0 / cap.max_stock ELSE 0 END, 1) ASC,
         s.shelf_code;

COMMENT ON VIEW public.v_refill_planning_compact IS
'PRD-019 C1 (AC-C1..C4). All real shelves per active machine for resolve_refill_plan_date(), one compact row each: slot, product, stock x/max, fill_pct, headroom, stance, global+local badge, sales_7d, final_score, planned action+qty, wh_availability (reserve-aware sellable WH stock for the shelf product) with wh_unsourceable flag, and the inline comment/clamp/edited_by fields. Default sort fill_pct asc. Chat and FE both read this object.';

GRANT SELECT ON public.v_refill_planning_compact TO anon, authenticated, service_role;
