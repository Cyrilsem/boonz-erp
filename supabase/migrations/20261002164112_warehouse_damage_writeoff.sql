-- New feature: DAMAGE write-off (Simran request 2026-10-02).
-- Rollback: supabase/migrations/20261002164112_warehouse_damage_writeoff_rollback.sql
--
-- Damage is a disposal reason, not a status. A damaged unit is split off the source batch into
-- its own Inactive sibling row (same product, batch_id, expiry), never by flipping the source
-- row's own status (Article 6: warehouse_inventory.status is manager propose-then-confirm only;
-- this migration never writes .status on an existing row, only decrements its warehouse_stock,
-- same as adjust_warehouse_stock's own precedent for INSERTing a chosen status on a brand new row).
--
-- 1. warehouse_inventory_disposal_reason_check gains 'Damaged'.
-- 2. New nullable column damage_source text, check in ('supplier','handling','transit').
-- 3. New SECURITY DEFINER warehouse_damage_writeoff(p_wh_inventory_id, p_qty, p_source, p_reason,
--    p_caller, p_dry_run DEFAULT true): role-gated the same as adjust_warehouse_stock. Validates
--    0 < p_qty <= free stock on the batch, where free stock is warehouse_stock minus whatever is
--    currently pinned by an unpacked dispatch line referencing this wh_inventory_id (the same
--    "committed" definition check_dispatch_batch_overcommit already uses, so a damage report can
--    never undercut a pack that is already relying on this batch). Decrements the source batch by
--    p_qty only -- partial qty is the whole point, the source batch is never zeroed by this
--    function on purpose, though a decrement that happens to reach 0 still correctly triggers the
--    existing tg_propose_inactivate_on_zero_stock manager-confirm flow, same as any other stock
--    decrement. Inserts a sibling row: same product/batch_id/expiry, warehouse_stock = p_qty,
--    status = 'Inactive' (a brand new row, not a flip of an existing one), disposal_reason =
--    'Damaged', damage_source = p_source, provenance_reason = 'manual_adjust' (set via the
--    app.provenance_reason GUC so trg_set_wh_provenance stamps it, matching every other writer in
--    this codebase). Returns before/after free stock on both rows.
-- 4. Backfill: today's 3 real damage lines (Coke Zero x1 on two batches, Al Ain Zero x1) were
--    already decremented via adjust_warehouse_stock before this RPC existed (reason starting
--    'DAMAGE (Simran 02 Oct)', confirmed in inventory_audit_log). This migration inserts the
--    matching Inactive 'Damaged' sibling rows (damage_source 'handling') so v_damage_log and the
--    FE badge pick them up, WITHOUT touching warehouse_stock on the source rows again (that
--    decrement already happened and must not be repeated).
-- 5. v_damage_log: date, product, qty, source, supplier (best-effort match from batch_id's PO
--    prefix), value at cost (boonz_products.avg_cost). Reads only warehouse_inventory rows with
--    disposal_reason = 'Damaged'; v_waste_by_sku_90d (the existing expiry-waste KPI) reads from
--    disposition_events.state = 'waste' instead, a completely separate table this migration never
--    writes to, so damage cannot leak into expiry waste KPIs by construction.

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT warehouse_inventory_disposal_reason_check;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT warehouse_inventory_disposal_reason_check
  CHECK (
    disposal_reason IS NULL
    OR disposal_reason = 'Waste'
    OR disposal_reason = 'Returning to supplier'
    OR disposal_reason = 'Returned to supplier'
    OR disposal_reason = 'audit_zero'
    OR disposal_reason = 'Damaged'
    OR disposal_reason ~ '^ghost_purge_\d{4}-\d{2}-\d{2}$'
  );

ALTER TABLE public.warehouse_inventory ADD COLUMN IF NOT EXISTS damage_source text;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT warehouse_inventory_damage_source_check
  CHECK (damage_source IS NULL OR damage_source IN ('supplier', 'handling', 'transit'));

CREATE OR REPLACE FUNCTION public.warehouse_damage_writeoff(
  p_wh_inventory_id uuid,
  p_qty numeric,
  p_source text,
  p_reason text,
  p_caller uuid,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_caller_role text;
  v_wh public.warehouse_inventory%ROWTYPE;
  v_pinned numeric;
  v_free numeric;
  v_new_wh_id uuid;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = p_caller;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse', 'operator_admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'warehouse_damage_writeoff: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  IF p_source IS NULL OR p_source NOT IN ('supplier', 'handling', 'transit') THEN
    RAISE EXCEPTION 'warehouse_damage_writeoff: p_source must be supplier, handling, or transit (got %)', p_source;
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'warehouse_damage_writeoff: p_reason is required (>=10 chars)';
  END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'warehouse_damage_writeoff: p_qty must be > 0';
  END IF;

  SELECT * INTO v_wh FROM warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'warehouse_damage_writeoff: wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  -- Free stock = batch stock minus whatever an unpacked dispatch line already pinned on this
  -- exact batch. Same committed-quantity definition check_dispatch_batch_overcommit uses.
  SELECT COALESCE(SUM(qty), 0) INTO v_pinned FROM (
    SELECT rd.quantity AS qty
    FROM refill_dispatching rd
    WHERE rd.from_wh_inventory_id = p_wh_inventory_id
      AND (rd.driver_confirmed_breakdown IS NULL OR jsonb_array_length(rd.driver_confirmed_breakdown) = 0)
      AND COALESCE(rd.packed, false) = false AND COALESCE(rd.dispatched, false) = false
      AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.skipped, false) = false
      AND COALESCE(rd.returned, false) = false
      AND rd.dispatch_date >= (now() AT TIME ZONE 'Asia/Dubai')::date
    UNION ALL
    SELECT (e ->> 'qty')::numeric AS qty
    FROM refill_dispatching rd, jsonb_array_elements(rd.driver_confirmed_breakdown) e
    WHERE (e ->> 'wh_inventory_id')::uuid = p_wh_inventory_id
      AND rd.driver_confirmed_breakdown IS NOT NULL
      AND COALESCE(rd.packed, false) = false AND COALESCE(rd.dispatched, false) = false
      AND COALESCE(rd.cancelled, false) = false AND COALESCE(rd.skipped, false) = false
      AND COALESCE(rd.returned, false) = false
      AND rd.dispatch_date >= (now() AT TIME ZONE 'Asia/Dubai')::date
  ) pinned;

  v_free := COALESCE(v_wh.warehouse_stock, 0) - v_pinned;

  IF p_qty > v_free THEN
    RAISE EXCEPTION 'warehouse_damage_writeoff: p_qty % exceeds free stock % (batch stock %, % pinned by an unpacked dispatch line)',
      p_qty, v_free, v_wh.warehouse_stock, v_pinned;
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object(
      'dry_run', true, 'wh_inventory_id', p_wh_inventory_id,
      'batch_stock', v_wh.warehouse_stock, 'pinned', v_pinned, 'free_stock', v_free,
      'qty', p_qty, 'after_batch_stock', v_wh.warehouse_stock - p_qty);
  END IF;

  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'warehouse_damage_writeoff', true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  PERFORM set_config('app.mutation_reason',
    format('warehouse_damage_writeoff: wh=%s qty=%s source=%s reason=%s caller=%s',
      p_wh_inventory_id, p_qty, p_source, p_reason, p_caller), true);

  UPDATE warehouse_inventory
  SET warehouse_stock = warehouse_stock - p_qty
  WHERE wh_inventory_id = p_wh_inventory_id;

  INSERT INTO inventory_audit_log (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason)
  VALUES (p_wh_inventory_id, v_wh.boonz_product_id, p_caller, v_wh.warehouse_stock, v_wh.warehouse_stock - p_qty,
    format('warehouse_damage_writeoff: %s units damaged (%s): %s', p_qty, p_source, p_reason));

  v_new_wh_id := gen_random_uuid();
  INSERT INTO warehouse_inventory (
    wh_inventory_id, boonz_product_id, snapshot_date, warehouse_stock, consumer_stock,
    expiration_date, batch_id, status, warehouse_id, disposal_reason, damage_source
  ) VALUES (
    v_new_wh_id, v_wh.boonz_product_id, CURRENT_DATE, p_qty, 0,
    v_wh.expiration_date, v_wh.batch_id, 'Inactive', v_wh.warehouse_id, 'Damaged', p_source
  );

  RETURN jsonb_build_object(
    'status', 'ok', 'source_wh_inventory_id', p_wh_inventory_id,
    'before_batch_stock', v_wh.warehouse_stock, 'after_batch_stock', v_wh.warehouse_stock - p_qty,
    'damaged_wh_inventory_id', v_new_wh_id, 'qty', p_qty, 'source', p_source);
END;
$function$;

-- Backfill: the 3 real damage lines already decremented by hand before this RPC existed.
-- Disclosed direct INSERT (no canonical RPC fits an insert-only backfill without repeating the
-- already-applied decrement): sets app.via_rpc/app.rpc_name/app.provenance_reason first, same
-- discipline as every other one-off cleanup write in this codebase.
DO $$
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'warehouse_damage_writeoff_backfill_20261002', true);
  PERFORM set_config('app.provenance_reason', 'manual_adjust', true);
  PERFORM set_config('app.mutation_reason',
    'Backfill: Inactive Damaged sibling rows for the 3 damage lines already decremented by hand 2026-10-02 (Simran request), reason DAMAGE (Simran 02 Oct).', true);

  INSERT INTO warehouse_inventory (
    boonz_product_id, snapshot_date, warehouse_stock, consumer_stock,
    expiration_date, batch_id, status, warehouse_id, disposal_reason, damage_source
  )
  SELECT boonz_product_id, CURRENT_DATE, 1, 0, expiration_date, batch_id, 'Inactive', warehouse_id, 'Damaged', 'handling'
  FROM warehouse_inventory
  WHERE wh_inventory_id IN (
    '093b104f-a4a4-4e9b-bbfb-978ed8a26a27', -- Coke Zero, exp 25 Feb 27
    'f250682e-7cf4-4919-8d64-5100ae1a1206', -- Coke Zero, exp 08 Mar 27
    'af6eee21-eb2c-46d3-b4e7-164d8d009c73'  -- Al Ain Zero, exp 24 Aug 27
  );
END $$;

CREATE OR REPLACE VIEW public.v_damage_log AS
SELECT
  wi.wh_inventory_id,
  wi.created_at::date AS damage_date,
  wi.boonz_product_id,
  bp.boonz_product_name,
  wi.warehouse_stock AS qty,
  wi.damage_source AS source,
  s.supplier_name AS supplier,
  (wi.warehouse_stock * COALESCE(bp.avg_cost, 0)) AS value_aed,
  wi.batch_id,
  wi.expiration_date
FROM public.warehouse_inventory wi
JOIN public.boonz_products bp ON bp.product_id = wi.boonz_product_id
LEFT JOIN LATERAL (
  SELECT po.supplier_id
  FROM public.purchase_orders po
  WHERE wi.batch_id LIKE (po.po_id || '-%')
    AND po.boonz_product_id = wi.boonz_product_id
  LIMIT 1
) po_match ON true
LEFT JOIN public.suppliers s ON s.supplier_id = po_match.supplier_id
WHERE wi.disposal_reason = 'Damaged';
