-- Fix: process_weimi_staging was referencing the wrong alias column.
-- machine_name_aliases has (original_name, official_name, machine_id) — not alias_name.
-- The bug caused any WEIMI row whose Machine Name did NOT exactly match
-- machines.official_name to fall into the alias fallback and hit
-- `column a.alias_name does not exist`, then be marked failed.
--
-- Symptom: first 2026 upload reported {"failed":1353,"updated":4478,"inserted":0}.
-- 1353 rows were hyphen-format machine names (LLFP-2006/2007/2005) that should
-- have resolved via the alias table.

CREATE OR REPLACE FUNCTION public.process_weimi_staging(
  p_batch_label text DEFAULT NULL,
  p_dry_run     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $func$
DECLARE
  r            weimi_staging%ROWTYPE;
  v_processed  int := 0;
  v_inserted   int := 0;
  v_updated    int := 0;
  v_skipped    int := 0;
  v_failed     int := 0;
  v_existed    boolean;
  v_txn_sn            text;
  v_machine_name      text;
  v_machine_id        uuid;
  v_delivery_status   text;
  v_delivery_time     timestamptz;
  v_qty               numeric;
  v_total_amount      numeric;
  v_paid_amount       numeric;
  v_cost_amount       numeric;
  v_member_discount   numeric;
  v_refunded_amount   numeric;
  v_product_cost      numeric;
  v_recommended_price numeric;
  v_actual_price      numeric;
BEGIN
  FOR r IN
    SELECT * FROM weimi_staging s
    WHERE s.processed_at IS NULL
      AND s.process_error IS NULL
      AND (p_batch_label IS NULL OR s.batch_label = p_batch_label)
    ORDER BY s.staging_id
    LIMIT 10000
  LOOP
    BEGIN
      v_txn_sn       := NULLIF(trim(r."Internal transaction S/N"), '');
      v_machine_name := NULLIF(trim(r."Machine Name"), '');
      IF v_txn_sn IS NULL THEN
        UPDATE weimi_staging
        SET process_error='missing Internal transaction S/N', processed_at=now()
        WHERE staging_id=r.staging_id;
        v_skipped := v_skipped + 1; CONTINUE;
      END IF;
      -- Direct match on official_name
      SELECT machine_id INTO v_machine_id
      FROM machines WHERE official_name = v_machine_name;
      -- Fallback: machine_name_aliases.original_name -> machine_id
      IF v_machine_id IS NULL THEN
        SELECT m.machine_id INTO v_machine_id
        FROM machine_name_aliases a
        JOIN machines m ON m.machine_id = a.machine_id
        WHERE a.original_name = v_machine_name;
      END IF;
      IF v_machine_id IS NULL THEN
        UPDATE weimi_staging
        SET process_error='unknown machine: '||COALESCE(v_machine_name,'NULL'),
            processed_at=now()
        WHERE staging_id=r.staging_id;
        v_skipped := v_skipped + 1; CONTINUE;
      END IF;
      v_delivery_status := NULLIF(trim(r."Delivery status"),'');
      IF v_delivery_status NOT IN ('Successful','Failed','Partial') THEN
        v_delivery_status := 'Failed';
      END IF;
      v_delivery_time     := NULLIF(trim(r."Delivery finished time"),'')::timestamptz;
      v_qty               := NULLIF(trim(r."Qty"),'')::numeric;
      v_total_amount      := NULLIF(trim(r."Total amount"),'')::numeric;
      v_paid_amount       := NULLIF(trim(r."Paid amount"),'')::numeric;
      v_cost_amount       := NULLIF(trim(r."Cost amount"),'')::numeric;
      v_member_discount   := NULLIF(trim(r."Member discount amount"),'')::numeric;
      v_refunded_amount   := NULLIF(trim(r."Refunded amount"),'')::numeric;
      v_product_cost      := NULLIF(trim(r."Product cost"),'')::numeric;
      v_recommended_price := NULLIF(trim(r."Recommended selling price"),'')::numeric;
      v_actual_price      := NULLIF(trim(r."Actual selling price"),'')::numeric;
      SELECT EXISTS(SELECT 1 FROM sales_history WHERE internal_txn_sn = v_txn_sn)
      INTO v_existed;
      INSERT INTO sales_history (
        machine_id, internal_txn_sn, route_name, goods_slot, slot_name,
        pod_product_name, product_cost, recommended_price, actual_selling_price,
        unit, qty, total_amount, cost_amount, member_discount_amount,
        paid_amount, refunded_amount, delivered_from, delivered_from_name,
        delivery_status, delivery_failed_desc, error_code, delivery_finished_time,
        refund_status, classification_name, classification_remark,
        transaction_date
      ) VALUES (
        v_machine_id, v_txn_sn,
        NULLIF(trim(r."Route Name"),''),
        NULLIF(trim(r."Goods slot"),''),
        NULLIF(trim(r."Slot name"),''),
        NULLIF(trim(r."Product name"),''),
        v_product_cost, v_recommended_price, v_actual_price,
        NULLIF(trim(r."Unit"),''),
        v_qty, v_total_amount, v_cost_amount, v_member_discount,
        v_paid_amount, v_refunded_amount,
        NULLIF(trim(r."Delivered from"),''),
        NULLIF(trim(r."Delivered from Name"),''),
        v_delivery_status,
        NULLIF(trim(r."Delivery failed description"),''),
        NULLIF(trim(r."Error code"),''),
        v_delivery_time,
        NULLIF(trim(r."Refund status"),''),
        NULLIF(trim(r."Classification name"),''),
        NULLIF(trim(r."Classification remark"),''),
        v_delivery_time
      )
      ON CONFLICT (internal_txn_sn) DO UPDATE SET
        machine_id             = EXCLUDED.machine_id,
        route_name             = EXCLUDED.route_name,
        goods_slot             = EXCLUDED.goods_slot,
        slot_name              = EXCLUDED.slot_name,
        pod_product_name       = EXCLUDED.pod_product_name,
        product_cost           = EXCLUDED.product_cost,
        recommended_price      = EXCLUDED.recommended_price,
        actual_selling_price   = EXCLUDED.actual_selling_price,
        unit                   = EXCLUDED.unit,
        qty                    = EXCLUDED.qty,
        total_amount           = EXCLUDED.total_amount,
        cost_amount            = EXCLUDED.cost_amount,
        member_discount_amount = EXCLUDED.member_discount_amount,
        paid_amount            = EXCLUDED.paid_amount,
        refunded_amount        = EXCLUDED.refunded_amount,
        delivered_from         = EXCLUDED.delivered_from,
        delivered_from_name    = EXCLUDED.delivered_from_name,
        delivery_status        = EXCLUDED.delivery_status,
        delivery_failed_desc   = EXCLUDED.delivery_failed_desc,
        error_code             = EXCLUDED.error_code,
        delivery_finished_time = EXCLUDED.delivery_finished_time,
        refund_status          = EXCLUDED.refund_status,
        classification_name    = EXCLUDED.classification_name,
        classification_remark  = EXCLUDED.classification_remark,
        transaction_date       = EXCLUDED.transaction_date;
      IF NOT p_dry_run THEN
        UPDATE weimi_staging SET processed_at = now() WHERE staging_id = r.staging_id;
      END IF;
      v_processed := v_processed + 1;
      IF v_existed THEN v_updated := v_updated + 1;
      ELSE              v_inserted := v_inserted + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE weimi_staging
      SET process_error = SQLERRM, processed_at = now()
      WHERE staging_id = r.staging_id;
      v_failed := v_failed + 1;
    END;
  END LOOP;
  IF p_dry_run THEN
    RAISE EXCEPTION 'DRY RUN ROLLBACK' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object(
    'processed', v_processed,
    'inserted',  v_inserted,
    'updated',   v_updated,
    'skipped',   v_skipped,
    'failed',    v_failed
  );
EXCEPTION WHEN SQLSTATE 'P0001' THEN
  RETURN jsonb_build_object(
    'dry_run', true, 'processed', v_processed, 'inserted', v_inserted,
    'updated', v_updated, 'skipped', v_skipped, 'failed', v_failed
  );
END;
$func$;
