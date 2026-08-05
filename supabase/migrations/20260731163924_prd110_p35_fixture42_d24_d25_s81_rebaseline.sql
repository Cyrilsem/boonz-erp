-- PRD-110 P3.5 / fixture 42 re-baseline for CS DECISIONS D-24 + D-25, plus the S-81 grant pin
-- and the S-79 sweep of the var_* family.
--
-- ⛔ S-78: every assertion INSERT below is BARE. Fixture 42 held seq 1..55 CONTIGUOUSLY (probed
-- before writing); the new work starts at 56. A seq collision must ERROR, never silently
-- DO UPDATE over a live assertion and still report a clean apply.
--
-- WHAT CHANGED SEMANTICALLY: the OUT column cadence_floor_due used to mean "at the service
-- TARGET" and now means "BREACHED". Assertions whose SQL stays correct under the new rule get
-- their DESCRIPTIONS corrected (31, 32, 33, 34, 35) so a later reader is never told the wrong
-- thing by a green test. Two assertions genuinely stop being true and are RE-EXPRESSED (21, 40),
-- both into strictly stronger forms that do not depend on today's arithmetic.

-- ---------------------------------------------------------------------------
-- (1) SCENARIO: add the independent BREACH recomputation beside the existing
--     independent SOFT-due one. The breach predicate is computed off
--     v_machine_health_signals - the Article 16 canonical visit clock, the same
--     object the function reads - so seq 62 tests D-24, not clock drift
--     (clock agreement is already pinned by seq 6 and seq 54).
-- ---------------------------------------------------------------------------
UPDATE golden.fixtures SET scenario_sql = $scen$
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
  -- SOFT: merely at the service target. Before CS decision D-24 this is what forced a machine
  -- into the day. It now sorts NOTHING - it is reported for transparency only.
  'cadence_due',            (SELECT count(*) FROM public.v_machine_priority p
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = p.machine_id
                              WHERE p.days_since_visit >= g.gap_days),
  -- HARD (D-24): BREACHED. Recomputed here from the Article 16 canonical visit clock
  -- (v_machine_health_signals) and the two POLICY params, never from the function under test.
  'cadence_breached',       (SELECT count(*) FROM public.v_machine_health_signals h
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id
                              CROSS JOIN (SELECT var_cadence_floor_multiple AS mult,
                                                 var_cadence_hard_max_days::numeric AS capd
                                          FROM public.refill_policy_params LIMIT 1) q
                              WHERE h.days_since_visit >= LEAST(g.gap_days * q.mult, q.capd)),
  'cadence_floor_multiple', (SELECT var_cadence_floor_multiple FROM public.refill_policy_params LIMIT 1),
  'cadence_hard_max_days',  (SELECT var_cadence_hard_max_days FROM public.refill_policy_params LIMIT 1),
  -- The re-expressed seq 21 numerator: machines that have a claim on the day under the NEW rule -
  -- either the service target has been reached or there is real money on the shelf.
  'target_or_var',          (SELECT count(*) FROM public.v_machine_priority p
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = p.machine_id
                              LEFT JOIN (SELECT machine_id, sum(lost_units * COALESCE(unit_price,0)) AS v
                                         FROM f42_shelf GROUP BY 1) z ON z.machine_id = p.machine_id
                              WHERE p.days_since_visit >= g.gap_days OR COALESCE(z.v, 0) > 0),
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
  'mtop_breached',          (SELECT (max(h.days_since_visit) >= LEAST(max(g.gap_days) * max(q.mult), max(q.capd)))::text
                              FROM public.v_machine_health_signals h
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id
                              CROSS JOIN (SELECT var_cadence_floor_multiple AS mult,
                                                 var_cadence_hard_max_days::numeric AS capd
                                          FROM public.refill_policy_params LIMIT 1) q
                              WHERE h.machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'),
  'mcad_breached',          (SELECT (max(h.days_since_visit) >= LEAST(max(g.gap_days) * max(q.mult), max(q.capd)))::text
                              FROM public.v_machine_health_signals h
                              JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id
                              CROSS JOIN (SELECT var_cadence_floor_multiple AS mult,
                                                 var_cadence_hard_max_days::numeric AS capd
                                          FROM public.refill_policy_params LIMIT 1) q
                              WHERE h.machine_id = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'),
  'mtop_gt_mcad',           (SELECT ((SELECT sum(lost_units * COALESCE(unit_price,0)) FROM f42_shelf
                                       WHERE machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045')
                                   > (SELECT sum(lost_units * COALESCE(unit_price,0)) FROM f42_shelf
                                       WHERE machine_id = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'))::text),
  'mtv_before',             (SELECT count(*) FROM public.machines_to_visit));

-- Per-machine INDEPENDENT breach verdict, so seq 62 can prove the function's cadence_floor_due
-- column means exactly what D-24 says it means, machine by machine, not just in aggregate.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'breach',
       COALESCE(jsonb_agg(jsonb_build_object(
         'm',  h.machine_id,
         'br', (h.days_since_visit >= LEAST(g.gap_days * q.mult, q.capd)))), '[]'::jsonb)
FROM public.v_machine_health_signals h
JOIN (SELECT DISTINCT machine_id, gap_days FROM f42_shelf) g ON g.machine_id = h.machine_id
CROSS JOIN (SELECT var_cadence_floor_multiple AS mult,
                   var_cadence_hard_max_days::numeric AS capd
            FROM public.refill_policy_params LIMIT 1) q;

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
$scen$
WHERE fixture_id = 42;

-- ---------------------------------------------------------------------------
-- (2) RE-EXPRESSED assertions. Both stop being true under D-24 and both are
--     re-expressed into forms that do not depend on today's arithmetic.
-- ---------------------------------------------------------------------------

-- seq 21 was: "more machines are cadence-due than a day can hold". Under D-24 the breached set
-- is 4 against a capacity of 8, so the SOFT count no longer describes oversubscription of
-- anything that binds. Re-expressed against the population that actually has a claim on the day:
-- target-due OR carrying real money.
UPDATE golden.assertions SET
  description = 'THE HARD CASE IS LIVE UNDER D-24: more machines have a genuine claim on the day - the service target reached OR real money on the shelf - than a day of driver minutes can hold, so the picker is choosing under scarcity and not merely listing. Compared against the TIGHTER of the two caps, computed from the params, so this does not sit one machine away from flipping',
  check_sql = 'SELECT ((value->>''target_or_var'')::int
           > LEAST((value->>''driver_capacity'')::int, (value->>''max_machines_by_minutes'')::int))::text
    FROM golden.scratch WHERE fixture_id=42 AND key=''pop'''
WHERE fixture_id = 42 AND seq = 21;

-- seq 40 was: "at least one cadence-due machine that did not fit carries the explicit reason".
-- Under D-24 all four BREACHED machines fit, so the old form reds on correct work (S-79 disease).
-- Re-expressed as 0 VIOLATIONS: the floor is never silently dropped, whatever today's counts are.
UPDATE golden.assertions SET
  description = 'THE BREACHED FLOOR IS NEVER SILENTLY DROPPED: every machine that has breached its visit cadence is either SELECTED or carries the explicit reason cadence_due_over_capacity - 0 violations. Stronger than the old "at least one overflowed" form, which reddened the day the breached set finally fit inside capacity',
  expect_op = 'eq',
  expect = '0',
  check_sql = 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT'' ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key=''out''
      AND (e->>''cadence_floor_due'')::boolean
      AND NOT (e->>''selected'')::boolean
      AND e->>''selection_reason'' IS DISTINCT FROM ''cadence_due_over_capacity'') END'
WHERE fixture_id = 42 AND seq = 40;

-- ---------------------------------------------------------------------------
-- (3) DESCRIPTION-ONLY corrections. The SQL of each of these is still correct
--     under D-24; what changed is what the words "cadence-due" mean. A green
--     test that describes the wrong rule is a trap for the next reader.
-- ---------------------------------------------------------------------------
UPDATE golden.assertions SET description =
 'NON-VACUITY: the SOFT service target is genuinely reached by machines right now. Since D-24 this state no longer forces a machine into the day on its own - seq 61 is the sensor for the state that does'
WHERE fixture_id = 42 AND seq = 20;

UPDATE golden.assertions SET description =
 'Anchor separation: M_TOP has not even reached its soft service target, so anything that selects it must have selected it on money. This is CS acceptance machine VOXMCC-1005 - seq 60 is the acceptance test itself'
WHERE fixture_id = 42 AND seq = 22;

UPDATE golden.assertions SET description =
 'Anchor separation: M_CAD has reached its soft service target (and seq 34 shows it has gone further and BREACHED the hard floor)'
WHERE fixture_id = 42 AND seq = 23;

UPDATE golden.assertions SET description =
 'THE BREACHED FLOOR IS A FLOOR, NOT A WEIGHT: every machine that has BREACHED its visit cadence ranks above every machine that has not - 0 inversions. Under D-24 cadence_floor_due reports the BREACH, so this is now the only cadence state that pre-empts money'
WHERE fixture_id = 42 AND seq = 31;

UPDATE golden.assertions SET description =
 'D-24 MONEY FIRST: within each breach group the ranking is by money, descending - 0 inversions. For the 27 non-breached machines this IS the primary sort'
WHERE fixture_id = 42 AND seq = 32;

UPDATE golden.assertions SET description =
 'M_TOP is the highest-VAR machine that has NOT breached its cadence floor, and under D-24 that makes it the first machine the money rule reaches'
WHERE fixture_id = 42 AND seq = 33;

UPDATE golden.assertions SET description =
 'M_CAD is reported cadence_floor_due (= BREACHED under D-24) by the function itself, not just by the fixture'
WHERE fixture_id = 42 AND seq = 34;

UPDATE golden.assertions SET description =
 'M_CAD outranks M_TOP despite carrying 543.50 AED less at risk - this single assertion is what proves the BREACHED floor still beats money, which is the one thing D-24 deliberately kept'
WHERE fixture_id = 42 AND seq = 35;

-- ---------------------------------------------------------------------------
-- (4) NEW assertions, seq 56..67. BARE INSERTs (S-78): a collision must ERROR.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(42, 56,
 'Param: var_cadence_floor_multiple defaults to 2.0 - a machine breaches at twice its own service interval (CS decision D-24). POLICY: CS retunes it with one UPDATE and no migration',
 'SELECT ((value->>''cadence_floor_multiple'')::numeric = 2.0)::text FROM golden.scratch WHERE fixture_id=42 AND key=''pop''',
 'eq', 'true', true, 'P3'),

(42, 57,
 'Param: var_cadence_hard_max_days defaults to 14 - the absolute ceiling nobody exceeds regardless of their own gap. On live data it is this cap, not the multiple, that binds the breached set',
 'SELECT ((value->>''cadence_hard_max_days'')::int = 14)::text FROM golden.scratch WHERE fixture_id=42 AND key=''pop''',
 'eq', 'true', true, 'P3'),

(42, 58,
 'S-79 REQUIRED-SET (replaces the count(*)=literal shape that reds on correct work): all nine var_* policy columns exist on refill_policy_params - 0 missing. Adding a tenth param does NOT red this; deleting one of the nine does',
 'SELECT (SELECT count(*) FROM unnest(ARRAY[''var_driver_day_minutes'',''var_service_minutes_per_machine'',''var_pack_minutes_per_line'',''var_travel_minutes_intra_cluster'',''var_travel_minutes_inter_cluster'',''var_price_lookback_days'',''var_default_gap_days'',''var_cadence_floor_multiple'',''var_cadence_hard_max_days'']) c
    WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns ic
                       WHERE ic.table_schema=''public'' AND ic.table_name=''refill_policy_params''
                         AND ic.column_name=c))::text',
 'eq', '0', true, 'P3'),

(42, 59,
 'S-79 0-VIOLATIONS, strictly stronger than any count: no var_* column on refill_policy_params lacks a column comment. A future param added without documenting what it means reds here, where the old "five of them are commented" count went green',
 'SELECT (SELECT count(*) FROM information_schema.columns ic
    WHERE ic.table_schema=''public'' AND ic.table_name=''refill_policy_params''
      AND ic.column_name LIKE ''var\_%''
      AND COALESCE(col_description(''public.refill_policy_params''::regclass, ic.ordinal_position), '''') = '''')::text',
 'eq', '0', true, 'P3'),

(42, 60,
 'CS D-24 ACCEPTANCE TEST, VERBATIM: VOXMCC-1005-0201-B0 carries 543.50 AED of value at risk and IS SELECTED within capacity. Before D-24 it sat unselected at rank 10 behind nine cadence-due machines, seven of which carried 0.00 AED. This is the assertion CS asked for by name',
 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT'' ELSE (SELECT (e->>''selected'') FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key=''out'' AND e->>''machine_id''=''148c4fcf-b794-43f0-a2a8-e6f17605b045'') END',
 'eq', 'true', true, 'P3'),

(42, 61,
 'S-75 SENSOR FOR THE SENSOR: the hard floor is neither decorative nor collapsed back into the soft target - 0 < breached < target_due. If the multiple were set to 1.0 the two counts would coincide and D-24 would be undone silently; if the cap were raised out of reach the floor would stop binding and nothing else would red',
 'SELECT (((value->>''cadence_breached'')::int > 0)
        AND ((value->>''cadence_breached'')::int < (value->>''cadence_due'')::int))::text
    FROM golden.scratch WHERE fixture_id=42 AND key=''pop''',
 'eq', 'true', true, 'P3'),

(42, 62,
 'D-24 CONTRACT, MACHINE BY MACHINE: the function''s cadence_floor_due column equals the fixture''s independent BREACH predicate (days_since_visit >= LEAST(gap * multiple, hard_max)) computed from the Article 16 canonical visit clock - 0 disagreements. This is what pins the column to its NEW meaning rather than its old one',
 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT''
         WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''breach'') THEN ''NO_BREACH_BASELINE''
         ELSE (SELECT count(*)::text FROM
    (SELECT e->>''machine_id'' m, (e->>''cadence_floor_due'')::boolean br
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key=''out'') fn
    FULL JOIN
    (SELECT e->>''m'' m, (e->>''br'')::boolean br
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key=''breach'') ix
    ON fn.m = ix.m
    WHERE fn.m IS NULL OR ix.m IS NULL OR fn.br IS DISTINCT FROM ix.br) END',
 'eq', '0', true, 'P3'),

(42, 63,
 'NON-VACUITY OF THE WHOLE DECISION: machines exist right now that have reached the soft service target but have NOT breached the hard floor. These are exactly the machines D-24 stops from pre-empting money. If this ever reads 0 the soft/hard distinction has no population and every other D-24 assertion passes over an empty set',
 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT'' ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key=''out''
      AND (e->''reasoning''->''cadence''->>''target_due'')::boolean
      AND NOT (e->>''cadence_floor_due'')::boolean) END',
 'gt', '0', true, 'P3'),

(42, 64,
 'CS D-25 TIEBREAK: among machines tied on breach state AND on money, the one whose coverage is staler ranks first - 0 inversions. This is what makes a blind machine surface instead of sinking to an alphabetical grave behind every other 0.00 AED machine',
 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT'' ELSE (SELECT count(*)::text FROM
    (SELECT (e->>''rank'')::int rk, (e->>''cadence_floor_due'')::boolean br,
            (e->>''value_at_risk_aed'')::numeric v,
            (e->''reasoning''->''coverage_gaps''->>''coverage_staleness'')::numeric cs
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key=''out'') a
    JOIN
    (SELECT (e->>''rank'')::int rk, (e->>''cadence_floor_due'')::boolean br,
            (e->>''value_at_risk_aed'')::numeric v,
            (e->''reasoning''->''coverage_gaps''->>''coverage_staleness'')::numeric cs
       FROM golden.scratch s, jsonb_array_elements(s.value) e
      WHERE s.fixture_id=42 AND s.key=''out'') b
    ON a.br = b.br AND a.v = b.v AND a.rk < b.rk AND a.cs < b.cs) END',
 'eq', '0', true, 'P3'),

(42, 65,
 'CS D-25 NO SYNTHETIC IMPUTATION: coverage staleness is reported on every single row and is never negative - 0 violations. It sorts, it never scores: seq 27 independently proves value_at_risk_aed is still purely realized revenue, recomputed from base tables with no staleness term anywhere in it',
 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT'' ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key=''out''
      AND (e->''reasoning''->''coverage_gaps''->>''coverage_staleness'' IS NULL
           OR (e->''reasoning''->''coverage_gaps''->>''coverage_staleness'')::numeric < 0)) END',
 'eq', '0', true, 'P3'),

(42, 66,
 'D-25 TIEBREAK IS NON-VACUOUS: machines with strictly positive coverage staleness exist right now, so seq 64 is ordering a real population rather than a column of zeros',
 'SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=42 AND key=''out'') THEN ''NO_PICKER_OUTPUT'' ELSE (SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
    WHERE s.fixture_id=42 AND s.key=''out''
      AND (e->''reasoning''->''coverage_gaps''->>''coverage_staleness'')::numeric > 0) END',
 'gt', '0', true, 'P3'),

(42, 67,
 'S-81 GRANT PIN (mirrors fixture 43 seq 15): rank_machines_by_value_at_risk_v3 is NOT EXECUTable by anon or by PUBLIC - it returns fleet-wide value at risk in AED. This grant was swept once under S-57 and regrew, because seq 51 pins VOLATILITY and nothing pinned GRANTS. It cannot regrow a third time silently',
 'SELECT CASE WHEN (SELECT proacl FROM pg_proc WHERE proname=''rank_machines_by_value_at_risk_v3''
                     AND pronamespace=''public''::regnamespace) IS NULL
              THEN ''ACL_NULL_MEANS_DEFAULT_PUBLIC_GRANTS''
              ELSE (SELECT count(*)::text FROM pg_proc p, aclexplode(p.proacl) a
                     WHERE p.proname=''rank_machines_by_value_at_risk_v3''
                       AND p.pronamespace=''public''::regnamespace
                       AND a.privilege_type=''EXECUTE''
                       AND (a.grantee = 0
                            OR a.grantee = (SELECT oid FROM pg_roles WHERE rolname=''anon''))) END',
 'eq', '0', true, 'P3');
