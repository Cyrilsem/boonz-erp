-- PRD-110 · P2.1 · leg 34 · FIXTURE FIRST (LAW 1)
--
-- Proves the contract that `engine_add_pod_v3` does NOT yet honour: the engine must size on the
-- shelf-grain in-stock velocity, must record WHERE that number came from, and must never emit a
-- silent 0 (LAW 5) nor invent a number (LAW 6).
--
-- All 9 assertions are ACCEPTANCE-GATED on the engine actually carrying the capability, so until
-- the engine migration lands they report as EXPECTED-RED, not as failures. ⭐ They are the ONLY
-- expected-red in the suite while that is true — see the EXECUTION-LOG for the captured baseline.
--
-- WHY THIS RIDES ON FIXTURE 14 INSTEAD OF A NEW FIXTURE (S-26 / leg-33 precedent):
--   `v_shelf_instock_velocity_split_v3` costs ~20 s per evaluation and machine-scoping does NOT
--   reduce that (its `vel` CTE is MATERIALIZED, so no predicate pushdown — measured leg 34:
--   one machine 19.77 s vs fleet-wide 19.8 s). A separate fixture would add a second full
--   evaluation to every suite run. Fixture 14 already runs the v3 engine, so the contract rides
--   on that one run and adds exactly ONE read of the object.
--
-- WHY AMZ-1046-2406-O1 JOINS THE PICKED SET:
--   Both branches must be exercised in one run or the assertions are vacuous (S-29).
--   Measured leg 34: MPMCC-1058-0000-R0 = 16/16 shelves `velocity_status='ok'` with a non-null
--   shelf velocity (the `instock_split` branch); AMZ-1046-2406-O1 = 16/16
--   `out_of_canonical_scope` with a NULL shelf velocity but a non-null `v_shelf_state.velocity_raw`
--   (the `weimi_raw_fallback` branch — D-13). Adding it costs no extra velocity evaluation.
--   Every pre-existing fixture-14 assertion is either scoped to `machine_name =
--   'MPMCC-1058-0000-R0'` (seq 30-33) or is run/absolute-scoped (seq 86-99), so widening the
--   picked set cannot move any of them. Verified before writing this file.
--
-- ⛔ L33-3: `scenario_sql` is a MUTABLE ROW. It is edited here by ANCHORED replace() with a RAISE
--    if the anchor has moved — never rebuilt from the migration file that created it.

BEGIN;

-- ── Guard, BEFORE and AFTER (header of 20260731010500) — run MANUALLY, not embedded ─────────────
--   WITH refs AS (SELECT DISTINCT (regexp_matches(check_sql,'value->>''([a-z0-9_]+)''','g'))[1] k
--                   FROM golden.assertions WHERE fixture_id = 14),
--        have AS (SELECT DISTINCT jsonb_object_keys(value) k FROM golden.scratch WHERE fixture_id = 14)
--   SELECT refs.k FROM refs LEFT JOIN have USING (k) WHERE have.k IS NULL;
--
-- ⚠️ leg-34 REFINEMENT: the expected result is NOT unconditionally empty. `error` is written into
--    the `engine_v3` scratch key ONLY when the v3 call raised, so on a clean run it is legitimately
--    absent and the guard reports it. `error` is the one known conditional key; ANY OTHER name in
--    the output is a real defect. That is why this guard is a manual read with a human reading the
--    key names, not an embedded RAISE — embedding it as written would fail every clean run.
--    Verified for this migration: leg 34 ran it before and after and got exactly {error}.

-- ── 1. Widen the picked set so BOTH velocity branches are exercised by the one engine run ───────
DO $edit$
DECLARE
  v_old text;
  v_new text;
  v_anchor_a CONSTANT text := E'FROM public.machines WHERE official_name = \'MPMCC-1058-0000-R0\';';
  v_anchor_b CONSTANT text := 'SELECT golden.run_engine_v3_if_built({{fixture_id}}, {{plan_date}}, 7);';
  v_cap      CONSTANT text :=
$vel$-- P2.1 (leg 34): ONE read of the shelf-grain velocity object for the whole fixture (S-26 /
-- RISK 88). Assertions 42 and 44 compare the engine's recorded provenance against THIS map;
-- everything else is internal to the engine's own output and costs nothing.
-- The anchor is recorded because it moves (RISK 53) - a later investigation must be able to
-- separate "the anchor moved" from "the engine changed" without guessing.
INSERT INTO golden.scratch (fixture_id, key, value)
WITH s AS MATERIALIZED (SELECT * FROM public.v_shelf_instock_velocity_split_v3),
     f AS (SELECT * FROM s WHERE machine_name IN ('MPMCC-1058-0000-R0','AMZ-1046-2406-O1'))
SELECT {{fixture_id}}, 'vel', jsonb_build_object(
  'scope_n',    (SELECT count(*) FROM f),
  'n_instock',  (SELECT count(velocity_instock_shelf) FROM f),
  'n_null',     (SELECT count(*) FILTER (WHERE velocity_instock_shelf IS NULL) FROM f),
  'vi_map',     COALESCE((SELECT jsonb_object_agg(shelf_id::text, velocity_instock_shelf)
                            FROM f WHERE velocity_instock_shelf IS NOT NULL), '{}'::jsonb),
  't_anchor',   (SELECT max(t_anchor)::text FROM s));

$vel$;
BEGIN
  SELECT scenario_sql INTO v_old FROM golden.fixtures WHERE fixture_id = 14;

  IF position(v_anchor_a IN v_old) = 0 THEN
    RAISE EXCEPTION 'fixture 14 anchor A moved - refusing to edit scenario_sql blind (L33-3)';
  END IF;
  IF position(v_anchor_b IN v_old) = 0 THEN
    RAISE EXCEPTION 'fixture 14 anchor B moved - refusing to edit scenario_sql blind (L33-3)';
  END IF;

  v_new := replace(v_old, v_anchor_a,
             E'FROM public.machines\n WHERE official_name IN (\'MPMCC-1058-0000-R0\',\'AMZ-1046-2406-O1\');');
  v_new := replace(v_new, v_anchor_b, v_cap || v_anchor_b);

  UPDATE golden.fixtures
     SET scenario_sql = v_new,
         name = 'Sensor lie (WEIMI count > capacity) + velocity provenance'
   WHERE fixture_id = 14;
END $edit$;

-- ── 2. The contract (9 assertions, seq 40-48) ───────────────────────────────────────────────────
-- Gate: TRUE only once engine_add_pod_v3 actually carries the capability. Until then these are
-- EXPECTED-RED by design, never silent passes. Note run_fixture fails a broken gate CLOSED-to-open
-- (treats it as binding), so a typo here surfaces as a hard failure, not as a hidden green.
INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required, acceptance_gate_sql)
VALUES

(14, 40,
 'v3 VELOCITY PROVENANCE (SHADOW): every shadow line records an explicit velocity_source. LAW 5 - the engine may not size on a number whose origin it cannot name.',
 $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (prs.reasoning->>'velocity_source') IS NULL)::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 41,
 'v3 VELOCITY PROVENANCE: velocity_source is drawn ONLY from the declared vocabulary (instock_split | weimi_raw_fallback | none_no_signal). A new branch must declare itself here before it can ship.',
 $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND COALESCE(prs.reasoning->>'velocity_source','~')
             NOT IN ('instock_split','weimi_raw_fallback','none_no_signal'))::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 42,
 'v3 VELOCITY PROVENANCE: the classification is EXACT, not approximate - a line reads instock_split IFF v_shelf_instock_velocity_split_v3 carries a non-null velocity_instock_shelf for that shelf (0 mismatches in EITHER direction). Compared against the single scratch read, not a second evaluation (S-26).',
 $q$SELECT CASE
      WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run'
      WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='vel')
        THEN 'no_vel_scratch'
      ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       CROSS JOIN (SELECT COALESCE(value->'vi_map','{}'::jsonb) AS m
                     FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='vel') g
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (g.m ? prs.shelf_id::text)
             IS DISTINCT FROM (prs.reasoning->>'velocity_source' = 'instock_split'))::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 43,
 'v3 VELOCITY PROVENANCE: velocity_effective_daily is present and non-negative on EVERY line. LAW 5 - a shelf the engine cannot measure still gets a line and an explicit number, never a NULL and never a silent absence.',
 $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND ( (prs.reasoning->>'velocity_effective_daily') IS NULL
            OR (prs.reasoning->>'velocity_effective_daily')::numeric < 0 ))::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 44,
 'v3 VELOCITY PROVENANCE: an instock_split line uses the shelf-grain in-stock velocity EXACTLY as the canonical object published it - no rescaling, no rounding, no re-derivation (LAW 6).',
 $q$SELECT CASE
      WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run'
      WHEN NOT EXISTS (SELECT 1 FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='vel')
        THEN 'no_vel_scratch'
      ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       CROSS JOIN (SELECT COALESCE(value->'vi_map','{}'::jsonb) AS m
                     FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='vel') g
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND prs.reasoning->>'velocity_source' = 'instock_split'
         AND (prs.reasoning->>'velocity_effective_daily')::numeric
             IS DISTINCT FROM (g.m->>prs.shelf_id::text)::numeric)::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 45,
 'v3 VELOCITY PROVENANCE: a weimi_raw_fallback line uses v_shelf_state.velocity_raw EXACTLY (D-10 answer / LAW 6) - the WEIMI-derived rate, never an archetype guess and never an invented number.',
 $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
        JOIN public.v_shelf_state s ON s.shelf_id = prs.shelf_id
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND prs.reasoning->>'velocity_source' = 'weimi_raw_fallback'
         AND (prs.reasoning->>'velocity_effective_daily')::numeric
             IS DISTINCT FROM s.velocity_raw::numeric)::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 46,
 'v3 SIZING UNIT CONTRACT (S-13): cover_units = ceil(velocity_effective_daily x days_cover). velocity_instock is a DAILY rate by construction - any /30 or x30 anywhere in the chain reds this. v19 disagrees with itself on exactly this point; v3 may not.',
 $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (prs.reasoning->>'cover_units')::int
             IS DISTINCT FROM ceil((prs.reasoning->>'velocity_effective_daily')::numeric
                                   * prs.days_cover)::int)::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 47,
 'v3 VELOCITY PROVENANCE: the pod_refills_shadow.velocity_instock COLUMN is non-null on EXACTLY the instock_split lines. Before P2.1 this column was written through verbatim from a column that is always NULL - this assertion is what makes it readable as canonical.',
 $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT count(*) FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}})
         AND (prs.velocity_instock IS NOT NULL)
             IS DISTINCT FROM (prs.reasoning->>'velocity_source' = 'instock_split'))::text END$q$,
 'eq', '0', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$),

(14, 48,
 'VACUOUS-GREEN GUARD (S-29): this run actually exercised BOTH velocity branches - at least one instock_split line AND at least one weimi_raw_fallback line. Without this, seq 42-47 could all pass on a population of zero.',
 $q$SELECT CASE WHEN golden.v3_run_id({{fixture_id}}) IS NULL THEN 'no_v3_run' ELSE (
      SELECT (count(*) FILTER (WHERE prs.reasoning->>'velocity_source' = 'instock_split') > 0
          AND count(*) FILTER (WHERE prs.reasoning->>'velocity_source' = 'weimi_raw_fallback') > 0)
        FROM public.pod_refills_shadow prs
       WHERE prs.run_id = golden.v3_run_id({{fixture_id}}))::text END$q$,
 'eq', 'true', true, 'P2',
 $g$SELECT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                    WHERE n.nspname='public' AND p.proname='engine_add_pod_v3'
                      AND p.prosrc LIKE '%velocity_source%')$g$);

COMMIT;
