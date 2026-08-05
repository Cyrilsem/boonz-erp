-- PRD-110 P3.4 — golden fixture 48: the facing rightsizing queue.
--
-- ⛔ LAW 1 (FIXTURE FIRST): this fixture is applied BEFORE propose_facing_changes_v3 exists.
-- The proposer calls sit inside a `DO ... IF EXISTS (pg_proc)` guard (the fixture-43 idiom), so
-- the fixture RUNS CLEANLY in the RED phase: the report-half assertions (the view's identity
-- grain, the ppad discipline) go GREEN immediately, and every queue-half assertion reads a
-- missing scratch key as NULL, which golden.compare returns false for. That is the RED signature
-- this unit wants: the measurement was already proven at leg 68, the queue is what is unproven.
--
-- ⭐ WHAT THIS FIXTURE PINS ABOVE ALL ELSE IS THE DOUBLE-COUNT TRAP.
-- v_shelf_instock_velocity_split_v3 canonicalises the Hunter/Hunter Ridge alias INTERNALLY but
-- emits the RAW pod key per shelf, while its pod_shelf_count and velocity_*_pod are FAMILY-level.
-- Grouping on the emitted key splits one 2-lane family into TWO rows that EACH claim facings = 2
-- and EACH claim the full family velocity -- doubled revenue, and two "drop a lane" proposals for
-- a family that should lose exactly one. It is a contradiction, not an error, so nothing
-- downstream would have caught it. Assertions 1-8 hold the report at the one grain that cannot
-- express that bug: one row per alias-merged family, facings agreeing with the canonical identity
-- owner v_shelf_sales_identity, and NO machine holding two Hunter% rows.
--
-- ⛔ THE ppad TRAP (assertions 9-13). velocity_instock is sales / IN-STOCK hours -- the same class
-- of quantity as PRD-108's rank_slot_suitability.proven. Measured live it is >= the calendar rate
-- on every one of 456 families (mean 1.121x, MAX 14.003x). So the report carries BOTH rates and
-- neither is "the" velocity, and starvation_ratio (their quotient) is the ONLY admissible evidence
-- for ADDING a lane: high revenue per lane alone argues for RESTOCKING it, not for a second one.
--
-- ⛔ S-71: starvation_ratio must be NULL where calendar velocity is 0 -- UNMEASURABLE, never
-- "not starved". Assertion 11 fails loudly if that ever becomes a 0 or a false.
--
-- ⚠️ PERF (S-26 / RISK 88): v_facing_performance_v3 costs ~25 s and machine-scoping does NOT
-- reduce it (the inner vel CTE is MATERIALIZED). This fixture therefore reads it ONCE into a TEMP
-- TABLE, and makes exactly THREE proposer calls (dry+limit, real, re-run). Budget ~110 s: a
-- heavyweight like 42/43. ⛔ RUN IT INDIVIDUALLY -- a 2-minute client timeout will kill it, and
-- per S-98 a killed client leaves the transaction open holding its locks.

DELETE FROM golden.assertions WHERE fixture_id = 48;
DELETE FROM golden.fixtures  WHERE fixture_id = 48;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (
48,
'Facing rightsizing proposes one lane more or one lane fewer per product family, at the alias-merged grain that cannot double-count a two-lane family, judging a lane on what it earns WHILE STOCKED and demanding evidence of starvation before it will ever add one -- behind the CS gate, writing nothing but its own queue (P3.4)',
'PRD-110 BUILD-SPEC P3.4. Leg 68 shipped the measurement half (v_facing_performance_v3) and staged the queue half unapplied at docs/prds/staged-p34/ because LAW 1 forbids the engine before the fixture. The trap that motivated the split grain was measured, not reasoned: grouping the split velocity view on its emitted pod key gives 7 dual-Hunter machines two rows that each claim facings=2 and each claim the full family velocity, so the fleet would be told to drop two lanes from a family that should lose one. Separately, velocity_instock is an in-stock-hours rate overstating the calendar rate by up to 14.003x live, so a lane judged on it alone would be judged on a number the assortment never earned.',
'P3',
DATE '2030-02-18',
$f48$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DELETE FROM public.facing_proposals_v3 WHERE plan_date = {{plan_date}};

-- (1) PARAMS, snapshotted so the oracle and the engine cannot read different thresholds.
CREATE TEMP TABLE f48_p ON COMMIT DROP AS
SELECT fac_min_facings_to_shrink AS minfac,
       fac_shrink_ratio          AS shr_ratio,
       fac_expand_ratio          AS exp_ratio,
       fac_starvation_ratio      AS starv_ratio,
       fac_min_peer_families     AS minpeer,
       fac_min_abs_rev_gap_aed   AS mingap,
       fac_max_proposals         AS maxprop
FROM public.refill_policy_params LIMIT 1;

-- (2) THE REPORT, READ EXACTLY ONCE. ~25 s; everything below reads this snapshot.
CREATE TEMP TABLE f48_perf ON COMMIT DROP AS
SELECT * FROM public.v_facing_performance_v3;

-- (3) THE ORACLE. The candidate set re-derived INDEPENDENTLY of the proposer, so the assertions
--     compare two derivations of the same rule rather than the engine against a frozen count that
--     would rot the moment the 30-day window rolls.
CREATE TEMP TABLE f48_cand ON COMMIT DROP AS
SELECT f.machine_id, f.pod_product_id, d.direction
FROM f48_perf f
CROSS JOIN f48_p p
CROSS JOIN LATERAL (
  SELECT f.rev_per_facing_day_potential / NULLIF(f.machine_peer_median_potential, 0) AS ratio
) r
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN f.facings >= p.minfac
     AND r.ratio   <  p.shr_ratio
     AND (f.machine_peer_median_potential - f.rev_per_facing_day_potential) >= p.mingap
      THEN 'shrink'
    WHEN r.ratio > p.exp_ratio
     AND f.starvation_ratio IS NOT NULL
     AND f.starvation_ratio >= p.starv_ratio
     AND (f.rev_per_facing_day_potential - f.machine_peer_median_potential) >= p.mingap
      THEN 'expand'
    END AS direction
) d
WHERE d.direction IS NOT NULL
  AND f.in_refill_universe
  AND f.operating_model IS DISTINCT FROM 'partner_managed'
  AND f.price_basis    <> 'none'
  AND f.velocity_basis  = 'instock_split'
  AND f.machine_peer_families >= p.minpeer;

-- (4) ORACLE FACTS. ⛔ S-93: a sibling subquery cannot see another's write, so every scratch key
--     is its own statement and is read back separately.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'oracle', jsonb_build_object(
  'n',                  (SELECT count(*) FROM f48_cand),
  'n_shrink',           (SELECT count(*) FROM f48_cand WHERE direction = 'shrink'),
  'n_expand',           (SELECT count(*) FROM f48_cand WHERE direction = 'expand'),
  'maxprop',            (SELECT maxprop FROM f48_p),
  'dry_limit_expect',   LEAST(3, (SELECT count(*) FROM f48_cand)),
  'view_rows',          (SELECT count(*) FROM f48_perf),
  -- the double-count trap
  'ident_rows',         (SELECT count(*) FROM public.v_shelf_sales_identity),
  'joined',             (SELECT count(*) FROM f48_perf f
                           JOIN public.v_shelf_sales_identity i USING (machine_id, pod_product_id)),
  'facing_mismatch',    (SELECT count(*) FROM f48_perf f
                           JOIN public.v_shelf_sales_identity i USING (machine_id, pod_product_id)
                          WHERE f.facings IS DISTINCT FROM i.facings),
  'dup_grain',          (SELECT count(*) FROM (SELECT machine_id, pod_product_id FROM f48_perf
                                                GROUP BY 1,2 HAVING count(*) > 1) z),
  'hunter_rows',        (SELECT count(*) FROM f48_perf WHERE pod_name LIKE 'Hunter%'),
  'hunter_machines_2',  (SELECT count(*) FROM (SELECT machine_id FROM f48_perf
                                                WHERE pod_name LIKE 'Hunter%'
                                                GROUP BY machine_id HAVING count(*) > 1) z),
  'multi_facing',       (SELECT count(*) FROM f48_perf WHERE facings > 1),
  'disagreement',       (SELECT count(*) FROM f48_perf WHERE facing_count_disagreement),
  -- the ppad discipline
  'ppad_violations',    (SELECT count(*) FROM f48_perf
                          WHERE velocity_instock IS NOT NULL AND velocity_calendar IS NOT NULL
                            AND velocity_instock < velocity_calendar),
  'instock_strictly_gt',(SELECT count(*) FROM f48_perf
                          WHERE velocity_instock IS NOT NULL AND velocity_calendar IS NOT NULL
                            AND velocity_instock > velocity_calendar),
  'starv_lie',          (SELECT count(*) FROM f48_perf
                          WHERE COALESCE(velocity_calendar, 0) = 0 AND starvation_ratio IS NOT NULL),
  'zero_cal',           (SELECT count(*) FROM f48_perf WHERE COALESCE(velocity_calendar, 0) = 0),
  'starv_measured',     (SELECT count(*) FROM f48_perf WHERE starvation_ratio IS NOT NULL)
);

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'oracle_set',
       COALESCE((SELECT jsonb_agg(x ORDER BY x)
                   FROM (SELECT machine_id::text || ':' || pod_product_id::text || ':' || direction AS x
                           FROM f48_cand) z), '[]'::jsonb);

-- (5) LAW 4 TRIPWIRE, BEFORE. The proposer is advisory: it may write its own queue and NOTHING
--     else -- no plan row, no dispatch leg, no visit list, no shadow ledger, no sibling queue.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'mtv',            (SELECT count(*) FROM public.machines_to_visit),
  'live_plan',      (SELECT count(*) FROM public.pod_refill_plan),
  'rpo',            (SELECT count(*) FROM public.refill_plan_output),
  'rpo_shadow',     (SELECT count(*) FROM public.refill_plan_output_shadow),
  'pod_refills_sh', (SELECT count(*) FROM public.pod_refills_shadow),
  'rotations',      (SELECT count(*) FROM public.rotation_proposals_v3),
  'blocked',        (SELECT count(*) FROM public.blocked_demand));

-- (6) THE ENGINE UNDER TEST. Guarded so the fixture is runnable before it exists (LAW 1).
--     Exactly THREE calls, each ~25 s: dry+limit, real, re-run.
DO $d48$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE proname = 'propose_facing_changes_v3'
                AND pronamespace = 'public'::regnamespace) THEN

    -- (6a) DRY RUN WITH A LIMIT. One call proves two contracts: the limit clamps, and a dry run
    --      computes the full answer while writing nothing.
    EXECUTE $x48$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 48, 'dry3', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
      FROM public.propose_facing_changes_v3(DATE '2030-02-18', 3, true) r
    $x48$;
    EXECUTE $x48$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 48, 'rows_after_dry',
             to_jsonb((SELECT count(*) FROM public.facing_proposals_v3
                        WHERE plan_date = DATE '2030-02-18'))
    $x48$;

    -- (6b) THE REAL RUN.
    EXECUTE $x48$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 48, 'out', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
      FROM public.propose_facing_changes_v3(DATE '2030-02-18') r
    $x48$;

    -- (6c) IDEMPOTENCY (STEP 7 S4): the same batch key twice must write nothing new.
    EXECUTE $x48$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 48, 'out_again', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
      FROM public.propose_facing_changes_v3(DATE '2030-02-18') r
    $x48$;

    EXECUTE $x48$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 48, 'written', jsonb_build_object(
        'rows',        (SELECT count(*) FROM public.facing_proposals_v3 WHERE plan_date = DATE '2030-02-18'),
        'non_pending', (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND status <> 'pending'),
        'shrink',      (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND direction = 'shrink'),
        'expand',      (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND direction = 'expand'),
        'to_zero',     (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND facings_proposed < 1),
        'shrink_below_2', (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND direction = 'shrink' AND facings_current < 2),
        'expand_no_starv', (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND direction = 'expand' AND starvation_ratio IS NULL),
        'multi_lane_jump', (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18'
                           AND abs(facings_proposed - facings_current) <> 1),
        'bad_price_basis', (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND price_basis = 'none'),
        'bad_vel_basis',   (SELECT count(*) FROM public.facing_proposals_v3
                         WHERE plan_date = DATE '2030-02-18' AND velocity_basis <> 'instock_split'),
        'thin_peers',      (SELECT count(*) FROM public.facing_proposals_v3 fp
                         CROSS JOIN public.refill_policy_params pp
                         WHERE fp.plan_date = DATE '2030-02-18'
                           AND fp.peer_families < pp.fac_min_peer_families),
        'dup_family',      (SELECT count(*) FROM (SELECT machine_id, pod_product_id
                         FROM public.facing_proposals_v3 WHERE plan_date = DATE '2030-02-18'
                         GROUP BY 1,2 HAVING count(*) > 1) z))
    $x48$;

    EXECUTE $x48$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 48, 'written_set',
             COALESCE((SELECT jsonb_agg(x ORDER BY x)
                         FROM (SELECT machine_id::text || ':' || pod_product_id::text || ':' || direction AS x
                                 FROM public.facing_proposals_v3
                                WHERE plan_date = DATE '2030-02-18') z), '[]'::jsonb)
    $x48$;

    -- The out-of-universe / partner-managed exclusions, checked against the REPORT rather than
    -- against the proposal rows, because a correct engine leaves no such row to inspect.
    EXECUTE $x48$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 48, 'excluded_leak', jsonb_build_object(
        'out_of_universe', (SELECT count(*) FROM public.facing_proposals_v3 fp
                              JOIN public.v_facing_performance_v3 v
                                ON v.machine_id = fp.machine_id AND v.pod_product_id = fp.pod_product_id
                             WHERE fp.plan_date = DATE '2030-02-18' AND NOT v.in_refill_universe),
        'partner',         (SELECT count(*) FROM public.facing_proposals_v3 fp
                              JOIN public.v_facing_performance_v3 v
                                ON v.machine_id = fp.machine_id AND v.pod_product_id = fp.pod_product_id
                             WHERE fp.plan_date = DATE '2030-02-18' AND v.operating_model = 'partner_managed'))
    $x48$;

  END IF;
END
$d48$;

-- (7) LAW 4 TRIPWIRE, AFTER.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'mtv',            (SELECT count(*) FROM public.machines_to_visit),
  'live_plan',      (SELECT count(*) FROM public.pod_refill_plan),
  'rpo',            (SELECT count(*) FROM public.refill_plan_output),
  'rpo_shadow',     (SELECT count(*) FROM public.refill_plan_output_shadow),
  'pod_refills_sh', (SELECT count(*) FROM public.pod_refills_shadow),
  'rotations',      (SELECT count(*) FROM public.rotation_proposals_v3),
  'blocked',        (SELECT count(*) FROM public.blocked_demand));
$f48$
);

-- ---------------------------------------------------------------------------
-- ASSERTIONS. ⛔ Every check_sql must be THROW-PROOF in the RED phase: a check that
-- raises aborts the entire fixture run, so nothing here calls the proposer, and every
-- read of a scratch key the RED phase never wrote resolves to NULL -- which
-- golden.compare returns false for. That is a RED, not an error.
-- ---------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

-- ===== A. THE DOUBLE-COUNT TRAP: the report's grain (green even in RED -- leg 68 shipped it) =====
(48, 1, 'Report holds exactly ONE row per (machine, alias-merged family): no duplicate grain',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'dup_grain')$c$, 'eq', '0', 'P3'),
(48, 2, 'Report grain equals the canonical identity owner v_shelf_sales_identity row-for-row (Article 16: read identity from its owner, never re-implement the alias rule)',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'view_rows')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'ident_rows')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 3, 'Every report row resolves in v_shelf_sales_identity (no orphan family)',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'joined')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'view_rows')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 4, 'facings agrees with the canonical owner on every family -- the report never invents a lane count',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'facing_mismatch')$c$, 'eq', '0', 'P3'),
(48, 5, 'THE TRAP: no machine holds two Hunter% rows -- an alias-merged family is ONE row, not two each claiming the full family velocity',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'hunter_machines_2')$c$, 'eq', '0', 'P3'),
(48, 6, 'NON-VACUITY for seq 5: Hunter% families actually exist in the report',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'hunter_rows')$c$, 'gte', '1', 'P3'),
(48, 7, 'NON-VACUITY for seq 1-5: multi-lane families exist, so there is something a double-count could have split',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'multi_facing')$c$, 'gte', '1', 'P3'),
(48, 8, 'facing_count_disagreement is clear fleet-wide: the two independent lane counts agree',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'disagreement')$c$, 'eq', '0', 'P3'),

-- ===== B. THE ppad DISCIPLINE =====
(48, 9, 'velocity_instock >= velocity_calendar on EVERY family: the in-stock rate can never be below the calendar rate it is derived from',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'ppad_violations')$c$, 'eq', '0', 'P3'),
(48, 10, 'NON-VACUITY for seq 9: the two rates genuinely differ somewhere (else the ppad guard tests nothing)',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'instock_strictly_gt')$c$, 'gte', '1', 'P3'),
(48, 11, 'S-71: starvation_ratio is NULL wherever calendar velocity is 0 -- UNMEASURABLE, never reported as "not starved"',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'starv_lie')$c$, 'eq', '0', 'P3'),
(48, 12, 'NON-VACUITY for seq 11: zero-calendar-velocity families actually exist',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'zero_cal')$c$, 'gte', '1', 'P3'),
(48, 13, 'NON-VACUITY: starvation is measurable on a real population, so the expand gate is a gate and not a blanket refusal',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'starv_measured')$c$, 'gte', '1', 'P3'),

-- ===== C. THE QUEUE vs AN INDEPENDENT ORACLE (RED until the proposer exists) =====
(48, 14, 'The proposer writes exactly the candidate set an independent re-derivation of the rule produces (count)',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'rows')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'n')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 15, 'Shrink count matches the oracle',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'shrink')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'n_shrink')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 16, 'Expand count matches the oracle',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'expand')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'n_expand')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 17, 'SET EQUALITY, not just cardinality: the exact (machine, family, direction) triples match the oracle',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written_set')
        = (SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle_set'))::text$c$, 'eq', 'true', 'P3'),
(48, 18, 'NON-VACUITY for seq 14-17: the oracle found something to propose (an empty agreement proves nothing)',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'n')$c$, 'gte', '1', 'P3'),
(48, 19, 'The batch never exceeds fac_max_proposals',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'rows')::int
        <= ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'maxprop')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 20, 'THE CS GATE: every proposal lands pending -- this engine decides nothing',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'non_pending')$c$, 'eq', '0', 'P3'),
(48, 21, 'A shrink ALWAYS leaves a lane behind: no proposal takes a family to zero (delisting is not a rightsizing decision)',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'to_zero')$c$, 'eq', '0', 'P3'),
(48, 22, 'No shrink is proposed for a single-lane family',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'shrink_below_2')$c$, 'eq', '0', 'P3'),
(48, 23, 'EXPAND REQUIRES STARVATION: no expand carries a NULL starvation_ratio -- high revenue per lane alone argues for restocking, not for a second lane',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'expand_no_starv')$c$, 'eq', '0', 'P3'),
(48, 24, 'Each proposal moves EXACTLY one lane: a 3->1 jump would be two decisions wearing one row',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'multi_lane_jump')$c$, 'eq', '0', 'P3'),
(48, 25, 'No proposal on a family with no AED basis (price_basis=none is no signal, not a weak one)',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'bad_price_basis')$c$, 'eq', '0', 'P3'),
(48, 26, 'No proposal on a family with no in-stock rate: without it there is no potential metric and no starvation test',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'bad_vel_basis')$c$, 'eq', '0', 'P3'),
(48, 27, 'No proposal judged against a thin peer group: a median over two lanes is not a benchmark',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'thin_peers')$c$, 'eq', '0', 'P3'),
(48, 28, 'One open proposal per family: a family never holds a shrink AND an expand at once',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'dup_family')$c$, 'eq', '0', 'P3'),
(48, 29, 'No proposal on a family outside the refill universe -- not ours to plan',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='excluded_leak')->>'out_of_universe')$c$, 'eq', '0', 'P3'),
(48, 30, 'No proposal on a partner_managed machine -- the partner owns that assortment',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='excluded_leak')->>'partner')$c$, 'eq', '0', 'P3'),

-- ===== D. DRY RUN AND LIMIT =====
(48, 31, 'A dry run writes NOTHING: the queue is still empty after a full dry evaluation',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='rows_after_dry') #>> '{}')$c$, 'eq', '0', 'P3'),
(48, 32, 'p_limit clamps the batch to LEAST(limit, candidates)',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='dry3')->0->>'proposals_written')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'dry_limit_expect')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 33, 'A dry run reports itself as one',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='dry3')->0->>'dry_run')$c$, 'eq', 'true', 'P3'),

-- ===== E. IDEMPOTENCY (STEP 7 S4) =====
(48, 34, 'IDEMPOTENT: re-running the same batch key writes zero new proposals',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='out_again')->0->>'proposals_written')$c$, 'eq', '0', 'P3'),
(48, 35, 'The real run reports exactly what it wrote (no silent divergence between the return value and the table)',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='out')->0->>'proposals_written')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='written')->>'rows')::int)::text$c$, 'eq', 'true', 'P3'),

-- ===== F. LAW 4: ADVISORY MEANS ADVISORY =====
(48, 36, 'LAW 4 tripwire: machines_to_visit untouched (Gate 0 is CS-manual, LAW 11)',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='before')->>'mtv')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='after')->>'mtv'))::text$c$, 'eq', 'true', 'P3'),
(48, 37, 'LAW 4 tripwire: the LIVE plan table untouched',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='before')->>'live_plan')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='after')->>'live_plan'))::text$c$, 'eq', 'true', 'P3'),
(48, 38, 'LAW 4 tripwire: refill_plan_output untouched',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='before')->>'rpo')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='after')->>'rpo'))::text$c$, 'eq', 'true', 'P3'),
(48, 39, 'LAW 4 tripwire: the shadow plan ledger untouched -- this engine is not in the plan pipeline at all',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='before')->>'rpo_shadow')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='after')->>'rpo_shadow'))::text$c$, 'eq', 'true', 'P3'),
(48, 40, 'LAW 4 tripwire: pod_refills_shadow untouched',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='before')->>'pod_refills_sh')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='after')->>'pod_refills_sh'))::text$c$, 'eq', 'true', 'P3'),
(48, 41, 'The sibling advisory queue (rotation_proposals_v3) untouched: two proposers, two queues',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='before')->>'rotations')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='after')->>'rotations'))::text$c$, 'eq', 'true', 'P3'),
(48, 42, 'blocked_demand untouched: a facing proposal is not unmet demand and must never reach procurement',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='before')->>'blocked')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='after')->>'blocked'))::text$c$, 'eq', 'true', 'P3'),

-- ===== G. S-88: RLS IS NOT THE WRITE GUARD, THE GRANT IS =====
(48, 43, 'S-88: the proposer is NOT executable by anon -- a SECURITY DEFINER reachable by anon is an unauthenticated write path',
 $c$SELECT COALESCE((SELECT has_function_privilege('anon', p.oid, 'EXECUTE')::text FROM pg_proc p
   WHERE p.proname='propose_facing_changes_v3' AND p.pronamespace='public'::regnamespace LIMIT 1), 'absent')$c$, 'eq', 'false', 'P3'),
(48, 44, 'S-88: the proposer is NOT executable by authenticated either -- service_role only',
 $c$SELECT COALESCE((SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE')::text FROM pg_proc p
   WHERE p.proname='propose_facing_changes_v3' AND p.pronamespace='public'::regnamespace LIMIT 1), 'absent')$c$, 'eq', 'false', 'P3'),
(48, 45, 'The proposer is SECURITY DEFINER (it must bypass the table RLS that blocks every client write)',
 $c$SELECT COALESCE((SELECT p.prosecdef::text FROM pg_proc p
   WHERE p.proname='propose_facing_changes_v3' AND p.pronamespace='public'::regnamespace LIMIT 1), 'absent')$c$, 'eq', 'true', 'P3'),
(48, 46, 'The queue is NOT INSERTable by a logged-in client: the proposer is the only writer',
 $c$SELECT COALESCE((SELECT has_table_privilege('authenticated', c.oid, 'INSERT')::text FROM pg_class c
   WHERE c.oid = to_regclass('public.facing_proposals_v3')), 'absent')$c$, 'eq', 'false', 'P3'),
(48, 47, 'The queue is NOT UPDATEable by a logged-in client (the approve/reject path will be its own RPC and its own Cody review)',
 $c$SELECT COALESCE((SELECT has_table_privilege('authenticated', c.oid, 'UPDATE')::text FROM pg_class c
   WHERE c.oid = to_regclass('public.facing_proposals_v3')), 'absent')$c$, 'eq', 'false', 'P3'),
(48, 48, 'The queue is NOT DELETEable by a logged-in client',
 $c$SELECT COALESCE((SELECT has_table_privilege('authenticated', c.oid, 'DELETE')::text FROM pg_class c
   WHERE c.oid = to_regclass('public.facing_proposals_v3')), 'absent')$c$, 'eq', 'false', 'P3'),
(48, 49, 'The queue is NOT readable by anon',
 $c$SELECT COALESCE((SELECT has_table_privilege('anon', c.oid, 'SELECT')::text FROM pg_class c
   WHERE c.oid = to_regclass('public.facing_proposals_v3')), 'absent')$c$, 'eq', 'false', 'P3'),
(48, 50, 'The queue IS readable by authenticated -- a queue nobody can read is not a queue',
 $c$SELECT COALESCE((SELECT has_table_privilege('authenticated', c.oid, 'SELECT')::text FROM pg_class c
   WHERE c.oid = to_regclass('public.facing_proposals_v3')), 'absent')$c$, 'eq', 'true', 'P3'),

-- ===== H. LAW 5: NOTHING IS SILENTLY DROPPED =====
(48, 51, 'LAW 5: the proposer accounts for EVERY family in the report, not just the ones it judged',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='out')->0->>'families_considered')::int
        = ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='oracle')->>'view_rows')::int)::text$c$, 'eq', 'true', 'P3'),
(48, 52, 'LAW 5 NON-VACUITY: the declined families are actually counted and reported, not zeroed',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=48 AND key='out')->0->>'skipped_no_velocity')$c$, 'gte', '1', 'P3');
