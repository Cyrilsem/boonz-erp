-- PRD-110 P3.1c / S-85 + S-86 - fixture 40 gains the two rung-1 anchors it never had.
--
-- LAW 1 (fixture first / incident closed <=> fixture exists) for the S-85 crash fixed by
-- 20260731170130. Fixture 40 was 38/38 GREEN while the function it guards threw 55000 on
-- every satisfiable call, because anchors A and B are BOTH starved by design: A is the
-- sentinel trap, B is the contention case. Between them they proved rungs 2-6 and never
-- once executed terminal rung 1. A green suite over a blind spot is worse than a red one.
--
--   C = MPMCC-1058-0000-R0 / A02 / Red Bull      -> rung 1 FULL    (the call that crashed)
--   D = AMZ-1046-2406-O1  / A11 / Hunter Ridge   -> rung 1 PARTIAL (BUILD-SPEC line 89 pod)
--
-- D also pins S-86: the ladder terminates at the FIRST SATISFIABLE rung at ANY quantity and
-- does NOT cascade the remainder - rung 2 reads 'attempted: false' even though one unit went
-- unserved. That stranded unit is a LAW 5 obligation on the ladder's consumer, not on the
-- ladder, and seq 55 states it as a contract so stitch_v3 cannot be built without honouring it.
--
-- D's demand is asked as net_primary + 1, computed in the scenario from base tables, so the
-- partial is guaranteed BY CONSTRUCTION and cannot decay into a vacuous pass as stock moves.
-- Article 12: additive. golden.* is test infrastructure, not a protected entity.

UPDATE golden.fixtures
   SET scenario_sql = $fx40s$
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
               'ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239'::uuid, 8),
         -- S-85 (leg 63). A and B are BOTH starved by design, so between them they
         -- prove rungs 2-6 and never once execute the terminal rung 1. That blind spot
         -- is exactly where the ladder crashed: `record "v_sub" is not assigned yet`
         -- fired on EVERY satisfiable call, i.e. the happy path. C and D close it.
         -- C = rung 1 FULLY satisfiable (MPMCC-1058 A02 Red Bull).
         ('C', '9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid,
               '65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid,
               'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'::uuid, 7),
         -- D = rung 1 PARTIALLY satisfiable (AMZ-1046 A11 Hunter Ridge - the very pod
         -- BUILD-SPEC line 89 names). Its qty_needed here is a PLACEHOLDER: the real
         -- call below asks for net_primary + 1, so the partial is guaranteed BY
         -- CONSTRUCTION and cannot go vacuous as live warehouse stock moves.
         ('D', '981a155e-8bfc-4d6e-b168-0770ef082dc9'::uuid,
               '68511c6d-ebd1-4b9a-908d-fe5490a493c6'::uuid,
               '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid, 2)
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
-- Prior claims on the same pod for the same plan_date, excluding the anchor's own
-- shelf. Derived here from base tables so the net arithmetic below is INDEPENDENT of
-- the function under test (S-64: gross stock is not availability).
claims AS (
  SELECT a.tag, COALESCE(SUM(pr.qty), 0)::int AS claimed
  FROM anchors a
  LEFT JOIN public.pod_refills pr
         ON pr.plan_date = DATE '2026-07-30'
        AND pr.pod_product_id = a.pod_product_id
        AND pr.shelf_id IS DISTINCT FROM a.shelf_id
  GROUP BY a.tag
),
supply AS (
  SELECT vr.tag,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
              AND w.warehouse_id = mc.primary_warehouse_id), 0)                AS real_primary,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
              AND w.warehouse_id IS DISTINCT FROM mc.primary_warehouse_id), 0) AS real_other,
         COALESCE(SUM(w.warehouse_stock) FILTER (
            WHERE w.batch_id LIKE 'VOXSOURCE-%'), 0)                           AS sentinel_units
  FROM variants vr
  JOIN public.machines mc ON mc.machine_id = vr.machine_id
  LEFT JOIN public.v_wh_pickable w
         ON w.boonz_product_id = vr.boonz_product_id
        AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = vr.machine_id)
  GROUP BY vr.tag
)
SELECT {{fixture_id}}, 'supply', jsonb_build_object(
  'A_real_primary', (SELECT real_primary   FROM supply WHERE tag='A'),
  'A_real_other',   (SELECT real_other     FROM supply WHERE tag='A'),
  'A_sentinel',     (SELECT sentinel_units FROM supply WHERE tag='A'),
  'B_real_primary', (SELECT real_primary   FROM supply WHERE tag='B'),
  'B_real_other',   (SELECT real_other     FROM supply WHERE tag='B'),
  'B_sentinel',     (SELECT sentinel_units FROM supply WHERE tag='B'),
  'A_variants',     (SELECT count(*) FROM variants WHERE tag='A'),
  'B_variants',     (SELECT count(*) FROM variants WHERE tag='B'),
  -- S-85 anchors. net_primary is modelled the way the ladder models it: claims consume
  -- the primary warehouse FIRST. D_need is therefore net+1 == guaranteed rung-1 partial.
  'C_real_primary', (SELECT real_primary   FROM supply WHERE tag='C'),
  'C_sentinel',     (SELECT sentinel_units FROM supply WHERE tag='C'),
  'C_claimed',      (SELECT claimed FROM claims WHERE tag='C'),
  'C_net_primary',  GREATEST((SELECT real_primary FROM supply WHERE tag='C')
                             - (SELECT claimed FROM claims WHERE tag='C'), 0),
  'C_variants',     (SELECT count(*) FROM variants WHERE tag='C'),
  'D_real_primary', (SELECT real_primary   FROM supply WHERE tag='D'),
  'D_sentinel',     (SELECT sentinel_units FROM supply WHERE tag='D'),
  'D_claimed',      (SELECT claimed FROM claims WHERE tag='D'),
  'D_net_primary',  GREATEST((SELECT real_primary FROM supply WHERE tag='D')
                             - (SELECT claimed FROM claims WHERE tag='D'), 0),
  'D_need',         GREATEST((SELECT real_primary FROM supply WHERE tag='D')
                             - (SELECT claimed FROM claims WHERE tag='D'), 0) + 1,
  'D_variants',     (SELECT count(*) FROM variants WHERE tag='D')
);

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
             public.resolve_supply_ladder_v3(DATE '2026-07-30', t.mid, t.sid, t.pid, t.need, 3)
      FROM (VALUES
        ('A','148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,'733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid,7),
        ('B','148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'cfed8e4f-7cba-4129-90ac-56ab0af0cfa8'::uuid,'ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239'::uuid,8)
      ) AS t(tag,mid,sid,pid,need)
    $x$;
    -- C: rung 1 fully satisfiable. THIS IS THE CALL THAT CRASHED before S-85.
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 40, 'ladder_C', public.resolve_supply_ladder_v3(
        DATE '2026-07-30',
        '9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid,
        '65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid,
        'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'::uuid, 7, 3)
    $x$;
    -- D: ask for one unit MORE than rung 1 can serve. The partial is structural, not
    -- a snapshot of today's stock, so this assertion cannot rot into a vacuous pass.
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 40, 'ladder_D', public.resolve_supply_ladder_v3(
        DATE '2026-07-30',
        '981a155e-8bfc-4d6e-b168-0770ef082dc9'::uuid,
        '68511c6d-ebd1-4b9a-908d-fe5490a493c6'::uuid,
        '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid,
        (SELECT (value->>'D_need')::int FROM golden.scratch
          WHERE fixture_id = 40 AND key = 'supply'), 3)
    $x$;
  END IF;
END
$do$;
$fx40s$,
       notes = notes || ' | S-85 (leg 63): anchors C (rung-1 full, MPMCC-1058 Red Bull) and D '
                     || '(rung-1 partial by construction, AMZ-1046 Hunter Ridge) added. A and B '
                     || 'are both STARVED, so pre-leg-63 this fixture proved rungs 2-6 and never '
                     || 'executed terminal rung 1 - the exact path on which resolve_supply_ladder_v3 '
                     || 'raised 55000 "record v_sub is not assigned yet". D also pins S-86 '
                     || '(no cascade after a partial rung-1 fill).'
 WHERE fixture_id = 40;


INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 39, 'Anchor guard (C): machine MPMCC-1058 9acce2bf is still co_managed with a primary warehouse', 'SELECT m.operating_model || ''|'' || (m.primary_warehouse_id IS NOT NULL)::text FROM public.machines m WHERE m.machine_id = ''9acce2bf-0e65-48f4-bf44-cefa0326f2c5''::uuid', 'eq', 'co_managed|true', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 40, 'Anchor guard (C): Red Bull a602c923 is still categorised Energy & Sports Drinks', 'SELECT pp.product_category FROM public.pod_products pp WHERE pp.pod_product_id = ''a602c923-c4c0-4ecc-b5f7-3c13a1960beb''::uuid', 'eq', 'Energy & Sports Drinks', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 41, 'Anchor guard (D): machine AMZ-1046 981a155e is still fully_managed with a primary warehouse', 'SELECT m.operating_model || ''|'' || (m.primary_warehouse_id IS NOT NULL)::text FROM public.machines m WHERE m.machine_id = ''981a155e-8bfc-4d6e-b168-0770ef082dc9''::uuid', 'eq', 'fully_managed|true', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 42, 'Anchor guard (D): Hunter Ridge 51e4600f is still categorised Chips & Crisps (BUILD-SPEC line 89 pod)', 'SELECT pp.product_category FROM public.pod_products pp WHERE pp.pod_product_id = ''51e4600f-2c15-428b-92ef-85fdc783c3af''::uuid', 'eq', 'Chips & Crisps', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 43, 'NON-VACUITY (C): net primary-WH supply still covers the full need of 7 - if this reds, re-pick anchor C, do not weaken seq 49', 'SELECT (value->>''C_net_primary'')::int FROM golden.scratch WHERE fixture_id = 40 AND key = ''supply''', 'gte', '7', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 44, 'NON-VACUITY (D): rung 1 is satisfiable at all (net >= 1), so D is genuinely a rung-1 PARTIAL and not a disguised rung-2 case', 'SELECT (value->>''D_net_primary'')::int FROM golden.scratch WHERE fixture_id = 40 AND key = ''supply''', 'gte', '1', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 45, 'S-85 REGRESSION SENSOR (C): the ladder RETURNED an object on a rung-1-satisfiable call. Pre-fix this call raised 55000 and no scratch key landed at all', 'SELECT count(*)::int FROM golden.scratch WHERE fixture_id = 40 AND key = ''ladder_C'' AND jsonb_typeof(value) = ''object''', 'eq', '1', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 46, 'S-85 REGRESSION SENSOR (D): the ladder RETURNED an object on the partial rung-1 call', 'SELECT count(*)::int FROM golden.scratch WHERE fixture_id = 40 AND key = ''ladder_D'' AND jsonb_typeof(value) = ''object''', 'eq', '1', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 47, 'C terminates at rung 1 by BOTH name and number - the pair can never silently disagree', 'SELECT (value->>''resolved_rung'') || ''#'' || (value->>''rung_no'') FROM golden.scratch WHERE fixture_id = 40 AND key = ''ladder_C''', 'eq', 'variant#1', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 48, 'D terminates at rung 1 by BOTH name and number, despite serving less than was asked', 'SELECT (value->>''resolved_rung'') || ''#'' || (value->>''rung_no'') FROM golden.scratch WHERE fixture_id = 40 AND key = ''ladder_D''', 'eq', 'variant#1', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 49, 'C is a FULL rung-1 fill: resolved/needed/shortfall = 7/7/0', 'SELECT (value->>''qty_resolved'') || ''/'' || (value->>''qty_needed'') || ''/'' || (value->>''qty_shortfall'') FROM golden.scratch WHERE fixture_id = 40 AND key = ''ladder_C''', 'eq', '7/7/0', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 50, 'D is a PARTIAL rung-1 fill BY CONSTRUCTION: it was asked for net_primary + 1, served exactly net_primary, and is short exactly 1 - true whatever live stock does', 'SELECT ((value->>''qty_resolved'')::int = (SELECT (s.value->>''D_net_primary'')::int FROM golden.scratch s WHERE s.fixture_id = 40 AND s.key = ''supply'') AND (value->>''qty_shortfall'')::int = 1 AND (value->>''qty_needed'')::int = (value->>''qty_resolved'')::int + 1)::text FROM golden.scratch WHERE fixture_id = 40 AND key = ''ladder_D''', 'eq', 'true', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 51, 'S-86 NO-CASCADE, 0 VIOLATIONS: rung 2 reads attempted=false on both rung-1 anchors. A partial fill does NOT fall through to the rungs below - the terminal rung is the first SATISFIABLE one, at any quantity', 'SELECT count(*)::int FROM golden.scratch s WHERE s.fixture_id = 40 AND s.key IN (''ladder_C'',''ladder_D'') AND (s.value->''ladder''->1->>''attempted'')::boolean IS DISTINCT FROM false', 'eq', '0', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 52, 'All SIX rungs are still logged on the path that used to crash, 0 violations - the ladder''s own completeness invariant now holds on rung-1 terminations too', 'SELECT count(*)::int FROM golden.scratch s WHERE s.fixture_id = 40 AND s.key IN (''ladder_C'',''ladder_D'') AND jsonb_array_length(s.value->''ladder'') <> 6', 'eq', '0', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 53, 'CONSERVATION across ALL four anchors, 0 violations: qty_resolved + qty_shortfall = qty_needed. No unit is invented and none is silently dropped', 'SELECT count(*)::int FROM golden.scratch s WHERE s.fixture_id = 40 AND s.key LIKE ''ladder\_%'' AND (s.value->>''qty_resolved'')::int + (s.value->>''qty_shortfall'')::int <> (s.value->>''qty_needed'')::int', 'eq', '0', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 54, 'S-79 REQUIRED-SET companion to seq 53: exactly the four named ladder anchors ran. Guards seq 53 against going vacuous if an anchor stops producing a scratch key', 'SELECT string_agg(replace(s.key,''ladder_'',''''), '','' ORDER BY s.key) FROM golden.scratch s WHERE s.fixture_id = 40 AND s.key LIKE ''ladder\_%''', 'eq', 'A,B,C,D', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 55, 'THE stitch_v3 CONTRACT (LAW 5 / S-86): D ends on a NON-blocked rung while still short. Unmet units at a satisfiable rung are the CONSUMER''s obligation to route to blocked_demand - the ladder will never do it for them', 'SELECT ((value->>''resolved_rung'') <> ''blocked_demand'' AND (value->>''qty_shortfall'')::int > 0)::text FROM golden.scratch WHERE fixture_id = 40 AND key = ''ladder_D''', 'eq', 'true', true, 'P3');

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES (40, 56, 'S-63 holds on the rung-1 path too, 0 violations: sentinel exclusion is still reported even when no sentinel rescue was needed', 'SELECT count(*)::int FROM golden.scratch s WHERE s.fixture_id = 40 AND s.key IN (''ladder_C'',''ladder_D'') AND NOT (s.value->''supply'' ? ''sentinel_units_excluded'')', 'eq', '0', true, 'P3');
