-- PRD-110 leg 144 - D-44 EXECUTE: the picker reserves K money slots.
--
-- CS RULING (2026-08-04, "D-43..D-47 ALL CLOSED"):
--   "D-44 CLOSED: RESERVE K=2 MONEY SLOTS. Of the day capacity of 6, 2 slots always go to the
--    money rule; the remaining 4 drain the breached-cadence set. D-24's intent (highest-value
--    machine gets picked) is restored; cadence debt still clears. Executing leg: implement in
--    the picker, make fixture 42 self-supply its |breached| < capacity precondition per the
--    leg-114/115 idiom, and add the explicit |breached|-vs-capacity sensor so recurrence names
--    its cause. Do NOT loosen seq 60."
--
-- ALREADY DONE AT LEG 118, NOT REDONE HERE: fixture 42 self-supplies the |breached| < capacity
-- precondition, and the |breached|-vs-capacity sensor is live as seq 72/73/74. This migration
-- ships the remaining half - the PICKER change - plus the fixture restatements it forces.
--
-- WHY PICKER AND FIXTURE SHIP IN ONE TRANSACTION (the DR-4 / leg-132 lesson): seq 35 and seq 42
-- are the only assertions that pin the pre-D-44 ranking contract. Changing the picker alone would
-- leave golden RED between two migrations. The re-statement is the proof the fix landed (the
-- D-45 / D-46 idiom), so it lands in the same statement-set as the fix.
--
-- ⛔ NOTHING IS LOOSENED. seq 60 (the CS D-24 acceptance test) is byte-untouched and a guard below
-- refuses to apply if its check_sql / expect_op / expect ever moved. seq 35 and seq 42 are
-- RESTATED under S-103 (expect AND description together), never weakened: each keeps its original
-- claim and re-points it at the population the claim is still about.
--
-- ⚠️ THE RULING'S "6" IS NOT THE `driver_capacity` DIAL. Live `pick_urgency_params.driver_capacity`
-- is 8; the "day capacity of 6" CS wrote is the OBSERVED minutes-bound capacity read off the
-- picker's own output on 2026-08-04 (leg 118's conservative model reads 5). The ruling's operative
-- number is K=2 - "2 slots ALWAYS go to the money rule" - which is an absolute reservation, not a
-- ratio of 6. K is therefore a dial, not a fraction of capacity.

-- ⛔ NO EXPLICIT BEGIN/COMMIT. The management-API `/database/query` shim wraps the whole body in
-- ONE transaction (S-215, proven). An explicit COMMIT here would commit the picker change before
-- `/tmp/apply_mig.sh` appends its schema_migrations registration, breaking both the "nothing
-- half-applied" handoff invariant and the terminal-RAISE dry run.

-- ---------------------------------------------------------------------------------------------
-- GUARD 0: refuse to double-apply.
-- ---------------------------------------------------------------------------------------------
DO $g0$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='public' AND table_name='refill_policy_params'
                AND column_name='var_money_reserved_slots') THEN
    RAISE EXCEPTION 'D-44 ALREADY APPLIED: refill_policy_params.var_money_reserved_slots exists';
  END IF;
END $g0$;

-- ---------------------------------------------------------------------------------------------
-- GUARD 1: the picker is the body this migration was written against (S-109: md5 over prosrc,
-- NEVER pg_get_functiondef).
-- ---------------------------------------------------------------------------------------------
DO $g1$
DECLARE v_md5 text;
BEGIN
  SELECT substr(md5(prosrc),1,8) INTO v_md5
    FROM pg_proc WHERE proname='rank_machines_by_value_at_risk_v3';
  IF v_md5 IS NULL THEN
    RAISE EXCEPTION 'rank_machines_by_value_at_risk_v3 not found';
  END IF;
  IF v_md5 <> '3a6c5914' THEN
    RAISE EXCEPTION 'PICKER BODY MOVED: expected 3a6c5914, found %. Re-derive the diff before applying.', v_md5;
  END IF;
END $g1$;

-- ---------------------------------------------------------------------------------------------
-- GUARD 2: seq 60 - the CS D-24 acceptance test - must be exactly where leg 118 left it. This
-- migration is forbidden from touching it and proves so by pinning it before and after.
-- ---------------------------------------------------------------------------------------------
DO $g2$
DECLARE v_md5 text;
BEGIN
  SELECT md5(check_sql || '|' || expect_op || '|' || expect) INTO v_md5
    FROM golden.assertions WHERE fixture_id=42 AND seq=60;
  IF v_md5 IS NULL THEN
    RAISE EXCEPTION 'fixture 42 seq 60 (CS D-24 acceptance test) is MISSING';
  END IF;
  PERFORM set_config('prd110.d44_seq60_md5', v_md5, true);
END $g2$;

-- ---------------------------------------------------------------------------------------------
-- 1. THE DIAL. K=2 is the ruled value, so it ships as the DEFAULT rather than as an inert 0 -
--    D-44 is an authorised execution, not a parked flag. The dial exists so the fixture can
--    prove dial-controls-feature (the D-40 / fixture-68 idiom) and so CS can retune without a
--    migration.
-- ---------------------------------------------------------------------------------------------
ALTER TABLE public.refill_policy_params
  ADD COLUMN var_money_reserved_slots integer NOT NULL DEFAULT 2;

ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_var_money_reserved_slots_nonneg
  CHECK (var_money_reserved_slots >= 0);

COMMENT ON COLUMN public.refill_policy_params.var_money_reserved_slots IS
  'CS D-44 (2026-08-04): K slots of the driver day are reserved for the money rule so the '
  'highest-value machine is never starved by zero-value overdue machines. K=2 is the ruled '
  'value. A machine is only ever reserved when value_at_risk_aed > 0 - a slot is never held '
  'for a 0.00 AED machine. K=0 restores the pure D-24 ordering.';

-- ---------------------------------------------------------------------------------------------
-- 2. THE PICKER. Signature is byte-identical - no OUT column is added, because changing a
--    RETURNS TABLE would force a DROP (LAW 3 forbids destructive change). The two new facts
--    travel in the existing `reasoning` jsonb and in `selection_reason`.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rank_machines_by_value_at_risk_v3(p_plan_date date, p_limit integer DEFAULT NULL::integer)
RETURNS TABLE(rank integer, machine_id uuid, machine_name text, route_cluster text, value_at_risk_aed numeric, lost_units numeric, shelves_at_risk integer, shelves_total integer, no_price_basis_shelves integer, no_velocity_shelves integer, gap_days numeric, days_since_visit integer, cadence_floor_due boolean, est_refill_lines integer, visit_minutes numeric, cum_minutes numeric, selected boolean, selection_reason text, reasoning jsonb)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $picker$
WITH prm AS (
  SELECT var_driver_day_minutes, var_service_minutes_per_machine, var_pack_minutes_per_line,
         var_travel_minutes_intra_cluster, var_travel_minutes_inter_cluster,
         var_price_lookback_days, var_default_gap_days,
         var_cadence_floor_multiple, var_cadence_hard_max_days,
         var_money_reserved_slots
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
-- D-44. THE MONEY LADDER, computed on money ALONE - no cadence term - so that "the highest-value
-- machine" means exactly what CS said it means. machine_name breaks ties so the ladder is total
-- and deterministic.
moneyed AS (
  SELECT b.*,
         row_number() OVER (ORDER BY b.value_at_risk_aed DESC, b.machine_name ASC)::int AS money_rank
  FROM base b
),
-- D-44. THE RESERVATION. K slots are held for the top of the money ladder.
-- ⛔ THE `value_at_risk_aed > 0` GUARD IS LOAD-BEARING: without it, on a day when fewer than K
-- machines carry any value at all, the reservation would hold a driver slot for a 0.00 AED
-- machine and out-rank a genuinely breached one. That is the exact harm D-44 was raised to stop,
-- inverted. A reservation is only ever spent on money that actually exists.
reserved AS (
  SELECT m.*,
         (m.value_at_risk_aed > 0 AND m.money_rank <= prm.var_money_reserved_slots) AS is_money_reserved
  FROM moneyed m CROSS JOIN prm
),
ranked AS (
  SELECT r.*,
         row_number() OVER (ORDER BY r.is_money_reserved DESC,
                                     r.cadence_floor_due DESC,
                                     r.value_at_risk_aed DESC,
                                     COALESCE(r.coverage_staleness, 0) DESC,
                                     r.machine_name ASC)::int AS rnk,
         lag(r.route_cluster) OVER (ORDER BY r.is_money_reserved DESC,
                                             r.cadence_floor_due DESC,
                                             r.value_at_risk_aed DESC,
                                             COALESCE(r.coverage_staleness, 0) DESC,
                                             r.machine_name ASC) AS prev_cluster
  FROM reserved r
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
    WHEN f.sel AND f.is_money_reserved            THEN 'money_reserved'
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
    'ranking_rule',     'D-44 MONEY RESERVATION FIRST, then D-24 MONEY-AFTER-BREACH: '
                        || 'is_money_reserved DESC, cadence_floor_due (BREACHED) DESC, '
                        || 'value_at_risk_aed DESC, coverage_staleness DESC, machine_name ASC',
    'cadence',          jsonb_build_object(
                          'floor_due_breached',  f.cadence_floor_due,
                          'target_due',          f.cadence_target_due,
                          'breach_threshold_days', f.cadence_breach_days,
                          'floor_multiple',      (SELECT var_cadence_floor_multiple FROM prm),
                          'hard_max_days',       (SELECT var_cadence_hard_max_days FROM prm),
                          'rule',                'BREACHED at days_since_visit >= LEAST(gap_days * floor_multiple, hard_max_days). '
                                                 || 'target_due alone does NOT pre-empt money (CS decision D-24). '
                                                 || 'Outside the D-44 reserved slots a BREACHED machine still beats money.'),
    'money_reservation', jsonb_build_object(
                          'is_money_reserved',   f.is_money_reserved,
                          'money_rank',          f.money_rank,
                          'reserved_slots',      (SELECT var_money_reserved_slots FROM prm),
                          'rule',                'CS decision D-44: K slots of the driver day are held for the top of the '
                                                 || 'money ladder so the highest-value machine is never starved by '
                                                 || 'zero-value overdue machines. A slot is NEVER reserved for a machine '
                                                 || 'with value_at_risk_aed = 0. K=0 restores the pure D-24 ordering.'),
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
$picker$;

-- ---------------------------------------------------------------------------------------------
-- 3. FIXTURE 42 - THE TWO RESTATEMENTS D-44 FORCES. Both are S-103 restatements: the original
--    claim is kept and re-pointed, never softened, and the `description` moves with the `expect`.
-- ---------------------------------------------------------------------------------------------

-- seq 35. WAS: "M_CAD outranks M_TOP - the BREACHED floor still beats money."
-- That claim is now FALSE BY RULING for the reserved slots, and STILL TRUE everywhere else.
-- The restatement asserts the surviving half as a UNIVERSAL over the non-reserved population
-- rather than as a single-pair anecdote: no non-breached machine may outrank a breached one
-- once the reserved slots are set aside. That is strictly STRONGER than the pair it replaces.
UPDATE golden.assertions SET
  check_sql = $c35$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
    SELECT count(*)::text FROM (
      SELECT (e->>'rank')::int AS rnk,
             (e->>'cadence_floor_due')::boolean AS breached,
             (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean AS reserved
        FROM golden.scratch s, jsonb_array_elements(s.value) e
       WHERE s.fixture_id=42 AND s.key='out') z
    WHERE NOT z.reserved AND NOT z.breached
      AND EXISTS (SELECT 1 FROM (
            SELECT (e->>'rank')::int AS rnk,
                   (e->>'cadence_floor_due')::boolean AS breached,
                   (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean AS reserved
              FROM golden.scratch s, jsonb_array_elements(s.value) e
             WHERE s.fixture_id=42 AND s.key='out') y
           WHERE NOT y.reserved AND y.breached AND y.rnk > z.rnk)) END$c35$,
  description = 'CS D-24 SURVIVES D-44, RESTATED AS A UNIVERSAL: outside the K reserved money slots, '
             || 'a BREACHED machine is never outranked by a non-breached one - 0 violations. '
             || 'This assertion USED to be the single pair M_CAD < M_TOP; D-44 deliberately '
             || 'inverts that pair (M_TOP is money-reserved), so the pair was replaced by the '
             || 'general property it was standing in for, which is strictly stronger. '
             || 'S-103 restatement, NOT a loosening: the breached-beats-money contract is still '
             || 'asserted, over every machine instead of over two.'
WHERE fixture_id=42 AND seq=35;

-- seq 42. WAS: two legal selection reasons. D-44 adds a THIRD, and it is named, not unnamed -
-- which is the property seq 42 actually exists to defend.
UPDATE golden.assertions SET
  check_sql = $c42$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out' AND (e->>'selected')::boolean
      AND e->>'selection_reason' NOT IN ('money_reserved','cadence_floor','value_at_risk')) END$c42$,
  description = 'Every SELECTED row was selected by one of the THREE legal rules, never by an '
             || 'unnamed one. D-44 added money_reserved as a third NAMED rule; the assertion '
             || 'still refuses any reason outside the enumerated set, which is the property it '
             || 'exists to defend. S-103 restatement.'
WHERE fixture_id=42 AND seq=42;

-- ---------------------------------------------------------------------------------------------
-- 4. FIXTURE 42 - THE NEW D-44 PROPERTY ASSERTIONS.
--    ⛔ S-267 BINDS HERE: at least one count must be derived from the SOURCE rather than from
--    the object under test. seq 78 counts the flag; seq 80 re-derives the SAME set from
--    value_at_risk_aed by hand and demands they agree. A flag that self-reports consistently
--    but disagrees with the money ladder dies at seq 80.
-- ---------------------------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(42, 77,
 'D-44 DIAL IS AT THE RULED VALUE: var_money_reserved_slots = 2, exactly the K CS ruled on '
 || '2026-08-04. If a leg retunes K this assertion is where the change must be declared.',
 $c77$SELECT var_money_reserved_slots::text FROM public.refill_policy_params LIMIT 1$c77$,
 'eq', '2', true, 'P3'),

(42, 78,
 'D-44 RESERVES EXACTLY K SLOTS, NEVER MORE: the number of money-reserved machines equals '
 || 'LEAST(K, number of machines carrying any value at all). The second term is what stops the '
 || 'assertion demanding 2 reservations on a day when only one machine has money.',
 $c78$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
   SELECT (count(*) FILTER (WHERE (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean)
           = LEAST((SELECT var_money_reserved_slots FROM public.refill_policy_params LIMIT 1),
                   count(*) FILTER (WHERE (e->>'value_at_risk_aed')::numeric > 0)))::text
     FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out') END$c78$,
 'eq', 'true', true, 'P3'),

(42, 79,
 'D-44 NEVER HOLDS A SLOT FOR A 0.00 AED MACHINE: every money-reserved machine carries '
 || 'value_at_risk_aed > 0 - 0 violations. This is the load-bearing guard in the ruling; '
 || 'without it the reservation would inflict the exact starvation D-44 was raised to stop.',
 $c79$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
   SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'
      AND (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean
      AND (e->>'value_at_risk_aed')::numeric <= 0) END$c79$,
 'eq', '0', true, 'P3'),

(42, 80,
 'S-267 HAND-DERIVED CHECK: the reserved SET is re-computed independently off value_at_risk_aed '
 || '(top K by money, ties broken by name) and must equal the set the picker flagged - 0 '
 || 'symmetric-difference. A count assertion that reads the flag proves the flag is '
 || 'self-consistent; only this one proves it is RIGHT.',
 $c80$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
   WITH r_out AS (
     SELECT e->>'machine_id' AS mid,
            (e->>'value_at_risk_aed')::numeric AS var_aed,
            e->>'machine_name' AS mname,
            (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean AS flagged
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out'),
   derived AS (
     SELECT mid FROM r_out WHERE var_aed > 0
      ORDER BY var_aed DESC, mname ASC
      LIMIT (SELECT var_money_reserved_slots FROM public.refill_policy_params LIMIT 1))
   SELECT (
     (SELECT count(*) FROM derived WHERE mid NOT IN (SELECT mid FROM r_out WHERE flagged))
   + (SELECT count(*) FROM r_out WHERE flagged AND mid NOT IN (SELECT mid FROM derived)))::text) END$c80$,
 'eq', '0', true, 'P3'),

(42, 81,
 'D-44 RESERVED MACHINES SORT FIRST: every money-reserved machine holds a rank <= the number of '
 || 'reserved machines, i.e. the reservation is an actual seat at the front of the day and not a '
 || 'label attached to a machine the driver never reaches - 0 violations.',
 $c81$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
   WITH r_out AS (
     SELECT (e->>'rank')::int AS rnk,
            (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean AS flagged
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out')
   SELECT count(*)::text FROM r_out
    WHERE flagged AND rnk > (SELECT count(*) FROM r_out WHERE flagged)) END$c81$,
 'eq', '0', true, 'P3'),

(42, 82,
 'D-44 IS NON-VACUOUS: at least one machine is money-reserved. If this reads 0 the whole D-44 '
 || 'family above is asserting over an empty set (the S-48/S-52/S-55 mode burned four times on '
 || 'this build) and every one of those greens is worthless.',
 $c82$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
   SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'
      AND (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean) END$c82$,
 'gt', '0', true, 'P3'),

(42, 83,
 'NON-VACUITY PARTNER OF THE RESTATED seq 35: the non-reserved population contains BOTH breached '
 || 'and non-breached machines. Without this, seq 35 is satisfied by 0 = 0 the moment either '
 || 'group empties, and its universal would prove nothing.',
 $c83$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
   WITH r_out AS (
     SELECT (e->>'cadence_floor_due')::boolean AS breached,
            (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean AS reserved
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out')
   SELECT LEAST(count(*) FILTER (WHERE NOT reserved AND breached),
                count(*) FILTER (WHERE NOT reserved AND NOT breached))::text
     FROM r_out) END$c83$,
 'gt', '0', true, 'P3'),

(42, 84,
 'D-44 REASON CODE IS WIRED, NOT DECORATIVE: every SELECTED money-reserved row reports '
 || 'selection_reason = money_reserved. This is what makes the reservation legible to CS on the '
 || 'board instead of hiding inside the ranking - 0 violations.',
 $c84$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key='out') THEN 'NO_PICKER_OUTPUT' ELSE (
   SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'
      AND (e->>'selected')::boolean
      AND (e->'reasoning'->'money_reservation'->>'is_money_reserved')::boolean
      AND e->>'selection_reason' <> 'money_reserved') END$c84$,
 'eq', '0', true, 'P3');

-- ---------------------------------------------------------------------------------------------
-- GUARD 3: seq 60 must be byte-identical to what GUARD 2 pinned. The ruling says "Do NOT loosen
-- seq 60" and this is the enforcement, not the promise.
-- ---------------------------------------------------------------------------------------------
DO $g3$
DECLARE v_before text; v_after text;
BEGIN
  v_before := current_setting('prd110.d44_seq60_md5', true);
  SELECT md5(check_sql || '|' || expect_op || '|' || expect) INTO v_after
    FROM golden.assertions WHERE fixture_id=42 AND seq=60;
  IF v_before IS NULL OR v_after IS NULL OR v_before <> v_after THEN
    RAISE EXCEPTION 'seq 60 MOVED during this migration (before=%, after=%). The CS D-24 acceptance test is untouchable.', v_before, v_after;
  END IF;
END $g3$;

-- ---------------------------------------------------------------------------------------------
-- GUARD 4: the picker really did change, and it changed in the direction claimed.
-- ---------------------------------------------------------------------------------------------
DO $g4$
DECLARE v_src text;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc WHERE proname='rank_machines_by_value_at_risk_v3';
  IF v_src NOT LIKE '%is_money_reserved DESC%' THEN
    RAISE EXCEPTION 'picker did not pick up the D-44 reservation ordering';
  END IF;
  IF v_src NOT LIKE '%value_at_risk_aed > 0 AND m.money_rank <= prm.var_money_reserved_slots%' THEN
    RAISE EXCEPTION 'picker did not pick up the D-44 zero-value guard';
  END IF;
END $g4$;

-- ---------------------------------------------------------------------------------------------
-- GUARD 5: assertion count moved by exactly +8 and nothing was dropped.
-- ---------------------------------------------------------------------------------------------
DO $g5$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM golden.assertions WHERE fixture_id=42 AND enabled;
  IF n <> 84 THEN
    RAISE EXCEPTION 'fixture 42 enabled assertion count is %, expected 84 (76 + 8)', n;
  END IF;
END $g5$;
