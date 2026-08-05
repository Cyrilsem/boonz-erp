-- PRD-110 P3 gate · FIXTURE 12 — Guardrail products never swap in
-- GOLDEN-FIXTURES row 12 (Evian 1L): "Assert never appears as swap-in/size-up candidate".
-- LAW 1: this fixture lands BEFORE the engine change it demands, and is RED on arrival.
--
-- THE RED, probed live at leg 76 on three real (machine, shelf, anchor) triples:
--   find_substitutes_for_shelf_v3  -> Evian - 1L at RANK 1 on all three (in_category_performer)
--   rank_slot_suitability          -> Evian - 1L returned ZERO times on the same three
-- Same machine, same shelf, same anchor, same date. The PRD-106b2 standing CS guardrail
-- lives ONLY as a hardcoded uuid inside rank_slot_suitability; the v3 substitute path has
-- no equivalent, so the "one brain" proposes what the old brain refuses.
--
-- NOTE ON SCOPE. The guardrail blocks INTRODUCING Evian 1L to a machine that does not carry
-- it. It must NOT block refilling the 6 shelves that legitimately hold it today (seq 8).
-- v1 find_substitutes_for_shelf is NOT fixed (same precedent as fixture 39: engine_swap_pod
-- and compute_nowh_proposals consume it); it is recorded as a witness and its md5 pinned.

DELETE FROM golden.assertions WHERE fixture_id = 12;
DELETE FROM golden.fixtures   WHERE fixture_id = 12;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, enabled, notes, scenario_sql)
VALUES (
  12,
  'Guardrail products never swap in: a standing CS guardrail product is refused as a substitution candidate by EVERY engine, is subtracted from the eligible universe by exactly one element and no more, and is still refilled normally on the shelves that legitimately carry it (P3.1a)',
  'PRD-110 GOLDEN-FIXTURES row 12 (Evian 1L) + charter line 112. Probed live at leg 76: find_substitutes_for_shelf_v3 returns Evian - 1L at RANK 1 as in_category_performer on 8 distinct live machines, while rank_slot_suitability (PRD-106b2 hardcode) refuses it on the identical inputs.',
  'P3',
  DATE '2030-01-13',
  'failing_expected',
  true,
  'The guardrail must be DATA-DRIVEN (assortment_guardrails), not a second hardcoded uuid: seq 20/21 fail a fix that merely copies the PRD-106b2 constant into a second engine. Non-vacuity is load-bearing here - seq 1-5 re-derive Evian eligibility from base tables, so a green caused by Evian simply running out of warehouse stock reads as RED, not as a pass.',
$scen$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (1) NON-VACUITY / ELIGIBILITY, computed INDEPENDENTLY of the function under
--     test. Every gate in find_substitutes_for_shelf_v3's `cand` CTE is
--     re-derived here from base tables. If Evian 1L ever stops being otherwise
--     eligible (stock drains, velocity dies, it gets assorted everywhere) these
--     go RED and the fixture tells us it has gone vacuous instead of banking a
--     free green.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH ev AS (SELECT '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid AS pid),
m AS (
  SELECT machine_id, primary_warehouse_id AS pw, secondary_warehouse_id AS sw
    FROM public.machines
   WHERE machine_id IN ('0f698c26-0a21-44f3-bc93-f39e8d88e7cb'::uuid,
                        '23104d17-59f2-4305-838b-0b9969842a57'::uuid,
                        '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid)
),
wh AS (
  SELECT m.machine_id, SUM(wp.warehouse_stock)::numeric AS s
    FROM m
    JOIN LATERAL (SELECT DISTINCT pm0.pod_product_id, pm0.boonz_product_id
                    FROM public.product_mapping pm0, ev
                   WHERE pm0.status = 'Active'
                     AND pm0.pod_product_id = ev.pid
                     AND (pm0.machine_id IS NULL OR pm0.machine_id = m.machine_id)) pm ON true
    JOIN public.v_wh_pickable wp
      ON wp.boonz_product_id = pm.boonz_product_id
     AND wp.warehouse_id IN (m.pw, m.sw)
     AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = m.machine_id)
   GROUP BY 1
)
SELECT {{fixture_id}}, 'eligibility', jsonb_build_object(
  'global_v30',   (SELECT AVG(sl.velocity_30d)::numeric FROM public.slot_lifecycle sl, ev
                    WHERE sl.archived = false AND sl.is_current = true AND sl.pod_product_id = ev.pid),
  'is_catchall',  (SELECT COALESCE(pp.is_catchall,false) FROM public.pod_products pp, ev
                    WHERE pp.pod_product_id = ev.pid),
  'category',     (SELECT pp.product_category FROM public.pod_products pp, ev WHERE pp.pod_product_id = ev.pid),
  'decommission', (SELECT count(*) FROM public.strategic_intents si, ev
                    WHERE si.intent_type = 'decommission' AND si.status IN ('queued','in_progress')
                      AND si.scope_pod_product_id = ev.pid),
  'machines_with_wh', (SELECT count(*) FROM wh WHERE s > 0),
  'wh_units',     (SELECT COALESCE(SUM(s),0) FROM wh),
  'present_on_probe_machines',
                  (SELECT count(*) FROM public.slot_lifecycle sl, ev, m
                    WHERE sl.machine_id = m.machine_id AND sl.archived = false
                      AND sl.is_current = true AND sl.pod_product_id = ev.pid),
  'live_slots_fleetwide',
                  (SELECT count(*) FROM public.slot_lifecycle sl, ev
                    WHERE sl.archived = false AND sl.is_current = true AND sl.pod_product_id = ev.pid)
);

-- ---------------------------------------------------------------------------
-- (2) THE ELIGIBLE UNIVERSE, re-derived from base tables per probe machine.
--     This is what makes seq 12-14 a two-sided claim: the engine's answer must
--     equal this universe MINUS the guardrail set, exactly - not fewer (over-
--     blocking), not more (under-blocking).
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
WITH probe(machine_id, shelf_id, anchor) AS (VALUES
  ('0f698c26-0a21-44f3-bc93-f39e8d88e7cb'::uuid,'2bb42c72-d489-4741-aecb-512ce9c708ae'::uuid,'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid),
  ('23104d17-59f2-4305-838b-0b9969842a57'::uuid,'108283a3-b3bf-43ab-8522-b5a19c554a8e'::uuid,'07eb303d-eb6e-45d8-a9b8-afb059c207df'::uuid),
  ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'072e3c08-1cac-4490-a70e-d80ad82503a2'::uuid,'11b11bda-d277-4ab0-8105-595a209750ce'::uuid)
),
m AS (SELECT p.machine_id, p.anchor, mm.primary_warehouse_id AS pw, mm.secondary_warehouse_id AS sw
        FROM probe p JOIN public.machines mm ON mm.machine_id = p.machine_id),
present AS (
  SELECT m.machine_id, sl.pod_product_id FROM m JOIN public.slot_lifecycle sl
    ON sl.machine_id = m.machine_id AND sl.archived = false AND sl.is_current = true
  UNION
  SELECT m.machine_id, v.pod_product_id FROM m JOIN public.v_live_shelf_stock v
    ON v.machine_id = m.machine_id AND v.pod_product_id IS NOT NULL AND v.current_stock > 0
),
gp AS (SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS g
         FROM public.slot_lifecycle sl WHERE sl.archived = false AND sl.is_current = true GROUP BY 1),
wh AS (
  SELECT m.machine_id, pm.pod_product_id, SUM(wp.warehouse_stock)::numeric AS s
    FROM m
    JOIN LATERAL (SELECT DISTINCT pm0.pod_product_id, pm0.boonz_product_id
                    FROM public.product_mapping pm0
                   WHERE pm0.status = 'Active'
                     AND (pm0.machine_id IS NULL OR pm0.machine_id = m.machine_id)) pm ON true
    JOIN public.v_wh_pickable wp
      ON wp.boonz_product_id = pm.boonz_product_id
     AND wp.warehouse_id IN (m.pw, m.sw)
     AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = m.machine_id)
   GROUP BY 1,2
),
universe AS (
  SELECT w.machine_id, w.pod_product_id
    FROM wh w
    JOIN gp ON gp.pod_product_id = w.pod_product_id AND gp.g > 0
    JOIN public.pod_products pp ON pp.pod_product_id = w.pod_product_id
                               AND COALESCE(pp.is_catchall,false) = false
    JOIN m ON m.machine_id = w.machine_id
   WHERE w.s > 0
     AND w.pod_product_id <> m.anchor
     AND NOT EXISTS (SELECT 1 FROM present p WHERE p.machine_id = w.machine_id
                                               AND p.pod_product_id = w.pod_product_id)
     AND NOT EXISTS (SELECT 1 FROM public.strategic_intents si
                      WHERE si.intent_type = 'decommission' AND si.status IN ('queued','in_progress')
                        AND si.scope_pod_product_id = w.pod_product_id)
)
SELECT {{fixture_id}}, 'universe', jsonb_object_agg(machine_id::text, ids)
FROM (SELECT machine_id, jsonb_agg(pod_product_id::text ORDER BY pod_product_id::text) AS ids
        FROM universe GROUP BY machine_id) z;

-- ---------------------------------------------------------------------------
-- (3) THE SUBJECT. One wide-open call per probe anchor, stored whole so every
--     assertion reads the SAME snapshot. Guarded on to_regprocedure so a
--     pre-existence baseline is a clean RED, never a scenario ERROR.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)') IS NULL
  THEN RETURN; END IF;
  EXECUTE $q$
    SELECT jsonb_object_agg(mid, rows) FROM (
      SELECT p.machine_id::text AS mid,
             COALESCE(jsonb_agg(jsonb_build_object('pod', f.pod_product_id::text, 'rank', f.rank,
                                                   'name', f.pod_product_name) ORDER BY f.rank),
                      '[]'::jsonb) AS rows
        FROM (VALUES
          ('0f698c26-0a21-44f3-bc93-f39e8d88e7cb'::uuid,'2bb42c72-d489-4741-aecb-512ce9c708ae'::uuid,'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid),
          ('23104d17-59f2-4305-838b-0b9969842a57'::uuid,'108283a3-b3bf-43ab-8522-b5a19c554a8e'::uuid,'07eb303d-eb6e-45d8-a9b8-afb059c207df'::uuid),
          ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'072e3c08-1cac-4490-a70e-d80ad82503a2'::uuid,'11b11bda-d277-4ab0-8105-595a209750ce'::uuid)
        ) AS p(machine_id, shelf_id, anchor)
        LEFT JOIN LATERAL public.find_substitutes_for_shelf_v3(
                    DATE '2030-01-13', p.machine_id, p.shelf_id, p.anchor, 500, 50) f ON true
       GROUP BY p.machine_id) z $q$ INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (12, 'v3_wide', COALESCE(v,'{}'::jsonb));
END $do$;

-- (3b) The narrow, operator-facing call: top 5 is what a human is actually offered.
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)') IS NULL
  THEN RETURN; END IF;
  EXECUTE $q$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('mid', p.machine_id::text, 'pod', f.pod_product_id::text,
                                                 'rank', f.rank)), '[]'::jsonb)
      FROM (VALUES
        ('0f698c26-0a21-44f3-bc93-f39e8d88e7cb'::uuid,'2bb42c72-d489-4741-aecb-512ce9c708ae'::uuid,'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid),
        ('23104d17-59f2-4305-838b-0b9969842a57'::uuid,'108283a3-b3bf-43ab-8522-b5a19c554a8e'::uuid,'07eb303d-eb6e-45d8-a9b8-afb059c207df'::uuid),
        ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'072e3c08-1cac-4490-a70e-d80ad82503a2'::uuid,'11b11bda-d277-4ab0-8105-595a209750ce'::uuid)
      ) AS p(machine_id, shelf_id, anchor)
      JOIN LATERAL public.find_substitutes_for_shelf_v3(
             DATE '2030-01-13', p.machine_id, p.shelf_id, p.anchor, 5, 50) f ON true $q$ INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (12, 'v3_top5', COALESCE(v,'[]'::jsonb));
END $do$;

-- ---------------------------------------------------------------------------
-- (4) THE CONTROL ENGINE. rank_slot_suitability already honours the guardrail
--     (PRD-106b2). Pinned here so a later leg cannot delete it and still be
--     green, and so the RED is provably a DISAGREEMENT between two engines on
--     identical inputs rather than a property of the inputs.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.rank_slot_suitability(date,uuid,uuid,uuid,integer,uuid[])') IS NULL
  THEN RETURN; END IF;
  EXECUTE $q$
    SELECT jsonb_object_agg(mid, jsonb_build_object('n', n, 'evian', ev)) FROM (
      SELECT p.machine_id::text AS mid, count(r.*) AS n,
             count(*) FILTER (WHERE r.pod_product_id = '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid) AS ev
        FROM (VALUES
          ('0f698c26-0a21-44f3-bc93-f39e8d88e7cb'::uuid,'2bb42c72-d489-4741-aecb-512ce9c708ae'::uuid,'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid),
          ('23104d17-59f2-4305-838b-0b9969842a57'::uuid,'108283a3-b3bf-43ab-8522-b5a19c554a8e'::uuid,'07eb303d-eb6e-45d8-a9b8-afb059c207df'::uuid),
          ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'072e3c08-1cac-4490-a70e-d80ad82503a2'::uuid,'11b11bda-d277-4ab0-8105-595a209750ce'::uuid)
        ) AS p(machine_id, shelf_id, anchor)
        LEFT JOIN LATERAL public.rank_slot_suitability(
                    DATE '2030-01-13', p.machine_id, p.shelf_id, p.anchor, 500, NULL) r ON true
       GROUP BY p.machine_id) z $q$ INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (12, 'rank_slot', COALESCE(v,'{}'::jsonb));
END $do$;

-- ---------------------------------------------------------------------------
-- (5) THE v1 WITNESS. v1 is NOT being fixed (fixture 39 precedent). Recorded so
--     the open hole is visible in evidence, and its md5 pinned so this leg can
--     prove it did not touch it.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regprocedure('public.find_substitutes_for_shelf(date,uuid,uuid,uuid,integer,integer)') IS NULL
  THEN RETURN; END IF;
  EXECUTE $q$
    SELECT jsonb_build_object(
      'evian_rows', count(*) FILTER (WHERE f.pod_product_id = '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid),
      'total_rows', count(*))
      FROM (VALUES
        ('0f698c26-0a21-44f3-bc93-f39e8d88e7cb'::uuid,'2bb42c72-d489-4741-aecb-512ce9c708ae'::uuid,'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid),
        ('23104d17-59f2-4305-838b-0b9969842a57'::uuid,'108283a3-b3bf-43ab-8522-b5a19c554a8e'::uuid,'07eb303d-eb6e-45d8-a9b8-afb059c207df'::uuid),
        ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'072e3c08-1cac-4490-a70e-d80ad82503a2'::uuid,'11b11bda-d277-4ab0-8105-595a209750ce'::uuid)
      ) AS p(machine_id, shelf_id, anchor)
      JOIN LATERAL public.find_substitutes_for_shelf(
             DATE '2030-01-13', p.machine_id, p.shelf_id, p.anchor, 500, 50) f ON true $q$ INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (12, 'v1_witness', COALESCE(v,'{}'::jsonb));
END $do$;

-- ---------------------------------------------------------------------------
-- (6) THE REGISTRY + DETERMINISM. The guardrail must be data-driven, so the
--     registry itself is evidence. Determinism because S7 runs run_all x3.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v jsonb;
BEGIN
  IF to_regclass('public.assortment_guardrails') IS NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    VALUES (12, 'registry', jsonb_build_object('exists', false));
    RETURN;
  END IF;
  EXECUTE $q$
    SELECT jsonb_build_object(
      'exists', true,
      'n', count(*),
      'has_evian', count(*) FILTER (WHERE g.pod_product_id = '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid),
      'evian_reason_len', COALESCE(max(length(g.reason)) FILTER
                            (WHERE g.pod_product_id = '990461ff-ff92-4b3f-aedb-cde0e951aaf8'::uuid), 0))
      FROM public.assortment_guardrails g WHERE g.active $q$ INTO v;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (12, 'registry', v);
END $do$;

DO $do$
DECLARE d1 text; d2 text;
BEGIN
  IF to_regprocedure('public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)') IS NULL
  THEN RETURN; END IF;
  EXECUTE $q$ SELECT md5(string_agg(f.pod_product_id::text||':'||f.rank::text,'|' ORDER BY f.rank))
                FROM public.find_substitutes_for_shelf_v3(DATE '2030-01-13',
                       '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,
                       '072e3c08-1cac-4490-a70e-d80ad82503a2'::uuid,
                       '11b11bda-d277-4ab0-8105-595a209750ce'::uuid, 500, 50) f $q$ INTO d1;
  EXECUTE $q$ SELECT md5(string_agg(f.pod_product_id::text||':'||f.rank::text,'|' ORDER BY f.rank))
                FROM public.find_substitutes_for_shelf_v3(DATE '2030-01-13',
                       '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,
                       '072e3c08-1cac-4490-a70e-d80ad82503a2'::uuid,
                       '11b11bda-d277-4ab0-8105-595a209750ce'::uuid, 500, 50) f $q$ INTO d2;
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (12, 'determinism', jsonb_build_object('d1', d1, 'd2', d2));
END $do$;
$scen$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ═══ NON-VACUITY: Evian 1L is otherwise fully eligible ═══════════════════════
(12, 1, 'NON-VACUITY: guardrail product still has fleet velocity > 0 (else the fixture is proving nothing)',
 $$SELECT ((value->>'global_v30')::numeric > 0)::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='eligibility'$$,
 'eq','true',true,'P3'),
(12, 2, 'NON-VACUITY: guardrail product has pickable warehouse stock at the probe machines'' warehouses',
 $$SELECT ((value->>'wh_units')::numeric > 0)::text FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='eligibility'$$,
 'eq','true',true,'P3'),
(12, 3, 'NON-VACUITY: all three probe machines can reach that stock',
 $$SELECT (value->>'machines_with_wh') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='eligibility'$$,
 'eq','3',true,'P3'),
(12, 4, 'NON-VACUITY: guardrail product is NOT already assorted on any probe machine (so only the guardrail can exclude it)',
 $$SELECT (value->>'present_on_probe_machines') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='eligibility'$$,
 'eq','0',true,'P3'),
(12, 5, 'NON-VACUITY: guardrail product carries no decommission intent (that is a DIFFERENT exclusion, already honoured)',
 $$SELECT (value->>'decommission') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='eligibility'$$,
 'eq','0',true,'P3'),
(12, 6, 'NON-VACUITY: guardrail product is not a catch-all pod (catch-alls are excluded by a different rule)',
 $$SELECT (value->>'is_catchall') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='eligibility'$$,
 'eq','false',true,'P3'),
(12, 7, 'NON-VACUITY: the eligible universe is re-derived and non-empty on every probe machine',
 $$SELECT (SELECT count(*) FROM golden.scratch s, jsonb_each(s.value) e
            WHERE s.fixture_id={{fixture_id}} AND s.key='universe'
              AND jsonb_array_length(e.value) >= 5)::text$$,
 'eq','3',true,'P3'),
(12, 8, 'SCOPE GUARD: the guardrail blocks INTRODUCTION only - the shelves that legitimately carry Evian 1L today are untouched',
 $$SELECT (value->>'live_slots_fleetwide') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='eligibility'$$,
 'gte','1',true,'P3'),

-- ═══ THE CLAIM: never a swap-in candidate, on any surface ════════════════════
(12, 10, 'THE CLAIM (wide): the guardrail product appears ZERO times in find_substitutes_for_shelf_v3 across all three anchors, even with top_n wide open',
 $$SELECT COALESCE((SELECT count(*) FROM golden.scratch s, jsonb_each(s.value) m, jsonb_array_elements(m.value) e
                     WHERE s.fixture_id={{fixture_id}} AND s.key='v3_wide'
                       AND e->>'pod' = '990461ff-ff92-4b3f-aedb-cde0e951aaf8'), -1)::text$$,
 'eq','0',true,'P3'),
(12, 11, 'THE CLAIM (narrow): and zero times in the top-5 a human is actually offered',
 $$SELECT COALESCE((SELECT count(*) FROM golden.scratch s, jsonb_array_elements(s.value) e
                     WHERE s.fixture_id={{fixture_id}} AND s.key='v3_top5'
                       AND e->>'pod' = '990461ff-ff92-4b3f-aedb-cde0e951aaf8'), -1)::text$$,
 'eq','0',true,'P3'),
(12, 12, 'NO UNDER-BLOCKING: the returned set on each anchor is exactly the re-derived universe minus the guardrail set',
 $$WITH u AS (SELECT m.key AS mid, jsonb_array_elements_text(m.value) AS pod
               FROM golden.scratch s, jsonb_each(s.value) m
              WHERE s.fixture_id={{fixture_id}} AND s.key='universe'),
       r AS (SELECT m.key AS mid, e->>'pod' AS pod
               FROM golden.scratch s, jsonb_each(s.value) m, jsonb_array_elements(m.value) e
              WHERE s.fixture_id={{fixture_id}} AND s.key='v3_wide')
  SELECT (SELECT count(*) FROM u WHERE pod <> '990461ff-ff92-4b3f-aedb-cde0e951aaf8'
            AND NOT EXISTS (SELECT 1 FROM r WHERE r.mid=u.mid AND r.pod=u.pod))::text$$,
 'eq','0',true,'P3'),
(12, 13, 'NO OVER-BLOCKING: nothing outside the guardrail set was dropped - the engine returns no row the universe does not contain',
 $$WITH u AS (SELECT m.key AS mid, jsonb_array_elements_text(m.value) AS pod
               FROM golden.scratch s, jsonb_each(s.value) m
              WHERE s.fixture_id={{fixture_id}} AND s.key='universe'),
       r AS (SELECT m.key AS mid, e->>'pod' AS pod
               FROM golden.scratch s, jsonb_each(s.value) m, jsonb_array_elements(m.value) e
              WHERE s.fixture_id={{fixture_id}} AND s.key='v3_wide')
  SELECT (SELECT count(*) FROM r WHERE NOT EXISTS (SELECT 1 FROM u WHERE u.mid=r.mid AND u.pod=r.pod))::text$$,
 'eq','0',true,'P3'),
(12, 14, 'THE SUBTRACTION IS EXACTLY ONE ELEMENT PER ANCHOR: universe minus result = the guardrail, on all three',
 $$WITH u AS (SELECT m.key AS mid, count(*) AS n FROM golden.scratch s, jsonb_each(s.value) m,
                     jsonb_array_elements_text(m.value) e
              WHERE s.fixture_id={{fixture_id}} AND s.key='universe' GROUP BY 1),
       r AS (SELECT m.key AS mid, count(*) AS n FROM golden.scratch s, jsonb_each(s.value) m,
                     jsonb_array_elements(m.value) e
              WHERE s.fixture_id={{fixture_id}} AND s.key='v3_wide' GROUP BY 1)
  SELECT (SELECT count(*) FROM u JOIN r ON r.mid=u.mid WHERE u.n - r.n = 1)::text$$,
 'eq','3',true,'P3'),
(12, 15, 'NON-VACUITY of the claim: each anchor still returns a real slate of alternatives after the guardrail is applied',
 $$SELECT COALESCE((SELECT count(*) FROM golden.scratch s, jsonb_each(s.value) m
                     WHERE s.fixture_id={{fixture_id}} AND s.key='v3_wide'
                       AND jsonb_array_length(m.value) >= 5), -1)::text$$,
 'eq','3',true,'P3'),

-- ═══ THE CONTROL ENGINE: proves the RED was a disagreement, not the inputs ═══
(12, 16, 'CONTROL: rank_slot_suitability refuses the guardrail product on the identical inputs (PRD-106b2, pinned so it cannot be deleted)',
 $$SELECT COALESCE((SELECT SUM((m.value->>'evian')::int) FROM golden.scratch s, jsonb_each(s.value) m
                     WHERE s.fixture_id={{fixture_id}} AND s.key='rank_slot'), -1)::text$$,
 'eq','0',true,'P3'),
(12, 17, 'CONTROL non-vacuity: rank_slot_suitability did return a real candidate slate (it is refusing Evian, not refusing everything)',
 $$SELECT COALESCE((SELECT SUM((m.value->>'n')::int) FROM golden.scratch s, jsonb_each(s.value) m
                     WHERE s.fixture_id={{fixture_id}} AND s.key='rank_slot'), -1)::text$$,
 'gte','10',true,'P3'),

-- ═══ THE MECHANISM must be data-driven, not a second hardcoded uuid ══════════
(12, 20, 'MECHANISM: a guardrail REGISTRY exists (a second copy of the PRD-106b2 hardcode does not satisfy this fixture)',
 $$SELECT COALESCE((SELECT value->>'exists' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='registry'),'absent')$$,
 'eq','true',true,'P3'),
(12, 21, 'MECHANISM: the registry names the guardrail product',
 $$SELECT COALESCE((SELECT value->>'has_evian' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='registry'),'absent')$$,
 'eq','1',true,'P3'),
(12, 22, 'MECHANISM: and carries a human-readable reason, so CS can see WHY a product is refused',
 $$SELECT COALESCE((SELECT (value->>'evian_reason_len')::int >= 20 FROM golden.scratch
                     WHERE fixture_id={{fixture_id}} AND key='registry'),false)::text$$,
 'eq','true',true,'P3'),
(12, 23, 'MECHANISM: the v3 engine reads the registry rather than a literal uuid (no magic constant in find_substitutes_for_shelf_v3)',
 $$SELECT (prosrc ILIKE '%assortment_guardrails%' AND prosrc NOT ILIKE '%990461ff%')::text
     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='find_substitutes_for_shelf_v3'$$,
 'eq','true',true,'P3'),

-- ═══ HYGIENE ════════════════════════════════════════════════════════════════
(12, 30, 'DETERMINISM (S7): two identical calls one statement apart return the identical ranking',
 $$SELECT COALESCE((SELECT ((value->>'d1') = (value->>'d2'))::text FROM golden.scratch
                     WHERE fixture_id={{fixture_id}} AND key='determinism'),'no_run')$$,
 'eq','true',true,'P3'),
(12, 31, 'LAW 3: v1 find_substitutes_for_shelf was NOT touched by this fix (md5 pinned; it is recorded as a witness, not repaired)',
 $$SELECT substr(md5(prosrc),1,8) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='find_substitutes_for_shelf'$$,
 'eq','8486ff04',true,'P3'),
(12, 32, 'WITNESS CAPTURED: the v1 probe ran and its result is on record (the open hole is visible, not silently inherited)',
 $$SELECT COALESCE((SELECT value->>'total_rows' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='v1_witness'),'no_run')$$,
 'not_null','',true,'P3'),
(12, 33, 'DEFENCE IN DEPTH: preflight INV-09 still blocks a DICTATED guardrail line at commit (swap_v3 is a human verb, not a candidate generator)',
 $$SELECT (prosrc ILIKE '%INV-09%' AND prosrc ILIKE '%v_evian%')::text
     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='preflight_refill_plan'$$,
 'eq','true',true,'P3'),
(12, 34, 'LAW 4: this fixture wrote nothing to any plan table',
 $$SELECT (SELECT count(*) FROM public.refill_plan_output WHERE plan_date = DATE '2030-01-13')::text$$,
 'eq','0',true,'P3'),
(12, 35, 'LAW 4: and nothing to the shadow plan tables either',
 $$SELECT (SELECT count(*) FROM public.refill_plan_output_shadow WHERE plan_date = DATE '2030-01-13')::text$$,
 'eq','0',true,'P3');
