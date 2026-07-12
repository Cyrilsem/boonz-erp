-- Migration: fix_upsert_sales_lines_setbased_and_txn_sn_pattern_idx
-- Date: 2026-07-11 | Cody-approved (Articles 1,2,4,8,12,14)
-- Problem: FE "Refresh data" -> rpc upsert_sales_lines times out at the
--   authenticated role's 8s statement_timeout.
-- Root causes:
--   1. prevent_duplicate_txn_forms BEFORE trigger runs a LIKE-prefix EXISTS
--      per incoming row with no text_pattern_ops index => seq scan of
--      sales_history (~12ms warm) x ~1,800 rows/refresh ~= 22s.
--   2. upsert_sales_lines looped row-by-row (resolve_machine_id x4 lookups
--      + INSERT + xmax probe per row).
--   3. Inline REFRESH MATERIALIZED VIEW CONCURRENTLY (~1.2s) kept: cron
--      job 4 (10-min refresher) is disabled, this is the only refresher.
-- Fix: (A) text_pattern_ops index; (B) set-based rewrite. Return contract
--   preserved (status, inserted, updated, skipped, total, upserted) plus
--   additive key 'unchanged'. No-op updates are skipped entirely.

-- A. Index for the trigger's LIKE prefix check (and base-txn deletes)
CREATE INDEX IF NOT EXISTS idx_sh_txn_sn_pattern
  ON public.sales_history (internal_txn_sn text_pattern_ops);

-- B. Set-based rewrite
CREATE OR REPLACE FUNCTION public.upsert_sales_lines(items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET "TimeZone" TO 'Asia/Dubai'
 SET search_path TO 'public'
AS $function$
DECLARE
  inserted_count  int := 0;
  updated_count   int := 0;
  eligible_count  int := 0;
  skipped_count   int := 0;
  unchanged_count int := 0;
  total_count     int := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'upsert_sales_lines', true);

  total_count := COALESCE(jsonb_array_length(items), 0);

  WITH raw AS (
    SELECT elem, ord
    FROM jsonb_array_elements(items) WITH ORDINALITY AS t(elem, ord)
  ),
  resolved AS (            -- resolve each distinct device name ONCE per batch
    SELECT machine_name, resolve_machine_id(machine_name) AS machine_id
    FROM (SELECT DISTINCT elem->>'machine_name' AS machine_name FROM raw) n
  ),
  dedup AS (               -- last occurrence wins within one batch
    SELECT DISTINCT ON (elem->>'internal_txn_sn') elem
    FROM raw
    ORDER BY elem->>'internal_txn_sn', ord DESC
  ),
  eligible AS (
    SELECT d.elem, r.machine_id
    FROM dedup d
    JOIN resolved r ON r.machine_name = d.elem->>'machine_name'
    WHERE r.machine_id IS NOT NULL
  ),
  ins AS (
    INSERT INTO sales_history (
      machine_id, internal_txn_sn, goods_slot, slot_name,
      pod_product_name, actual_selling_price, qty, total_amount,
      cost_amount, member_discount_amount, paid_amount, refunded_amount,
      delivery_status, delivery_finished_time, transaction_date,
      route_name, classification_name
    )
    SELECT
      e.machine_id,
      e.elem->>'internal_txn_sn',
      e.elem->>'goods_slot',
      e.elem->>'slot_name',
      e.elem->>'product_name',
      COALESCE((e.elem->>'actual_selling_price')::numeric, 0),
      COALESCE((e.elem->>'qty')::numeric, 1),
      COALESCE((e.elem->>'total_amount')::numeric, 0),
      COALESCE((e.elem->>'cost_amount')::numeric, 0),
      COALESCE((e.elem->>'member_discount_amount')::numeric, 0),
      COALESCE((e.elem->>'paid_amount')::numeric, 0),
      COALESCE((e.elem->>'refunded_amount')::numeric, 0),
      COALESCE(e.elem->>'delivery_status', 'Successful'),
      (e.elem->>'delivery_finished_time')::timestamptz,
      (e.elem->>'transaction_date')::timestamptz,
      e.elem->>'route_name',
      e.elem->>'classification_name'
    FROM eligible e
    ON CONFLICT (internal_txn_sn) DO UPDATE SET
      actual_selling_price   = EXCLUDED.actual_selling_price,
      qty                    = EXCLUDED.qty,
      total_amount           = EXCLUDED.total_amount,
      member_discount_amount = EXCLUDED.member_discount_amount,
      paid_amount            = EXCLUDED.paid_amount,
      delivery_status        = EXCLUDED.delivery_status,
      delivery_finished_time = EXCLUDED.delivery_finished_time
    WHERE (sales_history.actual_selling_price,
           sales_history.qty,
           sales_history.total_amount,
           sales_history.member_discount_amount,
           sales_history.paid_amount,
           sales_history.delivery_status,
           sales_history.delivery_finished_time)
          IS DISTINCT FROM
          (EXCLUDED.actual_selling_price,
           EXCLUDED.qty,
           EXCLUDED.total_amount,
           EXCLUDED.member_discount_amount,
           EXCLUDED.paid_amount,
           EXCLUDED.delivery_status,
           EXCLUDED.delivery_finished_time)
    RETURNING (xmax = 0) AS was_insert
  )
  SELECT
    (SELECT count(*) FROM eligible),
    count(*) FILTER (WHERE was_insert),
    count(*) FILTER (WHERE NOT was_insert)
  INTO eligible_count, inserted_count, updated_count
  FROM ins;

  -- unresolved machine names + in-batch duplicate collapses
  skipped_count   := total_count - eligible_count;
  -- no-op updates + rows dropped by prevent_duplicate_txn_forms
  unchanged_count := eligible_count - inserted_count - updated_count;

  -- Matview refresh kept in-path: cron job 4 (refresh_sales_aggregated
  -- every 10 min) is currently DISABLED, so this is the only refresher.
  -- Skipped when nothing changed.
  IF inserted_count + updated_count > 0 THEN
    PERFORM refresh_sales_aggregated();
  END IF;

  RETURN jsonb_build_object(
    'status',    'ok',
    'inserted',  inserted_count,
    'updated',   updated_count,
    'skipped',   skipped_count,
    'unchanged', unchanged_count,
    'total',     total_count,
    'upserted',  inserted_count + updated_count
  );
END;
$function$;