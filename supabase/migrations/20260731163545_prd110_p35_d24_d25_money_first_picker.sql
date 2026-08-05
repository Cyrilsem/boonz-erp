-- PRD-110 P3.5 / CS DECISIONS D-24 + D-25 (CLOSED 2026-07-31 ~18:05 Dubai)
--
-- D-24 MONEY FIRST. Before this change the picker sorted `cadence_floor_due DESC` first, where
-- cadence_floor_due meant "days_since_visit >= gap_days" - merely reaching the service TARGET.
-- On live data that put nine machines ahead of everything else, SEVEN of them carrying 0.00 AED,
-- and left VOXMCC-1005-0201-B0 at 543.50 AED unselected at rank 10. CS's ruling: rank primarily
-- by AED value at risk; cadence demotes to a CONSTRAINT that forces inclusion only when the
-- max-days-between-visits floor is actually BREACHED.
--
-- ARTICLE 12 / RETURNS TABLE NOTE: adding an OUT column would force DROP + CREATE, which is
-- forbidden. So the EXISTING `cadence_floor_due` column is REDEFINED to mean BREACHED (which is
-- what the name says - a *floor* being *due*), and the soft state moves into the reasoning blob
-- as `reasoning.cadence.target_due`. The RETURNS TABLE signature and the DEFAULT on p_limit
-- (pronargdefaults = 1) are byte-identical, so this is a true CREATE OR REPLACE.
--
-- D-25 COVERAGE TIEBREAK. Blind machines - the ones whose AED reads 0.00 because the picker
-- cannot SEE their shelves rather than because nothing is at risk - surface via a tiebreak on
-- coverage staleness (blind_shelves / shelves_total * days_since_visit). It is a TIEBREAK ONLY:
-- it sorts, it never enters value_at_risk_aed. The AED figure stays purely realized revenue, so
-- fixture 42 seq 27 (the independent-recomputation spine) is preserved untouched. NO SYNTHETIC
-- IMPUTATION.
--
-- STABLE + SECURITY INVOKER unchanged: Postgres itself still enforces "writes nothing" (LAW 4),
-- and Gate 0 stays manual (LAW 11) - this object is advisory, CS selects.

CREATE OR REPLACE FUNCTION public.rank_machines_by_value_at_risk_v3(p_plan_date date, p_limit integer DEFAULT NULL::integer)
 RETURNS TABLE(rank integer, machine_id uuid, machine_name text, route_cluster text, value_at_risk_aed numeric, lost_units numeric, shelves_at_risk integer, shelves_total integer, no_price_basis_shelves integer, no_velocity_shelves integer, gap_days numeric, days_since_visit integer, cadence_floor_due boolean, est_refill_lines integer, visit_minutes numeric, cum_minutes numeric, selected boolean, selection_reason text, reasoning jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
WITH prm AS (
  SELECT var_driver_day_minutes, var_service_minutes_per_machine, var_pack_minutes_per_line,
         var_travel_minutes_intra_cluster, var_travel_minutes_inter_cluster,
         var_price_lookback_days, var_default_gap_days,
         var_cadence_floor_multiple, var_cadence_hard_max_days
  FROM public.refill_policy_params LIMIT 1
),
cap AS (
  SELECT driver_capacity FROM public.pick_urgency_params LIMIT 1
),
-- Machine universe + route cluster from v_machine_priority (it owns r_cluster and the
-- include_in_refill/status scope). THE VISIT CLOCK comes from v_machine_health_signals, the
-- canonical object METRICS_REGISTRY line 49 registers for it (Cody, Article 16, leg 58).
mach AS (
  SELECT p.machine_id, p.official_name AS machine_name, p.r_cluster AS route_cluster,
         h.days_since_visit,
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
  JOIN public.v_machine_health_signals h ON h.machine_id = p.machine_id
  LEFT JOIN public.v_machine_base_stock_policy_v3 b ON b.machine_id = p.machine_id
  LEFT JOIN public.machine_service_policy       msp ON msp.machine_id = p.machine_id
  LEFT JOIN LATERAL public.resolve_demand_multiplier_v3(p.machine_id, p_plan_date) dm ON true
  WHERE p.include_in_refill AND p.machine_status = 'Active'
),
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
         -- D-25: a shelf the picker cannot convert into money, for EITHER reason. This is the
         -- numerator of coverage staleness. It never touches var_aed.
         count(*) FILTER (WHERE velocity_basis = 'none'
                             OR price_basis    = 'none')::int                     AS blind_shelves,
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
         COALESCE(a.blind_shelves, 0)          AS blind_shelves,
         COALESCE(a.at_risk_unpriceable, 0)    AS at_risk_unpriceable,
         COALESCE(a.partner_excluded, 0)       AS partner_excluded,
         COALESCE(a.est_refill_lines, 0)       AS est_refill_lines,
         pm.mix                                AS price_mix,
         -- D-24. THE HARD FLOOR: breached, i.e. this machine has now gone longer without a visit
         -- than policy tolerates. This is what the OUT column cadence_floor_due now reports and
         -- the only cadence state that pre-empts money.
         round(LEAST(m.gap_days * prm.var_cadence_floor_multiple,
                     prm.var_cadence_hard_max_days::numeric), 4) AS cadence_breach_days,
         (m.days_since_visit >= LEAST(m.gap_days * prm.var_cadence_floor_multiple,
                                      prm.var_cadence_hard_max_days::numeric))
                                               AS cadence_floor_due,
         -- The SOFT state: merely at the service target. Reported for transparency, it sorts
         -- nothing. Before D-24 this was what cadence_floor_due meant.
         (m.days_since_visit >= m.gap_days)     AS cadence_target_due,
         -- D-25. TIEBREAK ONLY. Never added to, never imputed into, value_at_risk_aed.
         round(COALESCE(a.blind_shelves, 0)::numeric
               / NULLIF(COALESCE(a.shelves_total, 0), 0)
               * m.days_since_visit, 4)         AS coverage_staleness
  FROM mach m
  CROSS JOIN prm
  LEFT JOIN agg a        ON a.machine_id  = m.machine_id
  LEFT JOIN price_mix pm ON pm.machine_id = m.machine_id
),
ranked AS (
  SELECT b.*,
         row_number() OVER (ORDER BY b.cadence_floor_due DESC,
                                     b.value_at_risk_aed DESC,
                                     COALESCE(b.coverage_staleness, 0) DESC,
                                     b.machine_name ASC)::int AS rnk,
         lag(b.route_cluster) OVER (ORDER BY b.cadence_floor_due DESC,
                                             b.value_at_risk_aed DESC,
                                             COALESCE(b.coverage_staleness, 0) DESC,
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
    'visit_clock_source','v_machine_health_signals.days_since_visit (canonical, METRICS_REGISTRY line 49)',
    'price_source',     'realized paid_amount/qty from sales_history (NEVER product_mapping), lookback '
                        || (SELECT var_price_lookback_days FROM prm)::text || 'd',
    'price_basis_mix',  COALESCE(f.price_mix, '{}'::jsonb),
    'ranking_rule',     'D-24 MONEY FIRST: cadence_floor_due (BREACHED) DESC, value_at_risk_aed DESC, '
                        || 'coverage_staleness DESC, machine_name ASC',
    'cadence',          jsonb_build_object(
                          'floor_due_breached',  f.cadence_floor_due,
                          'target_due',          f.cadence_target_due,
                          'breach_threshold_days', f.cadence_breach_days,
                          'floor_multiple',      (SELECT var_cadence_floor_multiple FROM prm),
                          'hard_max_days',       (SELECT var_cadence_hard_max_days FROM prm),
                          'rule',                'BREACHED at days_since_visit >= LEAST(gap_days * floor_multiple, hard_max_days). '
                                                 || 'target_due alone does NOT pre-empt money (CS decision D-24).'),
    'coverage_gaps',    jsonb_build_object(
                          'no_price_basis_shelves',  f.no_price_basis_shelves,
                          'no_velocity_shelves',     f.no_velocity_shelves,
                          'at_risk_but_unpriceable', f.at_risk_unpriceable,
                          'partner_shelves_excluded',f.partner_excluded,
                          'blind_shelves',           f.blind_shelves,
                          'coverage_staleness',      COALESCE(f.coverage_staleness, 0),
                          'staleness_role',          'D-25 TIEBREAK ONLY. Surfaces blind machines in the ranking; '
                                                     || 'NEVER imputed into value_at_risk_aed, which stays purely realized revenue.'),
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
$function$;

COMMENT ON FUNCTION public.rank_machines_by_value_at_risk_v3(date, integer) IS
  'PRD-110 P3.5. Advisory value-at-risk ranking of the active in-refill fleet. CS decision D-24 '
  '(2026-07-31) MONEY FIRST: primary sort is AED value at risk; visit cadence is a CONSTRAINT that '
  'forces inclusion only when the floor is BREACHED (days_since_visit >= LEAST(gap_days * '
  'var_cadence_floor_multiple, var_cadence_hard_max_days)). The OUT column cadence_floor_due '
  'reports the BREACH; the soft service target lives in reasoning.cadence.target_due. CS decision '
  'D-25: coverage_staleness is a TIEBREAK ONLY so blind machines surface - no synthetic imputation, '
  'value_at_risk_aed stays purely realized revenue. STABLE + SECURITY INVOKER: writes nothing. '
  'Gate 0 stays manual (LAW 11).';
