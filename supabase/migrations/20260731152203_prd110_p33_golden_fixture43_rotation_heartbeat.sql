-- PRD-110 P3.3 — golden fixture 43: rotation heartbeat.
-- Authored RED, before propose_rotations_v3 exists (LAW 1).
--
-- ⭐ S-70 APPLIED AT AUTHORING TIME. Every violation-counting assertion below is wrapped so
--    that ABSENCE of function output is a distinct FAILING value ('NO_ROTATION_OUTPUT', or
--    '-1' where the op is gt/gte) rather than a vacuous 0. Fixture 42's RED had ELEVEN
--    assertions passing against a function that did not exist; this fixture is written so
--    that cannot happen even once.

DELETE FROM golden.assertions WHERE fixture_id = 43;
DELETE FROM golden.fixtures   WHERE fixture_id = 43;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  43,
  'Rotation heartbeat proposes moving stranded slow-moving stock to a machine where the same product demonstrably sells, never over-commits a destination shelf across proposals, never proposes stock that expires before it could clear, and writes proposals that stay behind the CS gate (P3.3)',
  'PRD-110 BUILD-SPEC line 91. Reconnaissance for this leg found that P3.3 was BUILT ONCE AND RETIRED: public.rotation_proposals does not exist, its 22 rows live in graveyard.rotation_proposals, and three SECURITY DEFINER functions (propose_rotation_plan, apply_rotation_proposal, reject_rotation_proposal) still reference the dead public path and throw on every call while retaining anon EXECUTE (S-74). This fixture pins the v3 replacement.',
  'P3',
  DATE '2030-02-13',
  true,
  'failing_expected',
  'P3.3. propose_rotations_v3 WRITES (VOLATILE, SECURITY DEFINER) - unlike the P3.5 picker - so LAW 12 is pinned explicitly: seq 46/47 prove no live plan table and no machines_to_visit row moved. Velocity comes from v_shelf_instock_velocity_split_v3, the canonical owner; NEVER from v_shelf_state.velocity_instock, which is STILL a NULL placeholder on all 656 shelves post-P2.1 (S-73). The fixture owns plan_date 2030-02-13 and deletes its own rows at scenario start, so absolute counts are legitimate here (S-58). BUDGET: reads the ~20 s velocity object once itself plus once per function call (3 calls) = expect ~80-100 s.',
$sc$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
-- The fixture OWNS this plan_date. Clearing it makes absolute counts legitimate and the
-- whole scenario re-runnable (S-58: absolute counts on append-only tables are not idempotent).
DELETE FROM public.rotation_proposals_v3 WHERE plan_date = {{plan_date}};

CREATE TEMP TABLE f43_p ON COMMIT DROP AS
SELECT rot_slow_velocity_per_day AS slow, rot_min_source_qty AS minqty,
       rot_min_speedup AS spd, rot_min_fit_score AS minfit, rot_max_proposals AS maxprop
FROM public.refill_policy_params LIMIT 1;

-- ---------------------------------------------------------------------------
-- (1) INDEPENDENT RECOMPUTATION from base tables. The function is never asked to
--     confirm its own arithmetic. Assertions 20-27 compare this row for row.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE f43_sh ON COMMIT DROP AS
WITH vel AS (
  SELECT shelf_id, velocity_instock_shelf AS v, velocity_status
  FROM public.v_shelf_instock_velocity_split_v3
)
SELECT s.machine_id, s.shelf_id, s.pod_product_id, s.sourcing,
       COALESCE(s.current_stock, 0) AS stock,
       COALESCE(s.max_stock, 0)     AS cap,
       GREATEST(COALESCE(s.max_stock,0) - COALESCE(s.current_stock,0), 0) AS headroom,
       vel.v, vel.velocity_status,
       s.oldest_expiry_est::date AS exp_date
FROM public.v_shelf_state s
LEFT JOIN vel ON vel.shelf_id = s.shelf_id
WHERE s.pod_product_id IS NOT NULL;

CREATE TEMP TABLE f43_pair ON COMMIT DROP AS
WITH pairs AS (
  SELECT src.shelf_id AS s_shelf, src.machine_id AS s_mach, src.pod_product_id AS pod,
         src.stock AS s_stock, src.v AS s_v, src.exp_date AS s_exp,
         tgt.shelf_id AS t_shelf, tgt.machine_id AS t_mach, tgt.v AS t_v,
         tgt.headroom AS t_head,
         LEAST(src.stock, tgt.headroom) AS qty,
         round(tgt.v / GREATEST(src.v, (SELECT slow FROM f43_p)/10.0), 4) AS fit,
         round(LEAST(src.stock, tgt.headroom)::numeric / tgt.v, 2)        AS pdays
  FROM f43_sh src
  JOIN f43_sh tgt
    ON  tgt.pod_product_id = src.pod_product_id
    AND tgt.machine_id <> src.machine_id
  WHERE src.velocity_status = 'ok'
    AND src.v < (SELECT slow FROM f43_p)
    AND src.stock >= (SELECT minqty FROM f43_p)
    AND src.sourcing IS DISTINCT FROM 'venue'
    AND tgt.velocity_status = 'ok'
    AND tgt.v > 0
    AND tgt.headroom > 0
    AND tgt.sourcing IS DISTINCT FROM 'venue'
    AND tgt.v >= src.v * (SELECT spd FROM f43_p)
    AND LEAST(src.stock, tgt.headroom) > 0
),
kept AS (
  SELECT * FROM pairs
  WHERE fit >= (SELECT minfit FROM f43_p)
    -- LAW 7 in its preventive form: never propose moving stock that expires before it
    -- could plausibly clear at the destination.
    AND (s_exp IS NULL OR (s_exp - {{plan_date}}::date) >= pdays)
),
best_src AS (
  SELECT *, row_number() OVER (PARTITION BY s_shelf ORDER BY fit DESC, qty DESC, t_shelf) rn
  FROM kept
),
best_tgt AS (
  SELECT *, row_number() OVER (PARTITION BY t_shelf ORDER BY fit DESC, qty DESC, s_shelf) rn2
  FROM best_src WHERE rn = 1
)
SELECT s_shelf, s_mach, pod, s_stock, s_v, s_exp, t_shelf, t_mach, t_v, t_head, qty, fit, pdays
FROM best_tgt WHERE rn2 = 1
ORDER BY fit DESC, qty DESC, s_shelf, t_shelf
LIMIT (SELECT maxprop FROM f43_p);

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'indep_' || s_shelf::text || '_' || t_shelf::text, jsonb_build_object(
  'qty', qty, 'fit', fit, 'pdays', pdays, 's_mach', s_mach, 't_mach', t_mach, 'pod', pod)
FROM f43_pair;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'pop', jsonb_build_object(
  'shelves_with_pod',  (SELECT count(*) FROM f43_sh),
  'vel_ok',            (SELECT count(*) FROM f43_sh WHERE velocity_status = 'ok'),
  'vel_null',          (SELECT count(*) FROM f43_sh WHERE v IS NULL),
  'source_candidates', (SELECT count(*) FROM f43_sh WHERE velocity_status='ok'
                          AND v < (SELECT slow FROM f43_p)
                          AND stock >= (SELECT minqty FROM f43_p)
                          AND sourcing IS DISTINCT FROM 'venue'),
  'target_candidates', (SELECT count(*) FROM f43_sh WHERE velocity_status='ok' AND v > 0
                          AND headroom > 0 AND sourcing IS DISTINCT FROM 'venue'),
  'expected_rows',     (SELECT count(*) FROM f43_pair),
  'distinct_src',      (SELECT count(DISTINCT s_shelf) FROM f43_pair),
  'distinct_tgt',      (SELECT count(DISTINCT t_shelf) FROM f43_pair),
  'maxprop',           (SELECT maxprop FROM f43_p),
  'mtv_before',        (SELECT count(*) FROM public.machines_to_visit),
  'live_plan_before',  (SELECT count(*) FROM public.pod_refill_plan),
  'rpo_before',        (SELECT count(*) FROM public.refill_plan_output));

-- ---------------------------------------------------------------------------
-- (2) THE FUNCTION UNDER TEST, guarded so the RED reports missing evidence
--     instead of aborting the scenario.
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'propose_rotations_v3'
                                     AND pronamespace = 'public'::regnamespace) THEN
    -- dry run FIRST: it must compute a full answer and write nothing.
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'out_dry', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
      FROM public.propose_rotations_v3(DATE '2030-02-13', NULL, true) r
    $x$;
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'rows_after_dry', to_jsonb((SELECT count(*) FROM public.rotation_proposals_v3
                                              WHERE plan_date = DATE '2030-02-13'))
    $x$;
    -- the real run
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'out', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
      FROM public.propose_rotations_v3(DATE '2030-02-13') r
    $x$;
    -- idempotency: a second identical heartbeat must add nothing
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'out_again', to_jsonb((SELECT count(*) FROM public.propose_rotations_v3(DATE '2030-02-13') r))
    $x$;
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'rows_after', to_jsonb((SELECT count(*) FROM public.rotation_proposals_v3
                                          WHERE plan_date = DATE '2030-02-13'))
    $x$;
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'out_limit3', to_jsonb((SELECT count(*) FROM public.propose_rotations_v3(DATE '2030-02-13', 3) r))
    $x$;
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'statuses', to_jsonb((SELECT count(*) FROM public.rotation_proposals_v3
                                        WHERE plan_date = DATE '2030-02-13' AND status <> 'pending'))
    $x$;
  END IF;
END
$do$;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'mtv_after',       (SELECT count(*) FROM public.machines_to_visit),
  'live_plan_after', (SELECT count(*) FROM public.pod_refill_plan),
  'rpo_after',       (SELECT count(*) FROM public.refill_plan_output));
$sc$
);
