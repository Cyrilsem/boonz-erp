-- PRD-110 P3.1b · golden fixture 40 — the SUPPLY LADDER resolves every gap, and never silently to qty 0
-- LAW 1: applied and run RED before resolve_supply_ladder_v3 exists.
-- plan_date anchor = DATE '2030-01-01' + 40 = 2030-02-10 (free; 2030-02-09 is fixture 39's).
--
-- BUILD-SPEC line 88 ladder, in order:
--   variant -> substitute product -> alt WH (transfer) -> sibling M2M (overstock donor)
--   -> spot_buy_candidate -> blocked_demand.
-- "Every rung logged in reasoning; silent qty-0 forbidden (assert)."
--
-- LIVE POPULATION (measured leg 56, before a line of the function was written):
--   20 open blocked_demand rows / 107 units / 8 machines, all plan_date 2026-07-30.
--
-- TWO ANCHORS ON ONE MACHINE (148c4fcf, co_managed, primary WH_MCC, secondary WH_CENTRAL).
-- They are deliberately the two DIFFERENT ways a gap can be real:
--
--  (A) SENTINEL TRAP   Fade Fit 733dcd39, shelf A04 48907909, 7 units blocked.
--      Its WH "stock" is 999-unit VOXSOURCE sentinel rows (40 rows / 39,463 phantom units
--      fleet-wide, wh_location='VOX_SOURCED', expiry 2099-12-31). A ladder that counts those
--      as supply "rescues" this gap with stock that does not exist. It MUST NOT.
--
--  (B) CONTENTION      Vitamin Well ef8f3ea9, shelf A16 cfed8e4f, 8 units blocked.
--      Engine recorded wh_avail=13 and need_raw=8 -- stock EXISTS and it still clamped
--      blocked_no_wh, because reasoning->>'prior_need_pool' = 40: the engine allocates a
--      shared WH pool fleet-wide in priority order, so wh_available_pod is GROSS pod stock,
--      not what remains. A ladder that reads gross stock double-allocates what the plan
--      has already spent. Net-of-claims accounting is therefore load-bearing, not polish.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes,
   enabled, baseline_status)
VALUES (
  40,
  'Supply ladder resolves every gap through all six rungs in order, logs every rung, excludes sentinel stock, nets off prior plan claims, and never returns a silent qty 0 (P3.1b)',
  'PRD-110 leg 56: 20 open blocked_demand rows on 2026-07-30. Fade Fit blocked while 7,992 phantom sentinel units sit in v_wh_pickable; Vitamin Well blocked with wh_avail=13 vs need_raw=8 because prior_need_pool=40 had already claimed the shared pool.',
  'P3',
  DATE '2030-02-10',
$SCEN$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (1) POPULATION + SUPPLY EVIDENCE, derived INDEPENDENTLY of the function under
--     test, straight from base tables. This is what lets the assertions below
--     say "the sentinel pool is phantom" and "real stock is already claimed"
--     without asking the function to confirm its own arithmetic.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH anchors(tag, machine_id, shelf_id, pod_product_id, qty_needed) AS (
  VALUES ('A', '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,
               '48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,
               '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid, 7),
         ('B', '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,
               'cfed8e4f-7cba-4129-90ac-56ab0af0cfa8'::uuid,
               'ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239'::uuid, 8)
),
-- product_mapping fan-out guard: DISTINCT the variants BEFORE any stock is summed.
-- A pod carrying both a global and a machine-specific mapping row would otherwise
-- have its warehouse stock counted twice (the documented 07-30 anti-pattern).
variants AS (
  SELECT a.tag, a.machine_id, v.boonz_product_id
  FROM anchors a
  CROSS JOIN LATERAL (
    SELECT DISTINCT pm.boonz_product_id
    FROM public.product_mapping pm
    WHERE pm.pod_product_id = a.pod_product_id
      AND pm.status = 'Active'
      AND (pm.machine_id = a.machine_id OR pm.machine_id IS NULL)
  ) v
),
supply AS (
  SELECT vr.tag,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
              AND w.warehouse_id = mc.primary_warehouse_id), 0)            AS real_primary,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
              AND w.warehouse_id IS DISTINCT FROM mc.primary_warehouse_id), 0) AS real_other,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id LIKE 'VOXSOURCE-%'), 0)                       AS sentinel_units
  FROM variants vr
  JOIN public.machines mc ON mc.machine_id = vr.machine_id
  LEFT JOIN public.v_wh_pickable w
         ON w.boonz_product_id = vr.boonz_product_id
        AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = vr.machine_id)
  GROUP BY vr.tag
)
SELECT {{fixture_id}}, k, v FROM (
  SELECT 'A_real_primary'   AS k, (SELECT real_primary::text   FROM supply WHERE tag='A') AS v
  UNION ALL SELECT 'A_real_other',    (SELECT real_other::text    FROM supply WHERE tag='A')
  UNION ALL SELECT 'A_sentinel',      (SELECT sentinel_units::text FROM supply WHERE tag='A')
  UNION ALL SELECT 'B_real_primary',  (SELECT real_primary::text   FROM supply WHERE tag='B')
  UNION ALL SELECT 'B_real_other',    (SELECT real_other::text     FROM supply WHERE tag='B')
  UNION ALL SELECT 'B_sentinel',      (SELECT sentinel_units::text FROM supply WHERE tag='B')
  UNION ALL SELECT 'A_variants',      (SELECT count(*)::text FROM variants WHERE tag='A')
  UNION ALL SELECT 'B_variants',      (SELECT count(*)::text FROM variants WHERE tag='B')
) s;

-- ---------------------------------------------------------------------------
-- (2) THE FUNCTION UNDER TEST. Guarded by to_regprocedure so that during the RED
--     baseline the scenario still completes and every population fact above lands
--     in scratch -- the RED then isolates exactly the object being built.
--     One call per anchor, whole result stored, so all assertions read ONE
--     consistent snapshot (fixture 39's idiom; golden.scratch PK is (fixture_id,key)).
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF to_regprocedure('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)') IS NOT NULL THEN
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 40, 'ladder_' || t.tag,
             public.resolve_supply_ladder_v3(DATE '2026-07-30', t.mid, t.sid, t.pid, t.need, 3)::text
      FROM (VALUES
        ('A','148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,'733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid,7),
        ('B','148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'cfed8e4f-7cba-4129-90ac-56ab0af0cfa8'::uuid,'ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239'::uuid,8)
      ) AS t(tag,mid,sid,pid,need)
    $x$;
  END IF;
END
$do$;
$SCEN$,
  'P3.1b. Anchors: A = sentinel trap (Fade Fit), B = contention despite real stock (Vitamin Well). Both on machine 148c4fcf, plan_date 2026-07-30. Ladder is READ-ONLY and advisory: it writes nothing, so LAW 4 and LAW 12 are untouched by construction.',
  true,
  'failing_expected'
);

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES

-- ---- drift guards: if any of these move, every number below means something else ----
(40, 1, 'Drift guard: {{plan_date}} still renders as the fixture-40 anchor 2030-02-10',
 $q$SELECT {{plan_date}}::text$q$, 'eq', '2030-02-10', true, 'P3'),

(40, 2, 'Anchor guard (A): Fade Fit 733dcd39 is still categorised Protein & Health Bars',
 $q$SELECT product_category FROM public.pod_products
    WHERE pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'$q$,
 'eq', 'Protein & Health Bars', true, 'P3'),

(40, 3, 'Anchor guard (B): Vitamin Well ef8f3ea9 is still categorised Vitamin & Health Drinks',
 $q$SELECT product_category FROM public.pod_products
    WHERE pod_product_id = 'ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239'$q$,
 'eq', 'Vitamin & Health Drinks', true, 'P3'),

(40, 4, 'Anchor guard: machine 148c4fcf is co_managed, primary WH_MCC, secondary WH_CENTRAL',
 $q$SELECT operating_model || '|' || primary_warehouse_id::text || '|' || secondary_warehouse_id::text
    FROM public.machines WHERE machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'$q$,
 'eq', 'co_managed|4fcfb52c-271f-4aa7-a373-3495e3271cd3|4bebef68-9e36-4a5c-9c2c-142f8dbdae85', true, 'P3'),

(40, 5, 'Sentinel pool still exists and is still phantom (VOXSOURCE batches, 2099 expiry) - the trap anchor A depends on',
 $q$SELECT count(*)::text FROM public.v_wh_pickable
    WHERE batch_id LIKE 'VOXSOURCE-%' AND expiration_date = DATE '2099-12-31'$q$,
 'gte', '20', true, 'P3'),

-- ---- population evidence, computed independently of the function under test ----
(40, 6, 'NON-VACUITY (A): Fade Fit has REAL sentinel supply on this machine - so a naive ladder WOULD have rescued it',
 $q$SELECT value FROM golden.scratch WHERE fixture_id = 40 AND key = 'A_sentinel'$q$,
 'gte', '999', true, 'P3'),

(40, 7, 'NON-VACUITY (A): Fade Fit has ZERO real (non-sentinel) primary-WH stock - so the ONLY way to rescue it is phantom',
 $q$SELECT value FROM golden.scratch WHERE fixture_id = 40 AND key = 'A_real_primary'$q$,
 'eq', '0', true, 'P3'),

(40, 8, 'NON-VACUITY (B): Vitamin Well HAS real primary-WH stock - so anchor B is blocked by contention, not by absence',
 $q$SELECT value FROM golden.scratch WHERE fixture_id = 40 AND key = 'B_real_primary'$q$,
 'gte', '1', true, 'P3'),

(40, 9, 'Fan-out guard: anchor B resolves to a DEDUPED variant set (>=1), not a per-mapping-row multiplication',
 $q$SELECT value FROM golden.scratch WHERE fixture_id = 40 AND key = 'B_variants'$q$,
 'gte', '1', true, 'P3'),

(40, 10, 'The live gap both anchors come from is real: >=15 open blocked_demand rows on 2026-07-30',
 $q$SELECT count(*)::text FROM public.blocked_demand
    WHERE plan_date = DATE '2026-07-30' AND resolved_at IS NULL$q$,
 'gte', '15', true, 'P3'),

-- ---- the object under test: existence and shape ----
(40, 11, 'resolve_supply_ladder_v3 EXISTS with the specified signature',
 $q$SELECT CASE WHEN to_regprocedure('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)')
              IS NULL THEN 'MISSING' ELSE 'PRESENT' END$q$,
 'eq', 'PRESENT', true, 'P3'),

(40, 12, 'It is STABLE and writes nothing (read-only advisory: LAW 4 and LAW 12 untouched by construction)',
 $q$SELECT provolatile::text FROM pg_proc
    WHERE oid = to_regprocedure('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)')$q$,
 'eq', 's', true, 'P3'),

(40, 13, 'Scenario captured a ladder result for anchor A',
 $q$SELECT count(*)::text FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'eq', '1', true, 'P3'),

(40, 14, 'Scenario captured a ladder result for anchor B',
 $q$SELECT count(*)::text FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', '1', true, 'P3'),

-- ---- BUILD-SPEC line 88: EVERY rung logged, in order ----
(40, 15, 'BUILD-SPEC 88: all SIX rungs are logged for anchor A, none skipped silently',
 $q$SELECT jsonb_array_length((value::jsonb)->'ladder')::text
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'eq', '6', true, 'P3'),

(40, 16, 'BUILD-SPEC 88: all SIX rungs are logged for anchor B',
 $q$SELECT jsonb_array_length((value::jsonb)->'ladder')::text
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', '6', true, 'P3'),

(40, 17, 'BUILD-SPEC 88: the rungs are logged in the SPECIFIED ORDER, not an arbitrary one',
 $q$SELECT string_agg(r->>'rung', '>' ORDER BY (r->>'rung_no')::int)
    FROM golden.scratch s, jsonb_array_elements((s.value::jsonb)->'ladder') r
    WHERE s.fixture_id = 40 AND s.key = 'ladder_A'$q$,
 'eq', 'variant>substitute>alt_wh>m2m>spot_buy>blocked_demand', true, 'P3'),

(40, 18, 'Every logged rung carries an explicit reason string - no rung is logged as a bare verdict',
 $q$SELECT count(*)::text
    FROM golden.scratch s, jsonb_array_elements((s.value::jsonb)->'ladder') r
    WHERE s.fixture_id = 40 AND s.key = 'ladder_B'
      AND COALESCE(r->>'reason','') = ''$q$,
 'eq', '0', true, 'P3'),

-- ---- LAW 5 / BUILD-SPEC 88: silent qty-0 is forbidden ----
(40, 19, 'LAW 5 (A): the ladder always names a terminal rung - never NULL, never unresolved',
 $q$SELECT CASE WHEN (value::jsonb)->>'resolved_rung' IS NULL THEN 'NULL' ELSE 'NAMED' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'eq', 'NAMED', true, 'P3'),

(40, 20, 'LAW 5 (B): the ladder always names a terminal rung',
 $q$SELECT CASE WHEN (value::jsonb)->>'resolved_rung' IS NULL THEN 'NULL' ELSE 'NAMED' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', 'NAMED', true, 'P3'),

(40, 21, 'LAW 5 (A): a qty-0 outcome is ONLY legal when the terminal rung is blocked_demand',
 $q$SELECT CASE WHEN (value::jsonb)->>'resolved_rung' <> 'blocked_demand'
                 AND ((value::jsonb)->>'qty_resolved')::int = 0
            THEN 'SILENT_ZERO' ELSE 'OK' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'eq', 'OK', true, 'P3'),

(40, 22, 'LAW 5 (B): a qty-0 outcome is ONLY legal when the terminal rung is blocked_demand',
 $q$SELECT CASE WHEN (value::jsonb)->>'resolved_rung' <> 'blocked_demand'
                 AND ((value::jsonb)->>'qty_resolved')::int = 0
            THEN 'SILENT_ZERO' ELSE 'OK' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', 'OK', true, 'P3'),

(40, 23, 'The function self-asserts the no-silent-zero invariant rather than leaving it to the caller',
 $q$SELECT (value::jsonb)->>'assert_no_silent_qty0'
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'eq', 'true', true, 'P3'),

-- ---- THE SENTINEL TRAP (anchor A) - the assertion this fixture exists for ----
(40, 24, 'SENTINEL TRAP: anchor A is NOT rescued by rung 1 - 999-unit phantom stock is not supply',
 $q$SELECT CASE WHEN (value::jsonb)->>'resolved_rung' = 'variant' THEN 'PHANTOM_RESCUE' ELSE 'OK' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'eq', 'OK', true, 'P3'),

(40, 25, 'SENTINEL TRAP: anchor A is NOT rescued by rung 3 (alt WH transfer) on phantom stock either',
 $q$SELECT CASE WHEN (value::jsonb)->>'resolved_rung' = 'alt_wh' THEN 'PHANTOM_RESCUE' ELSE 'OK' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'eq', 'OK', true, 'P3'),

(40, 26, 'SENTINEL TRAP: the excluded phantom units are REPORTED, not silently dropped - CS can see what was ignored',
 $q$SELECT (((value::jsonb)->'supply')->>'sentinel_units_excluded')::int::text
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_A'$q$,
 'gte', '999', true, 'P3'),

(40, 27, 'SENTINEL TRAP: rung 1 for anchor A reports ZERO available, consistent with the independent population read',
 $q$SELECT (r->>'qty_available')::int::text
    FROM golden.scratch s, jsonb_array_elements((s.value::jsonb)->'ladder') r
    WHERE s.fixture_id = 40 AND s.key = 'ladder_A' AND r->>'rung' = 'variant'$q$,
 'eq', '0', true, 'P3'),

-- ---- NET-OF-CLAIMS (anchor B) - the prior_need_pool finding made testable ----
(40, 28, 'NET-OF-CLAIMS: the ladder reports what the plan has ALREADY claimed for this pod',
 $q$SELECT CASE WHEN (((value::jsonb)->'supply')->>'claimed_units') IS NULL THEN 'MISSING' ELSE 'REPORTED' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', 'REPORTED', true, 'P3'),

(40, 29, 'NET-OF-CLAIMS: net availability never exceeds gross real stock (the double-allocation guard)',
 $q$SELECT CASE WHEN (((value::jsonb)->'supply')->>'net_primary')::numeric
                 > (((value::jsonb)->'supply')->>'gross_real_primary')::numeric
            THEN 'OVER_ALLOCATED' ELSE 'OK' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', 'OK', true, 'P3'),

(40, 30, 'NET-OF-CLAIMS: net availability is never negative',
 $q$SELECT CASE WHEN (((value::jsonb)->'supply')->>'net_primary')::numeric < 0
                  OR (((value::jsonb)->'supply')->>'net_other')::numeric < 0
            THEN 'NEGATIVE' ELSE 'OK' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', 'OK', true, 'P3'),

(40, 31, 'NET-OF-CLAIMS: the allocation model is NAMED in the output, not left as a hidden assumption',
 $q$SELECT CASE WHEN (((value::jsonb)->'supply')->>'allocation_model') IS NULL THEN 'HIDDEN' ELSE 'NAMED' END
    FROM golden.scratch WHERE fixture_id = 40 AND key = 'ladder_B'$q$,
 'eq', 'NAMED', true, 'P3'),

-- ---- rung 2 reuses the P3.1a selector rather than re-deriving substitute choice ----
(40, 32, 'Rung 2 delegates to find_substitutes_for_shelf_v3 (P3.1a), it does not re-implement selection',
 $q$SELECT CASE WHEN prosrc LIKE '%find_substitutes_for_shelf_v3%' THEN 'DELEGATES' ELSE 'REIMPLEMENTS' END
    FROM pg_proc WHERE oid = to_regprocedure('public.resolve_supply_ladder_v3(date,uuid,uuid,uuid,integer,integer)')$q$,
 'eq', 'DELEGATES', true, 'P3'),

(40, 33, 'LAW 3 / fixture 39 seq 30: v1 find_substitutes_for_shelf is byte-untouched by this unit',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE proname = 'find_substitutes_for_shelf'$q$,
 'eq', '8486ff042e91a3e42e862a395e205551', true, 'P3'),

(40, 34, 'LAW 3: the P3.1a selector find_substitutes_for_shelf_v3 is byte-untouched by this unit',
 $q$SELECT md5(prosrc) FROM pg_proc WHERE proname = 'find_substitutes_for_shelf_v3'$q$,
 'eq', 'ca7c52f99df518a1933e88db44864e03', true, 'P3'),

-- ---- S-57 applied forward: tight grants from birth, pinned in BOTH directions ----
(40, 35, 'S-57 forward: anon CANNOT execute the ladder',
 $q$SELECT count(*)::text FROM information_schema.role_routine_grants
    WHERE routine_schema = 'public' AND routine_name = 'resolve_supply_ladder_v3'
      AND grantee IN ('anon','PUBLIC')$q$,
 'eq', '0', true, 'P3'),

(40, 36, 'S-57 forward: authenticated CAN execute the ladder (the tightening must not strand the app)',
 $q$SELECT count(*)::text FROM information_schema.role_routine_grants
    WHERE routine_schema = 'public' AND routine_name = 'resolve_supply_ladder_v3'
      AND grantee = 'authenticated' AND privilege_type = 'EXECUTE'$q$,
 'gte', '1', true, 'P3'),

-- ---- ADR 8.3 tripwire, scoped per S-61's lesson ----
(40, 37, 'ADR 8.3: this fixture wrote NOTHING to the live plan table (attributed by transaction)',
 $q$SELECT count(*)::text FROM public.pod_refill_plan x
    WHERE golden.written_by_this_txn(x.xmin) AND x.plan_date = DATE '2026-07-30'$q$,
 'eq', '0', true, 'P3'),

(40, 38, 'The ladder wrote nothing to blocked_demand either - it is advisory, the writer lands with stitch_v3',
 $q$SELECT count(*)::text FROM public.blocked_demand x
    WHERE golden.written_by_this_txn(x.xmin)$q$,
 'eq', '0', true, 'P3');
