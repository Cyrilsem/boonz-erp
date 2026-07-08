-- PRD-087 housekeeping: re-create get_dashboard_ops with the exact body
-- committed to git (20260708165102 file, CTE j-pattern) so file == live.
-- Functionally identical to the previously applied inline-jsonb version.
CREATE OR REPLACE FUNCTION public.get_dashboard_ops()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH now_dxb AS (
  SELECT (now() AT TIME ZONE 'Asia/Dubai')::date AS today
),
health_src AS MATERIALIZED (
  SELECT machine_name, priority_tier, priority_score
  FROM get_machine_health()
  WHERE upper(machine_name) NOT LIKE 'WH%' AND include_in_refill
),
stock_src AS MATERIALIZED (
  SELECT product_name, machine_units, wh_units FROM get_stock_overview()
),
refill_lines AS MATERIALIZED (
  SELECT rd.include, rd.cancelled, rd.packed, rd.dispatched, rd.pack_outcome,
         rd.not_filled_reason, rd.skipped, rd.machine_id,
         m.official_name AS machine_name
  FROM refill_dispatching rd
  JOIN machines m ON m.machine_id = rd.machine_id
  WHERE rd.dispatch_date = (SELECT today FROM now_dxb)
),
exp_batches AS (
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
),
refill_today AS (
  SELECT jsonb_build_object(
    'machines', COALESCE(count(DISTINCT machine_id),0),
    'lines', COALESCE(count(*) FILTER (WHERE include AND NOT COALESCE(cancelled,false)),0),
    'packed', COALESCE(count(*) FILTER (WHERE packed),0),
    'dispatched', COALESCE(count(*) FILTER (WHERE dispatched),0),
    'not_filled', COALESCE(count(*) FILTER (WHERE pack_outcome = 'not_filled' OR not_filled_reason IS NOT NULL),0),
    'skipped', COALESCE(count(*) FILTER (WHERE COALESCE(skipped,false)),0),
    'machine_statuses', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'machine', t.machine_name, 'lines', t.lines,
        'dispatched', t.disp, 'packed', t.pk, 'not_filled', t.nf,
        'done', t.disp >= GREATEST(t.lines - t.nf - t.sk, 0) AND t.lines > 0)
        ORDER BY (t.disp >= GREATEST(t.lines - t.nf - t.sk, 0)), t.machine_name)
      FROM (
        SELECT machine_name,
               count(*) FILTER (WHERE include AND NOT COALESCE(cancelled,false)) AS lines,
               count(*) FILTER (WHERE dispatched) AS disp,
               count(*) FILTER (WHERE packed) AS pk,
               count(*) FILTER (WHERE pack_outcome = 'not_filled' OR not_filled_reason IS NOT NULL) AS nf,
               count(*) FILTER (WHERE COALESCE(skipped,false)) AS sk
        FROM refill_lines GROUP BY 1
      ) t), '[]'::jsonb)
  ) AS j
  FROM refill_lines
),
health AS (
  SELECT jsonb_build_object(
    'p1_count', COALESCE(count(*) FILTER (WHERE priority_tier = 'P1_RESTOCK'),0),
    'p2_count', COALESCE(count(*) FILTER (WHERE priority_tier = 'P2_MAINTAIN'),0),
    'top_urgent', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'machine', t.machine_name, 'tier', t.priority_tier,
        'score', round(t.priority_score)))
      FROM (
        SELECT machine_name, priority_tier, priority_score
        FROM health_src
        WHERE priority_tier IN ('P1_RESTOCK','P2_MAINTAIN')
        ORDER BY CASE priority_tier WHEN 'P1_RESTOCK' THEN 0 ELSE 1 END,
                 priority_score DESC NULLS LAST
        LIMIT 8
      ) t), '[]'::jsonb)
  ) AS j
  FROM health_src
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
        FROM stock_src
        WHERE machine_units > 0 AND wh_units < machine_units * 0.5
        ORDER BY machine_units DESC LIMIT 5
      ) t), '[]'::jsonb)
  ) AS j
  FROM stock_src
),
expiry AS (
  SELECT jsonb_build_object(
    'units_14d', COALESCE((SELECT sum(units) FROM exp_batches),0),
    'skus_14d', COALESCE((SELECT count(*) FROM exp_batches),0),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'product', bp.boonz_product_name, 'units', e.units, 'days', e.days)
        ORDER BY e.days)
      FROM (SELECT * FROM exp_batches ORDER BY days LIMIT 8) e
      JOIN boonz_products bp ON bp.product_id = e.boonz_product_id), '[]'::jsonb)
  ) AS j
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
      WHERE status = 'Active' AND COALESCE(venue_group,'') <> 'WH'),
    'products', (SELECT count(*) FROM boonz_products)
  ) AS j
)
SELECT jsonb_build_object(
  'generated_at', now(),
  'refill_today', (SELECT j FROM refill_today),
  'health', (SELECT j FROM health),
  'inventory', (SELECT j FROM inv),
  'expiry', (SELECT j FROM expiry),
  'procurement', (SELECT j FROM proc),
  'hot_leads', (SELECT j FROM leads),
  'driver_requests', (SELECT j FROM dreq),
  'fleet', (SELECT j FROM fleet)
);
$$;
