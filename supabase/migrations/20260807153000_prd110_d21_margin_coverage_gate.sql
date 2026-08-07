-- PRD-110 · D-21 · "FIX DATA FIRST": the margin-coverage worklist and its gate
--
-- CS RULING (2026-08-01): "No margin weight until `purchasing_cost` coverage >=90%.
-- Surface the 61-pod missing-cost list for the ops team (TASK, NOT MIGRATION);
-- weight term activates only after the threshold, with the weight itself
-- defaulting off pending a later CS value."
--
-- ⭐ THE RULING CUTS D-21 IN TWO, AND ONLY ONE HALF IS EXECUTABLE TODAY.
--   half 1 - the worklist + the threshold gate .......... THIS UNIT
--   half 2 - the margin term in the substitute ranking .. STILL PARKED, and not
--            because a leg ran out of room: the ruling says the weight awaits
--            "a later CS value". There is no W% to build with. Building the term
--            at a guessed weight would be inventing the decision CS reserved.
--
-- ⛔ WHAT THIS UNIT DOES **NOT** TOUCH: `find_substitutes_for_shelf_v3` is byte-
-- unchanged (md5(prosrc) 6aa6885e, pinned by fixture 68 seq 20). It is consumed by
-- `resolve_supply_ladder_v3`, so a ranking change there reaches the v3 engine; LAW 1
-- forbids it before the fixture that proves it, and the fixture cannot be written
-- without W%. The parking is enforced by a STANDING ASSERTION (S-138's lesson),
-- not by a comment: seq 18 goes red the day someone wires the weight in.
--
-- ⛔⛔ THE RULING'S THRESHOLD IS NECESSARY BUT NOT SUFFICIENT - measured live, not
-- assumed. `unit_margin` needs BOTH columns:
--     CASE WHEN pp.purchasing_cost > 0 AND pp.recommended_selling_price > 0 ...
-- Live today: 163 pods · 102 with cost (62.58%) · 136 with RSP · but only **88
-- margin-computable (53.99%)**. A gate reading purchasing_cost alone would open at
-- 90% cost coverage while a sixth of the fleet still had no computable margin - and
-- those pods would be silently demoted for a data-entry gap, which is the exact
-- harm D-21 was raised to prevent. ⭐ The gate therefore requires BOTH coverages to
-- clear the bar and PUBLISHES BOTH, so the ruling's number is honoured and the hole
-- beside it is named rather than smuggled shut.
--
-- ⭐ THE 61 IS STILL 61. D-21 was raised at 54% cost coverage; ops has since moved
-- it to 62.58%, and the missing-cost count is exactly the 61 the ruling names.
--
-- OBJECTS (Article 16 - one canonical object per metric, both read-only views):
--   v_pod_margin_coverage_v3 - pod grain, the ops worklist
--   v_pod_margin_gate_v3     - one row, the threshold verdict
-- DIALS (both on refill_policy_params):
--   substitute_margin_min_coverage_pct  DEFAULT 90  - the ruling's threshold
--   substitute_margin_weight            DEFAULT 0   - half 2, parked at zero so
--                                                     CS's answer is one UPDATE


------------------------------------------------------------------ dials ------
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS substitute_margin_min_coverage_pct numeric(5,2) NOT NULL DEFAULT 90,
  ADD COLUMN IF NOT EXISTS substitute_margin_weight           numeric(6,3) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.refill_policy_params.substitute_margin_min_coverage_pct IS
  'D-21: minimum pod cost/margin coverage before the substitute ranking may use margin. CS ruling 2026-08-01 set the bar at 90.';
COMMENT ON COLUMN public.refill_policy_params.substitute_margin_weight IS
  'D-21 half 2, PARKED AT 0. The margin weight in find_substitutes_for_shelf_v3''s ranking. CS owes the W% value; nothing reads this column yet and fixture 68 seq 18 asserts so.';

----------------------------------------------------- the ops worklist --------
CREATE OR REPLACE VIEW public.v_pod_margin_coverage_v3 AS
SELECT
  pp.pod_product_id,
  pp.pod_product_name,
  pp.product_category,
  pp.supplier_id,
  pp.purchasing_cost,
  pp.recommended_selling_price,
  (pp.purchasing_cost            > 0) AS has_cost,
  (pp.recommended_selling_price  > 0) AS has_rsp,
  -- ⛔ The SAME predicate find_substitutes_for_shelf_v3 uses. If that function's
  -- definition of a usable margin ever changes, this view must change with it,
  -- or the gate starts guarding a different population than the one at risk.
  (pp.purchasing_cost > 0 AND pp.recommended_selling_price > 0) AS margin_computable,
  CASE WHEN pp.purchasing_cost > 0 AND pp.recommended_selling_price > 0
       THEN ROUND(pp.recommended_selling_price - pp.purchasing_cost, 4)
  END AS unit_margin,
  CASE
    WHEN pp.purchasing_cost > 0 AND pp.recommended_selling_price > 0 THEN 'ok'
    WHEN pp.purchasing_cost > 0                                     THEN 'missing_rsp'
    WHEN pp.recommended_selling_price > 0                           THEN 'missing_cost'
    ELSE 'missing_both'
  END AS worklist_reason
FROM public.pod_products pp;

COMMENT ON VIEW public.v_pod_margin_coverage_v3 IS
  'D-21: canonical pod-grain margin-coverage worklist. Filter worklist_reason <> ''ok'' for the ops task. One row per pod_products row - never a fan-out, asserted by fixture 68 seq 1.';

--------------------------------------------------------- the threshold gate --
CREATE OR REPLACE VIEW public.v_pod_margin_gate_v3 AS
WITH p AS (
  SELECT substitute_margin_min_coverage_pct AS bar
    FROM public.refill_policy_params ORDER BY id LIMIT 1
), c AS (
  SELECT count(*)::int                                            AS pods_total,
         count(*) FILTER (WHERE has_cost)::int                    AS with_cost,
         count(*) FILTER (WHERE has_rsp)::int                     AS with_rsp,
         count(*) FILTER (WHERE margin_computable)::int           AS margin_computable,
         count(*) FILTER (WHERE NOT has_cost)::int                AS missing_cost,
         count(*) FILTER (WHERE NOT margin_computable)::int       AS not_margin_computable
    FROM public.v_pod_margin_coverage_v3
)
SELECT
  c.pods_total, c.with_cost, c.with_rsp, c.margin_computable,
  c.missing_cost, c.not_margin_computable,
  -- ⛔ zero pods is not 100% coverage. NULL, so the gate below reads closed.
  CASE WHEN c.pods_total = 0 THEN NULL
       ELSE round(100.0 * c.with_cost         / c.pods_total, 2) END AS cost_coverage_pct,
  CASE WHEN c.pods_total = 0 THEN NULL
       ELSE round(100.0 * c.margin_computable / c.pods_total, 2) END AS margin_coverage_pct,
  p.bar AS min_coverage_pct,
  COALESCE(CASE WHEN c.pods_total = 0 THEN NULL
                ELSE round(100.0 * c.with_cost / c.pods_total, 2) END >= p.bar, false) AS cost_gate_open,
  COALESCE(CASE WHEN c.pods_total = 0 THEN NULL
                ELSE round(100.0 * c.margin_computable / c.pods_total, 2) END >= p.bar, false) AS margin_gate_open,
  COALESCE(CASE WHEN c.pods_total = 0 THEN NULL
                ELSE round(100.0 * c.with_cost / c.pods_total, 2) END >= p.bar, false)
  AND
  COALESCE(CASE WHEN c.pods_total = 0 THEN NULL
                ELSE round(100.0 * c.margin_computable / c.pods_total, 2) END >= p.bar, false) AS gate_open,
  CASE
    WHEN c.pods_total = 0 THEN 'no_pods'
    WHEN round(100.0 * c.with_cost / c.pods_total, 2) < p.bar
     AND round(100.0 * c.margin_computable / c.pods_total, 2) < p.bar THEN 'both_below_bar'
    WHEN round(100.0 * c.with_cost / c.pods_total, 2) < p.bar         THEN 'cost_coverage_below_bar'
    WHEN round(100.0 * c.margin_computable / c.pods_total, 2) < p.bar THEN 'margin_coverage_below_bar'
    ELSE 'gate_open'
  END AS blocking_reason
FROM c CROSS JOIN p;

COMMENT ON VIEW public.v_pod_margin_gate_v3 IS
  'D-21: one row. Whether pod cost data is complete enough for the substitute ranking to use margin. Requires BOTH cost coverage and margin-computable coverage at or above substitute_margin_min_coverage_pct - the CS ruling names cost coverage, but unit_margin needs RSP too, so cost coverage alone is necessary and not sufficient.';

-- S-140: the Supabase default-privileges trap applies to VIEWS and to
-- `authenticated`, not just to functions and `anon`. Grant explicitly; assert in
-- the fixture that `anon` never appears.
REVOKE ALL ON public.v_pod_margin_coverage_v3 FROM PUBLIC;
REVOKE ALL ON public.v_pod_margin_gate_v3     FROM PUBLIC;
GRANT SELECT ON public.v_pod_margin_coverage_v3 TO authenticated;
GRANT SELECT ON public.v_pod_margin_gate_v3     TO authenticated;


-- ==========================================================================
-- GOLDEN FIXTURE 68
-- ==========================================================================
INSERT INTO golden.fixtures
  (fixture_id, name, notes, enabled, plan_date, phase_required, baseline_status, source_incident, scenario_sql)
VALUES (68,
 'D-21 margin-coverage gate: the worklist is real, the gate is SHUT, and the dial is what shuts it',
 'Leg 143. Proves half 1 of D-21 and PINS half 2 as parked. The scenario moves substitute_margin_min_coverage_pct to 0 and to 100 to prove the dial controls the gate (S-138 / D-40 lesson: never ship a dial without proving it controls its feature), then restores the operator value it found - not the literal 90. ⛔ That dial is safe to move because NOTHING but v_pod_margin_gate_v3 reads it, which seq 19 asserts.',
 true, DATE '2030-06-08', 'P4', 'passing',
 'PRD-110 D-21. find_substitutes_for_shelf_v3 returns unit_margin but does not rank on it, because purchasing_cost is on file for only 62.58% of pods (margin computable for 53.99%). Weighting margin today would demote 61 pods for a data-entry gap rather than a commercial reason.',
$fx68$
DO $fx68b$
DECLARE
  v_bar_before numeric;
  v_before jsonb; v_low jsonb; v_high jsonb; v_final jsonb;
BEGIN
  -- Article 8 (leg 87): name the harness write, do not claim it was an RPC.
  PERFORM set_config('app.rpc_name', 'golden.fixture_68', true);

  ------------------------------------------------------------------ reclaim --
  DELETE FROM golden.scratch WHERE fixture_id = 68;

  -- ⛔ CAPTURE THE OPERATOR'S VALUE, NEVER ASSUME 90. If CS moves the bar, this
  -- fixture must hand back what it found, not what the migration defaulted to.
  SELECT substitute_margin_min_coverage_pct INTO v_bar_before
    FROM public.refill_policy_params ORDER BY id LIMIT 1;

  v_before := (SELECT to_jsonb(g) FROM public.v_pod_margin_gate_v3 g);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (68, 'before', v_before);
  INSERT INTO golden.scratch(fixture_id, key, value)
       VALUES (68, 'bar_before', to_jsonb(v_bar_before));

  BEGIN
    ------------------------------------------------- dial-controls-gate probe --
    -- A bar of 0 must open the gate; a bar of 100 must shut it. Anything else and
    -- the dial is decorative - the failure mode D-40 was parked to avoid.
    UPDATE public.refill_policy_params SET substitute_margin_min_coverage_pct = 0
     WHERE id = (SELECT id FROM public.refill_policy_params ORDER BY id LIMIT 1);
    v_low := (SELECT to_jsonb(g) FROM public.v_pod_margin_gate_v3 g);
    INSERT INTO golden.scratch(fixture_id, key, value) VALUES (68, 'probe_low', v_low);

    UPDATE public.refill_policy_params SET substitute_margin_min_coverage_pct = 100
     WHERE id = (SELECT id FROM public.refill_policy_params ORDER BY id LIMIT 1);
    v_high := (SELECT to_jsonb(g) FROM public.v_pod_margin_gate_v3 g);
    INSERT INTO golden.scratch(fixture_id, key, value) VALUES (68, 'probe_high', v_high);
  EXCEPTION WHEN OTHERS THEN
    -- Restore before re-raising: a thrown probe must not leave the operator's dial
    -- on a fixture value. The subtransaction would roll the UPDATEs back anyway;
    -- this is belt and braces, and it is the dial the whole unit hangs on.
    UPDATE public.refill_policy_params SET substitute_margin_min_coverage_pct = v_bar_before
     WHERE id = (SELECT id FROM public.refill_policy_params ORDER BY id LIMIT 1);
    RAISE;
  END;

  ---------------------------------------------------------------- restore ----
  UPDATE public.refill_policy_params SET substitute_margin_min_coverage_pct = v_bar_before
   WHERE id = (SELECT id FROM public.refill_policy_params ORDER BY id LIMIT 1);

  v_final := (SELECT to_jsonb(g) FROM public.v_pod_margin_gate_v3 g);
  INSERT INTO golden.scratch(fixture_id, key, value) VALUES (68, 'final', v_final);
END
$fx68b$;
$fx68$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(68, 1,
 'the worklist is one row per pod, never a fan-out - it reads pod_products directly and joins nothing',
 $c$SELECT ((SELECT count(*) FROM public.v_pod_margin_coverage_v3)
         = (SELECT count(*) FROM public.pod_products))::text$c$,
 'eq', 'true', true, 'P4'),

(68, 2,
 '⛔ NON-VACUITY: there IS a pod population to measure, so seq 1 is not an equality of two zeros (S-48/S-52/S-55 mode)',
 $c$SELECT count(*)::text FROM public.v_pod_margin_coverage_v3$c$,
 'gt', '0', true, 'P4'),

(68, 3,
 'margin_computable is DERIVED from the two columns, never stored - and it is exactly the predicate find_substitutes_for_shelf_v3 uses',
 $c$SELECT bool_and(margin_computable = (has_cost AND has_rsp))::text FROM public.v_pod_margin_coverage_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 4,
 'unit_margin is populated exactly when margin is computable, and NULL exactly when it is not - no zero-instead-of-unknown',
 $c$SELECT bool_and((unit_margin IS NOT NULL) = margin_computable)::text FROM public.v_pod_margin_coverage_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 5,
 'and where it is populated it is RSP minus cost, to 4dp - the same arithmetic the substitute finder returns',
 $c$SELECT bool_and(unit_margin = round(recommended_selling_price - purchasing_cost, 4))::text
   FROM public.v_pod_margin_coverage_v3 WHERE margin_computable$c$,
 'eq', 'true', true, 'P4'),

(68, 6,
 'worklist_reason partitions the fleet - every pod carries exactly one of the four labels and none falls through',
 $c$SELECT count(*)::text FROM public.v_pod_margin_coverage_v3
   WHERE worklist_reason NOT IN ('ok','missing_cost','missing_rsp','missing_both')$c$,
 'eq', '0', true, 'P4'),

(68, 7,
 '⭐ THE OPS WORKLIST IS NON-EMPTY - this is the deliverable CS asked for, and a green here on an empty list would mean the task had evaporated rather than been done',
 $c$SELECT count(*)::text FROM public.v_pod_margin_coverage_v3 WHERE worklist_reason <> 'ok'$c$,
 'gt', '0', true, 'P4'),

(68, 8,
 'the missing-cost count the view reports equals the count derived independently off pod_products - the view is not inventing its own population',
 $c$SELECT ((SELECT count(*) FROM public.v_pod_margin_coverage_v3 WHERE NOT has_cost)
         = (SELECT count(*) FROM public.pod_products
             WHERE purchasing_cost IS NULL OR purchasing_cost <= 0))::text$c$,
 'eq', 'true', true, 'P4'),

(68, 9,
 'the gate is exactly one row - a threshold verdict that could return two is not a verdict',
 $c$SELECT count(*)::text FROM public.v_pod_margin_gate_v3$c$,
 'eq', '1', true, 'P4'),

(68, 10,
 'FORMULA: cost_coverage_pct = round(100 * with_cost / pods_total, 2), derived not pinned',
 $c$SELECT (cost_coverage_pct = round(100.0 * with_cost / pods_total, 2))::text
   FROM public.v_pod_margin_gate_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 11,
 'FORMULA: margin_coverage_pct = round(100 * margin_computable / pods_total, 2)',
 $c$SELECT (margin_coverage_pct = round(100.0 * margin_computable / pods_total, 2))::text
   FROM public.v_pod_margin_gate_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 12,
 '⛔⛔ THE FINDING THIS UNIT EXISTS TO RECORD: margin coverage is STRICTLY WORSE than cost coverage, because unit_margin needs RSP as well. A gate reading the CS ruling''s cost number alone would open while a sixth of the fleet still had no computable margin',
 $c$SELECT (margin_coverage_pct <= cost_coverage_pct)::text FROM public.v_pod_margin_gate_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 13,
 '⛔ NON-VACUITY for seq 12: the two coverages genuinely DIFFER today, so seq 12 is not comparing a number to itself',
 $c$SELECT (cost_coverage_pct - margin_coverage_pct)::text FROM public.v_pod_margin_gate_v3$c$,
 'gt', '0', true, 'P4'),

(68, 14,
 'FORMULA: gate_open is the AND of both coverages clearing the bar - never one of them, never an OR',
 $c$SELECT (gate_open = (cost_gate_open AND margin_gate_open))::text FROM public.v_pod_margin_gate_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 15,
 '⭐ THE GATE IS SHUT AT THE OPERATOR''S OWN BAR. If this ever goes green, the data has been fixed and D-21 half 2 is genuinely unblocked - which is the day CS owes the W%',
 $c$SELECT (value #>> '{gate_open}') FROM golden.scratch WHERE fixture_id=68 AND key='before'$c$,
 'eq', 'false', true, 'P4'),

(68, 16,
 '⭐ DIAL-CONTROLS-GATE, low end: drop the bar to 0 and the gate OPENS. Without this the dial is decorative - the exact failure D-40 was parked to avoid (fill_pct -> w_lowfill, corr -0.042)',
 $c$SELECT (value #>> '{gate_open}') FROM golden.scratch WHERE fixture_id=68 AND key='probe_low'$c$,
 'eq', 'true', true, 'P4'),

(68, 17,
 '⭐ DIAL-CONTROLS-GATE, high end: raise the bar to 100 and the gate SHUTS, with blocking_reason naming BOTH coverages',
 $c$SELECT ((value #>> '{gate_open}') || '/' || (value #>> '{blocking_reason}'))
   FROM golden.scratch WHERE fixture_id=68 AND key='probe_high'$c$,
 'eq', 'false/both_below_bar', true, 'P4'),

(68, 18,
 '⛔⛔ STANDING PARKING ASSERTION (S-138): D-21 half 2 is PARKED, and this is what enforces it. find_substitutes_for_shelf_v3 reads NEITHER the weight dial NOR the gate. Goes red the day someone wires margin into the ranking - which may not happen until CS supplies the W% the ruling reserved',
 $c$SELECT (position('substitute_margin_weight' in prosrc) = 0
      AND position('v_pod_margin_gate_v3'     in prosrc) = 0)::text
   FROM pg_proc WHERE proname = 'find_substitutes_for_shelf_v3'$c$,
 'eq', 'true', true, 'P4'),

(68, 19,
 '⛔ WHY THIS FIXTURE MAY SAFELY MOVE A LIVE DIAL: v_pod_margin_gate_v3 is the ONLY object in the database that reads substitute_margin_min_coverage_pct, so the probe above has no blast radius. If a second reader ever appears, this goes red and the probe must be re-thought before it can run again',
 $c$SELECT count(*)::text FROM pg_proc
   WHERE prosrc LIKE '%substitute_margin_min_coverage_pct%'$c$,
 'eq', '0', true, 'P4'),

(68, 20,
 '⛔ SENTINEL: the substitute finder is byte-unchanged by this unit. D-21 half 1 ships a worklist and a gate - it does NOT touch the engine path (find_substitutes_for_shelf_v3 -> resolve_supply_ladder_v3)',
 $c$SELECT left(md5(prosrc),8) FROM pg_proc WHERE proname = 'find_substitutes_for_shelf_v3'$c$,
 'eq', '6aa6885e', true, 'P4'),

(68, 21,
 'the weight dial is parked at zero - CS''s answer is one UPDATE, not a migration',
 $c$SELECT substitute_margin_weight::text FROM public.refill_policy_params ORDER BY id LIMIT 1$c$,
 'eq', '0.000', true, 'P4'),

(68, 22,
 'S-140: both views grant authenticated SELECT and NOTHING to anon - the Supabase default-privileges trap applies to views, not just functions',
 $c$SELECT (bool_and(array_to_string(relacl,',') LIKE '%authenticated=r/postgres%')
      AND bool_and(array_to_string(relacl,',') NOT LIKE '%anon=%'))::text
   FROM pg_class WHERE relname IN ('v_pod_margin_coverage_v3','v_pod_margin_gate_v3')$c$,
 'eq', 'true', true, 'P4'),

(68, 23,
 '⭐ RESIDUE: the fixture handed the operator''s bar back exactly as it found it - restored to what it read, never to the literal 90',
 $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=68 AND key='bar_before')
SELECT (((SELECT substitute_margin_min_coverage_pct FROM public.refill_policy_params ORDER BY id LIMIT 1))
        = (b.v #>> '{}')::numeric)::text FROM b$c$,
 'eq', 'true', true, 'P4'),

(68, 24,
 '⭐ RESIDUE, the stronger form: the whole gate row is back where it started - not merely the dial, but every number the probe could have disturbed',
 $c$WITH b AS (SELECT value v FROM golden.scratch WHERE fixture_id=68 AND key='before'),
     f AS (SELECT value v FROM golden.scratch WHERE fixture_id=68 AND key='final')
SELECT (b.v = f.v)::text FROM b, f$c$,
 'eq', 'true', true, 'P4');


-- ==========================================================================
-- POST-CONDITIONS
-- ==========================================================================
DO $post$
DECLARE
  v_gate record;
BEGIN
  IF (SELECT count(*) FROM golden.assertions WHERE fixture_id = 68) <> 24 THEN
    RAISE EXCEPTION 'D-21: fixture 68 did not land 24 assertions';
  END IF;

  SELECT * INTO v_gate FROM public.v_pod_margin_gate_v3;
  IF v_gate.gate_open THEN
    RAISE EXCEPTION 'D-21: the gate reads OPEN at apply time (cost %, margin %, bar %). Either the data was fixed - in which case half 2 is unblocked and CS owes the weight value - or the gate is wrong. Do not ship it green.',
      v_gate.cost_coverage_pct, v_gate.margin_coverage_pct, v_gate.min_coverage_pct;
  END IF;

  -- ⛔ The parking assertion must be TRUE at apply time, or seq 18 ships already red.
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'find_substitutes_for_shelf_v3'
               AND (position('substitute_margin_weight' in prosrc) > 0
                 OR position('v_pod_margin_gate_v3'     in prosrc) > 0)) THEN
    RAISE EXCEPTION 'D-21: half 2 appears to be wired already - this unit must not ship on top of it';
  END IF;

  RAISE NOTICE 'D-21 half 1 applied. Gate SHUT: cost %, margin %, bar %, reason %.',
    v_gate.cost_coverage_pct, v_gate.margin_coverage_pct, v_gate.min_coverage_pct, v_gate.blocking_reason;
END
$post$;
