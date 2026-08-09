-- PRD-113 A4 — the Refresh Data FIFO decrement never consumes EXPIRED pod stock.
--
-- The "Refresh Data" button on /refill (Stock Snapshot) calls edge function refresh-stage1,
-- whose "FIFO decrement... N processed" step calls run_pod_inventory_decrement(), which is a
-- thin wrapper over THIS function. That is the whole call graph:
--
--     refresh-stage1  ->  run_pod_inventory_decrement()  ->  auto_decrement_pod_inventory()
--
-- Verified 2026-08-10: no pg_cron job and no other RPC, edge function or FE call site
-- invokes either name. There is exactly ONE implementation of the decrement, so the PRD's
-- "cron parity — one shared implementation, not two copies" is satisfied by construction
-- and this single edit is the complete fix. refresh-stage1 needs no redeploy.
--
-- WHAT CHANGES
--   The batch-selection predicate gains one clause: a batch whose expiration_date is before
--   the current Dubai date is NOT eligible to absorb a sale. Ordering among the eligible
--   batches is unchanged (expiration_date ASC NULLS LAST, snapshot_date ASC), so genuine
--   FEFO behaviour on non-expired stock is byte-identical.
--
-- WHY
--   Expired units were being recorded as sold and vanishing from the system while physically
--   still sitting in the machine. That violates the standing CS iron rule, also carried as
--   v3 LAW 7 and golden fixture 20: EXPIRED STOCK NEVER EXITS BY ASSUMPTION — only by an
--   explicit manual write-off. Expired batches now stay visible at their true quantity until
--   a human writes them off. That flow is untouched.
--
-- OVERFLOW IS NOT SILENT (LAW 5)
--   If a sale cannot be fully absorbed by the non-expired batches AND expired stock was
--   sitting right there, the shortfall is recorded in monitoring_alerts rather than quietly
--   swallowed. The sale is still marked pod_inv_decremented — exactly as it already was when
--   total stock fell short — so nothing is reprocessed on the next run and the alert cannot
--   repeat forever.
--
-- ADDITIVE ONLY: CREATE OR REPLACE, same signature, same RETURNS TABLE shape.

CREATE OR REPLACE FUNCTION public.auto_decrement_pod_inventory()
 RETURNS TABLE(machine text, sales_processed integer, batches_decremented integer, batches_depleted integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  sale RECORD;
  batch RECORD;
  remaining_to_decrement numeric;
  current_machine text := '';
  machine_sales int := 0;
  machine_batches int := 0;
  machine_depleted int := 0;
  -- PRD-113
  v_today_dubai date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_expired_available numeric;
  v_overflow jsonb := '[]'::jsonb;
  v_overflow_n int := 0;
  v_overflow_units numeric := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'auto_decrement_pod_inventory', true);

  FOR sale IN
    SELECT sh.internal_txn_sn, sh.machine_id, m.official_name as machine_name,
           sh.pod_product_name, sh.qty, sh.goods_slot, sh.transaction_date
    FROM sales_history sh
    JOIN machines m ON m.machine_id = sh.machine_id
    WHERE sh.pod_inv_decremented = false
      AND sh.delivery_status IN ('Success', 'Successful')
      AND sh.pod_product_name IS NOT NULL
    ORDER BY sh.transaction_date ASC
    LIMIT 10000
  LOOP
    remaining_to_decrement := COALESCE(sale.qty, 1);

    IF sale.machine_name != current_machine THEN
      IF current_machine != '' THEN
        machine := current_machine;
        sales_processed := machine_sales;
        batches_decremented := machine_batches;
        batches_depleted := machine_depleted;
        RETURN NEXT;
      END IF;
      current_machine := sale.machine_name;
      machine_sales := 0;
      machine_batches := 0;
      machine_depleted := 0;
    END IF;

    FOR batch IN
      SELECT pi.pod_inventory_id, pi.current_stock
      FROM pod_inventory pi
      JOIN boonz_products bp ON bp.product_id = pi.boonz_product_id
      JOIN product_mapping pm ON pm.boonz_product_id = bp.product_id
        AND pm.machine_id = sale.machine_id
      JOIN pod_products pp ON pp.pod_product_id = pm.pod_product_id
      WHERE pi.machine_id = sale.machine_id
        AND pi.status = 'Active'
        AND pi.current_stock > 0
        AND lower(trim(pp.pod_product_name)) = lower(trim(sale.pod_product_name))
        -- PRD-113 IRON RULE: expired stock never exits by assumption. A batch that is
        -- already past its expiration_date in Dubai cannot absorb a sale; it stays visible
        -- at its true quantity until a human writes it off. NULL expiry is not expired.
        AND (pi.expiration_date IS NULL OR pi.expiration_date >= v_today_dubai)
      ORDER BY pi.expiration_date ASC NULLS LAST, pi.snapshot_date ASC
    LOOP
      EXIT WHEN remaining_to_decrement <= 0;

      IF batch.current_stock >= remaining_to_decrement THEN
        -- Branch 1: partial or exact drain
        INSERT INTO pod_inventory_audit_log
          (pod_inventory_id, machine_id, boonz_product_id, source, operation, old_stock, new_stock, delta, reference_id)
        SELECT pi.pod_inventory_id, pi.machine_id, pi.boonz_product_id, 'sale', 'update',
               pi.current_stock, pi.current_stock - remaining_to_decrement, -remaining_to_decrement, sale.internal_txn_sn
        FROM pod_inventory pi WHERE pi.pod_inventory_id = batch.pod_inventory_id;

        UPDATE pod_inventory
        SET current_stock = current_stock - remaining_to_decrement,
            estimated_remaining = current_stock - remaining_to_decrement,
            snapshot_at = NOW(),
            -- Layer-1 archive-on-zero: if this sale brings stock to 0, flip Inactive
            status = CASE
              WHEN current_stock - remaining_to_decrement <= 0 THEN 'Inactive'
              ELSE status
            END,
            removal_reason = CASE
              WHEN current_stock - remaining_to_decrement <= 0
                THEN format('sold_through_%s', CURRENT_DATE)
              ELSE removal_reason
            END
        WHERE pod_inventory_id = batch.pod_inventory_id;

        machine_batches := machine_batches + 1;
        IF batch.current_stock - remaining_to_decrement <= 0 THEN
          machine_depleted := machine_depleted + 1;
        END IF;
        remaining_to_decrement := 0;
      ELSE
        -- Branch 2: this batch can't satisfy the remaining qty — drain it fully
        INSERT INTO pod_inventory_audit_log
          (pod_inventory_id, machine_id, boonz_product_id, source, operation, old_stock, new_stock, delta, reference_id)
        SELECT pi.pod_inventory_id, pi.machine_id, pi.boonz_product_id, 'sale', 'update',
               pi.current_stock, 0, -pi.current_stock, sale.internal_txn_sn
        FROM pod_inventory pi WHERE pi.pod_inventory_id = batch.pod_inventory_id;

        remaining_to_decrement := remaining_to_decrement - batch.current_stock;
        UPDATE pod_inventory
        SET current_stock = 0,
            estimated_remaining = 0,
            snapshot_at = NOW(),
            -- Layer-1 archive-on-zero: full drain → always Inactive
            status = 'Inactive',
            removal_reason = format('sold_through_%s', CURRENT_DATE)
        WHERE pod_inventory_id = batch.pod_inventory_id;
        machine_batches := machine_batches + 1;
        machine_depleted := machine_depleted + 1;
      END IF;
    END LOOP;

    -- PRD-113 overflow accounting. Only speak up when the shortfall is attributable to the
    -- new rule: there IS expired stock of this product in this machine that the old code
    -- would have eaten. A shortfall with no expired stock behind it is the pre-existing
    -- "no batch to decrement" condition and its behaviour is unchanged.
    IF remaining_to_decrement > 0 THEN
      SELECT COALESCE(SUM(pi.current_stock), 0) INTO v_expired_available
      FROM pod_inventory pi
      JOIN boonz_products bp ON bp.product_id = pi.boonz_product_id
      JOIN product_mapping pm ON pm.boonz_product_id = bp.product_id
        AND pm.machine_id = sale.machine_id
      JOIN pod_products pp ON pp.pod_product_id = pm.pod_product_id
      WHERE pi.machine_id = sale.machine_id
        AND pi.status = 'Active'
        AND pi.current_stock > 0
        AND lower(trim(pp.pod_product_name)) = lower(trim(sale.pod_product_name))
        AND pi.expiration_date IS NOT NULL
        AND pi.expiration_date < v_today_dubai;

      IF v_expired_available > 0 THEN
        v_overflow_n     := v_overflow_n + 1;
        v_overflow_units := v_overflow_units + remaining_to_decrement;
        -- Cap the detail payload; the counters above stay exact either way.
        IF v_overflow_n <= 200 THEN
          v_overflow := v_overflow || jsonb_build_object(
            'machine',             sale.machine_name,
            'pod_product_name',    sale.pod_product_name,
            'internal_txn_sn',     sale.internal_txn_sn,
            'transaction_date',    sale.transaction_date,
            'units_unabsorbed',    remaining_to_decrement,
            'expired_units_left',  v_expired_available);
        END IF;
      END IF;
    END IF;

    UPDATE sales_history SET pod_inv_decremented = true
    WHERE internal_txn_sn = sale.internal_txn_sn;
    machine_sales := machine_sales + 1;
  END LOOP;

  IF current_machine != '' THEN
    machine := current_machine;
    sales_processed := machine_sales;
    batches_decremented := machine_batches;
    batches_depleted := machine_depleted;
    RETURN NEXT;
  END IF;

  IF v_overflow_n > 0 THEN
    INSERT INTO public.monitoring_alerts (source, severity, payload)
    VALUES ('prd113_fifo_expired_overflow',
            CASE WHEN v_overflow_units >= 20 THEN 'warning' ELSE 'info' END,
            jsonb_build_object(
              'ran_at',            now(),
              'dubai_date',        v_today_dubai,
              'sales_with_overflow', v_overflow_n,
              'units_unabsorbed',  v_overflow_units,
              'detail_capped_at',  200,
              'detail',            v_overflow,
              'message',           'FIFO decrement could not fully absorb these sales from '
                                || 'NON-EXPIRED pod batches. Expired batches were left '
                                || 'untouched by design (PRD-113 / LAW 7): expired stock '
                                || 'exits only by explicit manual write-off. Reconcile by '
                                || 'writing off the expired batch or correcting its expiry.'));
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.auto_decrement_pod_inventory() IS
  'FIFO sales decrement over pod_inventory, invoked by run_pod_inventory_decrement() from '
  'the refresh-stage1 edge function ("Refresh Data" on /refill). PRD-113: batches expired as '
  'of the current Dubai date are NOT eligible — expired stock never exits by assumption, '
  'only by explicit manual write-off. Shortfalls attributable to that rule are reported to '
  'monitoring_alerts under prd113_fifo_expired_overflow.';
