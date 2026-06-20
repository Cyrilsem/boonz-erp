-- PRD-035 Phase C (WS-D) - session readiness / context load. READ-ONLY (Cody fast-path).
--
-- get_refill_session_readiness(plan_date): one snapshot, built when a plan opens, that resolves for
-- every in-scope shelf the chain the engine is otherwise blind to:
--   pod -> mapped boonz flavor(s) -> on-shelf flavor -> REAL pickable WH (net of quarantine AND
--   reservations) -> can-fill / can't-fill + why.
--
-- Leans on PRD-028 canonical objects: v_wh_pickable (Active, NOT quarantined, in-date Dubai/NULL,
-- stock>0; Article 16 row 34) and v_pod_inventory_latest (live on-shelf flavor). Reservations are NOT
-- filtered by v_wh_pickable (it only exposes reserved_for_machine_id), so this RPC nets them per
-- machine: pickable_for_machine = unreserved batches OR batches reserved to THIS machine. That is what
-- lets it flag the (quarantined + reserved-elsewhere + unmapped) cases that silently fail at plan time.
--
-- SECURITY INVOKER: read-only, no writes, caller RLS applies (operator_admin already reads all these
-- tables in the refill FE). No app.via_rpc / audit needed (Article 4/8 are writer-only obligations).
--
-- Mapping precedence mirrors stitch_pod_to_boonz: machine-specific mapping wins, else global default.
-- Verdict logic mirrors Phase A (WS-C) so readiness predicts exactly what the stitch line-builder will do:
--   right-qty+right-SKU (ideal on shelf, in stock)  -> can_fill
--   right-qty via sibling (ideal OOS, sibling in WH) -> can_fill_via_sibling
--   empty (all mapped flavors OOS)                    -> cant_fill_wh_zero
--   no active mapping                                 -> cant_fill_unmapped

CREATE OR REPLACE FUNCTION public.get_refill_session_readiness(p_plan_date date DEFAULT (CURRENT_DATE + 1))
 RETURNS TABLE(
   machine_id uuid, machine_name text, shelf_id uuid, shelf_code text,
   pod_product_id uuid, pod_product_name text, action text, planned_qty integer,
   mapped_variant_n integer, mapped_in_stock_n integer, onshelf_variant_n integer,
   has_onshelf_flavor boolean, ideal_in_stock boolean, pickable_wh_total integer,
   onshelf_names text, best_sibling_name text, earliest_wh_expiry date, expiry_risk boolean,
   onboarding_gap text, readiness text, reason text
 )
 LANGUAGE sql
 STABLE
 SECURITY INVOKER
 SET search_path TO 'public'
AS $function$
  WITH scope AS (
    SELECT prp.plan_date, prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.action, prp.qty,
           m.official_name AS machine_name, sc.shelf_code, pp.pod_product_name
      FROM public.pod_refill_plan prp
      JOIN public.machines m ON m.machine_id = prp.machine_id
      JOIN public.shelf_configurations sc ON sc.shelf_id = prp.shelf_id
      JOIN public.pod_products pp ON pp.pod_product_id = prp.pod_product_id
     WHERE prp.plan_date = p_plan_date
       AND prp.action IN ('REFILL','ADD_NEW')
       AND prp.status IN ('draft','approved')
  ),
  mapped_raw AS (
    SELECT s.*, pm.boonz_product_id, bp.boonz_product_name,
           ROW_NUMBER() OVER (
             PARTITION BY s.machine_id, s.shelf_id, s.pod_product_id, pm.boonz_product_id
             ORDER BY (pm.machine_id = s.machine_id) DESC NULLS LAST, pm.is_global_default DESC, pm.boonz_product_id
           ) AS rnk
      FROM scope s
      JOIN public.product_mapping pm
        ON pm.pod_product_id = s.pod_product_id AND pm.status = 'Active'
       AND ( pm.machine_id = s.machine_id
          OR (pm.machine_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.product_mapping pms
                               WHERE pms.pod_product_id = s.pod_product_id
                                 AND pms.machine_id = s.machine_id
                                 AND pms.status = 'Active')) )
      JOIN public.boonz_products bp ON bp.product_id = pm.boonz_product_id
  ),
  mapped AS (SELECT * FROM mapped_raw WHERE rnk = 1),
  variant_state AS (
    SELECT m.machine_id, m.machine_name, m.shelf_id, m.shelf_code, m.pod_product_id, m.pod_product_name,
           m.action, m.qty, m.boonz_product_id, m.boonz_product_name,
           EXISTS (SELECT 1 FROM public.v_pod_inventory_latest pil
                    WHERE pil.machine_id = m.machine_id AND pil.shelf_id = m.shelf_id
                      AND pil.status = 'Active' AND pil.boonz_product_id = m.boonz_product_id) AS on_shelf,
           COALESCE((SELECT SUM(wp.warehouse_stock)::int FROM public.v_wh_pickable wp
                      WHERE wp.boonz_product_id = m.boonz_product_id
                        AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = m.machine_id)), 0) AS pickable_wh,
           (SELECT MIN(wp.expiration_date) FROM public.v_wh_pickable wp
             WHERE wp.boonz_product_id = m.boonz_product_id
               AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = m.machine_id)) AS variant_wh_expiry
      FROM mapped m
  ),
  agg AS (
    SELECT machine_id, machine_name, shelf_id, shelf_code, pod_product_id, pod_product_name, action, qty,
           COUNT(*)::int AS mapped_variant_n,
           COUNT(*) FILTER (WHERE pickable_wh > 0)::int AS mapped_in_stock_n,
           COUNT(*) FILTER (WHERE on_shelf)::int AS onshelf_variant_n,
           bool_or(on_shelf) AS has_onshelf_flavor,
           bool_or(on_shelf AND pickable_wh > 0) AS ideal_in_stock,
           SUM(pickable_wh)::int AS pickable_wh_total,
           string_agg(boonz_product_name, ', ') FILTER (WHERE on_shelf) AS onshelf_names,
           (array_agg(boonz_product_name ORDER BY pickable_wh DESC, boonz_product_name)
              FILTER (WHERE NOT on_shelf AND pickable_wh > 0))[1] AS best_sibling_name,
           MIN(variant_wh_expiry) FILTER (WHERE pickable_wh > 0) AS earliest_wh_expiry
      FROM variant_state
     GROUP BY machine_id, machine_name, shelf_id, shelf_code, pod_product_id, pod_product_name, action, qty
  ),
  unmapped AS (
    SELECT s.machine_id, s.machine_name, s.shelf_id, s.shelf_code, s.pod_product_id, s.pod_product_name, s.action, s.qty
      FROM scope s
     WHERE NOT EXISTS (SELECT 1 FROM mapped mp
                        WHERE mp.machine_id = s.machine_id AND mp.shelf_id = s.shelf_id
                          AND mp.pod_product_id = s.pod_product_id)
  ),
  rows_all AS (
    -- mapped shelves
    SELECT a.machine_id, a.machine_name, a.shelf_id, a.shelf_code, a.pod_product_id, a.pod_product_name,
           a.action, a.qty AS planned_qty,
           a.mapped_variant_n, a.mapped_in_stock_n, a.onshelf_variant_n,
           a.has_onshelf_flavor, a.ideal_in_stock, a.pickable_wh_total,
           a.onshelf_names, a.best_sibling_name, a.earliest_wh_expiry,
           (a.earliest_wh_expiry IS NOT NULL AND a.earliest_wh_expiry <= p_plan_date + 14) AS expiry_risk,
           NULL::text AS onboarding_gap,
           CASE
             -- REFILL onto a shelf that has a known on-shelf flavor: WS-C priority order
             WHEN a.action = 'REFILL' AND a.has_onshelf_flavor AND a.ideal_in_stock THEN 'can_fill'
             WHEN a.action = 'REFILL' AND a.has_onshelf_flavor AND a.best_sibling_name IS NOT NULL THEN 'can_fill_via_sibling'
             WHEN a.action = 'REFILL' AND a.has_onshelf_flavor THEN 'cant_fill_wh_zero'
             -- ADD_NEW, or REFILL onto an empty-of-known-variant shelf: any mapped flavor in stock fills
             WHEN a.mapped_in_stock_n > 0 THEN 'can_fill'
             ELSE 'cant_fill_wh_zero'
           END AS readiness
      FROM agg a
    UNION ALL
    -- unmapped shelves (onboarding gap)
    SELECT u.machine_id, u.machine_name, u.shelf_id, u.shelf_code, u.pod_product_id, u.pod_product_name,
           u.action, u.qty AS planned_qty,
           0, 0, 0,
           false, false, 0,
           NULL::text, NULL::text, NULL::date,
           false,
           'no_active_mapping'::text AS onboarding_gap,
           'cant_fill_unmapped'::text AS readiness
      FROM unmapped u
  )
  SELECT
    r.machine_id, r.machine_name, r.shelf_id, r.shelf_code,
    r.pod_product_id, r.pod_product_name, r.action, r.planned_qty,
    r.mapped_variant_n, r.mapped_in_stock_n, r.onshelf_variant_n,
    r.has_onshelf_flavor, r.ideal_in_stock, r.pickable_wh_total,
    r.onshelf_names, r.best_sibling_name, r.earliest_wh_expiry, r.expiry_risk,
    r.onboarding_gap, r.readiness,
    CASE r.readiness
      WHEN 'can_fill' THEN
        CASE WHEN r.expiry_risk
             THEN 'In-stock; ideal SKU available. EXPIRY RISK: earliest WH batch expires ' || r.earliest_wh_expiry::text
             ELSE 'In-stock; ideal SKU available' END
      WHEN 'can_fill_via_sibling' THEN
        'On-shelf flavor ' || COALESCE(r.onshelf_names,'(unknown)') || ' out of pickable WH; sibling '
        || COALESCE(r.best_sibling_name,'(unknown)') || ' available -> WS-C sibling fallback will fill'
      WHEN 'cant_fill_wh_zero' THEN
        'No pickable WH for any mapped flavor (' || r.mapped_variant_n::text
        || ' mapped, 0 in stock after quarantine + reservation netting)'
      WHEN 'cant_fill_unmapped' THEN
        'Onboarding gap: pod ' || r.pod_product_name || ' has no active product_mapping'
      ELSE 'review'
    END AS reason
  FROM rows_all r
  ORDER BY (r.readiness <> 'can_fill') DESC, r.machine_name, r.shelf_code;
$function$;

COMMENT ON FUNCTION public.get_refill_session_readiness(date) IS
  'PRD-035 WS-D session readiness snapshot. Read-only. Per in-scope shelf (pod_refill_plan REFILL/ADD_NEW, draft|approved): on-shelf flavor vs pickable WH per mapped flavor (quarantine + reservation netted via v_wh_pickable), mapping/onboarding health, expiry risk, and a can-fill/cant-fill+why verdict that mirrors the WS-C stitch line-builder.';
