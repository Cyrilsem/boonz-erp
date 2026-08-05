-- PRD-110 P3.3 — fixture 43 corrective: THE EXPIRY GUARD WAS MEASURED FROM THE WRONG DATE.
--
-- ⛔ S-75. The fixture anchors on the synthetic plan_date 2030-02-13 (LAW 12 requires a
--    synthetic date). Real oldest_expiry_est values across the fleet run 2026-08-26 to
--    2027-11-10. So `(expiry - DATE '2030-02-13') >= projected_days_to_sell` is NEGATIVE for
--    EVERY shelf whose expiry is known, and the guard silently collapsed into "keep only
--    shelves whose expiry is NULL": 52 of 802 candidate pairs, and the LAW-7 assertion would
--    have gone GREEN while blocking nothing real.
--    Measured from the real world instead, the same guard admits 765 pairs and BLOCKS 37 that
--    genuinely cannot clear before they expire. That is the rule doing its job.
--
-- ⭐ THE GENERAL FORM, and it is the transferable part: a synthetic far-future plan_date does
--    not make a real-world date comparison FAIL. It makes it stop binding, and a filter that
--    stops binding still returns rows, so the fixture still goes green. Same family as S-70
--    (a violation count over an absent subject is 0) wearing a calendar instead of a NULL.
--
-- THE FIX, and why it is also correct in production: expiry risk is a physical property of
--    stock in hand NOW, and the heartbeat generates proposals NOW for review within days.
--    p_plan_date is the batch key, not the moment the stock moves. The horizon is therefore
--    measured from CURRENT_DATE in both the fixture and the function.
--
-- Seq 19 is NEW and is a sensor FOR the sensor: it fails if no candidate pair is being
--    blocked by expiry at all, which is the only way seq 30 could quietly go vacuous again.

UPDATE golden.fixtures SET scenario_sql = $sc$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DELETE FROM public.rotation_proposals_v3 WHERE plan_date = {{plan_date}};

CREATE TEMP TABLE f43_p ON COMMIT DROP AS
SELECT rot_slow_velocity_per_day AS slow, rot_min_source_qty AS minqty,
       rot_min_speedup AS spd, rot_min_fit_score AS minfit, rot_max_proposals AS maxprop
FROM public.refill_policy_params LIMIT 1;

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

CREATE TEMP TABLE f43_all ON COMMIT DROP AS
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
  AND LEAST(src.stock, tgt.headroom) > 0;

CREATE TEMP TABLE f43_pair ON COMMIT DROP AS
WITH kept AS (
  SELECT * FROM f43_all
  WHERE fit >= (SELECT minfit FROM f43_p)
    -- ⭐ S-75: measured from the REAL WORLD, never from the synthetic plan_date.
    AND (s_exp IS NULL OR (s_exp - CURRENT_DATE) >= pdays)
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
  'all_pairs',         (SELECT count(*) FROM f43_all),
  -- ⭐ THE SENSOR FOR THE SENSOR (S-75). Pairs that clear every other test and are stopped
  --    ONLY by expiry. If this is 0, seq 30 has stopped binding.
  'blocked_by_expiry', (SELECT count(*) FROM f43_all
                          WHERE fit >= (SELECT minfit FROM f43_p)
                            AND s_exp IS NOT NULL AND (s_exp - CURRENT_DATE) < pdays),
  'expected_rows',     (SELECT count(*) FROM f43_pair),
  'distinct_src',      (SELECT count(DISTINCT s_shelf) FROM f43_pair),
  'distinct_tgt',      (SELECT count(DISTINCT t_shelf) FROM f43_pair),
  'maxprop',           (SELECT maxprop FROM f43_p),
  'mtv_before',        (SELECT count(*) FROM public.machines_to_visit),
  'live_plan_before',  (SELECT count(*) FROM public.pod_refill_plan),
  'rpo_before',        (SELECT count(*) FROM public.refill_plan_output));

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'propose_rotations_v3'
                                     AND pronamespace = 'public'::regnamespace) THEN
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
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 43, 'out', COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)
      FROM public.propose_rotations_v3(DATE '2030-02-13') r
    $x$;
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
WHERE fixture_id = 43;

-- Seq 30 re-based on the real world. WRAPPER PRESERVED, comparison corrected: this makes the
-- assertion STRONGER (it now has 37 real violations available to catch), never weaker.
UPDATE golden.assertions SET check_sql = $a$SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id=43 AND key='out')
   THEN 'NO_ROTATION_OUTPUT' ELSE (
     SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value) e
     JOIN public.v_shelf_state v ON v.shelf_id = (e->>'source_shelf_id')::uuid
     WHERE s.fixture_id=43 AND s.key='out'
       AND v.oldest_expiry_est IS NOT NULL
       AND (v.oldest_expiry_est::date - CURRENT_DATE) < (e->>'projected_days_to_sell')::numeric) END$a$
WHERE fixture_id = 43 AND seq = 30;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(43, 19, 'S-75 SENSOR FOR THE SENSOR: candidate pairs exist RIGHT NOW that pass every other test and are blocked ONLY because the stock would expire before it could clear. If this ever reads 0, seq 30 has stopped binding and the expiry rule is decorative -- it does NOT mean the fleet stopped having expiring stock',
 $a$SELECT COALESCE((SELECT (value->>'blocked_by_expiry') FROM golden.scratch WHERE fixture_id=43 AND key='pop'), '-1')$a$,
 'gt', '0', true, 'P3'),
(43, 52, 'S-75 DRIFT GUARD: the fixture population is drawn from a real candidate pool, not from the handful of shelves whose expiry happens to be unknown',
 $a$SELECT COALESCE((SELECT (value->>'all_pairs') FROM golden.scratch WHERE fixture_id=43 AND key='pop'), '-1')$a$,
 'gt', '100', true, 'P3');
