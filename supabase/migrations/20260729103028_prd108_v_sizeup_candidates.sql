-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-108 Volume-Driven Size-Up, step 3/4 (Phase 2b). Source:
-- docs/prds/PRD-108-EXECUTION-LOG.md 2.3-2.4; docs/architecture/MIGRATIONS_REGISTRY.md:709.
-- Recovered verbatim via pg_get_viewdef against live prod. The weekly DOUBLE DOWN proposal
-- surface: earns_double_down = floor AND T1 AND T2 AND T3 AND NOT is_blended;
-- dd_proposal = earns_double_down AND NOT is_dd (the CS batch-approval worklist). Proposes
-- only - rank_slot_suitability remains the sole gate and still requires is_dd (PRD-106b intact).
-- Built because rank_slot_suitability filters present products out of `gated` unless
-- is_size_up is already true, which requires is_dd - a product passing T1-T3 WITHOUT a DD flag
-- is invisible in that function's output, exactly the set this view surfaces.
-- Note: the rank-1-by-suitability newcomer benchmark (originally intended as a separate object,
-- see 20260729103303_prd108_v_sizeup_candidates_rank1_benchmark.sql) is inlined here as the
-- nc_pool/nc_pct/nc_ranked/newcomer CTEs, per the live view body - it does not exist as a
-- standalone catalog object in current prod.

CREATE OR REPLACE VIEW public.v_sizeup_candidates AS
WITH p AS (
  SELECT COALESCE(refill_policy_params.sizeup_min_vel_per_day, 1.25) AS t1,
         COALESCE(refill_policy_params.sizeup_overflow_factor, 1.25) AS t2,
         COALESCE(refill_policy_params.sizeup_vs_alternative_factor, 1.3) AS t3,
         COALESCE(refill_policy_params.sizeup_min_machine_units_wk, 30::numeric) AS floor
    FROM public.refill_policy_params
   ORDER BY refill_policy_params.id
   LIMIT 1
),
mach AS (
  SELECT m.machine_id, m.official_name, m.location_type, m.primary_warehouse_id, m.secondary_warehouse_id,
         COALESCE(msp.trip_interval_days, 21) AS trip,
         COALESCE(mv.daily_velocity_30d, 0::numeric) * 7::numeric AS machine_units_wk
    FROM public.machines m
    LEFT JOIN public.machine_service_policy msp ON msp.machine_id = m.machine_id
    LEFT JOIN public.v_machine_velocity mv ON mv.machine_id = m.machine_id
),
present AS (
  SELECT slot_lifecycle.machine_id, slot_lifecycle.pod_product_id
    FROM public.slot_lifecycle
   WHERE slot_lifecycle.archived = false AND slot_lifecycle.is_current = true AND slot_lifecycle.pod_product_id IS NOT NULL
  UNION
  SELECT v_live_shelf_stock.machine_id, v_live_shelf_stock.pod_product_id
    FROM public.v_live_shelf_stock
   WHERE v_live_shelf_stock.pod_product_id IS NOT NULL AND v_live_shelf_stock.current_stock > 0
),
dd AS (
  SELECT DISTINCT slot_lifecycle.machine_id, slot_lifecycle.pod_product_id
    FROM public.slot_lifecycle
   WHERE slot_lifecycle.archived = false AND slot_lifecycle.is_current = true AND slot_lifecycle.signal = 'DOUBLE DOWN'::text
),
cap AS (
  SELECT v_live_shelf_stock.machine_id, v_live_shelf_stock.pod_product_id,
         sum(GREATEST(v_live_shelf_stock.max_stock, 0))::numeric AS onmach_cap
    FROM public.v_live_shelf_stock
   WHERE v_live_shelf_stock.pod_product_id IS NOT NULL
     AND (v_live_shelf_stock.current_stock > 0 OR v_live_shelf_stock.max_stock > 0)
   GROUP BY v_live_shelf_stock.machine_id, v_live_shelf_stock.pod_product_id
),
lookalike AS (
  SELECT sl.pod_product_id, m2.location_type, avg(sl.velocity_30d) AS ll
    FROM public.slot_lifecycle sl
    JOIN public.machines m2 ON m2.machine_id = sl.machine_id
   WHERE sl.archived = false AND sl.is_current = true
   GROUP BY sl.pod_product_id, m2.location_type
),
fleetvel AS (
  SELECT slot_lifecycle.pod_product_id, avg(slot_lifecycle.velocity_30d) AS gv
    FROM public.slot_lifecycle
   WHERE slot_lifecycle.archived = false AND slot_lifecycle.is_current = true
   GROUP BY slot_lifecycle.pod_product_id
),
proven_cal AS (
  SELECT sh.machine_id, sh.pod_product_id, sum(sh.qty) / 90.0 AS pcal
    FROM public.v_sales_history_resolved sh
   WHERE sh.delivery_status = 'Successful'::text
     AND sh.transaction_date >= ((now() AT TIME ZONE 'Asia/Dubai'::text)::date - '90 days'::interval)
     AND sh.pod_product_id IS NOT NULL
   GROUP BY sh.machine_id, sh.pod_product_id
),
pod_boonz AS (
  SELECT DISTINCT ON (pm.pod_product_id, pm.machine_id) pm.pod_product_id, pm.machine_id, pm.boonz_product_id
    FROM public.product_mapping pm
   WHERE pm.status = 'Active'::text
),
wh AS (
  SELECT m.machine_id, pb.pod_product_id, sum(vp.warehouse_stock)::integer AS wh_units
    FROM mach m
    JOIN pod_boonz pb ON pb.machine_id IS NULL OR pb.machine_id = m.machine_id
    JOIN public.v_wh_pickable vp ON vp.boonz_product_id = pb.boonz_product_id
     AND (vp.warehouse_id = m.primary_warehouse_id OR vp.warehouse_id = m.secondary_warehouse_id)
     AND (vp.reserved_for_machine_id IS NULL OR vp.reserved_for_machine_id = m.machine_id)
   GROUP BY m.machine_id, pb.pod_product_id
  HAVING sum(vp.warehouse_stock) > 0::numeric
),
nc_pool AS (
  SELECT m.machine_id, psf.shelf_size, psf.pod_product_id,
         COALESCE(pc.pcal, 0::numeric) AS proven_cal,
         COALESCE(l.ll, 0::numeric) AS lookalike,
         GREATEST(COALESCE(pc.pcal, 0::numeric), COALESCE(l.ll, 0::numeric), COALESCE(f.gv, 0::numeric)) AS exp_vel
    FROM mach m
    JOIN public.product_size_fit psf ON psf.fits = true
    JOIN public.pod_products pp ON pp.pod_product_id = psf.pod_product_id AND COALESCE(pp.is_catchall, false) = false
    JOIN wh ON wh.machine_id = m.machine_id AND wh.pod_product_id = psf.pod_product_id
      AND wh.wh_units::numeric >= COALESCE(psf.min_refill_qty::numeric, ceil(0.7 * psf.cap_typical::numeric), 1::numeric)
    LEFT JOIN present pr ON pr.machine_id = m.machine_id AND pr.pod_product_id = psf.pod_product_id
    LEFT JOIN proven_cal pc ON pc.machine_id = m.machine_id AND pc.pod_product_id = psf.pod_product_id
    LEFT JOIN lookalike l ON l.pod_product_id = psf.pod_product_id AND l.location_type = m.location_type
    LEFT JOIN fleetvel f ON f.pod_product_id = psf.pod_product_id
   WHERE pr.machine_id IS NULL AND psf.pod_product_id <> '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid
     AND NOT (EXISTS (SELECT 1 FROM public.strategic_intents si
                        WHERE si.intent_type = 'decommission'::text
                          AND si.status = ANY (ARRAY['queued'::text, 'in_progress'::text])
                          AND si.scope_pod_product_id = psf.pod_product_id))
),
nc_pct AS (
  SELECT n.machine_id, n.shelf_size, n.pod_product_id, n.proven_cal, n.lookalike, n.exp_vel,
         percent_rank() OVER (PARTITION BY n.machine_id, n.shelf_size ORDER BY n.proven_cal) AS proven_n,
         percent_rank() OVER (PARTITION BY n.machine_id, n.shelf_size ORDER BY n.lookalike) AS lookalike_n
    FROM nc_pool n
),
nc_ranked AS (
  SELECT x.machine_id, x.shelf_size, x.pod_product_id, x.proven_cal, x.lookalike, x.exp_vel, x.proven_n, x.lookalike_n,
         row_number() OVER (PARTITION BY x.machine_id, x.shelf_size
                             ORDER BY (0.28::double precision * x.proven_n + 0.20::double precision * x.lookalike_n) DESC, x.exp_vel DESC) AS rnk
    FROM nc_pct x
),
newcomer AS (
  SELECT nc_ranked.machine_id, nc_ranked.shelf_size, nc_ranked.exp_vel AS best_exp_vel
    FROM nc_ranked
   WHERE nc_ranked.rnk = 1
),
fits AS (
  SELECT DISTINCT product_size_fit.pod_product_id, product_size_fit.shelf_size
    FROM public.product_size_fit
   WHERE product_size_fit.fits = true
),
base AS (
  SELECT pr.machine_id, ma.official_name AS machine_name, ma.trip, ma.machine_units_wk,
         pr.pod_product_id, pp.pod_product_name,
         COALESCE(ssi.dvel, pc.pcal, 0::numeric) AS vel_day,
         COALESCE(c.onmach_cap, 0::numeric) AS full_shelf_units,
         d.machine_id IS NOT NULL AS is_dd,
         pp.pod_product_name ~~* '%Mix%'::text
           OR (pp.pod_product_name = ANY (ARRAY['Soft Drinks Mix'::text, 'Coca Cola Mix'::text, 'Pepsi Mix'::text, 'Chocolate Bar'::text, 'Snack Bar'::text])) AS is_blended,
         max(n.best_exp_vel) AS newcomer_exp_vel
    FROM present pr
    JOIN mach ma ON ma.machine_id = pr.machine_id
    JOIN public.pod_products pp ON pp.pod_product_id = pr.pod_product_id
    LEFT JOIN public.v_shelf_sales_identity ssi ON ssi.machine_id = pr.machine_id AND ssi.pod_product_id = pr.pod_product_id
    LEFT JOIN proven_cal pc ON pc.machine_id = pr.machine_id AND pc.pod_product_id = pr.pod_product_id
    LEFT JOIN cap c ON c.machine_id = pr.machine_id AND c.pod_product_id = pr.pod_product_id
    LEFT JOIN dd d ON d.machine_id = pr.machine_id AND d.pod_product_id = pr.pod_product_id
    LEFT JOIN fits fz ON fz.pod_product_id = pr.pod_product_id
    LEFT JOIN newcomer n ON n.machine_id = pr.machine_id AND n.shelf_size = fz.shelf_size
   GROUP BY pr.machine_id, ma.official_name, ma.trip, ma.machine_units_wk, pr.pod_product_id, pp.pod_product_name, ssi.dvel, pc.pcal, c.onmach_cap, d.machine_id
)
SELECT b.machine_id, b.machine_name, b.pod_product_id, b.pod_product_name,
       round(b.machine_units_wk, 2) AS machine_units_wk,
       b.trip AS trip_interval_days,
       round(b.vel_day, 4) AS vel_day,
       round(b.vel_day * 7::numeric, 2) AS vel_wk,
       b.full_shelf_units,
       round(b.vel_day * b.trip::numeric, 3) AS demand_over_trip,
       round(GREATEST(0::numeric, b.vel_day - b.full_shelf_units / GREATEST(b.trip, 1)::numeric), 4) AS incremental_per_day,
       round(COALESCE(b.newcomer_exp_vel, 0::numeric), 4) AS newcomer_exp_vel,
       b.machine_units_wk > p.floor AS floor_pass,
       b.vel_day >= p.t1 AS t1_pass,
       (b.vel_day * b.trip::numeric) > (b.full_shelf_units * p.t2) AS t2_pass,
       GREATEST(0::numeric, b.vel_day - b.full_shelf_units / GREATEST(b.trip, 1)::numeric) >= (p.t3 * COALESCE(b.newcomer_exp_vel, 0::numeric)) AS t3_pass,
       b.is_dd, b.is_blended,
       b.machine_units_wk > p.floor AND b.vel_day >= p.t1 AND (b.vel_day * b.trip::numeric) > (b.full_shelf_units * p.t2)
         AND GREATEST(0::numeric, b.vel_day - b.full_shelf_units / GREATEST(b.trip, 1)::numeric) >= (p.t3 * COALESCE(b.newcomer_exp_vel, 0::numeric))
         AND NOT b.is_blended AS earns_double_down,
       b.machine_units_wk > p.floor AND b.vel_day >= p.t1 AND (b.vel_day * b.trip::numeric) > (b.full_shelf_units * p.t2)
         AND GREATEST(0::numeric, b.vel_day - b.full_shelf_units / GREATEST(b.trip, 1)::numeric) >= (p.t3 * COALESCE(b.newcomer_exp_vel, 0::numeric))
         AND NOT b.is_blended AND NOT b.is_dd AS dd_proposal
  FROM base b
  CROSS JOIN p;
