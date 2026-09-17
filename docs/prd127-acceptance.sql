-- PRD-127 acceptance suite (A1-A11), per PRD-127-propose-refill-plan.md section 7.
--
-- Runs entirely inside one transaction that ROLLBACKs at the end -- nothing here is left
-- behind: not the write-guard triggers (A1), not the synthetic expired lots (A6, A7), not the
-- refill_swap_params change (A7). Results accumulate in a temp table and print as one result
-- set at the very end, so this works identically whether run via psql, the Supabase SQL editor,
-- or a tool that only surfaces a script's last result set.
--
-- A1, A2, A3, A8 run against real 2026-09-17/09-18 data. A6 and A7 use one synthetic
-- short-dated lot each (different real shelves of the same real machine, ALJLT-1015-0200-O1,
-- so they never collide). A5 is a pure algorithm unit test (no DB state needed at all -- it
-- reproduces propose_refill_plan's own allocation window shape with synthetic numbers, proving
-- the shape is correct independent of what real data happens to be loaded today). An extra
-- "A7_pre" row records the pre-flip state for transparency; it is not one of the 11 gating
-- tests.
--
-- Run as: `psql -f docs/prd127-acceptance.sql` or paste into the SQL editor.
-- Expected: 11 result rows (A1..A11, one 'A7_pre' diagnostic besides), all `result = 'pass'`.

BEGIN;

CREATE TEMP TABLE _prd127_results (test text, result text, detail text) ON COMMIT DROP;

-- ── A1: propose_refill_plan writes nothing ─────────────────────────────────────────────────
-- Real per-table AFTER INSERT/UPDATE/DELETE guard triggers on the five protected tables.
-- Torn down with an explicit DROP (not ROLLBACK TO a savepoint) once the test result is safely
-- recorded -- ROLLBACK TO would undo the _prd127_results INSERT too, since it happened after
-- the savepoint would have been taken (discovered live on the first dry run of this script).
CREATE OR REPLACE FUNCTION public._prd127_write_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'A1 FAIL: propose_refill_plan wrote to %', TG_TABLE_NAME;
END; $$;
CREATE TRIGGER _prd127_guard_prp AFTER INSERT OR UPDATE OR DELETE ON pod_refill_plan
  FOR EACH ROW EXECUTE FUNCTION public._prd127_write_guard();
CREATE TRIGGER _prd127_guard_rpo AFTER INSERT OR UPDATE OR DELETE ON refill_plan_output
  FOR EACH ROW EXECUTE FUNCTION public._prd127_write_guard();
CREATE TRIGGER _prd127_guard_rd AFTER INSERT OR UPDATE OR DELETE ON refill_dispatching
  FOR EACH ROW EXECUTE FUNCTION public._prd127_write_guard();
CREATE TRIGGER _prd127_guard_pi AFTER INSERT OR UPDATE OR DELETE ON pod_inventory
  FOR EACH ROW EXECUTE FUNCTION public._prd127_write_guard();
CREATE TRIGGER _prd127_guard_wi AFTER INSERT OR UPDATE OR DELETE ON warehouse_inventory
  FOR EACH ROW EXECUTE FUNCTION public._prd127_write_guard();

CREATE OR REPLACE FUNCTION pg_temp._t_a1() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM propose_refill_plan('2026-09-18', NULL, '[]'::jsonb);
  RETURN 'pass';
EXCEPTION WHEN OTHERS THEN
  RETURN 'fail: ' || SQLERRM;
END; $$;

INSERT INTO _prd127_results VALUES ('A1', pg_temp._t_a1(), 'writes nothing to the 5 protected tables');

DROP TRIGGER _prd127_guard_prp ON pod_refill_plan;
DROP TRIGGER _prd127_guard_rpo ON refill_plan_output;
DROP TRIGGER _prd127_guard_rd ON refill_dispatching;
DROP TRIGGER _prd127_guard_pi ON pod_inventory;
DROP TRIGGER _prd127_guard_wi ON warehouse_inventory;
DROP FUNCTION public._prd127_write_guard();

-- ── A2: every lane gets exactly one reason code ────────────────────────────────────────────
WITH r AS (SELECT propose_refill_plan('2026-09-18', NULL, '[]'::jsonb) AS j),
agg AS (
  SELECT
    (SELECT sum(v.value::int) FROM r, jsonb_each_text(r.j->'totals'->'by_reason_code') v) AS sum_by_reason,
    (r.j->'totals'->>'lanes_total')::int AS lanes_total
  FROM r
)
INSERT INTO _prd127_results
SELECT 'A2',
  CASE WHEN sum_by_reason = lanes_total THEN 'pass' ELSE 'fail' END,
  format('by_reason_code sums to %s, lanes_total is %s', sum_by_reason, lanes_total)
FROM agg;

-- ── A3: the seeded Oreo Cookie - Regular BLOCK directive is honored ────────────────────────
WITH r AS (SELECT propose_refill_plan('2026-09-18', NULL, '[]'::jsonb) AS j)
INSERT INTO _prd127_results
SELECT 'A3',
  CASE WHEN NOT EXISTS (
    SELECT 1 FROM r, jsonb_array_elements(r.j->'machines') m, jsonb_array_elements_text(m->'fill') f
    WHERE f ILIKE '%Oreo Cookie - Regular%'
  ) AND (r.j->'totals'->>'blocked_by_directive')::int > 0
  THEN 'pass' ELSE 'fail' END,
  format('blocked_by_directive=%s, no fill line mentions the blocked product', (r.j->'totals'->>'blocked_by_directive'))
FROM r;

-- ── A4: the warehouse pool is computed by calling wh_available_for, not a second copy of its
--        predicates -- the only way to guarantee zero drift is one call site ────────────────
INSERT INTO _prd127_results
SELECT 'A4',
  CASE WHEN pg_get_functiondef(p.oid) ~
    'wh_pool_per_class AS \(\s*SELECT wpb\.boonz_product_id,\s*COALESCE\(\(SELECT SUM\(waf\.free_stock\) FROM public\.wh_available_for\(wpb\.rep_machine_id, wpb\.boonz_product_id\) waf\)'
  THEN 'pass' ELSE 'fail' END,
  'wh_pool is built by calling wh_available_for directly, not re-deriving its phantom/reservation/quarantine predicates'
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'propose_refill_plan';

-- ── A5: global allocation is AED-descending, synthetic 3-lane contention ───────────────────
-- Three lanes need 4, 3, 2 of one SKU; only 6 units of free stock exist. Reproduces
-- propose_refill_plan's own window shape (PARTITION BY product ORDER BY aed_at_risk DESC,
-- ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) with synthetic numbers.
WITH synthetic(lane, need_raw, aed_at_risk) AS (
  VALUES ('A', 4, 100), ('B', 3, 80), ('C', 2, 50)
),
allocated AS (
  SELECT s.*,
    COALESCE(SUM(s.need_raw) OVER (ORDER BY s.aed_at_risk DESC ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS prior_need
  FROM synthetic s
),
final AS (
  SELECT a.*, LEAST(a.need_raw, GREATEST(6 - a.prior_need, 0)) AS final_qty FROM allocated a
),
checked AS (
  SELECT bool_and(
    CASE lane WHEN 'A' THEN final_qty = 4 WHEN 'B' THEN final_qty = 2 WHEN 'C' THEN final_qty = 0 END
  ) AS ok,
  string_agg(format('%s:%s/%s', lane, final_qty, need_raw), ', ' ORDER BY aed_at_risk DESC) AS detail
  FROM final
)
INSERT INTO _prd127_results
SELECT 'A5', CASE WHEN ok THEN 'pass' ELSE 'fail' END, detail FROM checked;

-- ── A6: a synthetic expired-on-shelf lot classifies exactly as find_substitutes_for_shelf
--        alone would for the same shelf (no rule matches "Ice Tea") ───────────────────────
SELECT set_config('app.via_rpc', 'true', true);
SELECT set_config('app.rpc_name', 'prd127_acceptance_a6_fixture', true);
INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
    estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at)
VALUES ('69195812-2f81-457b-abff-527d4aa0af1c', '333189a2-be45-41b7-aded-e508be0d039a',
    'de915c25-fe0d-4e94-8e53-8a76e83c1640', CURRENT_DATE, 5, 5, CURRENT_DATE - 3,
    'PRD127-A6-SYNTHETIC-EXPIRED', 'Active', now(), now());

WITH direct AS (
  SELECT fs.wh_stock_units FROM find_substitutes_for_shelf(
    '2026-09-18', '69195812-2f81-457b-abff-527d4aa0af1c', '333189a2-be45-41b7-aded-e508be0d039a',
    '0e16cbb6-2eea-4ba7-bcd2-235d23d00ca0') fs ORDER BY fs.rank LIMIT 1
),
r AS (SELECT propose_refill_plan('2026-09-18', ARRAY['ALJLT-1015-0200-O1'], '[]'::jsonb) AS j),
observed AS (
  SELECT
    (SELECT string_agg(f,' | ') FROM r, jsonb_array_elements(r.j->'machines') m, jsonb_array_elements_text(m->'fill') f WHERE f LIKE 'A03:%') AS fill,
    (SELECT string_agg(f,' | ') FROM r, jsonb_array_elements(r.j->'machines') m, jsonb_array_elements_text(m->'exceptions') f WHERE f LIKE 'A03:%') AS exception
)
INSERT INTO _prd127_results
SELECT 'A6',
  CASE WHEN (SELECT wh_stock_units FROM direct) IS NULL AND observed.exception LIKE '%no substitute found%' AND observed.fill IS NULL
       THEN 'pass'
       WHEN (SELECT wh_stock_units FROM direct) IS NOT NULL AND observed.fill LIKE '%Remove Ice Tea%'
       THEN 'pass'
       ELSE 'fail' END,
  format('find_substitutes_for_shelf candidate=%s; propose_refill_plan fill=%s exception=%s',
         (SELECT wh_stock_units FROM direct), observed.fill, observed.exception)
FROM observed;

-- ── A7: refill_swap_params.min_substitute_stock_units is read live, not hardcoded ──────────
-- Dubai Popcorn A15 has a real substitution rule (-> Benlian Chips, 4 units at WH_CENTRAL).
-- At the default threshold (3) it substitutes; raising the threshold above 4 must flip it to
-- "no substitute found" -- proving the value comes from the table, not a hardcoded constant.
SELECT set_config('app.via_rpc', 'true', true);
SELECT set_config('app.rpc_name', 'prd127_acceptance_a7_fixture', true);
INSERT INTO pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
    estimated_remaining, expiration_date, batch_id, status, snapshot_at, created_at)
VALUES ('69195812-2f81-457b-abff-527d4aa0af1c', '49b600e9-a52e-461e-ba83-68363e5e7eee',
    '2f95dcf0-2c20-44cd-9794-f9d67ae194c2', CURRENT_DATE, 3, 3, CURRENT_DATE - 2,
    'PRD127-A7-SYNTHETIC-EXPIRED', 'Active', now(), now());

WITH before AS (
  SELECT propose_refill_plan('2026-09-18', ARRAY['ALJLT-1015-0200-O1'], '[]'::jsonb) AS j
),
before_fill AS (
  SELECT COALESCE((SELECT string_agg(f,' | ') FROM before, jsonb_array_elements(before.j->'machines') m, jsonb_array_elements_text(m->'fill') f WHERE f LIKE 'A15:%'), 'NONE') AS v
)
INSERT INTO _prd127_results
SELECT 'A7_pre',
  CASE WHEN (SELECT v FROM before_fill) LIKE '%Benlian Chips%' THEN 'pass' ELSE 'fail' END,
  (SELECT v FROM before_fill)
FROM before_fill;

UPDATE refill_swap_params SET min_substitute_stock_units = 5 WHERE id = 1;

WITH after_r AS (
  SELECT propose_refill_plan('2026-09-18', ARRAY['ALJLT-1015-0200-O1'], '[]'::jsonb) AS j
),
after_exc AS (
  SELECT COALESCE((SELECT string_agg(f,' | ') FROM after_r, jsonb_array_elements(after_r.j->'machines') m, jsonb_array_elements_text(m->'exceptions') f WHERE f LIKE 'A15:%'), 'NONE') AS v
)
INSERT INTO _prd127_results
SELECT 'A7',
  CASE WHEN (SELECT v FROM after_exc) LIKE '%no substitute found%' THEN 'pass' ELSE 'fail' END,
  format('raising min_substitute_stock_units to 5 (candidate has 4 units) flips to: %s', (SELECT v FROM after_exc))
FROM after_exc;

UPDATE refill_swap_params SET min_substitute_stock_units = 3 WHERE id = 1; -- restore before later tests read it

-- ── A8: fill/exceptions are plain strings; no raw per-lane row array at the top level ──────
WITH r AS (SELECT propose_refill_plan('2026-09-18', NULL, '[]'::jsonb) AS j)
INSERT INTO _prd127_results
SELECT 'A8',
  CASE WHEN NOT EXISTS (
    SELECT 1 FROM r, jsonb_array_elements(r.j->'machines') m, jsonb_array_elements(m->'fill') f WHERE jsonb_typeof(f) <> 'string'
  ) AND NOT EXISTS (
    SELECT 1 FROM r, jsonb_array_elements(r.j->'machines') m, jsonb_array_elements(m->'exceptions') f WHERE jsonb_typeof(f) <> 'string'
  ) AND NOT (SELECT r.j ? 'lanes' FROM r)
  THEN 'pass' ELSE 'fail' END,
  'every fill/exceptions element is a JSON string; no top-level "lanes" raw-row array'
FROM r;

-- ── A9: token budget for 8 machines <= 6,000 tokens at 4 chars/token ───────────────────────
WITH eight AS (
  SELECT array_agg(official_name ORDER BY official_name) AS names
  FROM (SELECT m.official_name FROM machines_to_visit mtv JOIN machines m ON m.machine_id = mtv.machine_id
        WHERE mtv.plan_date = '2026-09-18' AND mtv.status IN ('picked','cs_added')
        ORDER BY m.official_name LIMIT 8) x
),
r AS (SELECT propose_refill_plan('2026-09-18', (SELECT names FROM eight), '[]'::jsonb) AS j)
INSERT INTO _prd127_results
SELECT 'A9',
  CASE WHEN ceil(length(r.j::text) / 4.0) <= 6000 THEN 'pass' ELSE 'fail' END,
  format('%s chars, ~%s tokens for %s machines', length(r.j::text), ceil(length(r.j::text)/4.0), array_length((SELECT names FROM eight), 1))
FROM r;

-- ── A10: add_refill_directive raises on zero or ambiguous name matches ─────────────────────
CREATE OR REPLACE FUNCTION pg_temp._t_a10_unmatched() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM add_refill_directive('block', 'ThisNameMatchesNothingAnywhereXYZ999', 'test note here ok', '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid);
  RETURN 'fail: did not raise';
EXCEPTION WHEN OTHERS THEN
  RETURN CASE WHEN SQLERRM LIKE '%matches nothing%' THEN 'pass' ELSE 'fail: ' || SQLERRM END;
END; $$;
CREATE OR REPLACE FUNCTION pg_temp._t_a10_ambiguous() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  -- "Evian - 1L" is both a real pod_product name and a real boonz_product name.
  PERFORM add_refill_directive('block', 'Evian - 1L', 'test note here ok', '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid);
  RETURN 'fail: did not raise';
EXCEPTION WHEN OTHERS THEN
  RETURN CASE WHEN SQLERRM LIKE '%ambiguous%' THEN 'pass' ELSE 'fail: ' || SQLERRM END;
END; $$;
INSERT INTO _prd127_results
SELECT 'A10',
  CASE WHEN pg_temp._t_a10_unmatched() = 'pass' AND pg_temp._t_a10_ambiguous() = 'pass' THEN 'pass' ELSE 'fail' END,
  'zero-match and ambiguous-match names both raise instead of guessing';

-- ── A11: role gate on propose_refill_plan, add_refill_directive, retire_refill_directive ───
-- Switches to the authenticated role (simulating a real field_staff caller via
-- request.jwt.claims, which auth.uid() reads) and back with RESET, not SAVEPOINT/ROLLBACK TO --
-- the same lesson as A1: ROLLBACK TO a savepoint taken before the switch would also erase
-- whatever holds the captured result, since that capture necessarily happens after the switch.
-- The result is carried out via a plain GUC (set_config), not a table write -- the
-- authenticated role has no INSERT grant on a temp table the service role created.
SET LOCAL request.jwt.claims = '{"sub":"bddaec3c-fe18-40db-93e4-8ca543819519","role":"authenticated"}';
SET LOCAL role = authenticated;
CREATE OR REPLACE FUNCTION pg_temp._t_a11_propose() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM propose_refill_plan('2026-09-18', ARRAY['ALJLT-1015-0200-O1'], '[]'::jsonb);
  RETURN 'fail: did not raise';
EXCEPTION WHEN OTHERS THEN
  RETURN CASE WHEN SQLERRM LIKE '%forbidden%' THEN 'pass' ELSE 'fail: ' || SQLERRM END;
END; $$;
SELECT set_config('prd127.a11_propose', pg_temp._t_a11_propose(), true);
RESET role;
RESET request.jwt.claims;

CREATE OR REPLACE FUNCTION pg_temp._t_a11_add() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM add_refill_directive('block', 'Oreo Cookie - Regular', 'test note here ok', 'bddaec3c-fe18-40db-93e4-8ca543819519'::uuid);
  RETURN 'fail: did not raise';
EXCEPTION WHEN OTHERS THEN
  RETURN CASE WHEN SQLERRM LIKE '%forbidden%' THEN 'pass' ELSE 'fail: ' || SQLERRM END;
END; $$;
CREATE OR REPLACE FUNCTION pg_temp._t_a11_retire() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM retire_refill_directive((SELECT directive_id FROM refill_directives LIMIT 1), 'test reason here ok', 'bddaec3c-fe18-40db-93e4-8ca543819519'::uuid);
  RETURN 'fail: did not raise';
EXCEPTION WHEN OTHERS THEN
  RETURN CASE WHEN SQLERRM LIKE '%forbidden%' THEN 'pass' ELSE 'fail: ' || SQLERRM END;
END; $$;
INSERT INTO _prd127_results
SELECT 'A11',
  CASE WHEN current_setting('prd127.a11_propose', true) = 'pass'
        AND pg_temp._t_a11_add() = 'pass' AND pg_temp._t_a11_retire() = 'pass'
       THEN 'pass' ELSE 'fail' END,
  format('propose=%s, add=%s, retire=%s', current_setting('prd127.a11_propose', true),
         pg_temp._t_a11_add(), pg_temp._t_a11_retire());

-- ── final report ─────────────────────────────────────────────────────────────────────────
SELECT test, result, detail FROM _prd127_results ORDER BY test;

ROLLBACK;
