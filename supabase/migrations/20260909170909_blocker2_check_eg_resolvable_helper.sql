-- Blocker 2 (PRD-120 goal, 2026-09-09): read-only diagnostic helper.
-- CS: "the flavor-mismatched planning is partly mine, so give me a guard" --
-- surfaces a Remove line whose named boonz flavor has no Active pod lot on
-- that machine+shelf, BEFORE approval, as a warning only (never a block --
-- L5's push/bind fix is the actual remediation; this is visibility for the
-- human reviewing Gate-1).
--
-- Read-only, SECURITY INVOKER (plain SQL STABLE) -- no DEFINER, no role
-- gate, no mandatory reason: it mutates nothing, and RLS on
-- refill_plan_output/pod_inventory already governs what the caller can see.
-- Matches this repo's existing "read-only helpers" posture (Cody's own
-- review guidance: prefer INVOKER over DEFINER when DEFINER isn't needed).
--
-- Fixture (rolled back, real machine AMZ-1068-2401-O1/shelf D01, synthetic
-- 2099-01-01 refill_plan_output rows): a Remove naming a flavor NOT on the
-- shelf is flagged, with the shelf's real flavor(s) surfaced
-- (`shelf_actual_flavors`); a Remove naming the shelf's real flavor is
-- correctly NOT flagged.
--
-- Cody: approve, Article 16 (new diagnostic, not a re-derivation of an
-- existing registered metric), no writes.
CREATE OR REPLACE FUNCTION public.check_eg_resolvable(p_plan_date date)
RETURNS TABLE(
  refill_plan_output_id uuid,
  machine_name text,
  shelf_code text,
  planned_boonz_product_name text,
  quantity integer,
  shelf_actual_flavors text[]
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT rpo.id, rpo.machine_name, rpo.shelf_code, rpo.boonz_product_name, rpo.quantity,
    (SELECT array_agg(DISTINCT bp2.boonz_product_name ORDER BY bp2.boonz_product_name)
       FROM pod_inventory pi2
       JOIN boonz_products bp2 ON bp2.product_id = pi2.boonz_product_id
      WHERE pi2.machine_id = rpo.machine_id AND pi2.shelf_id = rpo.shelf_id
        AND pi2.status = 'Active' AND pi2.current_stock > 0) AS shelf_actual_flavors
  FROM public.refill_plan_output rpo
  WHERE rpo.plan_date = p_plan_date
    AND rpo.action = 'Remove'
    AND rpo.machine_id IS NOT NULL AND rpo.shelf_id IS NOT NULL AND rpo.boonz_product_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.pod_inventory pi
      WHERE pi.machine_id = rpo.machine_id AND pi.shelf_id = rpo.shelf_id
        AND pi.boonz_product_id = rpo.boonz_product_id
        AND pi.status = 'Active' AND pi.current_stock > 0
    );
$function$;
