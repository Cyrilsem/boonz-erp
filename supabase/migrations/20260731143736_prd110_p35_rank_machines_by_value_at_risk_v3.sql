-- PRD-110 P3.5 · rank_machines_by_value_at_risk_v3 — rank machines by the MONEY lost if they
-- are not visited today, with a service-policy cadence floor above the ranking and a
-- driver-day capacity model below it.
--
-- BUILD-SPEC line 93: "Value-at-risk picker v3: rank = SUM expected lost revenue until next
-- feasible visit; day capacity model (driver-hours, cluster travel, pack time);
-- service-policy cadence floor. Gate 0 UX unchanged (CS selects)."
--
-- ⛔ WHAT THIS OBJECT IS NOT. It is NOT a replacement for pick_machines_for_refill and it does
-- not write machines_to_visit. Gate 0 stays manual in wave 1 (LAW 11, CS decision #1): this is
-- ADVISORY ONLY - it ranks and explains, CS still selects. Declared LANGUAGE sql STABLE
-- SECURITY INVOKER so Postgres itself refuses to let it write anything (fixture 42 seq 51),
-- and fixture 42 seq 48 pins machines_to_visit unchanged across a call.
--
-- WHY IT EXISTS. The live picker ranks on v_machine_priority.urgency, a shelf-state composite
-- (empty / low-fill / runout / capacity / expiry / stale / holes) with NO revenue term at all.
-- Two machines one day from a stockout rank identically whether the shelf about to empty
-- earns 40 AED a day or 0.40. This object adds the missing dimension and nothing else.
--
-- THE MODEL, term by term. Every input is read from its canonical object; none are re-derived.
--   mu_base(shelf)  v_shelf_instock_velocity_split_v3.velocity_instock_shelf  (canonical P2.1)
--                   -> fallback v_shelf_state.velocity_raw -> 0, and WHICH tier is reported.
--   factor(machine) resolve_demand_multiplier_v3(machine, plan_date).factor   (canonical P2.4)
--   gap(machine)    v_machine_base_stock_policy_v3.visit_interval_days (canonical P2.2)
--                   -> machine_service_policy.trip_interval_days_v3 -> trip_interval_days
--                   -> refill_policy_params.var_default_gap_days. Floored at 1 day.
--   stock, capacity v_shelf_state (canonical shelf truth, Art 16)
--   days_since_visit v_machine_priority (PRD-074 SSOT - the executed-dispatch clock)
--   route cluster   v_machine_priority.r_cluster
--   price(shelf)    realized paid_amount/qty over var_price_lookback_days at machine x pod
--                   -> the same realized ratio fleet-wide for the pod
--                   -> pod_products.recommended_selling_price -> NONE (counted, never 0-scored)
--
--   lost_units(shelf) = GREATEST(0, mu_base * factor * gap - current_stock)
--   VAR(machine)      = SUM(lost_units * price) over shelves, sourcing IS DISTINCT FROM 'partner'
--
-- ⛔ LAW 6 COMPLIANCE, STATED EXPLICITLY. Price is read from sales_history joined through
-- v_sales_history_resolved on transaction_id. It is NEVER read through product_mapping - that
-- join fans out (253 raw rows for 7 distinct SKUs on one pod, S-67) and would multiply revenue.
-- This function touches product_mapping nowhere at all.
--
-- ⚠️ PARTNER-SOURCED SHELVES ARE EXCLUDED from VAR and the excluded count is reported. A
-- partner-managed shelf is not restocked by a Boonz visit, so its lost revenue is not a reason
-- to spend a driver-hour. Consistent with P2.5's "sourcing != partner" rule. Currently VACUOUS
-- (0 partner-sourced shelves live - the live values are boonz_wh / venue / mixed / NULL), and
-- the fixture says so rather than implying the branch was proven.
--
-- ⚠️ THE CAPACITY DEFAULTS ARE MODELLED, NOT MEASURED. trip_events is empty, so nothing in the
-- schema observes real driver minutes. See the var_* column comments and S-69.
--
-- THE DAY IS A PREFIX, NOT A KNAPSACK. Machines are taken in rank order until the day runs out
-- of minutes or machines. cum_minutes is monotone in rank, so "selected" is always a contiguous
-- prefix - a route a driver could actually drive, not a cherry-picked set. A cadence-due machine
-- that does not fit is reported as cadence_due_over_capacity, never dropped in silence (LAW 5).

CREATE OR REPLACE FUNCTION public.rank_machines_by_value_at_risk_v3(
  p_plan_date date,
  p_limit     integer DEFAULT NULL
)
RETURNS TABLE (
  rank                    integer,
  machine_id              uuid,
  machine_name            text,
  route_cluster           text,
  value_at_risk_aed       numeric,
  lost_units              numeric,
  shelves_at_risk         integer,
  shelves_total           integer,
  no_price_basis_shelves  integer,
  no_velocity_shelves     integer,
  gap_days                numeric,
  days_since_visit        integer,
  cadence_floor_due       boolean,
  est_refill_lines        integer,
  visit_minutes           numeric,
  cum_minutes             numeric,
  selected                boolean,
  selection_reason        text,
  reasoning               jsonb
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
WITH prm AS (
  SELECT var_driver_day_minutes, var_service_minutes_per_machine, var_pack_minutes_per_line,
         var_travel_minutes_intra_cluster, var_travel_minutes_inter_cluster,
         var_price_lookback_days, var_default_gap_days
  FROM public.refill_policy_params LIMIT 1
),
cap AS (
  SELECT driver_capacity FROM public.pick_urgency_params LIMIT 1
),
-- the machine universe: active, in-refill, straight from the PRD-074 SSOT view
mach AS (
  SELECT p.machine_id, p.official_name AS machine_name, p.r_cluster AS route_cluster,
         p.days_since_visit,
         GREATEST(1::numeric, COALESCE(b.visit_interval_days,
                                       msp.trip_interval_days_v3::numeric,
                                       msp.trip_interval_days::numeric,
                                       prm.var_default_gap_days)) AS gap_days,
         CASE WHEN b.visit_interval_days       IS NOT NULL THEN 'base_stock_policy_v3'
              WHEN msp.trip_interval_days_v3   IS NOT NULL THEN 'service_policy_v3'
              WHEN msp.trip_interval_days      IS NOT NULL THEN 'service_policy_v1'
              ELSE 'param_default' END                     AS gap_source,
         COALESCE(dm.factor, 1.0)                          AS demand_factor,
         dm.provenance                                     AS demand_provenance
  FROM public.v_machine_priority p
  CROSS JOIN prm
  LEFT JOIN public.v_machine_base_stock_policy_v3 b ON b.machine_id = p.machine_id
  LEFT JOIN public.machine_service_policy       msp ON msp.machine_id = p.machine_id
  LEFT JOIN LATERAL public.resolve_demand_multiplier_v3(p.machine_id, p_plan_date) dm ON true
  WHERE p.include_in_refill AND p.machine_status = 'Active'
),
-- realized unit price at machine x pod. sales_history, NEVER product_mapping (LAW 6).
px_mp AS (
  SELECT v.machine_id, v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  CROSS JOIN prm
  WHERE v.transaction_date >= CURRENT_DATE - prm.var_price_lookback_days
  GROUP BY 1, 2
  HAVING sum(sh.qty) > 0
),
px_fleet AS (
  SELECT v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  CROSS JOIN prm
  WHERE v.transaction_date >= CURRENT_DATE - prm.var_price_lookback_days
  GROUP BY 1
  HAVING sum(sh.qty) > 0
),
-- canonical P2.1 in-stock velocity. RISK 88 / S-26: this object costs ~20 s and machine-scoping
-- does NOT reduce it, so it is read exactly ONCE per call and joined.
vel AS (
  SELECT shelf_id, velocity_instock_shelf FROM public.v_shelf_instock_velocity_split_v3
),
shelf AS (
  SELECT s.machine_id, s.shelf_id, s.sourcing,
         COALESCE(s.current_stock, 0) AS stock,
         COALESCE(vel.velocity_instock_shelf, s.velocity_raw, 0)::numeric AS mu_base,
         CASE WHEN vel.velocity_instock_shelf IS NOT NULL THEN 'instock_split'
              WHEN s.velocity_raw              IS NOT NULL THEN 'raw_shelf'
              ELSE 'none' END AS velocity_basis,
         COALESCE(px_mp.unit_price, px_fleet.unit_price,
                  NULLIF(pp.recommended_selling_price, 0)) AS unit_price,
         CASE WHEN px_mp.unit_price               IS NOT NULL THEN 'realized_machine_pod'
              WHEN px_fleet.unit_price            IS NOT NULL THEN 'realized_fleet_pod'
              WHEN pp.recommended_selling_price   > 0         THEN 'recommended_price'
              ELSE 'none' END AS price_basis,
         GREATEST(0::numeric,
                  COALESCE(vel.velocity_instock_shelf, s.velocity_raw, 0)::numeric
                  * m.demand_factor * m.gap_days
                  - COALESCE(s.current_stock, 0)) AS lost_units,
         (COALESCE(s.current_stock, 0) < COALESCE(s.max_stock, 0))::int AS is_refill_line
  FROM public.v_shelf_state s
  JOIN mach m ON m.machine_id = s.machine_id
  LEFT JOIN vel      ON vel.shelf_id = s.shelf_id
  LEFT JOIN px_mp    ON px_mp.machine_id = s.machine_id AND px_mp.pod_product_id = s.pod_product_id
  LEFT JOIN px_fleet ON px_fleet.pod_product_id = s.pod_product_id
  LEFT JOIN public.pod_products pp ON pp.pod_product_id = s.pod_product_id
),
agg AS (
  SELECT machine_id,
         round(sum(CASE WHEN sourcing IS DISTINCT FROM 'partner'
                        THEN lost_units * COALESCE(unit_price, 0) ELSE 0 END), 2) AS var_aed,
         round(sum(CASE WHEN sourcing IS DISTINCT FROM 'partner'
                        THEN lost_units ELSE 0 END), 4)                           AS lost_units,
         count(*) FILTER (WHERE lost_units > 0
                            AND sourcing IS DISTINCT FROM 'partner')::int         AS shelves_at_risk,
         count(*)::int                                                            AS shelves_total,
         count(*) FILTER (WHERE price_basis    = 'none')::int                     AS no_price_basis_shelves,
         count(*) FILTER (WHERE velocity_basis = 'none')::int                     AS no_velocity_shelves,
         -- LAW 5 sensor: revenue we can neither price nor ignore. Never silently zero.
         count(*) FILTER (WHERE lost_units > 0 AND price_basis = 'none')::int      AS at_risk_unpriceable,
         count(*) FILTER (WHERE sourcing = 'partner')::int                        AS partner_excluded,
         COALESCE(sum(is_refill_line), 0)::int                                    AS est_refill_lines
  FROM shelf
  GROUP BY machine_id
),
price_mix AS (
  SELECT machine_id, jsonb_object_agg(price_basis, n) AS mix
  FROM (SELECT machine_id, price_basis, count(*) AS n FROM shelf GROUP BY 1, 2) z
  GROUP BY machine_id
),
base AS (
  SELECT m.machine_id, m.machine_name, m.route_cluster, m.days_since_visit,
         m.gap_days, m.gap_source, m.demand_factor, m.demand_provenance,
         COALESCE(a.var_aed, 0)                AS value_at_risk_aed,
         COALESCE(a.lost_units, 0)             AS lost_units,
         COALESCE(a.shelves_at_risk, 0)        AS shelves_at_risk,
         COALESCE(a.shelves_total, 0)          AS shelves_total,
         COALESCE(a.no_price_basis_shelves, 0) AS no_price_basis_shelves,
         COALESCE(a.no_velocity_shelves, 0)    AS no_velocity_shelves,
         COALESCE(a.at_risk_unpriceable, 0)    AS at_risk_unpriceable,
         COALESCE(a.partner_excluded, 0)       AS partner_excluded,
         COALESCE(a.est_refill_lines, 0)       AS est_refill_lines,
         pm.mix                                AS price_mix,
         (m.days_since_visit >= m.gap_days)    AS cadence_floor_due
  FROM mach m
  LEFT JOIN agg a        ON a.machine_id  = m.machine_id
  LEFT JOIN price_mix pm ON pm.machine_id = m.machine_id
),
ranked AS (
  SELECT b.*,
         row_number() OVER (ORDER BY b.cadence_floor_due DESC,
                                     b.value_at_risk_aed DESC,
                                     b.machine_name ASC)::int AS rnk,
         lag(b.route_cluster) OVER (ORDER BY b.cadence_floor_due DESC,
                                             b.value_at_risk_aed DESC,
                                             b.machine_name ASC) AS prev_cluster
  FROM base b
),
costed AS (
  SELECT r.*,
         CASE WHEN r.rnk = 1 OR r.prev_cluster IS DISTINCT FROM r.route_cluster
              THEN prm.var_travel_minutes_inter_cluster
              ELSE prm.var_travel_minutes_intra_cluster END AS travel_minutes,
         prm.var_service_minutes_per_machine
           + prm.var_pack_minutes_per_line * r.est_refill_lines
           + CASE WHEN r.rnk = 1 OR r.prev_cluster IS DISTINCT FROM r.route_cluster
                  THEN prm.var_travel_minutes_inter_cluster
                  ELSE prm.var_travel_minutes_intra_cluster END AS visit_minutes
  FROM ranked r CROSS JOIN prm
),
walked AS (
  SELECT c.*,
         sum(c.visit_minutes) OVER (ORDER BY c.rnk
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_minutes
  FROM costed c
),
final AS (
  SELECT w.*,
         (w.cum_minutes <= prm.var_driver_day_minutes AND w.rnk <= cap.driver_capacity) AS sel
  FROM walked w CROSS JOIN prm CROSS JOIN cap
)
SELECT
  f.rnk,
  f.machine_id,
  f.machine_name,
  f.route_cluster,
  f.value_at_risk_aed,
  f.lost_units,
  f.shelves_at_risk,
  f.shelves_total,
  f.no_price_basis_shelves,
  f.no_velocity_shelves,
  f.gap_days,
  f.days_since_visit,
  f.cadence_floor_due,
  f.est_refill_lines,
  round(f.visit_minutes, 2),
  round(f.cum_minutes, 2),
  f.sel,
  CASE
    WHEN f.sel AND f.cadence_floor_due            THEN 'cadence_floor'
    WHEN f.sel                                    THEN 'value_at_risk'
    WHEN f.cadence_floor_due                      THEN 'cadence_due_over_capacity'
    WHEN f.value_at_risk_aed = 0                  THEN 'no_value_at_risk'
    ELSE                                               'below_day_capacity'
  END,
  jsonb_build_object(
    'model',            'lost_revenue = SUM over shelves of GREATEST(0, mu*factor*gap - stock) * realized_unit_price',
    'plan_date',        p_plan_date,
    'gap_days',         f.gap_days,
    'gap_source',       f.gap_source,
    'demand_factor',    f.demand_factor,
    'demand_provenance',f.demand_provenance,
    'velocity_source',  'v_shelf_instock_velocity_split_v3.velocity_instock_shelf, fallback v_shelf_state.velocity_raw',
    'price_source',     'realized paid_amount/qty from sales_history (NEVER product_mapping), lookback '
                        || (SELECT var_price_lookback_days FROM prm)::text || 'd',
    'price_basis_mix',  COALESCE(f.price_mix, '{}'::jsonb),
    'coverage_gaps',    jsonb_build_object(
                          'no_price_basis_shelves',  f.no_price_basis_shelves,
                          'no_velocity_shelves',     f.no_velocity_shelves,
                          'at_risk_but_unpriceable', f.at_risk_unpriceable,
                          'partner_shelves_excluded',f.partner_excluded),
    'day_capacity',     jsonb_build_object(
                          'travel_minutes',      f.travel_minutes,
                          'service_minutes',     (SELECT var_service_minutes_per_machine FROM prm),
                          'pack_minutes',        round((SELECT var_pack_minutes_per_line FROM prm) * f.est_refill_lines, 2),
                          'est_refill_lines',    f.est_refill_lines,
                          'day_budget_minutes',  (SELECT var_driver_day_minutes FROM prm),
                          'machine_cap',         (SELECT driver_capacity FROM cap),
                          'cost_basis',          'MODELLED, not measured - trip_events is empty (S-69)'),
    'advisory_only',    'Gate 0 stays manual (LAW 11). This object writes nothing; CS selects.'
  )
FROM final f
ORDER BY f.rnk
LIMIT p_limit;
$fn$;

COMMENT ON FUNCTION public.rank_machines_by_value_at_risk_v3(date, integer) IS
'PRD-110 P3.5. ADVISORY value-at-risk machine picker: ranks every active in-refill machine by the expected revenue lost if it is NOT visited on p_plan_date and before its next feasible visit, forces service-policy cadence-due machines above that ranking, and marks the contiguous prefix that fits a modelled driver day (minutes + machine cap). READ-ONLY: STABLE / SECURITY INVOKER, writes nothing, and does NOT touch machines_to_visit - Gate 0 remains manual per LAW 11. Reads mu from v_shelf_instock_velocity_split_v3, the demand factor from resolve_demand_multiplier_v3, cadence from v_machine_base_stock_policy_v3, days_since_visit and route cluster from v_machine_priority, stock/capacity from v_shelf_state; price from realized sales_history revenue, never through product_mapping. Unpriceable and unmeasurable shelves are COUNTED per machine, never scored zero. Proven by golden fixture 42.';
