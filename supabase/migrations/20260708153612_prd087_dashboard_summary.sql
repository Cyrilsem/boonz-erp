-- PRD-087 — command-center dashboard aggregate. ONE read-only call feeding
-- /app: sales KPIs (today/7d/30d + 30d daily series), refill-today progress,
-- machine health alerts, inventory posture, open procurement, hot leads,
-- pending driver requests, fleet counts. No writes.
-- NOTE: superseded same-day by v2 (fleet fix: machines.status is 'Active',
-- not 'Live') — see 20260708153943_prd087_dashboard_summary_v2_active_fix.sql.
CREATE OR REPLACE FUNCTION public.get_dashboard_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH now_dxb AS (
  SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today
),
sales AS (
  SELECT (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date AS d,
         sh.qty, sh.paid_amount, sh.cost_amount
  FROM sales_history sh
  JOIN machines m ON m.machine_id = sh.machine_id
  WHERE sh.delivery_status IN ('Success','Successful')
    AND NOT (COALESCE(sh.refunded_amount,0) > 0
             AND COALESCE(sh.refunded_amount,0) >= COALESCE(sh.paid_amount,0))
    AND COALESCE(m.venue_group,'') <> 'WH'
    AND (sh.transaction_date AT TIME ZONE 'Asia/Dubai')::date
        >= (SELECT today FROM now_dxb) - 30
),
kpi AS (
  SELECT jsonb_build_object(
    'today', (SELECT jsonb_build_object(
        'revenue', COALESCE(round(sum(paid_amount),0),0),
        'units', COALESCE(sum(qty),0), 'txns', count(*),
        'margin', COALESCE(round(sum(paid_amount - COALESCE(cost_amount,0)),0),0))
      FROM sales WHERE d = (SELECT today FROM now_dxb)),
    'd7', (SELECT jsonb_build_object(
        'revenue', COALESCE(round(sum(paid_amount),0),0),
        'units', COALESCE(sum(qty),0), 'txns', count(*),
        'margin', COALESCE(round(sum(paid_amount - COALESCE(cost_amount,0)),0),0))
      FROM sales WHERE d > (SELECT today FROM now_dxb) - 7),
    'd30', (SELECT jsonb_build_object(
        'revenue', COALESCE(round(sum(paid_amount),0),0),
        'units', COALESCE(sum(qty),0), 'txns', count(*),
        'margin', COALESCE(round(sum(paid_amount - COALESCE(cost_amount,0)),0),0))
      FROM sales WHERE d > (SELECT today FROM now_dxb) - 30),
    'daily', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'd', gs::date, 'revenue', COALESCE(s.rev,0), 'units', COALESCE(s.units,0))
        ORDER BY gs), '[]'::jsonb)
      FROM generate_series((SELECT today FROM now_dxb) - 29,
                           (SELECT today FROM now_dxb), '1 day') gs
      LEFT JOIN (
        SELECT d, round(sum(paid_amount),0) rev, sum(qty) units
        FROM sales GROUP BY d
      ) s ON s.d = gs::date)
  ) AS j
),
refill_today AS (
  SELECT jsonb_build_object(
    'machines', COALESCE(count(DISTINCT rd.machine_id),0),
    'lines', COALESCE(count(*) FILTER (WHERE rd.include AND NOT COALESCE(rd.cancelled,false)),0),
    'packed', COALESCE(count(*) FILTER (WHERE rd.packed),0),
    'dispatched', COALESCE(count(*) FILTER (WHERE rd.dispatched),0),
    'not_filled', COALESCE(count(*) FILTER (WHERE rd.pack_outcome = 'not_filled' OR rd.not_filled_reason IS NOT NULL),0),
    'skipped', COALESCE(count(*) FILTER (WHERE COALESCE(rd.skipped,false)),0)
  ) AS j
  FROM refill_dispatching rd
  WHERE rd.dispatch_date = (SELECT today FROM now_dxb)
),
health AS (
  SELECT jsonb_build_object(
    'p1_count', COALESCE(count(*) FILTER (WHERE h.priority_tier = 'P1_RESTOCK'),0),
    'p2_count', COALESCE(count(*) FILTER (WHERE h.priority_tier = 'P2_MAINTAIN'),0),
    'top_urgent', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'machine', t.machine_name, 'tier', t.priority_tier,
        'score', round(t.priority_score)))
      FROM (
        SELECT machine_name, priority_tier, priority_score
        FROM get_machine_health()
        WHERE upper(machine_name) NOT LIKE 'WH%' AND include_in_refill
        ORDER BY priority_score DESC NULLS LAST LIMIT 6
      ) t), '[]'::jsonb)
  ) AS j
  FROM get_machine_health() h
  WHERE upper(h.machine_name) NOT LIKE 'WH%' AND h.include_in_refill
),
inv AS (
  SELECT jsonb_build_object(
    'machine_units', COALESCE(sum(machine_units),0),
    'wh_units', COALESCE(sum(wh_units),0),
    'products', count(*),
    'thin_count', COALESCE(count(*) FILTER (WHERE machine_units > 0 AND wh_units < machine_units * 0.5),0),
    'thin_top', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('product', t.product_name,
        'machine_units', t.machine_units, 'wh_units', t.wh_units))
      FROM (
        SELECT product_name, machine_units, wh_units
        FROM get_stock_overview()
        WHERE machine_units > 0 AND wh_units < machine_units * 0.5
        ORDER BY machine_units DESC LIMIT 5
      ) t), '[]'::jsonb)
  ) AS j
  FROM get_stock_overview()
),
expiring AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'product', bp.boonz_product_name, 'units', t.units, 'days', t.days)
    ORDER BY t.days), '[]'::jsonb) AS j
  FROM (
    SELECT wi.boonz_product_id, sum(wi.warehouse_stock) units,
           min(wi.expiration_date) - (SELECT today FROM now_dxb) AS days
    FROM warehouse_inventory wi
    WHERE wi.status = 'Active' AND COALESCE(wi.quarantined,false) = false
      AND wi.warehouse_stock > 0
      AND COALESCE(wi.wh_location,'') <> 'VOX_SOURCED'
      AND wi.expiration_date IS NOT NULL
      AND wi.expiration_date BETWEEN (SELECT today FROM now_dxb)
          AND (SELECT today FROM now_dxb) + 14
    GROUP BY wi.boonz_product_id
    ORDER BY days LIMIT 6
  ) t
  JOIN boonz_products bp ON bp.product_id = t.boonz_product_id
),
proc AS (
  SELECT jsonb_build_object(
    'open_pos', COALESCE(count(DISTINCT po_number) FILTER (WHERE purchase_outcome IS NULL),0),
    'open_lines', COALESCE(count(*) FILTER (WHERE purchase_outcome IS NULL),0),
    'open_units', COALESCE(sum(ordered_qty) FILTER (WHERE purchase_outcome IS NULL),0),
    'open_value', COALESCE(round(sum(total_price_aed) FILTER (WHERE purchase_outcome IS NULL),0),0)
  ) AS j
  FROM purchase_orders
),
leads AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'company', t.company_name, 'stage', t.funnel_stage,
    'machines', t.estimated_machines, 'owner', t.lead_owner,
    'follow_up', t.next_follow_up_date)
    ORDER BY t.ord), '[]'::jsonb) AS j
  FROM (
    SELECT company_name, funnel_stage, estimated_machines, lead_owner,
           next_follow_up_date,
           row_number() OVER (ORDER BY
             CASE funnel_stage WHEN 'Awarded' THEN 0 WHEN 'Negotiation' THEN 1
               WHEN 'Qualification' THEN 2 ELSE 3 END,
             next_follow_up_date NULLS LAST, priority_order NULLS LAST) AS ord
    FROM sales_leads
    WHERE funnel_stage NOT IN ('Installed')
      AND COALESCE(engagement_status,'') NOT ILIKE '%lost%'
      AND COALESCE(engagement_status,'') NOT ILIKE '%dead%'
    LIMIT 6
  ) t
),
dreq AS (
  SELECT jsonb_build_object('pending',
    (SELECT count(*) FROM v_driver_addition_review_queue)) AS j
),
fleet AS (
  SELECT jsonb_build_object(
    'active_machines', (SELECT count(*) FROM machines
      WHERE status ILIKE 'live' AND COALESCE(venue_group,'') <> 'WH'),
    'products', (SELECT count(*) FROM boonz_products)
  ) AS j
)
SELECT jsonb_build_object(
  'generated_at', now(),
  'today', (SELECT today FROM now_dxb),
  'kpis', (SELECT j FROM kpi),
  'refill_today', (SELECT j FROM refill_today),
  'health', (SELECT j FROM health),
  'inventory', (SELECT j FROM inv),
  'expiring', (SELECT j FROM expiring),
  'procurement', (SELECT j FROM proc),
  'hot_leads', (SELECT j FROM leads),
  'driver_requests', (SELECT j FROM dreq),
  'fleet', (SELECT j FROM fleet)
);
$$;

COMMENT ON FUNCTION public.get_dashboard_summary() IS
'PRD-087: single-call command-center aggregate for /app dashboard. Read-only.';
