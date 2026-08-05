-- PRD-110 P3.1b · fixture 40 corrective — golden.scratch.value is JSONB, not text.
--
-- The RED baseline run exposed this, exactly as a RED baseline is supposed to:
-- run_fixture caught "column value is of type jsonb but expression is of type text",
-- recorded it in golden.runs.detail, and carried on. seq 6-9 (the INDEPENDENT population
-- evidence, which must be GREEN even in the RED baseline) read NULL as a result.
--
-- Two corrections, no change to what anything asserts:
--   (1) the scenario now stores ONE jsonb object under key 'supply' and one per ladder
--       anchor -- fixture 39's house idiom -- instead of eight text scalars;
--   (2) seq 6-9 read value->>'field' off that object.
--
-- NOTE: golden.runs.detail is an ARRAY (it is built as '[]'::jsonb || jsonb_build_object(...),
-- so every object is APPENDED as an element). detail->>'scenario_error' therefore always
-- reads NULL; the error is only visible via jsonb_array_elements(detail). That cost a probe.

UPDATE golden.fixtures SET scenario_sql = $SCEN$
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
  'B_variants',     (SELECT count(*) FROM variants WHERE tag='B')
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
  END IF;
END
$do$;
$SCEN$
WHERE fixture_id = 40;

UPDATE golden.assertions SET check_sql =
  $q$SELECT value->>'A_sentinel' FROM golden.scratch WHERE fixture_id = 40 AND key = 'supply'$q$
WHERE fixture_id = 40 AND seq = 6;

UPDATE golden.assertions SET check_sql =
  $q$SELECT value->>'A_real_primary' FROM golden.scratch WHERE fixture_id = 40 AND key = 'supply'$q$
WHERE fixture_id = 40 AND seq = 7;

UPDATE golden.assertions SET check_sql =
  $q$SELECT value->>'B_real_primary' FROM golden.scratch WHERE fixture_id = 40 AND key = 'supply'$q$
WHERE fixture_id = 40 AND seq = 8;

UPDATE golden.assertions SET check_sql =
  $q$SELECT value->>'B_variants' FROM golden.scratch WHERE fixture_id = 40 AND key = 'supply'$q$
WHERE fixture_id = 40 AND seq = 9;
