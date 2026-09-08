-- ============================================================================
-- MIGRATION: prd117_reconcile_delivered_consumer_stock
-- DATE:      2026-08-21
-- INCIDENT:  Recurring "we refilled it but inventory still shows it" reports.
--            Root cause: pack moves units warehouse_stock -> consumer_stock on
--            the pinned batch row; the ONLY drain is receive_dispatch_line,
--            which the driver flow rarely triggers (last 7 days: ~590 delivered
--            lines, drain ran on 56). consumer_stock accumulates as ghost
--            inventory. One-off cleanup done manually 2026-08-21 (31 rows,
--            ~100 units); this migration closes the leak going forward.
-- DESIGN (Dara): additive columns on refill_dispatching as the idempotency
--            marker + a sweep RPC + nightly pg_cron. In-transit stock is
--            protected: per batch row, the drainable amount excludes the sum
--            of filled quantities on lines still on a truck.
-- CONSTITUTION (Cody): Art 1 (single writer for this concern), Art 4 (context
--            + role check, engine pattern: enforced only for authenticated
--            callers so pg_cron may run it), Art 6 (never touches
--            warehouse_inventory.status), Art 7/8 (audit insert-only, generic
--            trigger fires via app.via_rpc), Art 11 (cron calls the RPC),
--            Art 12 (forward-only), Art 14 (no parallel tables).
-- ============================================================================

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS consumer_reconciled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS consumer_reconciled_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_rd_consumer_unreconciled
  ON public.refill_dispatching (from_wh_inventory_id)
  WHERE item_added = true AND consumer_reconciled = false;

CREATE OR REPLACE FUNCTION public.reconcile_delivered_consumer_stock(p_dry_run boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_row record;
  v_line record;
  v_reserved numeric;
  v_drainable numeric;
  v_take numeric;
  v_lines_marked int := 0;
  v_lines_drained int := 0;
  v_units_drained numeric := 0;
  v_rows_touched int := 0;
  v_unattributable int := 0;
  v_already_received int := 0;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','reconcile_delivered_consumer_stock',true);
  PERFORM set_config('app.mutation_reason',
    'Nightly reconcile: drain consumer_stock for delivered dispatch lines whose per-line receive never ran',true);

  IF v_uid IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'reconcile_delivered_consumer_stock: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  -- (a) lines whose per-line receive DID run: it already drained. Mark only.
  IF NOT p_dry_run THEN
    UPDATE public.refill_dispatching
       SET consumer_reconciled = true, consumer_reconciled_at = now()
     WHERE item_added = true AND consumer_reconciled = false
       AND driver_confirmed_at IS NOT NULL;
    GET DIAGNOSTICS v_already_received = ROW_COUNT;
  ELSE
    SELECT count(*) INTO v_already_received FROM public.refill_dispatching
     WHERE item_added = true AND consumer_reconciled = false AND driver_confirmed_at IS NOT NULL;
  END IF;

  -- (b) unattributable lines (no pinned row): nothing to drain deterministically. Mark only.
  IF NOT p_dry_run THEN
    UPDATE public.refill_dispatching
       SET consumer_reconciled = true, consumer_reconciled_at = now()
     WHERE item_added = true AND consumer_reconciled = false
       AND driver_confirmed_at IS NULL
       AND (from_wh_inventory_id IS NULL
            OR COALESCE(is_m2m,false)
            OR action NOT IN ('Refill','Add New','Add')
            OR COALESCE(filled_quantity,0) <= 0);
    GET DIAGNOSTICS v_unattributable = ROW_COUNT;
  ELSE
    SELECT count(*) INTO v_unattributable FROM public.refill_dispatching
     WHERE item_added = true AND consumer_reconciled = false
       AND driver_confirmed_at IS NULL
       AND (from_wh_inventory_id IS NULL OR COALESCE(is_m2m,false)
            OR action NOT IN ('Refill','Add New','Add') OR COALESCE(filled_quantity,0) <= 0);
  END IF;

  -- (c) the real work: per pinned batch row, drain up to (consumer - in_transit_reserved)
  FOR v_row IN
    SELECT wi.wh_inventory_id, wi.boonz_product_id, wi.consumer_stock
      FROM public.warehouse_inventory wi
     WHERE wi.wh_inventory_id IN (
             SELECT DISTINCT rd.from_wh_inventory_id
               FROM public.refill_dispatching rd
              WHERE rd.item_added = true AND rd.consumer_reconciled = false
                AND rd.driver_confirmed_at IS NULL
                AND rd.from_wh_inventory_id IS NOT NULL
                AND NOT COALESCE(rd.is_m2m,false)
                AND rd.action IN ('Refill','Add New','Add')
                AND COALESCE(rd.filled_quantity,0) > 0)
     FOR UPDATE OF wi
  LOOP
    SELECT COALESCE(SUM(rd.filled_quantity),0) INTO v_reserved
      FROM public.refill_dispatching rd
     WHERE rd.from_wh_inventory_id = v_row.wh_inventory_id
       AND rd.picked_up = true AND rd.item_added = false
       AND NOT COALESCE(rd.returned,false) AND NOT COALESCE(rd.cancelled,false);

    v_drainable := GREATEST(COALESCE(v_row.consumer_stock,0) - v_reserved, 0);

    FOR v_line IN
      SELECT rd.dispatch_id, rd.filled_quantity
        FROM public.refill_dispatching rd
       WHERE rd.from_wh_inventory_id = v_row.wh_inventory_id
         AND rd.item_added = true AND rd.consumer_reconciled = false
         AND rd.driver_confirmed_at IS NULL
         AND NOT COALESCE(rd.is_m2m,false)
         AND rd.action IN ('Refill','Add New','Add')
         AND COALESCE(rd.filled_quantity,0) > 0
       ORDER BY rd.dispatch_date, rd.created_at
    LOOP
      v_take := LEAST(v_line.filled_quantity, v_drainable);
      IF NOT p_dry_run THEN
        IF v_take > 0 THEN
          UPDATE public.warehouse_inventory
             SET consumer_stock = GREATEST(COALESCE(consumer_stock,0) - v_take, 0)
           WHERE wh_inventory_id = v_row.wh_inventory_id;
          INSERT INTO public.inventory_audit_log
            (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty,
             reason, audited_at, provenance_reason, source_event_id)
          VALUES
            (gen_random_uuid(), v_row.wh_inventory_id, v_row.boonz_product_id, v_uid,
             v_row.consumer_stock, v_row.consumer_stock - v_take,
             format('reconcile: delivered dispatch %s drained %s [consumer_stock]', v_line.dispatch_id, v_take),
             now(), 'consumer_reconcile', v_line.dispatch_id);
          v_row.consumer_stock := v_row.consumer_stock - v_take;
        END IF;
        UPDATE public.refill_dispatching
           SET consumer_reconciled = true, consumer_reconciled_at = now()
         WHERE dispatch_id = v_line.dispatch_id;
      END IF;
      v_drainable := v_drainable - v_take;
      v_lines_marked := v_lines_marked + 1;
      IF v_take > 0 THEN
        v_lines_drained := v_lines_drained + 1;
        v_units_drained := v_units_drained + v_take;
      END IF;
    END LOOP;
    v_rows_touched := v_rows_touched + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status','ok','dry_run',p_dry_run,
    'lines_marked_already_received', v_already_received,
    'lines_marked_unattributable', v_unattributable,
    'lines_processed', v_lines_marked,
    'lines_drained', v_lines_drained,
    'units_drained', v_units_drained,
    'wh_rows_touched', v_rows_touched);
END;
$function$;

COMMENT ON FUNCTION public.reconcile_delivered_consumer_stock(boolean) IS
'PRD-117 (2026-08-21). Sweeps delivered dispatch lines (item_added) whose per-line receive never ran and drains their filled quantity from consumer_stock on the pinned warehouse_inventory row. In-transit stock protected via per-row reserved sum. Idempotent via refill_dispatching.consumer_reconciled. Nightly pg_cron; manual runs allowed for warehouse/admin roles. Cody-reviewed.';

-- Article 11: cron calls the RPC. 22:30 UTC = 02:30 Dubai, before morning counts.
SELECT cron.schedule(
  'reconcile_consumer_stock_nightly',
  '30 22 * * *',
  $$ SELECT public.reconcile_delivered_consumer_stock(false); $$
);