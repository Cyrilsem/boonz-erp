-- PRD-110 P1.3 · Sentinel retirement, part 1: the availability contract that makes sentinels unnecessary.
-- BUILD SPEC P1.3: "planners/stitch/pack read availability =
--   CASE sourcing WHEN 'boonz_wh' THEN real WH stock ELSE unconstrained."
-- Additive only. No consumer is rewired (engines frozen; consumption is engine_add_pod_v3, Phase 2).
-- The 40 VOXSOURCE-* sentinel rows are NOT deleted here. Deletion is parked (D-09).

------------------------------------------------------------------------------
-- 1. THE single definition of a sentinel row.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._is_sentinel_wh_row_v3(p_batch_id text, p_expiration_date date)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT COALESCE(p_batch_id LIKE 'VOXSOURCE-%'
                  AND p_expiration_date = DATE '2099-12-31', false);
$$;

COMMENT ON FUNCTION public._is_sentinel_wh_row_v3(text, date) IS
'PRD-110 P1.3. THE single definition of a VOX fake-stock sentinel row in warehouse_inventory.
The conjunction is load-bearing, not defensive style: 9 REAL PO-batch rows (202 units, WH_CENTRAL)
carry wh_location=''VOX_SOURCED'', so wh_location is NOT a sentinel discriminator and a DELETE keyed
on it would destroy real stock. Every sentinel query - this availability view, golden fixture 24, and
the parked retirement script (D-09) - must call this function and nothing else.';

------------------------------------------------------------------------------
-- 2. The availability contract, at shelf grain (the grain that plans).
------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_shelf_availability_v3
WITH (security_invoker = true) AS
WITH s AS (
  SELECT ss.shelf_id, ss.machine_id, ss.machine_name, ss.shelf_code, ss.slot_name,
         ss.pod_product_id, ss.pod_name, ss.sourcing, ss.current_stock, ss.max_stock,
         m.primary_warehouse_id, m.secondary_warehouse_id
  FROM public.v_shelf_state ss
  JOIN public.machines m ON m.machine_id = ss.machine_id
  WHERE ss.pod_product_id IS NOT NULL
), pods AS (
  SELECT DISTINCT machine_id, pod_product_id, primary_warehouse_id, secondary_warehouse_id
  FROM s
), wh AS (
  SELECT p.machine_id,
         p.pod_product_id,
         COALESCE(SUM(u.warehouse_stock) FILTER (WHERE NOT u.is_sentinel), 0)::int AS wh_units_real,
         COALESCE(SUM(u.warehouse_stock) FILTER (WHERE u.is_sentinel),     0)::int AS wh_units_sentinel
  FROM pods p
  LEFT JOIN LATERAL (
    -- DISTINCT on wh_inventory_id is the fan-out guard: one pod maps to many boonz products and a
    -- product may appear under several product_mapping scopes. Without it the same batch is summed
    -- once per mapping row. Same guard engine_add_pod v19 uses.
    SELECT DISTINCT k.wh_inventory_id,
                    k.warehouse_stock,
                    public._is_sentinel_wh_row_v3(k.batch_id, k.expiration_date) AS is_sentinel
    FROM public.product_mapping pm
    JOIN public.v_wh_pickable k
      ON k.boonz_product_id = pm.boonz_product_id
     AND k.warehouse_id = ANY (ARRAY[p.primary_warehouse_id, p.secondary_warehouse_id])
     AND (k.reserved_for_machine_id IS NULL OR k.reserved_for_machine_id = p.machine_id)
    WHERE pm.pod_product_id = p.pod_product_id
      AND pm.status = 'Active'
      AND (pm.machine_id IS NULL OR pm.machine_id = p.machine_id)
  ) u ON true
  GROUP BY 1, 2
)
SELECT
  s.shelf_id,
  s.machine_id,
  s.machine_name,
  s.shelf_code,
  s.slot_name,
  s.pod_product_id,
  s.pod_name,
  s.sourcing,
  s.current_stock,
  s.max_stock,
  -- 'mixed' (a pod holding both venue and boonz_wh edges) is treated as CONSTRAINED on purpose:
  -- the fail-safe points at constrained, never at unconstrained. Same direction as the
  -- resolve_product_sourcing_v3 unknown-edge fallback proven by fixture 5 seq 14.
  (s.sourcing IS DISTINCT FROM 'venue' AND s.sourcing IS DISTINCT FROM 'partner') AS is_constrained,
  -- THE contract. NULL = unconstrained (venue/partner supply it, Boonz WH stock is irrelevant).
  CASE WHEN s.sourcing IN ('venue', 'partner') THEN NULL::int
       ELSE w.wh_units_real END AS available_units,
  w.wh_units_real,
  w.wh_units_sentinel,
  (w.wh_units_sentinel > 0) AS sentinel_backed,
  -- Retirement impact, live. A view rather than a snapshot so the parked D-09 decision
  -- can never go stale (Article 14).
  (s.sourcing IS DISTINCT FROM 'venue' AND s.sourcing IS DISTINCT FROM 'partner'
     AND w.wh_units_sentinel > 0
     AND w.wh_units_real = 0) AS would_block_on_retirement
FROM s
JOIN wh w ON w.machine_id = s.machine_id AND w.pod_product_id = s.pod_product_id;

COMMENT ON VIEW public.v_shelf_availability_v3 IS
'PRD-110 P1.3. Canonical PLAN-TIME availability per pod-bound shelf: available_units IS NULL means
unconstrained (venue/partner-supplied), otherwise it is real Boonz WH stock with sentinel rows
excluded. This is the object that replaces the VOXSOURCE fake-stock pattern: it reports the same
answer whether or not the 40 sentinel rows exist, which is what makes their retirement safe.

Consumes the canonical v_wh_pickable (Article 16) rather than re-deriving the pickable predicate.
engine_add_pod v19 keeps its own inline copy - that is grandfathered debt recorded in
METRICS_REGISTRY, not a licence for new objects.

DELIBERATELY DISJOINT from the other availability objects; do not consolidate:
  v_wh_pickable          - batch grain, "what can be picked at all", no machine, no sourcing.
  v_dispatch_availability- batch grain, dispatch-date commitment-aware, for PACKING.
  v_dispatch_pickable    - packing truth incl. stranded stock in non-serving warehouses.
  v_shelf_availability_v3- SHELF grain, sourcing-aware, for PLANNING, commitment-blind.
A venue-sourced shelf is unconstrained here and simply absent from the dispatch views; collapsing
these loses the sourcing dimension, which is the whole point of WS-A2.

Known divergence from v19, stated rather than hidden: v_wh_pickable expires on the Dubai date and
requires warehouse_stock > 0; v19 inline uses CURRENT_DATE and no stock floor. Only a batch expiring
exactly today can differ, and zero-stock rows add zero to a SUM.';

------------------------------------------------------------------------------
-- 3. Point lookup. A thin wrapper so availability has exactly ONE definition.
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_shelf_availability_v3(p_shelf_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT to_jsonb(a) FROM public.v_shelf_availability_v3 a WHERE a.shelf_id = p_shelf_id;
$$;

COMMENT ON FUNCTION public.resolve_shelf_availability_v3(uuid) IS
'PRD-110 P1.3. Per-shelf point lookup of v_shelf_availability_v3. Deliberately a wrapper and not a
reimplementation: stitch/pack ask per line, the engine asks per machine, and both must get the same
number. SECURITY INVOKER - the caller''s RLS still applies through the view.';
