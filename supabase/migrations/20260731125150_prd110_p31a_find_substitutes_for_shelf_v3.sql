-- PRD-110 P3.1a · find_substitutes_for_shelf_v3 — CATEGORY-FIRST substitute selection
--
-- BUILD-SPEC line 89 (CS, 2026-07-31, live incident): raw Pearson basket correlation finds
-- COMPLEMENTS (a chips buyer also buys Pepsi), not SUBSTITUTES. Selection order is
--   (1) SAME CATEGORY first
--   (2) exclude anything already assorted on the machine (any shelf)
--   (3) then rank by performance / margin / stock, Pearson only as a tiebreak WITHIN category.
-- A beverage may replace a snack ONLY when no in-category candidate has stock, and then FLAGGED.
--
-- ⛔ LAW 3 — VERSIONED ADDITION. v1 `find_substitutes_for_shelf` is NOT modified and NOT dropped.
--    It has two live consumers (`engine_swap_pod`, `compute_nowh_proposals`) and Phase 3 has not
--    yet earned the right to change swap behaviour. Fixture 39 seq 30 pins v1's md5(prosrc).
--    ⭐ Note for the next reader: the object CS's correction *names* — `v_pod_substitutes`, the
--    pure-Pearson view — has ZERO consumers in pg_proc. It is dead code. Fixing it would have
--    changed nothing; `find_substitutes_for_shelf` is the live path.
--
-- WHAT IS COPIED VERBATIM FROM v1 (so that v3 RE-RANKS without RE-FILTERING; fixture 39 seq 28
-- asserts the two candidate SETS are identical with p_top_n wide open):
--   the `present` exclusion (slot_lifecycle ∪ live stock > 0 — rule (2) was ALREADY live in v1;
--   the BUILD SPEC calls it "the documented in-machine-duplicate bug" but the live function does
--   exclude, so it is NOT re-fixed here), the global_perf CTE, v1's (pod, boonz) mapping dedupe,
--   the is_catchall filter, the decommission-intent filter, global_v30 > 0.
--
-- ⭐ ARTICLE 16 — v3 reads the CANONICAL object for both registered metrics it needs, where v1
--    re-derived them inline. This is the one place v3 does more than re-order, and it was proven
--    behaviour-neutral BEFORE it was written, not assumed:
--      · WH pickable stock        -> `v_wh_pickable`            (was: raw warehouse_inventory)
--      · Candidate basket affinity -> `get_candidate_affinity()`  (was: inline correlation_pod_*)
--    Measured live on both fixture-39 anchor machines: 122 pods with stock > 0 under BOTH the
--    inline and the canonical read, IDENTICAL sets and IDENTICAL quantities. The only two rows
--    that differ sum to exactly 0 inline, and the `wh_stock > 0` filter drops them either way.
--    ⚠️ One deliberate semantic difference: get_candidate_affinity COALESCEs an unknown
--    correlation to 0, where v1's inline block left it NULL. Ranking is unaffected (Pearson is
--    only the third tiebreak and sorts plain DESC), but `pearson_score` now reads 0, not NULL,
--    for a candidate with no correlation history.
--    📌 NOT registered, so computed inline and flagged for the registry if it is ever promoted:
--    `global_v30` = AVG(slot_lifecycle.velocity_30d) across the fleet. This is a FLEET-WIDE
--    per-pod performance figure, which is not the registered per-machine "Machine velocity"
--    metric (`v_machine_velocity`) nor `v_shelf_instock_velocity_v3`. v1 derives it the same way.
--
-- WHAT CHANGES — the ORDER ONLY:
--   v1:  ORDER BY COALESCE(basket_corr, 0.05) * ln(1 + wh_stock) DESC, global_v30 DESC
--        => a high-correlation COMPLEMENT outranks every in-category peer. That is the bug.
--   v3:  ORDER BY category_match DESC,                        -- CS rule (1)
--                 global_v30 * ln(1 + wh_stock) DESC,         -- CS rule (3) performance x stock
--                 basket_corr DESC NULLS LAST,                -- Pearson demoted to a tiebreak
--                 pod_product_id                              -- ⭐ deterministic final tiebreak:
--                                                             --   STRESS S7 requires run_all() x3
--                                                             --   to be identical.
--
-- ⚠️ S-59 (open, parked): the category taxonomy is FRAGMENTED — `Chips` (1 pod) sits beside
--    `Chips & Crisps` (13), `Chocolate Bar` (2) beside `Chocolates` (9), 3 pods carry a NULL
--    category. This function matches on EXACT equality and will therefore UNDER-reach, falling
--    through to the cross-category rung where a merge mapping would have found a peer. That is
--    deliberate: a merge mapping is a taxonomy decision for CS, not one to invent here (LAW 10).
--    The under-reach is never silent — it shows up as requires_cs_review. A NULL category never
--    matches anything (fixture 39 seq 24).
--
-- ⏸️ D-20 (CORRECTED this leg): leg 54 recorded "margin is not available at pod grain". That is
--    FALSE — `pod_products.purchasing_cost` exists and is populated for 102 / 163 pods (88 have
--    both cost and RSP). Margin is therefore RETURNED as `unit_margin` so CS can see it, but is
--    deliberately NOT a ranking term: at 54% coverage a margin weight would systematically demote
--    the 46% of pods with no cost on file. Weighting it is the parked one-line ask.
--
-- p_shelf_id and p_aggressiveness_pct are accepted and unused — exactly as in v1, kept so the
-- two functions remain call-compatible for the eventual stitch_v3 wiring.

CREATE OR REPLACE FUNCTION public.find_substitutes_for_shelf_v3(
  p_plan_date              date,
  p_machine_id             uuid,
  p_shelf_id               uuid,
  p_anchor_pod_product_id  uuid,
  p_top_n                  integer,
  p_aggressiveness_pct     integer
)
RETURNS TABLE (
  rank                integer,
  pod_product_id      uuid,
  pod_product_name    text,
  product_category    text,
  category_match      boolean,
  requires_cs_review  boolean,
  perf_score          numeric,
  pearson_score       numeric,
  unit_margin         numeric,
  wh_stock_units      numeric,
  source              text,
  reason              text
)
LANGUAGE plpgsql
STABLE
AS $fn$
#variable_conflict use_column
DECLARE
  v_wh_pri     uuid;
  v_wh_sec     uuid;
  v_anchor_cat text;
BEGIN
  IF p_anchor_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'p_anchor_pod_product_id is required';
  END IF;

  SELECT m.primary_warehouse_id, m.secondary_warehouse_id
    INTO v_wh_pri, v_wh_sec
    FROM public.machines m WHERE m.machine_id = p_machine_id;

  -- CS rule (1) needs the anchor's own category. A NULL here means the anchor is one of the
  -- 3 uncategorised pods: every candidate then scores category_match = false and the whole
  -- result set is flagged, which is the honest answer rather than a silent cross-category pick.
  SELECT pp.product_category INTO v_anchor_cat
    FROM public.pod_products pp WHERE pp.pod_product_id = p_anchor_pod_product_id;

  RETURN QUERY
  WITH present AS (
    -- CS rule (2): anything already assorted on this machine, on ANY shelf.
    SELECT sl.pod_product_id FROM public.slot_lifecycle sl
     WHERE sl.machine_id = p_machine_id AND sl.archived = false AND sl.is_current = true
    UNION
    SELECT vls.pod_product_id FROM public.v_live_shelf_stock vls
     WHERE vls.machine_id = p_machine_id AND vls.pod_product_id IS NOT NULL AND vls.current_stock > 0
  ),
  global_perf AS (
    SELECT sl.pod_product_id, AVG(sl.velocity_30d)::numeric AS global_v30
    FROM public.slot_lifecycle sl
    WHERE sl.archived = false AND sl.is_current = true
    GROUP BY sl.pod_product_id
  ),
  wh AS (
    -- Article 16: pickable stock comes from `v_wh_pickable`, the canonical object (Active,
    -- NOT quarantined, in-date Dubai or NULL, stock > 0). v1 re-derived those predicates inline
    -- against warehouse_inventory; proven identical on both anchors before this swap was made.
    -- The machine-scoping and reservation predicates stay HERE because they are properties of
    -- the asking machine, not of pickability — the same way v_dispatch_availability layers them.
    -- DISTINCT (pod, boonz) AFTER the machine filter keeps v1's guarantee that each batch row is
    -- summed at most once per pod — no product_mapping fan-out.
    SELECT pm.pod_product_id, SUM(wp.warehouse_stock)::numeric AS wh_stock
    FROM (
      SELECT DISTINCT pm0.pod_product_id, pm0.boonz_product_id
      FROM public.product_mapping pm0
      WHERE pm0.status = 'Active'
        AND (pm0.machine_id IS NULL OR pm0.machine_id = p_machine_id)
    ) pm
    JOIN public.v_wh_pickable wp
      ON wp.boonz_product_id = pm.boonz_product_id
     AND wp.warehouse_id IN (v_wh_pri, v_wh_sec)
     AND (wp.reserved_for_machine_id IS NULL OR wp.reserved_for_machine_id = p_machine_id)
    GROUP BY pm.pod_product_id
  ),
  cand AS (
    SELECT gp.pod_product_id AS cand,
           gp.global_v30,
           w.wh_stock,
           pp.product_category AS cat,
           -- S-59: exact match only, and a NULL on either side is never a match.
           (pp.product_category IS NOT NULL
            AND v_anchor_cat IS NOT NULL
            AND pp.product_category = v_anchor_cat) AS cat_match,
           -- D-20: returned for visibility, NOT a ranking term (see header).
           CASE WHEN pp.purchasing_cost > 0 AND pp.recommended_selling_price > 0
                THEN ROUND(pp.recommended_selling_price - pp.purchasing_cost, 4)
           END AS unit_margin
    FROM global_perf gp
    JOIN wh w ON w.pod_product_id = gp.pod_product_id AND w.wh_stock > 0
    JOIN public.pod_products pp ON pp.pod_product_id = gp.pod_product_id
                               AND COALESCE(pp.is_catchall,false) = false
    WHERE gp.pod_product_id <> p_anchor_pod_product_id
      AND gp.global_v30 > 0
      AND gp.pod_product_id NOT IN (SELECT pod_product_id FROM present)
      AND NOT EXISTS (
        SELECT 1 FROM public.strategic_intents si
         WHERE si.intent_type = 'decommission'
           AND si.status IN ('queued','in_progress')
           AND si.scope_pod_product_id = gp.pod_product_id
      )
  ),
  scored AS (
    -- Article 16: the canonical affinity object. It encapsulates exactly what v1 inlined —
    -- the machine-level Pearson averaged over the machine's selling basket, falling back to the
    -- location-type table — and additionally COALESCEs an unknown correlation to 0.
    SELECT c.cand, c.global_v30, c.wh_stock, c.cat, c.cat_match, c.unit_margin,
           public.get_candidate_affinity(p_machine_id, c.cand) AS basket_corr
    FROM cand c
  ),
  -- One scalar over the WHOLE candidate set: does an in-category answer exist at all?
  -- This is what separates "cross-category because it is genuinely the only option" (flag it)
  -- from "cross-category filler ranked below a perfectly good in-category winner" (do not).
  flags AS (
    SELECT COALESCE(bool_or(s.cat_match), false) AS has_incat FROM scored s
  ),
  ranked AS (
    SELECT ROW_NUMBER() OVER (
             ORDER BY s.cat_match DESC,                              -- (1) same category first
                      (s.global_v30 * ln(1 + s.wh_stock)) DESC,      -- (3) performance x stock
                      s.basket_corr DESC NULLS LAST,                 --     Pearson = tiebreak only
                                                                     --     (canonical never NULLs;
                                                                     --      NULLS LAST kept as a
                                                                     --      belt-and-braces guard)
                      s.cand                                         --     S7 determinism
           ) AS rk,
           s.cand, s.basket_corr, s.global_v30, s.wh_stock, s.cat, s.cat_match, s.unit_margin,
           f.has_incat
    FROM scored s CROSS JOIN flags f
  )
  SELECT
    r.rk::int                                        AS rank,
    r.cand                                           AS pod_product_id,
    pp.pod_product_name                              AS pod_product_name,
    r.cat                                            AS product_category,
    r.cat_match                                      AS category_match,
    (NOT r.cat_match AND NOT r.has_incat)            AS requires_cs_review,
    ROUND(r.global_v30 * ln(1 + r.wh_stock), 4)      AS perf_score,
    ROUND(r.basket_corr, 3)                          AS pearson_score,
    r.unit_margin                                    AS unit_margin,
    r.wh_stock                                       AS wh_stock_units,
    CASE WHEN r.cat_match          THEN 'in_category_performer'
         WHEN NOT r.has_incat      THEN 'cross_category_flagged'
         ELSE                           'cross_category_filler'
    END                                              AS source,
    CASE
      WHEN r.cat_match THEN
        'Same category (' || COALESCE(r.cat,'?') || '); ' || ROUND(r.global_v30,2)
        || '/day fleet, ' || r.wh_stock || 'u in stock'
        || CASE WHEN r.basket_corr IS NOT NULL
                THEN ' (basket tiebreak ' || ROUND(r.basket_corr,2) || ')' ELSE '' END
      WHEN NOT r.has_incat THEN
        'NO in-category candidate has stock - cross-category ('
        || COALESCE(r.cat,'uncategorised') || ' for ' || COALESCE(v_anchor_cat,'uncategorised')
        || '). FLAGGED FOR CS REVIEW.'
      ELSE
        'Cross-category filler (' || COALESCE(r.cat,'uncategorised')
        || '); an in-category candidate ranks above this row'
    END                                              AS reason
  FROM ranked r
  JOIN public.pod_products pp ON pp.pod_product_id = r.cand
  WHERE r.rk <= COALESCE(p_top_n, 5)
  ORDER BY r.rk;
END
$fn$;

COMMENT ON FUNCTION public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer) IS
'PRD-110 P3.1a. Category-first substitute selection (BUILD-SPEC line 89, CS 2026-07-31). Same candidate set as v1 find_substitutes_for_shelf; differs in ORDER (category_match DESC, then performance x stock, then Pearson as an in-category tiebreak, then pod_product_id for determinism) and in reading the Article 16 canonical objects v_wh_pickable and get_candidate_affinity where v1 re-derived both inline (proven set- and quantity-identical on the fixture-39 anchors). requires_cs_review = cross-category AND no in-category candidate exists. unit_margin is informational, not a ranking term (D-20). Exact category matching only: the taxonomy is fragmented (S-59) so under-reach is possible, and it surfaces as requires_cs_review rather than silently. v1 is untouched and still owns engine_swap_pod. Proven by golden fixture 39.';

-- S-57 applied FORWARD instead of retroactively. ⭐ A GRANT is additive and Supabase default
-- privileges have ALREADY granted EXECUTE to anon on any new function in public — only an
-- explicit REVOKE narrows. v1 is executable by anon today; v3 ships tight from birth.
-- Fixture 39 seq 33/34 pin BOTH directions (anon cannot, authenticated can).
REVOKE ALL ON FUNCTION public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)
  FROM anon;
GRANT EXECUTE ON FUNCTION public.find_substitutes_for_shelf_v3(date,uuid,uuid,uuid,integer,integer)
  TO authenticated, service_role;
