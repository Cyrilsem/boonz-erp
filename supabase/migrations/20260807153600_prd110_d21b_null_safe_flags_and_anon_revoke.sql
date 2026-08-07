-- PRD-110 · D-21b · the two defects fixture 68 caught on its FIRST run
--
-- ⛔ FORWARD-ONLY (Article 12): `20260807153000` is applied and stays applied.
--
-- ==========================================================================
-- DEFECT 1 - THREE-VALUED LOGIC ATE 53 PODS, AND ONLY THE NEGATIVE COUNTS
-- ==========================================================================
-- `has_cost` was `(pp.purchasing_cost > 0)`. For the 53 pods whose cost is NULL
-- that expression is **NULL, not false**, so `count(*) FILTER (WHERE NOT has_cost)`
-- excluded them: the gate reported `missing_cost = 8` when the true figure is 61.
--
-- ⭐ THE POSITIVE COUNTS WERE ALL CORRECT - `FILTER (WHERE has_cost)` = 102, and
-- `cost_coverage_pct` = 62.58% was right. **That is what makes this defect
-- dangerous**: every headline number on the gate read true while the ops worklist
-- count underneath it was wrong by 53 pods, in the direction that makes the job
-- look nearly done. A reviewer reading the gate row would have seen 62.58%
-- coverage and "8 missing" and concluded the two were consistent. They are not.
--
-- ⭐ IT WAS CAUGHT BY THE ONE ASSERTION WRITTEN TO DISTRUST THE VIEW. seq 8 does
-- not re-read the view's own number - it derives the missing-cost count
-- INDEPENDENTLY off `pod_products` and compares. Every other count assertion in
-- the fixture passed. ⛔ STANDING LESSON: a count assertion that reads the object
-- under test proves the object is self-consistent, never that it is right. At
-- least one count per object must be derived from the source, by hand.
--
-- FIX: COALESCE the three exposed booleans so they are total, never NULL - plus
-- two PARTITION assertions (with_cost + missing_cost = pods_total) which state the
-- invariant directly instead of catching its violation by cross-check.
--
-- ⭐ `worklist_reason` and `unit_margin` were already correct and are untouched:
-- a CASE WHEN treats a NULL predicate as not-matched, which is exactly right here.
-- That is why seq 6 and seq 7 passed. Only the booleans the gate NEGATES were bad.
--
-- ==========================================================================
-- DEFECT 2 - S-140 FIRED, AND `REVOKE ... FROM PUBLIC` DID NOT STOP IT
-- ==========================================================================
-- Both views were created with
--   postgres=arwdDxtm, anon=rxtm, authenticated=arwdDxtm, service_role=arwdDxtm
-- ⛔ **The views shipped READABLE BY `anon` AND WRITABLE BY `authenticated`.** That
-- is Supabase's schema-level DEFAULT PRIVILEGES applying at CREATE time, and
-- `REVOKE ALL ... FROM PUBLIC` does not touch it, because `anon`, `authenticated`
-- and `service_role` are NAMED ROLES, not `PUBLIC`. The 20260807153000 migration
-- revoked from PUBLIC and granted SELECT to authenticated, and both statements
-- were no-ops against the privileges that actually existed.
--
-- ⭐ THIS IS THE D-30 EXPOSURE CLASS, SELF-INFLICTED, AND IT WAS LIVE FOR ~3
-- MINUTES. It is also the sharpest available restatement of S-140: the trap is not
-- "remember to grant" - the grant was there. **The trap is that the default
-- privileges are already wrong before your grant runs, and only an explicit REVOKE
-- FROM the named roles removes them.**
--
-- FIX: REVOKE ALL FROM anon, authenticated; then GRANT SELECT TO authenticated.
-- Target ACL, byte-matching the convention `v_proposal_acceptance_v3` already sets:
--   postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres,authenticated=r/postgres


CREATE OR REPLACE VIEW public.v_pod_margin_coverage_v3 AS
SELECT
  pp.pod_product_id,
  pp.pod_product_name,
  pp.product_category,
  pp.supplier_id,
  pp.purchasing_cost,
  pp.recommended_selling_price,
  -- ⛔ D-21b: COALESCE, NOT a bare `> 0`. A NULL cost made this NULL, and every
  -- FILTER that NEGATES it then dropped the row instead of counting it.
  (COALESCE(pp.purchasing_cost, 0)           > 0) AS has_cost,
  (COALESCE(pp.recommended_selling_price, 0) > 0) AS has_rsp,
  (COALESCE(pp.purchasing_cost, 0) > 0
   AND COALESCE(pp.recommended_selling_price, 0) > 0) AS margin_computable,
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

------------------------------------------------------------------ grants -----
REVOKE ALL ON public.v_pod_margin_coverage_v3 FROM anon, authenticated;
REVOKE ALL ON public.v_pod_margin_gate_v3     FROM anon, authenticated;
GRANT SELECT ON public.v_pod_margin_coverage_v3 TO authenticated;
GRANT SELECT ON public.v_pod_margin_gate_v3     TO authenticated;

-------------------------------------------------- the invariants, stated ------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(68, 25,
 '⛔ D-21b PARTITION: with_cost + missing_cost = pods_total. Stated directly, because the three-valued-logic defect made these two disagree by 53 while every rate on the row still read correct',
 $c$SELECT ((with_cost + missing_cost) = pods_total)::text FROM public.v_pod_margin_gate_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 26,
 '⛔ D-21b PARTITION: margin_computable + not_margin_computable = pods_total',
 $c$SELECT ((margin_computable + not_margin_computable) = pods_total)::text FROM public.v_pod_margin_gate_v3$c$,
 'eq', 'true', true, 'P4'),

(68, 27,
 '⛔ D-21b ROOT CAUSE, stated as a property rather than as a count: the three exposed booleans are TOTAL. Not one is ever NULL, so negating any of them in a FILTER is safe',
 $c$SELECT count(*)::text FROM public.v_pod_margin_coverage_v3
   WHERE has_cost IS NULL OR has_rsp IS NULL OR margin_computable IS NULL$c$,
 'eq', '0', true, 'P4'),

(68, 28,
 '⛔ NON-VACUITY for seq 27: pods with a NULL purchasing_cost genuinely EXIST, so seq 27 is not a property proven over a population that cannot violate it. This is the exact population the defect swallowed',
 $c$SELECT count(*)::text FROM public.pod_products WHERE purchasing_cost IS NULL$c$,
 'gt', '0', true, 'P4');

-- seq 22 restated: the old check asked for `authenticated=r/postgres` and got
-- `authenticated=arwdDxtm/postgres` + `anon=rxtm/postgres`. It was RIGHT. It is
-- restated only to name S-140's real mechanism in the description, and to assert
-- the absence of anon as its own clause so a future red says WHICH half broke.
UPDATE golden.assertions SET
  description = '⛔⛔ S-140, AND ITS REAL MECHANISM: `REVOKE ALL ... FROM PUBLIC` does NOT remove Supabase''s schema default privileges, because anon/authenticated/service_role are NAMED ROLES. Both views shipped anon-READABLE and authenticated-WRITABLE despite carrying a GRANT SELECT. Only an explicit REVOKE FROM anon, authenticated closes it. Asserted as two clauses so a red names which half broke'
WHERE fixture_id=68 AND seq=22;


-- ==========================================================================
-- POST-CONDITIONS - the numbers, read back rather than argued
-- ==========================================================================
DO $post$
DECLARE
  g record;
  v_acl_bad text[];
BEGIN
  SELECT * INTO g FROM public.v_pod_margin_gate_v3;

  IF g.missing_cost <> (SELECT count(*) FROM public.pod_products
                         WHERE purchasing_cost IS NULL OR purchasing_cost <= 0) THEN
    RAISE EXCEPTION 'D-21b: missing_cost still disagrees with the independent count (view %)', g.missing_cost;
  END IF;
  IF (g.with_cost + g.missing_cost) <> g.pods_total
     OR (g.margin_computable + g.not_margin_computable) <> g.pods_total THEN
    RAISE EXCEPTION 'D-21b: the coverage buckets still do not partition pods_total';
  END IF;
  IF g.gate_open THEN
    RAISE EXCEPTION 'D-21b: the gate reads OPEN - do not ship it green';
  END IF;

  SELECT array_agg(relname) INTO v_acl_bad FROM pg_class
   WHERE relname IN ('v_pod_margin_coverage_v3','v_pod_margin_gate_v3')
     AND (array_to_string(relacl,',') LIKE '%anon=%'
       OR array_to_string(relacl,',') NOT LIKE '%authenticated=r/postgres%');
  IF v_acl_bad IS NOT NULL THEN
    RAISE EXCEPTION 'D-21b: % still carries anon or non-read-only authenticated privileges', v_acl_bad;
  END IF;

  IF (SELECT count(*) FROM golden.assertions WHERE fixture_id = 68) <> 28 THEN
    RAISE EXCEPTION 'D-21b: fixture 68 should now hold 28 assertions';
  END IF;

  RAISE NOTICE 'D-21b: missing_cost %, not_margin_computable %, gate shut (% / % vs bar %).',
    g.missing_cost, g.not_margin_computable, g.cost_coverage_pct, g.margin_coverage_pct, g.min_coverage_pct;
END
$post$;
