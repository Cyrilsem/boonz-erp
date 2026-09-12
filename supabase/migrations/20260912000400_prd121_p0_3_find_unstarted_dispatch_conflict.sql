-- PRD-121 P0.3: "Add product to shelf" hits prevent_duplicate_unstarted_dispatch and shows
-- the raw Postgres exception text with a static hint pointing at "Change product" -- which
-- is the WRONG recovery action when the driver just wants more units of the SAME product
-- already pending on the shelf (Change product swaps the product on the existing line to
-- something else; it doesn't let the driver add to the existing quantity). PRD-112's own
-- incident (2026-08-08, VOXMCC-1005) was actually a different-product case where the hint is
-- right; a same-product duplicate needs a different, currently-missing recovery: bump the
-- existing row's quantity instead of failing outright.
--
-- New read-only helper so the FE can offer a real "add to existing line instead" action
-- rather than only supplementary hint text: given the same (machine, shelf, product,
-- action, date) key add_dispatch_row's INSERT would use, return the conflicting unstarted
-- row's dispatch_id/quantity/is_m2m if one exists. Mirrors
-- prevent_duplicate_unstarted_dispatch's own WHERE clause exactly (same predicate, so this
-- helper can never disagree with the trigger about what counts as a conflict) rather than
-- re-deriving a looser or stricter one.
--
-- SECURITY INVOKER (Cody D2/read-only default): this only reads refill_dispatching and
-- shelf_configurations, both of which authenticated field_staff can already read directly
-- (the packing/dispatching pages already do). No new access is granted; DEFINER is not
-- needed for a pure read.
--
-- Cody: approve. Read-only helper, no write path, no registered-metric re-derivation
-- (Article 16 n/a), SECURITY INVOKER (safer default over unjustified DEFINER).

CREATE OR REPLACE FUNCTION public.find_unstarted_dispatch_conflict(
  p_machine_id uuid, p_shelf_code text, p_boonz_product_id uuid,
  p_action text, p_dispatch_date date
)
RETURNS TABLE(dispatch_id uuid, quantity numeric, is_m2m boolean)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
  SELECT rd.dispatch_id, rd.quantity, COALESCE(rd.is_m2m, false)
  FROM public.refill_dispatching rd
  JOIN public.shelf_configurations sc ON sc.shelf_id = rd.shelf_id
  WHERE rd.machine_id = p_machine_id
    AND sc.shelf_code = p_shelf_code
    AND rd.boonz_product_id = p_boonz_product_id
    AND rd.dispatch_date = p_dispatch_date
    AND rd.action = p_action
    AND rd.include = true
    AND COALESCE(rd.filled_quantity, 0) = 0
    AND COALESCE(rd.packed, false) = false
    AND COALESCE(rd.item_added, false) = false
    AND COALESCE(rd.returned, false) = false
    AND COALESCE(rd.skipped, false) = false
    AND COALESCE(rd.cancelled, false) = false
  LIMIT 1;
$function$;
