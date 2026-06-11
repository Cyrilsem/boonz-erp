-- RD-05 — Expiry-aware product pick at edit time (FEFO chooser). Dara → Cody ✅. APPLY NOTHING (CS review).
--
-- SCOPE NOTE: PRD-UNIFY is NOT applied to prod (no pod_refill_plan.decision / compute_refill_decision).
-- Per the build rule, the WRITER extension (edit_/add_pod_refill_row + p_preferred_wh_inventory_id) is
-- HELD (documented at the bottom, not executed) so it does not collide with PRD-UNIFY's pending change
-- to the same writers. The pin COLUMN + the read RPC ship now (they don't touch the writers).
--
-- DISCOVERY NOTE: the PRD referenced `v_effective_expiry` — that view/function does NOT exist live;
-- FEFO uses warehouse_inventory.expiration_date directly. warehouse_inventory.quarantined exists and is
-- excluded; source warehouses = machines.primary_warehouse_id + secondary_warehouse_id.
--
-- CODY verdict (RD-05): ✅ Approve.
--   The read RPC is class-(c) read-only → SECURITY INVOKER, no GUCs (correct). The pin column is additive
--   with ON DELETE SET NULL. The pin WRITE goes through the existing canonical writers (Article 1) via a
--   verbatim diff-gated one-param extension (HELD here). Stitch honoring the pin is engine territory.
--   No Article 6 concern (reads WH, never writes warehouse_inventory.status). Articles 4, 8, 12.

-- 1) the pin column (NULL = let stitch FEFO decide)
ALTER TABLE public.pod_refill_plan
  ADD COLUMN IF NOT EXISTS preferred_wh_inventory_id uuid
  REFERENCES public.warehouse_inventory(wh_inventory_id) ON DELETE SET NULL;
COMMENT ON COLUMN public.pod_refill_plan.preferred_wh_inventory_id IS
  'RD-05: operator-pinned WH batch (by expiry) for this row; stitch prefers it over default FEFO; NULL = FEFO.';

-- 2) get_shelf_fefo_options — read-only FEFO chooser for a product across the machine's source WH(s).
CREATE OR REPLACE FUNCTION public.get_shelf_fefo_options(
  p_machine_id uuid,
  p_boonz_product_id uuid
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $function$
  WITH src AS (
    SELECT ARRAY_REMOVE(ARRAY[m.primary_warehouse_id, m.secondary_warehouse_id], NULL) AS wh_ids
    FROM public.machines m WHERE m.machine_id = p_machine_id
  ),
  batches AS (
    SELECT wi.wh_inventory_id, wi.warehouse_id, wi.expiration_date,
           wi.warehouse_stock::int AS warehouse_stock,
           (wi.expiration_date - CURRENT_DATE) AS days_to_expiry,
           ROW_NUMBER() OVER (ORDER BY wi.expiration_date ASC NULLS LAST, wi.wh_inventory_id) AS fefo_rank
    FROM public.warehouse_inventory wi, src
    WHERE wi.boonz_product_id = p_boonz_product_id
      AND wi.warehouse_id = ANY (src.wh_ids)
      AND wi.status = 'Active'
      AND wi.quarantined = false
      AND COALESCE(wi.warehouse_stock,0) > 0                              -- feedback_wh_stock_column
      AND (wi.expiration_date IS NULL OR wi.expiration_date >= CURRENT_DATE)  -- E5: never offer an expired batch
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'wh_inventory_id', b.wh_inventory_id,
           'warehouse_id',    b.warehouse_id,
           'expiration_date', b.expiration_date,
           'warehouse_stock', b.warehouse_stock,
           'days_to_expiry',  b.days_to_expiry,
           'is_default',      (b.fefo_rank = 1)        -- E1: nearest-expiry flagged FEFO default
         ) ORDER BY b.fefo_rank), '[]'::jsonb)          -- E3: empty array -> FE shows "raise PO" (RD-02)
  FROM batches b;
$function$;

GRANT EXECUTE ON FUNCTION public.get_shelf_fefo_options(uuid,uuid) TO anon, authenticated, service_role;

-- ============================================================================================
-- HELD (NOT executed) — writer extension. Apply ONLY AFTER PRD-UNIFY is applied (it also extends
-- these writers). Diff-gated: the ONLY change vs the live edit_/add_pod_refill_row is one new param.
--
--   edit_pod_refill_row(p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action, p_new_qty,
--                       p_reason, p_conductor_session,
--                       p_preferred_wh_inventory_id uuid DEFAULT NULL)   -- RD-05 added param
--   add_pod_refill_row (p_plan_date, p_machine_id, p_shelf_id, p_pod_product_id, p_action, p_qty,
--                       p_reason, p_conductor_session,
--                       p_preferred_wh_inventory_id uuid DEFAULT NULL)   -- RD-05 added param
--
--   In each writer's UPSERT into pod_refill_plan add:  preferred_wh_inventory_id = p_preferred_wh_inventory_id
--   Guard (E5): if p_preferred_wh_inventory_id IS NOT NULL, verify the batch exists, is Active,
--     non-quarantined, belongs to the machine's source WH(s), and expiration_date >= plan_date — else RAISE
--     'cannot pin an expired/foreign batch'. The pin is a PREFERENCE: stitch falls back to FEFO + records a
--     deviation if depleted (E4), never hard-fails (engine/refill-brain territory, not a new write path).
--   Guard (E7): on a product change the UPSERT path already rewrites the row; the pin is set from the new
--     param (NULL clears the stale pin to the old product's batch).
-- ============================================================================================
