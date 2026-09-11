-- PRD-120 follow-up G7: lane capacity is per product, not per lane.
--
-- WEIMI max_stock (v_live_shelf_stock.max_stock, sourced live from the vending machine's
-- own reported slot capacity) describes whatever product WAS physically loaded on the
-- lane -- it is a property of the lane's last-known contents, not of the lane's true
-- physical dimensions. On a relabel (an Add New line changing the pod product on a shelf
-- to something with a genuinely different physical form, not just a different flavor of
-- the same pod), the old max_stock number is meaningless for the new product: a lane that
-- fit 12 packs of one product might fit only 6 trays of another, and a lane sized for a
-- 250ml can will not take the same count of 355ml cans.
--
-- New read-only check function (SQL, STABLE, no DEFINER -- matches check_eg_resolvable's
-- own shape exactly, same review-screen family) surfaces this as a Gate-1 warning, never
-- a block, per the task's own instruction. A genuine relabel is detected via
-- slot_lifecycle/v_live_shelf_stock's pod_product_id (the physical pod identity) changing,
-- NOT via boonz_product_id alone -- a routine multi-flavor pod lane (e.g. two Keen Health
-- Dipped Crackers flavors sharing one physical pod) must never be flagged; only a genuine
-- change of the physical pod counts. Live repro found: MC-2004-0100-O1 A14, currently "Al
-- Ain Zero" (WEIMI max_stock=4), planned Add New "Vitamin Well - Care" (physical_type
-- bottle_large) qty=5 -- exceeds the OLD lane's number, and the planner should re-estimate
-- from product_slot_capacity (physical_type + shelf_size -> max_units), a table that
-- already exists in this schema for exactly this purpose.
--
-- Cody: approve, Article 16 (surfaces product_slot_capacity, the existing canonical
-- physical_type->capacity lookup, rather than inventing a second one; read-only, no
-- write path).

CREATE OR REPLACE FUNCTION public.check_lane_capacity_after_relabel(p_plan_date date)
RETURNS TABLE(
  refill_plan_output_id uuid, machine_name text, shelf_code text,
  previous_pod_product_name text, previous_lane_max_stock integer,
  new_boonz_product_name text, new_physical_type text, planned_quantity integer,
  shelf_size text, estimated_new_capacity integer
)
LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  SELECT rpo.id, rpo.machine_name, rpo.shelf_code,
    vls.goods_name_raw, vls.max_stock,
    rpo.boonz_product_name, bp.physical_type, rpo.quantity,
    sc.shelf_size, psc.max_units
  FROM public.refill_plan_output rpo
  JOIN public.shelf_configurations sc ON sc.shelf_id = rpo.shelf_id
  LEFT JOIN public.v_live_shelf_stock vls ON vls.machine_id = rpo.machine_id
    AND vls.slot_name = (left(sc.shelf_code,1) || substr(sc.shelf_code,2)::integer::text)
  LEFT JOIN public.boonz_products bp ON bp.product_id = rpo.boonz_product_id
  LEFT JOIN public.product_slot_capacity psc ON psc.physical_type = bp.physical_type AND psc.shelf_size = sc.shelf_size
  WHERE rpo.plan_date = p_plan_date
    AND rpo.action = 'Add New'
    AND vls.pod_product_id IS NOT NULL
    AND vls.pod_product_id <> COALESCE(rpo.pod_product_id,
          (SELECT pp.pod_product_id FROM public.pod_products pp
            WHERE lower(trim(pp.pod_product_name)) = lower(trim(rpo.pod_product_name)) LIMIT 1))
    AND vls.max_stock IS NOT NULL
    AND rpo.quantity > vls.max_stock;
$function$;
