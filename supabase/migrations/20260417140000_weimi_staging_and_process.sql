-- weimi_staging + process_weimi_staging()
-- Mirrors the adyen_staging / process_adyen_staging pattern for WEIMI sales uploads.
-- Column names match the WEIMI "Order details" xlsx tab exactly so rows can be
-- imported straight from the Supabase Table Editor (Import data from CSV).
-- Idempotent: uses sales_history.internal_txn_sn UNIQUE as ON CONFLICT target.

CREATE TABLE IF NOT EXISTS public.weimi_staging (
  staging_id     bigserial PRIMARY KEY,
  uploaded_at    timestamptz NOT NULL DEFAULT now(),
  processed_at   timestamptz,
  process_error  text,
  batch_label    text,
  "Machine ID"                    text,
  "Machine Name"                  text,
  "Route Name"                    text,
  "Goods slot"                    text,
  "Slot name"                     text,
  "Internal transaction S/N"      text,
  "Product name"                  text,
  "Product cost"                  text,
  "Recommended selling price"     text,
  "Actual selling price"          text,
  "Unit"                          text,
  "Qty"                           text,
  "Total amount"                  text,
  "Cost amount"                   text,
  "Member discount amount"        text,
  "Paid amount"                   text,
  "Refunded amount"               text,
  "Delivered from"                text,
  "Delivered from Name"           text,
  "Delivery status"               text,
  "Delivery failed description"   text,
  "Error code"                    text,
  "Delivery finished time"        text,
  "Refund status"                 text,
  "Classification name"           text,
  "Classification remark"         text
);

COMMENT ON TABLE public.weimi_staging IS
'Raw WEIMI Order-details upload target. Column names match the "Order details" xlsx tab exactly. Call process_weimi_staging() to ETL into sales_history.';

CREATE INDEX IF NOT EXISTS weimi_staging_unprocessed_idx
  ON public.weimi_staging (staging_id)
  WHERE processed_at IS NULL;

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
      SELECT machine_id INTO v_machine_id
      FROM machines WHERE official_name = v_machine_name;
      IF v_machine_id IS NULL THEN
        SELECT m.machine_id INTO v_machine_id
        FROM machine_name_aliases a
        JOIN machines m ON m.machine_id = a.machine_id
        WHERE a.alias_name = v_machine_name;
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
