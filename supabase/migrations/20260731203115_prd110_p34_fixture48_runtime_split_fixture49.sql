-- PRD-110 P3.4 — fixture 48 runtime fix + seq 44 expect fix + fixture 49 (dry-run/limit).
--
-- ⛔ TWO DEFECTS, BOTH FOUND BY RUNNING THE THING RATHER THAN READING IT.
--
-- (1) RUNTIME. Fixture 48 as first applied made FOUR reads of v_facing_performance_v3 (its
--     own oracle, plus three proposer calls) at ~25 s each and ran 126 s -- past the ~105 s
--     gateway ceiling that fixtures 42 (101.7 s) and 43 (103.1 s) already sit at. The run
--     COMMITTED server-side and only the HTTP response was lost (⭐ a 524 is therefore NOT
--     always "the query is already dead" as RISK 89 states -- read golden.runs before
--     concluding anything). The dry-run/limit contract moves to fixture 49, which needs ONE
--     call, leaving 48 at three reads (~95 s) and 49 at one (~30 s). Both under the ceiling,
--     and every contract still pinned.
--
-- (2) SEQ 44 EXPECT. The previous migration re-expressed seq 44's check_sql as "same ACL as
--     the ratified sibling" but left expect at 'false' from the superseded formulation, so a
--     correct engine read as a failure. The check now returns true and expect must say so.
--     ⛔ Changing a check_sql without re-reading its expect is a way to keep a green suite
--     while testing nothing -- here it failed loudly, which is the good direction.

UPDATE golden.fixtures SET scenario_sql = $f48$
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
--     Exactly TWO calls here, ~25 s each. The dry-run/limit contract moved to fixture 49
--     because four view reads (oracle + three calls) ran 126 s and blew the ~105 s gateway
--     ceiling that fixtures 42 and 43 already sit at.
DO $d48$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE proname = 'propose_facing_changes_v3'
                AND pronamespace = 'public'::regnamespace) THEN

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
WHERE fixture_id = 48;

-- Seq 31/32/33 depended on the removed dry+limit call; they move to fixture 49 verbatim in
-- intent. ⛔ Leaving them here would leave three assertions permanently RED against scratch
-- keys nothing writes -- a red that means nothing is worse than no assertion at all.
DELETE FROM golden.assertions WHERE fixture_id = 48 AND seq IN (31, 32, 33);

UPDATE golden.assertions SET expect = 'true' WHERE fixture_id = 48 AND seq = 44;

-- ---------------------------------------------------------------------------
-- FIXTURE 49 — the dry-run and limit contract, at ONE proposer call.
-- ---------------------------------------------------------------------------
DELETE FROM golden.assertions WHERE fixture_id = 49;
DELETE FROM golden.fixtures  WHERE fixture_id = 49;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (
49,
'The facing proposer can be asked what it WOULD do without doing it, and can be capped: a dry run computes the full answer and writes nothing at all, and p_limit clamps the batch (P3.4)',
'PRD-110 P3.4. Split out of fixture 48: four reads of v_facing_performance_v3 in one fixture ran 126 s and exceeded the gateway ceiling, so the dry-run/limit contract gets its own single-call fixture. The contract matters because the proposer is the first P3 advisory engine a human will point at a live date to ask a question, and a dry run that quietly wrote rows would put unreviewed proposals in front of CS.',
'P3',
DATE '2030-02-19',
$f49$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DELETE FROM public.facing_proposals_v3 WHERE plan_date = {{plan_date}};

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before',
       jsonb_build_object('total', (SELECT count(*) FROM public.facing_proposals_v3));

DO $d49$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE proname = 'propose_facing_changes_v3'
                AND pronamespace = 'public'::regnamespace) THEN
    EXECUTE $x49$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 49, 'dry3', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
      FROM public.propose_facing_changes_v3(DATE '2030-02-19', 3, true) r
    $x49$;
  END IF;
END
$d49$;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'batch', (SELECT count(*) FROM public.facing_proposals_v3 WHERE plan_date = {{plan_date}}),
  'total', (SELECT count(*) FROM public.facing_proposals_v3));
$f49$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(49, 1, 'A dry run reports itself as one',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'dry_run')$c$, 'eq', 'true', 'P3'),
(49, 2, 'A dry run writes NOTHING for its own batch key: the queue is empty after a full dry evaluation',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='after')->>'batch')$c$, 'eq', '0', 'P3'),
(49, 3, 'A dry run writes nothing ANYWHERE: the whole queue is byte-stable across the call, not just this plan_date',
 $c$SELECT (((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='before')->>'total')
        = ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='after')->>'total'))::text$c$, 'eq', 'true', 'P3'),
(49, 4, 'p_limit CLAMPS the batch: never more than the caller asked for',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'proposals_written')$c$, 'lte', '3', 'P3'),
(49, 5, 'NON-VACUITY for seq 4: the dry run actually found something, so the clamp is clamping a real answer and not hiding an empty one',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'proposals_written')$c$, 'gte', '1', 'P3'),
(49, 6, 'LAW 5: a dry run still accounts for every family in the report',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'families_considered')$c$, 'gte', '1', 'P3'),
(49, 7, 'LAW 5: a dry run still reports the families it declined to judge',
 $c$SELECT ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'skipped_no_velocity')$c$, 'gte', '1', 'P3'),
(49, 8, 'The shrink/expand split is reported on a dry run too, not just the total',
 $c$SELECT ((((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'shrink_count')::int
         + ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'expand_count')::int)
        = ((SELECT value FROM golden.scratch WHERE fixture_id=49 AND key='dry3')->0->>'proposals_written')::int)::text$c$, 'eq', 'true', 'P3');
