-- PRD-113b: in-machine moves on a MULTI-FLAVOUR shelf were not detected.
-- is_internal_move_dispatch paired Remove -> Add New on boonz_product_id. When the driver
-- splits a Remove by flavour ("[DRIVER-INSERT] Multi-variant split") the child rows lose the
-- parent's m2m tagging (source_kind='unknown', source_machine_id NULL) AND the destination
-- Add New often carries only one flavour of the pod. Result: the other flavours match nothing,
-- are treated as warehouse returns, and sit in "Returns awaiting your approval" — where
-- approving them would credit warehouse stock that never left the machine.
-- Live case: MPMCC-1054 (Magic Planet) 2026-08-20 DM re-layout, Popit Mix moved A06 -> A05;
-- Orange Squeeze 2 + Original Cola 3 + a 0-qty leg stranded in the queue.
-- Fix: add a POD-PRODUCT-level fallback, narrowly gated so it cannot swallow a genuine return —
-- the destination Add New must itself be an in-machine move (source_kind='m2m' pointing at this
-- same machine) with NO warehouse source. clear_internal_move_flag remains the human override.
-- Read-only STABLE function, no writes. Articles 12, 16. Cody OK.
-- Applied to prod via MCP 2026-08-21 20:46 UTC.
CREATE OR REPLACE FUNCTION public.is_internal_move_dispatch(p_dispatch_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN rd.internal_move_cleared_at IS NOT NULL THEN false
    WHEN COALESCE(rd.is_internal_move, false) THEN true
    WHEN rd.action <> 'Remove' THEN false
    WHEN COALESCE(rd.is_m2m, false) THEN false
    WHEN rd.source_kind = 'm2m' AND rd.source_machine_id = rd.machine_id THEN true
    ELSE EXISTS (
      SELECT 1
      FROM public.refill_dispatching add_leg
      WHERE add_leg.machine_id       = rd.machine_id
        AND add_leg.dispatch_date    = rd.dispatch_date
        AND add_leg.action           IN ('Add New', 'Add')
        AND add_leg.shelf_id IS DISTINCT FROM rd.shelf_id
        AND COALESCE(add_leg.cancelled, false) = false
        AND COALESCE(add_leg.skipped,   false) = false
        AND COALESCE(add_leg.include,   true)  = true
        AND (
              add_leg.boonz_product_id = rd.boonz_product_id
              OR (
                    add_leg.pod_product_id IS NOT NULL
                AND rd.pod_product_id      IS NOT NULL
                AND add_leg.pod_product_id  = rd.pod_product_id
                AND add_leg.from_warehouse_id IS NULL
                AND add_leg.source_kind = 'm2m'
                AND add_leg.source_machine_id = add_leg.machine_id
              )
            )
    )
  END
  FROM public.refill_dispatching rd
  WHERE rd.dispatch_id = p_dispatch_id
    AND rd.boonz_product_id IS NOT NULL;
$function$;
