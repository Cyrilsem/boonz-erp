-- PRD-079 Part A (additive, read-only, Article-16 canonical predicate + held-state view).
-- wh_is_pickable = canonical WH pickability predicate; 0-mismatch parity with v_wh_pickable.
-- v_wh_stock_state = per-batch pickable_units + held_class. Engines untouched.
-- Part B (engine_add_pod/v_wh_pickable UNIFICATION onto wh_is_pickable, flag wh_gate_v2) PARKED:
-- engine_add_pod carries a divergent inline wh_avail; Dara+CS must investigate the historical
-- divergence before a refactor (pre-seeded park). Held-state layer ships without it.
CREATE OR REPLACE FUNCTION public.wh_is_pickable(p_wh_inventory_id uuid, p_machine_id uuid DEFAULT NULL, p_today date DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT wi.status = 'Active'
     AND NOT COALESCE(wi.quarantined, false)
     AND (wi.expiration_date >= COALESCE(p_today, (now() AT TIME ZONE 'Asia/Dubai')::date) OR wi.expiration_date IS NULL)
     AND wi.warehouse_stock > 0
     AND (wi.reserved_for_machine_id IS NULL OR wi.reserved_for_machine_id = p_machine_id)
  FROM warehouse_inventory wi WHERE wi.wh_inventory_id = p_wh_inventory_id;
$$;
GRANT EXECUTE ON FUNCTION public.wh_is_pickable(uuid, uuid, date) TO authenticated, service_role;

CREATE OR REPLACE VIEW public.v_wh_stock_state AS
WITH t AS (SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today)
SELECT wi.wh_inventory_id, wi.boonz_product_id, wi.warehouse_id, wi.batch_id, wi.expiration_date,
  wi.reserved_for_machine_id, wi.warehouse_stock, wi.consumer_stock,
  CASE WHEN wi.status='Active' AND NOT COALESCE(wi.quarantined,false)
         AND (wi.expiration_date >= t.today OR wi.expiration_date IS NULL) AND wi.warehouse_stock>0
       THEN wi.warehouse_stock ELSE 0 END AS pickable_units,
  CASE WHEN COALESCE(wi.quarantined,false) THEN 'quarantined'
       WHEN wi.status <> 'Active' THEN 'inactive'
       WHEN wi.expiration_date < t.today THEN 'expired'
       WHEN wi.reserved_for_machine_id IS NOT NULL THEN 'pinned_other_machine'
       WHEN COALESCE(wi.consumer_stock,0) > 0 THEN 'consumer_moved'
       ELSE 'available' END AS held_class
FROM warehouse_inventory wi CROSS JOIN t;
GRANT SELECT ON public.v_wh_stock_state TO authenticated, service_role;

COMMENT ON FUNCTION public.wh_is_pickable(uuid,uuid,date) IS
  'PRD-079 canonical WH pickability predicate (Article 16). 0-mismatch parity with v_wh_pickable membership.';
