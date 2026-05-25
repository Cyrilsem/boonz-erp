-- Phase G P3 C.6 + C.7: daily flow reconciliation view + log table + 6am cron.
-- View is SECURITY INVOKER (default). Log table is append-only with RLS
-- read-only to staff roles. Cron at 6am Dubai (02:00 UTC) writes yesterday's
-- snapshot.
-- Applied to prod 2026-05-25 via MCP. This file is the repo mirror.
--
-- Scope note (intentional Phase 3 narrowing):
-- The PRD wishlist includes wh_end_of_day reconstruction from audit log
-- cumulative. That's a substantial undertaking and not the high-value signal.
-- This Phase 3 substrate ships the movement-based reconciliation (the
-- delta-per-day-per-product) which already surfaces drift > 2u. wh_end_of_day
-- reconstruction can be a follow-up extension to the view if CS needs it.

-- 1. Append-only log table for daily snapshots.
CREATE TABLE IF NOT EXISTS public.daily_reconciliation_log (
  log_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reconciliation_date date NOT NULL,
  boonz_product_id uuid NOT NULL,
  procurement_in_po numeric NOT NULL DEFAULT 0,
  procurement_in_additions numeric NOT NULL DEFAULT 0,
  wh_in_from_returns numeric NOT NULL DEFAULT 0,
  wh_out_to_packs numeric NOT NULL DEFAULT 0,
  sales_out numeric NOT NULL DEFAULT 0,
  net_wh_flow numeric NOT NULL DEFAULT 0,
  discrepancy_flagged boolean NOT NULL DEFAULT false,
  generated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (reconciliation_date, boonz_product_id)
);

CREATE INDEX IF NOT EXISTS idx_drl_date_flagged
  ON public.daily_reconciliation_log(reconciliation_date, discrepancy_flagged);

ALTER TABLE public.daily_reconciliation_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS drl_select ON public.daily_reconciliation_log;
CREATE POLICY drl_select ON public.daily_reconciliation_log FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles up
      WHERE up.id = (SELECT auth.uid())
        AND up.role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])
    )
  );

DROP POLICY IF EXISTS drl_no_update ON public.daily_reconciliation_log;
CREATE POLICY drl_no_update ON public.daily_reconciliation_log FOR UPDATE USING (false);

DROP POLICY IF EXISTS drl_no_delete ON public.daily_reconciliation_log;
CREATE POLICY drl_no_delete ON public.daily_reconciliation_log FOR DELETE USING (false);

-- 2. Movement-aggregation view (C.6).
CREATE OR REPLACE VIEW public.v_daily_flow_reconciliation AS
WITH date_product AS (
  SELECT DISTINCT received_date AS reconciliation_date, boonz_product_id
    FROM public.purchase_orders
   WHERE received_date IS NOT NULL AND boonz_product_id IS NOT NULL
  UNION
  SELECT DISTINCT received_at::date, boonz_product_id
    FROM public.po_additions
   WHERE received_at IS NOT NULL AND status = 'received'
     AND boonz_product_id IS NOT NULL
  UNION
  SELECT DISTINCT dispatch_date, boonz_product_id
    FROM public.refill_dispatching
   WHERE dispatch_date IS NOT NULL AND boonz_product_id IS NOT NULL
  UNION
  SELECT DISTINCT transaction_date::date, boonz_product_id
    FROM public.sales_history
   WHERE transaction_date IS NOT NULL AND boonz_product_id IS NOT NULL
),
po_in AS (
  SELECT received_date AS d, boonz_product_id, SUM(received_qty)::numeric AS qty_in
    FROM public.purchase_orders
   WHERE received_date IS NOT NULL AND received_qty IS NOT NULL
   GROUP BY received_date, boonz_product_id
),
addn_in AS (
  SELECT received_at::date AS d, boonz_product_id, SUM(qty)::numeric AS qty_in
    FROM public.po_additions
   WHERE received_at IS NOT NULL AND status = 'received'
   GROUP BY received_at::date, boonz_product_id
),
returns_in AS (
  SELECT dispatch_date AS d, boonz_product_id, SUM(quantity)::numeric AS qty_in
    FROM public.refill_dispatching
   WHERE action IN ('Remove','REMOVE') AND returned = true AND dispatched = true
     AND boonz_product_id IS NOT NULL
   GROUP BY dispatch_date, boonz_product_id
),
packs_out AS (
  SELECT dispatch_date AS d, boonz_product_id, SUM(quantity)::numeric AS qty_out
    FROM public.refill_dispatching
   WHERE action IN ('Refill','Add New','Add') AND packed = true
     AND boonz_product_id IS NOT NULL
   GROUP BY dispatch_date, boonz_product_id
),
sales_out AS (
  SELECT transaction_date::date AS d, boonz_product_id, SUM(qty)::numeric AS qty_out
    FROM public.sales_history
   WHERE transaction_date IS NOT NULL AND boonz_product_id IS NOT NULL
   GROUP BY transaction_date::date, boonz_product_id
)
SELECT
  dp.reconciliation_date,
  dp.boonz_product_id,
  COALESCE(po.qty_in, 0)  AS procurement_in_po,
  COALESCE(ad.qty_in, 0)  AS procurement_in_additions,
  COALESCE(rt.qty_in, 0)  AS wh_in_from_returns,
  COALESCE(pk.qty_out, 0) AS wh_out_to_packs,
  COALESCE(sl.qty_out, 0) AS sales_out,
  (COALESCE(po.qty_in,0) + COALESCE(ad.qty_in,0) + COALESCE(rt.qty_in,0)
   - COALESCE(pk.qty_out,0)) AS net_wh_flow
FROM date_product dp
LEFT JOIN po_in      po ON po.d = dp.reconciliation_date AND po.boonz_product_id = dp.boonz_product_id
LEFT JOIN addn_in    ad ON ad.d = dp.reconciliation_date AND ad.boonz_product_id = dp.boonz_product_id
LEFT JOIN returns_in rt ON rt.d = dp.reconciliation_date AND rt.boonz_product_id = dp.boonz_product_id
LEFT JOIN packs_out  pk ON pk.d = dp.reconciliation_date AND pk.boonz_product_id = dp.boonz_product_id
LEFT JOIN sales_out  sl ON sl.d = dp.reconciliation_date AND sl.boonz_product_id = dp.boonz_product_id;

GRANT SELECT ON public.v_daily_flow_reconciliation TO authenticated;

-- 3. Cron-callable canonical writer that snapshots yesterday into the log.
CREATE OR REPLACE FUNCTION public.cron_daily_inventory_reconciliation()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_target_date date := ((CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai') - interval '1 day')::date;
  v_inserted    integer := 0;
  v_flagged     integer := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'cron_daily_inventory_reconciliation', true);

  WITH ins AS (
    INSERT INTO public.daily_reconciliation_log (
      reconciliation_date, boonz_product_id,
      procurement_in_po, procurement_in_additions,
      wh_in_from_returns, wh_out_to_packs, sales_out,
      net_wh_flow, discrepancy_flagged, generated_at
    )
    SELECT
      v.reconciliation_date, v.boonz_product_id,
      v.procurement_in_po, v.procurement_in_additions,
      v.wh_in_from_returns, v.wh_out_to_packs, v.sales_out,
      v.net_wh_flow,
      (ABS(v.net_wh_flow - v.sales_out) > 2) AS discrepancy_flagged,
      now()
    FROM public.v_daily_flow_reconciliation v
    WHERE v.reconciliation_date = v_target_date
    ON CONFLICT (reconciliation_date, boonz_product_id) DO UPDATE
      SET procurement_in_po        = EXCLUDED.procurement_in_po,
          procurement_in_additions = EXCLUDED.procurement_in_additions,
          wh_in_from_returns       = EXCLUDED.wh_in_from_returns,
          wh_out_to_packs          = EXCLUDED.wh_out_to_packs,
          sales_out                = EXCLUDED.sales_out,
          net_wh_flow              = EXCLUDED.net_wh_flow,
          discrepancy_flagged      = EXCLUDED.discrepancy_flagged,
          generated_at             = EXCLUDED.generated_at
    RETURNING discrepancy_flagged
  )
  SELECT COUNT(*), COUNT(*) FILTER (WHERE discrepancy_flagged) INTO v_inserted, v_flagged FROM ins;

  RETURN jsonb_build_object(
    'status', 'ok',
    'reconciliation_date', v_target_date,
    'rows_written', v_inserted,
    'rows_flagged', v_flagged
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cron_daily_inventory_reconciliation() TO authenticated;

-- 4. pg_cron job at 6:00 AM Dubai = 02:00 UTC daily.
SELECT cron.schedule(
  'daily_inventory_reconciliation',
  '0 2 * * *',
  $$SELECT public.cron_daily_inventory_reconciliation();$$
);
