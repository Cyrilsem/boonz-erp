-- PRD-110 P3.5 · golden fixture 42 — the value-at-risk picker ranks machines by the money
-- lost if they are NOT visited today, forces the service-policy cadence floor above that
-- ranking, fits the day inside a driver-minute + machine-count capacity model, and reports
-- every shelf it could not price or could not measure instead of scoring it zero.
-- LAW 1: applied and run RED before rank_machines_by_value_at_risk_v3 exists.
-- plan_date anchor = DATE '2030-01-01' + 42 = 2030-02-12 (free; 2030-02-11 is fixture 41's).
--
-- BUILD-SPEC line 93 (P3.5): "Value-at-risk picker v3: rank = SUM expected lost revenue
-- until next feasible visit; day capacity model (driver-hours, cluster travel, pack time);
-- service-policy cadence floor. Gate 0 UX unchanged (CS selects)."
--
-- THE MODEL, stated once so the fixture and the function cannot drift apart:
--   mu_base(shelf)  = COALESCE(v_shelf_instock_velocity_split_v3.velocity_instock_shelf,
--                              v_shelf_state.velocity_raw, 0)         -- canonical P2.1 object
--   factor(machine) = resolve_demand_multiplier_v3(machine, plan_date).factor  -- canonical P2.4
--   gap(machine)    = GREATEST(1, COALESCE(v_machine_base_stock_policy_v3.visit_interval_days,
--                              machine_service_policy.trip_interval_days_v3,
--                              machine_service_policy.trip_interval_days,
--                              refill_policy_params.var_default_gap_days))
--   lost_units      = GREATEST(0, mu_base * factor * gap - current_stock)
--   price(shelf)    = realized machine x pod (paid_amount/qty, lookback)
--                     -> realized fleet pod -> pod_products.recommended_selling_price -> NONE
--   VAR(machine)    = SUM(lost_units * price) over shelves with sourcing IS DISTINCT FROM 'partner'
--
-- WHY THE ASSERTIONS BELOW PIN IDENTITIES AND ORDERINGS RATHER THAN AED CONSTANTS:
-- VAR moves with every WEIMI snapshot and every sale, so a hardcoded 549.37 would red the
-- suite within hours for no defect. What CANNOT move without a real defect is (a) that the
-- function's number equals an independent recomputation from base tables, (b) that the
-- ordering obeys cadence-floor-then-VAR, (c) that capacity is respected, and (d) that
-- unpriceable and unmeasurable shelves are COUNTED rather than silently scored zero.
--
-- LIVE POPULATION (measured before a line of the function was written, leg 58):
--   656 shelves / 31 active machines. Price ladder: 494 realized machine x pod, 28 realized
--   fleet pod, 0 recommended-price, 134 with NO basis (112 of those carry a NULL pod_product_id
--   and 22 are the three new "Freakin" pods with no sales anywhere). Velocity: 522 instock_split,
--   22 raw_shelf, 112 none. Fleet VAR ~1141 AED over 25 at-risk shelves.
--   9 machines are cadence-due against a driver_capacity of 8 -- THE CADENCE FLOOR IS LIVE AND
--   OVERSUBSCRIBED, which is exactly the case that must not resolve silently.
--
-- THREE ANCHORS, chosen so the two selection rules visibly disagree:
--   M_TOP  VOXMCC-1005-0201-B0  148c4fcf  dsv 0  gap 5   highest VAR, NOT cadence-due
--   M_CAD  NOVO-1023-0000-W0    0a9a4836  dsv 15 gap 4   cadence-due, ~11th by VAR
--   M_ZERO MC-2004-0100-O1      0f698c26  dsv 2  gap 4   VAR 0, neither rule selects it
-- If the picker were VAR-only, M_CAD would not be selected. If it were cadence-only, M_TOP
-- would not be. Both must be, and the reason each carries must say which rule did it.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes,
   enabled, baseline_status)
VALUES (
  42,
  'Value-at-risk picker v3 ranks machines by expected lost revenue until the next feasible visit, forces the service-policy cadence floor above that ranking, respects a driver-minute and machine-count day capacity, reports cadence-due machines it could not fit instead of dropping them, and counts every unpriceable / unmeasurable shelf rather than scoring it zero (P3.5)',
  'PRD-110 leg 58 / BUILD-SPEC line 93. The live picker pick_machines_for_refill ranks on v_machine_priority urgency, which is a shelf-state composite with no revenue term at all: a machine one day from emptying its best seller and a machine one day from emptying its worst rank the same. P3.5 adds the money dimension. Gate 0 stays manual (LAW 11) - this object writes nothing and machines_to_visit is pinned unchanged.',
  'P3',
  DATE '2030-02-12',
$SCEN$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (1) INDEPENDENT RECOMPUTATION, from base tables, never asking the function
--     under test to confirm its own arithmetic. This is the spine of the fixture:
--     assertion 27 compares it to the function machine by machine.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE f42_shelf ON COMMIT DROP AS
WITH vel AS (
  SELECT shelf_id, velocity_instock_shelf
  FROM public.v_shelf_instock_velocity_split_v3
),
px_mp AS (
  SELECT v.machine_id, v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  WHERE v.transaction_date >= CURRENT_DATE - 90
  GROUP BY 1, 2
  HAVING sum(sh.qty) > 0
),
px_fleet AS (
  SELECT v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  WHERE v.transaction_date >= CURRENT_DATE - 90
  GROUP BY 1
  HAVING sum(sh.qty) > 0
),
mach AS (
  SELECT p.machine_id,
         GREATEST(1::numeric, COALESCE(b.visit_interval_days,
                                       msp.trip_interval_days_v3::numeric,
                                       msp.trip_interval_days::numeric,
                                       (SELECT var_default_gap_days FROM public.refill_policy_params LIMIT 1),
                                       3::numeric)) AS gap_days,
         (SELECT f.factor FROM public.resolve_demand_multiplier_v3(p.machine_id, {{plan_date}}) f) AS factor
  FROM public.v_machine_priority p
  LEFT JOIN public.v_machine_base_stock_policy_v3 b ON b.machine_id = p.machine_id
  LEFT JOIN public.machine_service_policy msp ON msp.machine_id = p.machine_id
  WHERE p.include_in_refill AND p.machine_status = 'Active'
)
SELECT s.machine_id, s.shelf_id, s.sourcing,
       COALESCE(s.current_stock, 0)                                   AS stock,
       COALESCE(vel.velocity_instock_shelf, s.velocity_raw, 0)::numeric AS mu_base,
       CASE WHEN vel.velocity_instock_shelf IS NOT NULL THEN 'instock_split'
            WHEN s.velocity_raw IS NOT NULL              THEN 'raw_shelf'
            ELSE 'none' END                                            AS velocity_basis,
       COALESCE(px_mp.unit_price, px_fleet.unit_price,
                NULLIF(pp.recommended_selling_price, 0))               AS unit_price,
       CASE WHEN px_mp.unit_price IS NOT NULL          THEN 'realized_machine_pod'
            WHEN px_fleet.unit_price IS NOT NULL       THEN 'realized_fleet_pod'
            WHEN pp.recommended_selling_price > 0      THEN 'recommended_price'
            ELSE 'none' END                                            AS price_basis,
       m.gap_days, COALESCE(m.factor, 1.0) AS factor,
       GREATEST(0::numeric,
                COALESCE(vel.velocity_instock_shelf, s.velocity_raw, 0)::numeric
                * COALESCE(m.factor, 1.0) * m.gap_days
                - COALESCE(s.current_stock, 0))                        AS lost_units,
       (COALESCE(s.current_stock, 0) < COALESCE(s.max_stock, 0))::int  AS is_refill_line
FROM public.v_shelf_state s
JOIN mach m            ON m.machine_id = s.machine_id
LEFT JOIN vel          ON vel.shelf_id = s.shelf_id
LEFT JOIN px_mp        ON px_mp.machine_id = s.machine_id AND px_mp.pod_product_id = s.pod_product_id
LEFT JOIN px_fleet     ON px_fleet.pod_product_id = s.pod_product_id
LEFT JOIN public.pod_products pp ON pp.pod_product_id = s.pod_product_id;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'indep_' || machine_id::text, jsonb_build_object(
  'var_aed',        round(sum(CASE WHEN sourcing IS DISTINCT FROM 'partner'
                                   THEN lost_units * COALESCE(unit_price, 0) ELSE 0 END), 2),
  'lost_units',     round(sum(CASE WHEN sourcing IS DISTINCT FROM 'partner'
                                   THEN lost_units ELSE 0 END), 4),
  'shelves_at_risk',count(*) FILTER (WHERE lost_units > 0 AND sourcing IS DISTINCT FROM 'partner'),
  'refill_lines',   sum(is_refill_line))
FROM f42_shelf GROUP BY machine_id;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'pop', jsonb_build_object(
  'shelves',                (SELECT count(*) FROM f42_shelf),
  'machines',               (SELECT count(DISTINCT machine_id) FROM f42_shelf),
  'pb_machine_pod',         (SELECT count(*) FROM f42_shelf WHERE price_basis = 'realized_machine_pod'),
  'pb_fleet_pod',           (SELECT count(*) FROM f42_shelf WHERE price_basis = 'realized_fleet_pod'),
  'pb_none',                (SELECT count(*) FROM f42_shelf WHERE price_basis = 'none'),
  'pb_none_at_risk',        (SELECT count(*) FROM f42_shelf WHERE price_basis = 'none' AND lost_units > 0),
  'vb_instock',             (SELECT count(*) FROM f42_shelf WHERE velocity_basis = 'instock_split'),
  'vb_none',                (SELECT count(*) FROM f42_shelf WHERE velocity_basis = 'none'),
  'machines_with_var',      (SELECT count(*) FROM (SELECT machine_id FROM f42_shelf
                              GROUP BY machine_id HAVING sum(lost_units * COALESCE(unit_price,0)) > 0) z),
  'cadence_due',            (SELECT count(*) FROM public.v_machine_priority p
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = p.machine_id
                              WHERE p.days_since_visit >= g.gap_days),
  'driver_capacity',        (SELECT driver_capacity FROM public.pick_urgency_params LIMIT 1),
  -- how many machines an 8-hour driver day can actually hold at the modelled per-machine
  -- cost, computed here from the params and the live line counts so assertion 21 does not
  -- depend on the function under test (and does not sit one machine away from flipping).
  'max_machines_by_minutes',(SELECT floor( (SELECT var_driver_day_minutes FROM public.refill_policy_params LIMIT 1)
                                  / NULLIF( (SELECT var_service_minutes_per_machine FROM public.refill_policy_params LIMIT 1)
                                          + (SELECT var_travel_minutes_inter_cluster FROM public.refill_policy_params LIMIT 1)
                                          + (SELECT var_pack_minutes_per_line FROM public.refill_policy_params LIMIT 1)
                                            * (SELECT avg(n) FROM (SELECT sum(is_refill_line) n FROM f42_shelf GROUP BY machine_id) z)
                                          , 0) )),
  'dsv_disagreements',      (SELECT count(*) FROM public.v_machine_priority p
                              WHERE p.include_in_refill AND p.machine_status = 'Active'
                                AND p.days_since_visit IS DISTINCT FROM
                                    (SELECT max(x.days_since_visit) FROM public.v_shelf_state x WHERE x.machine_id = p.machine_id)),
  'null_clusters',          (SELECT count(*) FROM public.v_machine_priority p
                              WHERE p.include_in_refill AND p.machine_status = 'Active' AND p.r_cluster IS NULL),
  'partner_shelves',        (SELECT count(*) FROM f42_shelf WHERE sourcing = 'partner'),
  'mtop_due',               (SELECT (max(p.days_since_visit) >= max(g.gap_days))::text
                              FROM public.v_machine_priority p
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = p.machine_id
                              WHERE p.machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'),
  'mcad_due',               (SELECT (max(p.days_since_visit) >= max(g.gap_days))::text
                              FROM public.v_machine_priority p
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = p.machine_id
                              WHERE p.machine_id = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'),
  'mtop_gt_mcad',           (SELECT ((SELECT sum(lost_units * COALESCE(unit_price,0)) FROM f42_shelf
                                       WHERE machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045')
                                   > (SELECT sum(lost_units * COALESCE(unit_price,0)) FROM f42_shelf
                                       WHERE machine_id = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'))::text),
  'mtv_before',             (SELECT count(*) FROM public.machines_to_visit));

-- ---------------------------------------------------------------------------
-- (2) THE FUNCTION UNDER TEST. Guarded so the RED baseline reports missing
--     evidence instead of aborting the whole scenario (leg 55/56/57 idiom).
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'rank_machines_by_value_at_risk_v3'
                                     AND pronamespace = 'public'::regnamespace) THEN
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 42, 'out', jsonb_agg(to_jsonb(r) ORDER BY r.rank)
      FROM public.rank_machines_by_value_at_risk_v3(DATE '2030-02-12') r
    $x$;
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 42, 'out_again', jsonb_agg(jsonb_build_object('rank', r.rank, 'm', r.machine_id) ORDER BY r.rank)
      FROM public.rank_machines_by_value_at_risk_v3(DATE '2030-02-12') r
    $x$;
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 42, 'out_limit3', to_jsonb(count(*))
      FROM public.rank_machines_by_value_at_risk_v3(DATE '2030-02-12', 3) r
    $x$;
  END IF;
END
$do$;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'mtv_after', to_jsonb((SELECT count(*) FROM public.machines_to_visit));
$SCEN$,
  'P3.5. rank_machines_by_value_at_risk_v3 is READ-ONLY (STABLE, SECURITY INVOKER): it writes nothing, so LAW 4 and LAW 12 hold by construction, and LAW 11 (Gate 0 stays manual) is pinned by seq 43 comparing machines_to_visit before and after. It reads mu from the canonical P2.1 object v_shelf_instock_velocity_split_v3, the demand factor from the canonical P2.4 resolver, cadence from v_machine_base_stock_policy_v3, days_since_visit from v_machine_priority (PRD-074 SSOT), and shelf stock/capacity from v_shelf_state - re-deriving none of them. Price comes from realized paid_amount/qty in sales_history, NEVER through product_mapping joins (LAW 6). BUDGET NOTE: the fixture reads the ~20 s velocity object twice (once itself, once inside the function), so fixture 42 alone runs ~40-50 s and run_all(P3) is no longer sub-second.',
  true,
  'failing_expected'
);

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES

-- ---- drift guards: if any of these move, every number below means something else ----
(42, 1, 'Drift guard: {{plan_date}} still renders as the fixture-42 anchor 2030-02-12',
 $q$SELECT {{plan_date}}::text$q$, 'eq', '2030-02-12', true, 'P3'),

(42, 2, 'Drift guard: anchor M_TOP 148c4fcf is still VOXMCC-1005-0201-B0',
 $q$SELECT official_name FROM public.machines WHERE machine_id='148c4fcf-b794-43f0-a2a8-e6f17605b045'$q$,
 'eq', 'VOXMCC-1005-0201-B0', true, 'P3'),

(42, 3, 'Drift guard: anchor M_CAD 0a9a4836 is still NOVO-1023-0000-W0',
 $q$SELECT official_name FROM public.machines WHERE machine_id='0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'$q$,
 'eq', 'NOVO-1023-0000-W0', true, 'P3'),

(42, 4, 'Drift guard: anchor M_ZERO 0f698c26 is still MC-2004-0100-O1',
 $q$SELECT official_name FROM public.machines WHERE machine_id='0f698c26-0a21-44f3-bc93-f39e8d88e7cb'$q$,
 'eq', 'MC-2004-0100-O1', true, 'P3'),

(42, 5, 'Cadence coverage is total: every active in-refill machine has a base-stock policy row, so no machine falls back to the default gap',
 $q$SELECT count(*)::text FROM public.v_machine_priority p
    WHERE p.include_in_refill AND p.machine_status='Active'
      AND NOT EXISTS (SELECT 1 FROM public.v_machine_base_stock_policy_v3 b WHERE b.machine_id=p.machine_id)$q$,
 'eq', '0', true, 'P3'),

(42, 6, 'PRD-074 SSOT holds: days_since_visit agrees between v_machine_priority and v_shelf_state on every active machine, so the cadence floor and the shelf model share one clock',
 $q$SELECT value->>'dsv_disagreements' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'eq', '0', true, 'P3'),

(42, 7, 'Travel model is total: no active machine has a NULL route cluster',
 $q$SELECT value->>'null_clusters' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'eq', '0', true, 'P3'),

(42, 8, 'The machine/day cap is read from the one live-calibrated capacity primitive, pick_urgency_params.driver_capacity, and it is a positive number',
 $q$SELECT value->>'driver_capacity' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'gte', '1', true, 'P3'),

-- ---- the capacity-model parameters exist and carry their documented defaults ----
(42, 9, 'Param: var_driver_day_minutes defaults to 480 (an 8-hour driver day)',
 $q$SELECT var_driver_day_minutes::text FROM public.refill_policy_params LIMIT 1$q$,
 'eq', '480', true, 'P3'),

(42, 10, 'Param: var_service_minutes_per_machine defaults to 25',
 $q$SELECT var_service_minutes_per_machine::text FROM public.refill_policy_params LIMIT 1$q$,
 'eq', '25', true, 'P3'),

(42, 11, 'Param: var_pack_minutes_per_line defaults to 1.5 - this is the pack-time term BUILD-SPEC line 93 names',
 $q$SELECT var_pack_minutes_per_line::text FROM public.refill_policy_params LIMIT 1$q$,
 'eq', '1.5', true, 'P3'),

(42, 12, 'Param: intra-cluster travel 10 min is strictly cheaper than inter-cluster 35 - the cluster-travel term is real, not decorative',
 $q$SELECT (var_travel_minutes_intra_cluster < var_travel_minutes_inter_cluster)::text
    FROM public.refill_policy_params LIMIT 1$q$,
 'eq', 'true', true, 'P3'),

(42, 13, 'Param: var_price_lookback_days defaults to 90, matching the window this fixture recomputes against',
 $q$SELECT var_price_lookback_days::text FROM public.refill_policy_params LIMIT 1$q$,
 'eq', '90', true, 'P3'),

-- ---- population evidence, computed independently of the function under test ----
(42, 14, 'Population: the shelf universe is the full v_shelf_state fleet, not a sample',
 $q$SELECT value->>'shelves' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'gte', '600', true, 'P3'),

(42, 15, 'Population: most shelves price off REALIZED machine x pod revenue, not a list price',
 $q$SELECT value->>'pb_machine_pod' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'gte', '400', true, 'P3'),

(42, 16, 'NON-VACUITY of the reporting path: shelves with NO price basis at all genuinely exist, so the no-price counter cannot be trivially zero',
 $q$SELECT value->>'pb_none' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'gt', '0', true, 'P3'),

(42, 17, 'LAW 5 SENSOR: no shelf is simultaneously at risk and unpriceable today - and if that ever changes this assertion reds instead of the revenue silently vanishing',
 $q$SELECT value->>'pb_none_at_risk' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'eq', '0', true, 'P3'),

(42, 18, 'Population: the canonical P2.1 in-stock velocity covers most shelves, so mu is not mostly a raw fallback',
 $q$SELECT value->>'vb_instock' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'gte', '400', true, 'P3'),

(42, 19, 'NON-VACUITY: at least one machine carries a strictly positive value at risk, so the ranking has something to rank',
 $q$SELECT value->>'machines_with_var' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'gt', '0', true, 'P3'),

(42, 20, 'NON-VACUITY: the service-policy cadence floor is genuinely binding on live data - machines are overdue right now',
 $q$SELECT value->>'cadence_due' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'gt', '0', true, 'P3'),

(42, 21, 'THE HARD CASE IS LIVE: more machines are cadence-due than a day of driver minutes can hold, so the oversubscription branch is exercised and not hypothetical. Compared against the TIGHTER of the two caps, computed from the params, so this does not sit one machine away from flipping',
 $q$SELECT ((value->>'cadence_due')::int
           > LEAST((value->>'driver_capacity')::int, (value->>'max_machines_by_minutes')::int))::text
    FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'eq', 'true', true, 'P3'),

(42, 22, 'Anchor separation: M_TOP is NOT cadence-due, so anything that selects it must have selected it on money',
 $q$SELECT value->>'mtop_due' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'eq', 'false', true, 'P3'),

(42, 23, 'Anchor separation: M_CAD IS cadence-due',
 $q$SELECT value->>'mcad_due' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'eq', 'true', true, 'P3'),

(42, 24, 'THE TWO RULES GENUINELY DISAGREE: M_TOP carries strictly more value at risk than the cadence-due M_CAD, so a VAR-only picker and a cadence-only picker would not produce the same day',
 $q$SELECT value->>'mtop_gt_mcad' FROM golden.scratch WHERE fixture_id=42 AND key='pop'$q$,
 'eq', 'true', true, 'P3'),

-- ---- the function under test ----
(42, 25, 'RED tripwire: the picker returned rows at all - this is the assertion that fails when the function is absent',
 $q$SELECT jsonb_array_length(value)::text FROM golden.scratch WHERE fixture_id=42 AND key='out'$q$,
 'gte', '25', true, 'P3'),

(42, 26, 'The picker covers exactly the machines the independent recomputation covers - no machine silently dropped from consideration',
 $q$SELECT (jsonb_array_length(s.value) = (p.value->>'machines')::int)::text
    FROM golden.scratch s, golden.scratch p
    WHERE s.fixture_id=42 AND s.key='out' AND p.fixture_id=42 AND p.key='pop'$q$,
 'eq', 'true', true, 'P3'),

(42, 27, 'THE SPINE: every machine value_at_risk_aed the picker reports equals the fixture independent recomputation from base tables, to the fil - 0 mismatches',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    JOIN golden.scratch i ON i.fixture_id=42 AND i.key = 'indep_' || (e->>'machine_id')
    WHERE s.fixture_id=42 AND s.key='out'
      AND round((e->>'value_at_risk_aed')::numeric,2) IS DISTINCT FROM round((i.value->>'var_aed')::numeric,2)$q$,
 'eq', '0', true, 'P3'),

(42, 28, 'Same for lost_units: the unit arithmetic is reproduced independently, 0 mismatches',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    JOIN golden.scratch i ON i.fixture_id=42 AND i.key = 'indep_' || (e->>'machine_id')
    WHERE s.fixture_id=42 AND s.key='out'
      AND round((e->>'lost_units')::numeric,4) IS DISTINCT FROM round((i.value->>'lost_units')::numeric,4)$q$,
 'eq', '0', true, 'P3'),

(42, 29, 'Same for shelves_at_risk, 0 mismatches',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    JOIN golden.scratch i ON i.fixture_id=42 AND i.key = 'indep_' || (e->>'machine_id')
    WHERE s.fixture_id=42 AND s.key='out'
      AND (e->>'shelves_at_risk')::int IS DISTINCT FROM (i.value->>'shelves_at_risk')::int$q$,
 'eq', '0', true, 'P3'),

(42, 30, 'Ranks are dense 1..N with no gaps and no duplicates',
 $q$SELECT (count(DISTINCT (e->>'rank')::int) = count(*)
           AND min((e->>'rank')::int) = 1
           AND max((e->>'rank')::int) = count(*))::text
    FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'$q$,
 'eq', 'true', true, 'P3'),

(42, 31, 'THE CADENCE FLOOR IS A FLOOR, NOT A WEIGHT: every cadence-due machine ranks above every machine that is not cadence-due - 0 inversions',
 $q$SELECT count(*)::text FROM
    (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out') a
    JOIN
    (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out') b
    ON a.due AND NOT b.due AND a.rk > b.rk$q$,
 'eq', '0', true, 'P3'),

(42, 32, 'Within each cadence group the ranking is by money, descending - 0 inversions',
 $q$SELECT count(*)::text FROM
    (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due,
            (e->>'value_at_risk_aed')::numeric v
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out') a
    JOIN
    (SELECT (e->>'rank')::int rk, (e->>'cadence_floor_due')::boolean due,
            (e->>'value_at_risk_aed')::numeric v
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key='out') b
    ON a.due = b.due AND a.rk < b.rk AND a.v < b.v$q$,
 'eq', '0', true, 'P3'),

(42, 33, 'M_TOP is the highest-VAR machine that is NOT cadence-due - the money rule picked it',
 $q$SELECT (e->>'machine_id') FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out' AND NOT (e->>'cadence_floor_due')::boolean
    ORDER BY (e->>'rank')::int LIMIT 1$q$,
 'eq', '148c4fcf-b794-43f0-a2a8-e6f17605b045', true, 'P3'),

(42, 34, 'M_CAD is reported cadence_floor_due by the function itself, not just by the fixture',
 $q$SELECT (e->>'cadence_floor_due') FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out' AND e->>'machine_id'='0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'$q$,
 'eq', 'true', true, 'P3'),

(42, 35, 'M_CAD outranks M_TOP despite carrying less money at risk - this single assertion is what proves the floor beats the score',
 $q$SELECT (( SELECT (e->>'rank')::int FROM golden.scratch s, jsonb_array_elements(s.value) e
             WHERE s.fixture_id=42 AND s.key='out' AND e->>'machine_id'='0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04')
         < ( SELECT (e->>'rank')::int FROM golden.scratch s, jsonb_array_elements(s.value) e
             WHERE s.fixture_id=42 AND s.key='out' AND e->>'machine_id'='148c4fcf-b794-43f0-a2a8-e6f17605b045'))::text$q$,
 'eq', 'true', true, 'P3'),

(42, 36, 'A machine with nothing at risk still gets a row: M_ZERO is present in the output rather than filtered out, so CS sees the whole fleet ranked and not just the alarming end of it',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out' AND e->>'machine_id'='0f698c26-0a21-44f3-bc93-f39e8d88e7cb'$q$,
 'eq', '1', true, 'P3'),

-- ---- the day capacity model ----
(42, 37, 'Day capacity: the selected set never exceeds the machine/day cap',
 $q$SELECT (count(*) FILTER (WHERE (e->>'selected')::boolean)
           <= (SELECT (p.value->>'driver_capacity')::int FROM golden.scratch p WHERE p.fixture_id=42 AND p.key='pop'))::text
    FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'$q$,
 'eq', 'true', true, 'P3'),

(42, 38, 'Day capacity: no selected machine pushes cumulative driver minutes past the day budget',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out' AND (e->>'selected')::boolean
      AND (e->>'cum_minutes')::numeric > (SELECT var_driver_day_minutes FROM public.refill_policy_params LIMIT 1)$q$,
 'eq', '0', true, 'P3'),

(42, 39, 'Day capacity is genuinely binding today: at least one machine is left unselected',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out' AND NOT (e->>'selected')::boolean$q$,
 'gt', '0', true, 'P3'),

(42, 40, 'THE OVERSUBSCRIBED FLOOR IS REPORTED, NEVER SILENT: at least one cadence-due machine that did not fit carries the explicit reason cadence_due_over_capacity',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'
      AND (e->>'cadence_floor_due')::boolean AND NOT (e->>'selected')::boolean
      AND e->>'selection_reason' = 'cadence_due_over_capacity'$q$,
 'gt', '0', true, 'P3'),

(42, 41, 'Every row carries a non-empty selection_reason - a machine is never left without an explanation of why it was or was not chosen',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'
      AND COALESCE(e->>'selection_reason','') = ''$q$,
 'eq', '0', true, 'P3'),

(42, 42, 'Every SELECTED row was selected by one of the two legal rules, never by an unnamed one',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out' AND (e->>'selected')::boolean
      AND e->>'selection_reason' NOT IN ('cadence_floor','value_at_risk')$q$,
 'eq', '0', true, 'P3'),

-- ---- LAW 5: what the picker could not measure is COUNTED, not scored zero ----
(42, 43, 'LAW 5: no row leaves value_at_risk_aed, shelves_at_risk, no_price_basis_shelves or no_velocity_shelves NULL',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'
      AND (e->>'value_at_risk_aed' IS NULL OR e->>'shelves_at_risk' IS NULL
           OR e->>'no_price_basis_shelves' IS NULL OR e->>'no_velocity_shelves' IS NULL)$q$,
 'eq', '0', true, 'P3'),

(42, 44, 'The unpriceable shelves the picker reports sum to the number the fixture counted independently',
 $q$SELECT (sum((e->>'no_price_basis_shelves')::int)
           = (SELECT (p.value->>'pb_none')::int FROM golden.scratch p WHERE p.fixture_id=42 AND p.key='pop'))::text
    FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'$q$,
 'eq', 'true', true, 'P3'),

(42, 45, 'Every row explains its own inputs: reasoning carries the gap source and the demand factor it used',
 $q$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key='out'
      AND (e->'reasoning'->>'gap_source' IS NULL OR e->'reasoning'->>'demand_factor' IS NULL)$q$,
 'eq', '0', true, 'P3'),

(42, 46, 'p_limit is a display limit and is honoured exactly',
 $q$SELECT value::text FROM golden.scratch WHERE fixture_id=42 AND key='out_limit3'$q$,
 'eq', '3', true, 'P3'),

(42, 47, 'DETERMINISM: two consecutive calls on the same date return the identical rank-to-machine mapping - the tiebreak is total, so equal-VAR machines cannot shuffle between runs',
 $q$SELECT (jsonb_path_query_array(b.value, '$[*].machine_id')
          = jsonb_path_query_array(a.value, '$[*].m'))::text
    FROM golden.scratch a, golden.scratch b
    WHERE a.fixture_id=42 AND a.key='out_again' AND b.fixture_id=42 AND b.key='out'$q$,
 'eq', 'true', true, 'P3'),

-- ---- LAW pins ----
(42, 48, 'LAW 11 PIN: running the picker did not add, remove or touch a single machines_to_visit row - Gate 0 stays manual and CS still selects',
 $q$SELECT ((SELECT value::text FROM golden.scratch WHERE fixture_id=42 AND key='mtv_after')
         = (SELECT value->>'mtv_before' FROM golden.scratch WHERE fixture_id=42 AND key='pop'))::text$q$,
 'eq', 'true', true, 'P3'),

(42, 49, 'LAW 3 PIN: the live Gate-0 picker pick_machines_for_refill is byte-untouched by this leg',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE proname='pick_machines_for_refill'$q$,
 'eq', 'd9f508d12aa1b7d35eb11927da234748', true, 'P3'),

(42, 50, 'LAW 3 PIN: the live confirm_machines_to_visit writer is byte-untouched by this leg',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE proname='confirm_machines_to_visit'$q$,
 'eq', 'a3344191ed395df23934893429aaadb6', true, 'P3'),

(42, 51, 'LAW 4 PIN: rank_machines_by_value_at_risk_v3 is STABLE and SECURITY INVOKER, so Postgres itself enforces "writes nothing" (provolatile cast per S-68)',
 $q$SELECT provolatile::text || '|' || prosecdef::text FROM pg_proc
    WHERE proname='rank_machines_by_value_at_risk_v3'$q$,
 'eq', 's|false', true, 'P3');
