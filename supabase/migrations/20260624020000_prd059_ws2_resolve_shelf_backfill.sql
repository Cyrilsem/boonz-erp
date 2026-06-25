-- PRD-059 WS2: RESOLVE — backfill pod_inventory.shelf_id (NULL -> resolved live shelf).
--
-- Scope: Active, current_stock>0, shelf_id IS NULL batches that the Stock Snapshot card
-- counts (via v_machine_expiry_batches) but the drawer cannot place. The resolution rule
-- (PRD-059) maps boonz_product_id -> pod_product_id via product_mapping (Active,
-- machine-specific preferred over global), confirms the pod-product is LIVE on the machine
-- via v_live_shelf_stock (is_enabled), and resolves the shelf via slot_lifecycle's single
-- current shelf for (machine_id, pod_product_id).
--
-- SAFETY (Hard Rule 6 / no-destructive):
--   * Pointer backfill ONLY: shelf_id NULL -> value. Zero change to current_stock, status,
--     expiration_date, batch_id, or any other column. No DELETE, no DROP, no stock zeroing.
--   * Idempotent: the `pi.shelf_id IS NULL` guard means re-running is a no-op.
--   * Deterministic: only batches whose pod-product resolves to EXACTLY ONE current shelf
--     are touched (count(DISTINCT shelf_id)=1). Ambiguous "Mix"/multi-shelf batches resolve
--     to NULL and are intentionally left NULL (surfaced by WS6 orphan section).
--   * Re-resolved inline at apply time (not a frozen id list) so it is correct against
--     current pod_inventory. Of 158 RESOLVE batches: 61 clean backfills (CS-approved);
--     74 collide with an already-shelved Active row (skipped by the anti-collision guard
--     below -> secondary expiry batches, surfaced by WS6 display, no relocation); 23 are
--     ambiguous "Mix"/multi-shelf (resolve to NULL -> untouched). Applied = 61 rows.
--   * Self-asserting: aborts if the touched count exceeds a sane cap (anomaly guard).
--   * Audited automatically by tg_audit_pod_inventory; app.rpc_name labels the provenance.
-- Rollback: UPDATE pod_inventory SET shelf_id=NULL WHERE pod_inventory_id = ANY(<ids logged
--   in write_audit_log for rpc_name='prd059_ws2_resolve_shelf_backfill'>). (Pointer-only;
--   restores the prior NULL state exactly.)

DO $$
DECLARE
  v_count int;
BEGIN
  -- label provenance for the audit trigger (local to this transaction)
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'prd059_ws2_resolve_shelf_backfill', true);

  WITH am AS (
    SELECT boonz_product_id, machine_id, pod_product_id, is_global_default
    FROM public.product_mapping WHERE status = 'Active'
  ),
  resolve AS (
    -- NULL-shelf, card-counted batches whose pod-product is LIVE on the machine
    SELECT b.pod_inventory_id, b.machine_id, b.boonz_product_id,
      COALESCE(
        (SELECT pod_product_id FROM am ms
           WHERE ms.boonz_product_id = b.boonz_product_id AND ms.machine_id = b.machine_id
           ORDER BY pod_product_id LIMIT 1),
        (SELECT pod_product_id FROM am g
           WHERE g.boonz_product_id = b.boonz_product_id AND g.is_global_default
           ORDER BY pod_product_id LIMIT 1)
      ) AS pod_product_id
    FROM public.v_machine_expiry_batches b
    WHERE b.shelf_id IS NULL
      AND EXISTS (
        SELECT 1 FROM public.v_live_shelf_stock vls
        WHERE vls.machine_id = b.machine_id AND vls.is_enabled
          AND vls.pod_product_id IN (
            SELECT pod_product_id FROM am ms
              WHERE ms.boonz_product_id = b.boonz_product_id AND ms.machine_id = b.machine_id
            UNION
            SELECT pod_product_id FROM am g
              WHERE g.boonz_product_id = b.boonz_product_id AND g.is_global_default
                AND NOT EXISTS (SELECT 1 FROM am ms2
                  WHERE ms2.boonz_product_id = b.boonz_product_id AND ms2.machine_id = b.machine_id)
          )
      )
  ),
  resolved AS (
    -- single unambiguous current shelf for the live pod-product (else NULL -> not touched)
    SELECT r.pod_inventory_id, r.machine_id,
      (SELECT CASE WHEN count(DISTINCT s.shelf_id) = 1 THEN (array_agg(DISTINCT s.shelf_id))[1] END
         FROM public.slot_lifecycle s
         WHERE s.machine_id = r.machine_id AND s.pod_product_id = r.pod_product_id AND s.is_current
      ) AS shelf_id
    FROM resolve r
  )
  UPDATE public.pod_inventory pi
  SET shelf_id = z.shelf_id
  FROM resolved z
  WHERE pi.pod_inventory_id = z.pod_inventory_id
    AND z.shelf_id IS NOT NULL
    AND pi.shelf_id IS NULL          -- idempotency / no-overwrite guard
    AND pi.status = 'Active'         -- belt-and-suspenders: never touch non-Active
    AND pi.current_stock > 0
    -- anti-collision: respect UNIQUE idx_pod_inv_active_shelf (machine,shelf,boonz) WHERE Active.
    -- Skip rows whose target shelf already holds an Active row for the same product
    -- (those are secondary expiry batches of an already-shelved product -> handled by WS6
    -- display, not by a 2nd Active slot row). Without this the backfill aborts on the index.
    AND NOT EXISTS (
      SELECT 1 FROM public.pod_inventory e
      WHERE e.machine_id = z.machine_id
        AND e.shelf_id = z.shelf_id
        AND e.boonz_product_id = pi.boonz_product_id
        AND e.status = 'Active'
        AND e.pod_inventory_id <> pi.pod_inventory_id
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RAISE NOTICE 'PRD-059 WS2: backfilled shelf_id on % pod_inventory rows (expected ~61).', v_count;

  IF v_count > 120 THEN
    RAISE EXCEPTION 'PRD-059 WS2 safety abort: % rows exceeds the expected ~61 ceiling', v_count;
  END IF;
END $$;
