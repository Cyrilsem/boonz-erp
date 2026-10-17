-- PRD-142a Phase 1, item 3.4: product supply snapshot.
--
-- One row per pod product per Dubai day (400 days kept).
--   wh_units_central: Active, not quarantined, not expired stock in
--     WH_CENTRAL for the boonz products the pod maps to (any Active
--     product_mapping row). NULL for mixed and catch-all pods
--     (pod_products.is_catchall, plus the handover fan-out list: Chocolate
--     Bar, Soft Drinks Mix, Vitamin Well, Tannourine Water, Sun Blast Juice)
--     because mapping fan-out inflates the count (handover section 7).
--   wh_status: none when raw central units <= 5; low when weeks of cover
--     <= 2; else stocked. Computed for every pod, fan-out pods included
--     (status only).
--   deployed_units: current shelf stock from v_shelf_capacity (the live
--     shelf truth; pod_inventory keeps historical snapshot rows), shelf
--     product name normalised through product_name_conventions.
--   open_po_units: purchase_orders lines with received_date NULL and
--     purchase_outcome NULL for the mapped boonz products. Shown, never
--     treated as fuel.
--   weekly_rate: Boonz-population units per week over the last 4 complete
--     Monday weeks (fact_product_weekly). WH_CENTRAL fuels Boonz machines;
--     partner machines run on venue stock.
--   weeks_of_cover = wh_units / weekly_rate, NULL when either side is
--     unknown or the rate is 0.

CREATE TABLE public.product_supply_daily (
  pod_product_id   uuid NOT NULL,
  d                date NOT NULL,
  wh_units_central numeric,
  wh_status        text NOT NULL CHECK (wh_status IN ('stocked', 'low', 'none')),
  deployed_units   numeric,
  open_po_units    numeric,
  weekly_rate      numeric,
  weeks_of_cover   numeric,
  is_fanout        boolean NOT NULL DEFAULT false,
  PRIMARY KEY (pod_product_id, d)
);
CREATE INDEX product_supply_daily_d_idx ON public.product_supply_daily (d);
COMMENT ON TABLE public.product_supply_daily IS 'PRD-142a 3.4. Daily supply snapshot per pod product. Built by build_product_supply(). Fan-out pods carry wh_status only (wh_units_central NULL).';

ALTER TABLE public.product_supply_daily ENABLE ROW LEVEL SECURITY;
CREATE POLICY product_supply_daily_admin_select ON public.product_supply_daily
  FOR SELECT TO authenticated USING (public.is_admin((SELECT auth.uid())));
REVOKE ALL ON public.product_supply_daily FROM anon;

CREATE OR REPLACE FUNCTION public.build_product_supply(p_d date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_t0   timestamptz := clock_timestamp();
  v_d    date := COALESCE(p_d, (now() AT TIME ZONE 'Asia/Dubai')::date);
  v_wk   date := date_trunc('week', v_d)::date;
  v_wh   uuid;
  v_n    int;
BEGIN
  SELECT warehouse_id INTO v_wh FROM warehouses WHERE name = 'WH_CENTRAL';

  DELETE FROM product_supply_daily WHERE d = v_d OR d < v_d - 400;

  INSERT INTO product_supply_daily (pod_product_id, d, wh_units_central, wh_status, deployed_units,
    open_po_units, weekly_rate, weeks_of_cover, is_fanout)
  WITH pods AS (
    SELECT pod_product_id,
           (COALESCE(is_catchall, false)
            OR pod_product_name IN ('Chocolate Bar', 'Soft Drinks Mix', 'Vitamin Well', 'Tannourine Water', 'Sun Blast Juice')) AS fanout
    FROM pod_products
  ),
  bmap AS (
    SELECT DISTINCT pod_product_id, boonz_product_id FROM product_mapping WHERE status = 'Active'
  ),
  wh AS (
    SELECT bm.pod_product_id, sum(wi.warehouse_stock) AS units
    FROM bmap bm
    JOIN warehouse_inventory wi ON wi.boonz_product_id = bm.boonz_product_id
    WHERE wi.warehouse_id = v_wh AND wi.status = 'Active'
      AND NOT COALESCE(wi.quarantined, false) AND NOT COALESCE(wi.manually_quarantined, false)
      AND (wi.expiration_date IS NULL OR wi.expiration_date >= v_d)
      AND COALESCE(wi.warehouse_stock, 0) > 0
    GROUP BY 1
  ),
  po AS (
    SELECT bm.pod_product_id, sum(po.ordered_qty) AS units
    FROM bmap bm
    JOIN purchase_orders po ON po.boonz_product_id = bm.boonz_product_id
    WHERE po.received_date IS NULL AND po.purchase_outcome IS NULL
    GROUP BY 1
  ),
  dep AS (
    SELECT pp.pod_product_id, sum(c.current_stock) AS units
    FROM v_shelf_capacity c
    LEFT JOIN LATERAL (SELECT official_name FROM product_name_conventions n
                       WHERE n.original_name = c.current_product ORDER BY n.created_at DESC LIMIT 1) pnc ON true
    JOIN pod_products pp ON pp.pod_product_name = COALESCE(pnc.official_name, c.current_product)
    WHERE COALESCE(c.current_stock, 0) > 0
    GROUP BY 1
  ),
  rate AS (
    SELECT pod_product_id, sum(units) / 4.0 AS r
    FROM fact_product_weekly
    WHERE population = 'boonz' AND week_start >= v_wk - 28 AND week_start < v_wk
    GROUP BY 1
  )
  SELECT p.pod_product_id, v_d,
         CASE WHEN p.fanout THEN NULL ELSE COALESCE(wh.units, 0) END,
         CASE WHEN COALESCE(wh.units, 0) <= 5 THEN 'none'
              WHEN rate.r > 0 AND wh.units / rate.r <= 2 THEN 'low'
              ELSE 'stocked' END,
         COALESCE(dep.units, 0),
         COALESCE(po.units, 0),
         round(rate.r, 2),
         CASE WHEN NOT p.fanout AND rate.r > 0 THEN round(COALESCE(wh.units, 0) / rate.r, 2) END,
         p.fanout
  FROM pods p
  LEFT JOIN wh USING (pod_product_id)
  LEFT JOIN po USING (pod_product_id)
  LEFT JOIN dep USING (pod_product_id)
  LEFT JOIN rate USING (pod_product_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('d', v_d, 'pods', v_n,
    'seconds', round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 2));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.build_product_supply(date) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.build_product_supply(date) TO service_role;
