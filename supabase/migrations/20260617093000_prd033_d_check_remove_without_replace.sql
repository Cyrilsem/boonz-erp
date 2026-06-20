-- PRD-033 Phase D (R4): check_remove_without_replace - pre-commit invariant that flags any
-- shelf where an incumbent is being REMOVE/M2W'd but its paired ADD_NEW resolves to 0
-- dispatchable units (no pickable WH), which would empty the shelf with nothing to load.
--
-- Implemented as a READ-ONLY check RPC rather than editing the (large, canonical) stitch
-- writer: the refill conductor / FE calls this before commit and blocks on status='block'.
-- This is the DEFAULT-BLOCK behaviour. CS may instead choose auto-hold-the-REMOVE; that is a
-- writer change (edit the REMOVE row) and is deliberately NOT done here - this RPC only
-- detects and reports, so it writes nothing and needs no protected-write Cody gate.
--
-- "Dispatchable units" for the ADD_NEW = SUM(pickable WH) over the pod's Active mapped boonz
-- (machine-scoped or global), reserved to this machine or unreserved - mirrors stitch's
-- wh_avail. Pure removals (a REMOVE/M2W with no paired ADD_NEW on the shelf) are intentional
-- and are NOT flagged. Only active (non-superseded/voided) plan rows are considered.

CREATE OR REPLACE FUNCTION public.check_remove_without_replace(p_plan_date date)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH shelves AS (
    SELECT DISTINCT prp.machine_id, prp.shelf_id
    FROM public.pod_refill_plan prp
    WHERE prp.plan_date = p_plan_date
      AND prp.action IN ('REMOVE','M2W')
      AND prp.status NOT IN ('superseded','voided')
  ),
  adds AS (
    SELECT prp.machine_id, prp.shelf_id, prp.pod_product_id, prp.qty
    FROM public.pod_refill_plan prp
    JOIN shelves s ON s.machine_id = prp.machine_id AND s.shelf_id = prp.shelf_id
    WHERE prp.plan_date = p_plan_date
      AND prp.action = 'ADD_NEW'
      AND prp.status NOT IN ('superseded','voided')
  ),
  resolved AS (
    SELECT a.machine_id, a.shelf_id, a.pod_product_id, a.qty,
           COALESCE((
             SELECT SUM(wp.warehouse_stock)::int
             FROM public.product_mapping pm
             JOIN public.v_wh_pickable wp ON wp.boonz_product_id = pm.boonz_product_id
             WHERE pm.pod_product_id = a.pod_product_id
               AND pm.status = 'Active'
               AND (pm.machine_id = a.machine_id OR pm.machine_id IS NULL)
               AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = a.machine_id)
           ), 0) AS pickable_units
    FROM adds a
  ),
  flagged AS (
    SELECT r.*, m.official_name AS machine_name, sc.shelf_code, pp.pod_product_name
    FROM resolved r
    JOIN public.machines m              ON m.machine_id = r.machine_id
    JOIN public.shelf_configurations sc ON sc.shelf_id = r.shelf_id
    JOIN public.pod_products pp         ON pp.pod_product_id = r.pod_product_id
    WHERE r.pickable_units = 0
  )
  SELECT jsonb_build_object(
    'plan_date', p_plan_date,
    'status', CASE WHEN EXISTS (SELECT 1 FROM flagged) THEN 'block' ELSE 'ok' END,
    'flagged_count', (SELECT COUNT(*) FROM flagged),
    'message', CASE WHEN EXISTS (SELECT 1 FROM flagged)
                    THEN 'One or more shelves remove an incumbent but the replacement resolves to 0 dispatchable units. Release WH quarantine / restock, or pull the REMOVE, before commit.'
                    ELSE 'No remove-without-replace shelves.' END,
    'flagged', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'machine', f.machine_name, 'shelf', f.shelf_code,
               'add_pod_product', f.pod_product_name, 'add_qty', f.qty,
               'pickable_units', f.pickable_units)
             ORDER BY f.machine_name, f.shelf_code)
      FROM flagged f), '[]'::jsonb)
  );
$function$;
