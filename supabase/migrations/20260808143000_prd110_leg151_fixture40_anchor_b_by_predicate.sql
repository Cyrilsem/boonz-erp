-- PRD-110 leg 151 - fixture 40 anchor B is now resolved BY PREDICATE (S-255 idiom, S-274 doctrine).
--
-- THE RED: seq 8 (`B_real_primary + B_real_other >= 1`) read 0.
-- ⛔ THE SENSOR WAS RIGHT AND MUST NOT BE WEAKENED. Anchor B was pinned to shelf
-- cfed8e4f (VOXMCC-1005-0201-B0, the Vitamin Well pod) and that pod now has ZERO real
-- non-sentinel stock anywhere in the warehouse network - 0 at its primary WH and 0 at every
-- other. Its rung-1 failure therefore no longer proves what the fixture claims: B is meant to be
-- "blocked while genuinely supplied", which is what makes rungs 2-6 worth exercising. Blocked by
-- ABSENCE proves nothing the anchor-A case does not already prove (A is blocked by the sentinel
-- exclusion, 8010 phantom units). The fixture had quietly lost one of its two distinct cases.
--
-- THE FIX, and it is leg 136's own prescription for this fixture ("anchor by PREDICATE, or plant
-- the precondition"): anchor B is selected the way anchor D already is - by the property it must
-- have, not by a uuid that decays:
--     real_primary + real_other >= 1        -- genuinely supplied SOMEWHERE (this IS seq 8)
--     GREATEST(real_primary - claimed, 0)=0 -- yet starved at rung 1
--     sourcing IS DISTINCT FROM 'venue'     -- so rung 1 fails on SUPPLY, never on policy
-- ⭐ seq 8 stops being a fact the fixture INHERITS and becomes a property it MAKES. The selector
-- RAISEs by name if the fleet ever stops supplying the case, so the fixture can go red loudly but
-- can never go vacuously green (S-274, the fixture-54 pattern).
--
-- ⛔ ORDERING MATTERS. anchor_B is resolved BEFORE anchor_D, because D's candidate set excludes
-- the other anchors' shelves by id and must now exclude whichever shelf B chose. B (net = 0) and
-- D (net >= 1) are mutually exclusive by predicate, so the exclusion is belt-and-braces - but a
-- future edit to either predicate would collide silently without it.
--
-- ⛔ NOTHING ELSE ABOUT B MOVES. Every other assertion that reads ladder_B (seqs 9, 14, 16, 18,
-- 20, 22, 28, 29, 30, 31) is STRUCTURAL - six rungs logged, every rung reasoned, no silent qty-0,
-- net never exceeds gross, net never negative, allocation model named. Not one of them pins a
-- B-specific product, machine or number, which is exactly why B can be re-anchored without
-- restating them. Verified by reading all eleven before writing this migration.
--
-- Measured at authoring time: 42 shelves satisfy the predicate; the historical anchor is NOT among
-- them, which is the whole point.

DO $guard$
DECLARE v_src text; v_n int;
BEGIN
  SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = 40;
  IF v_src IS NULL THEN RAISE EXCEPTION 'fixture 40 has no scenario_sql'; END IF;

  -- PRE-IMAGE PIN (leg 150 idiom): a 12,304-character body edited by five string substitutions
  -- must REFUSE rather than guess if it is not the body this migration was written against.
  IF md5(v_src) <> '146e3968d3f9ac9e2f5f8e3f3467d58d' THEN
    RAISE EXCEPTION 'fixture 40 scenario pre-image md5 is %, expected 146e3968d3f9ac9e2f5f8e3f3467d58d - refusing to substitute into a body this migration has not read', md5(v_src);
  END IF;

  -- every substitution must match EXACTLY the expected number of times, or refuse
  v_n := (length(v_src) - length(replace(v_src, '''cfed8e4f-7cba-4129-90ac-56ab0af0cfa8''::uuid', '')))
         / length('''cfed8e4f-7cba-4129-90ac-56ab0af0cfa8''::uuid');
  IF v_n <> 3 THEN RAISE EXCEPTION 'expected 3 occurrences of anchor-B shelf uuid, found %', v_n; END IF;

  v_n := (length(v_src) - length(replace(v_src, '''ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239''::uuid', '')))
         / length('''ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239''::uuid');
  IF v_n <> 2 THEN RAISE EXCEPTION 'expected 2 occurrences of anchor-B pod uuid, found %', v_n; END IF;

  IF (length(v_src) - length(replace(v_src, '(''B'', ''148c4fcf-b794-43f0-a2a8-e6f17605b045''::uuid,', ''))) = 0 THEN
    RAISE EXCEPTION 'anchors-CTE B machine literal not found';
  END IF;
  IF (length(v_src) - length(replace(v_src, '(''B'',''148c4fcf-b794-43f0-a2a8-e6f17605b045''::uuid,', ''))) = 0 THEN
    RAISE EXCEPTION 'ladder-EXECUTE B machine literal not found';
  END IF;
  IF (length(v_src) - length(replace(v_src, 'DO $fx40d$', ''))) = 0 THEN
    RAISE EXCEPTION 'anchor_D block marker DO $fx40d$ not found - cannot position the anchor_B block';
  END IF;
  IF position('anchor_B' in v_src) > 0 THEN
    RAISE EXCEPTION 'fixture 40 already resolves anchor_B - refusing to apply twice';
  END IF;
END
$guard$;

UPDATE golden.fixtures
   SET scenario_sql = replace(replace(replace(replace(replace(
         scenario_sql,
         -- (1) the anchor_B resolver, placed immediately before the anchor_D resolver
         'DO $fx40d$',
$blk$DO $fx40b$
DECLARE
  v_mid uuid; v_sid uuid; v_pid uuid;
  v_name text; v_code text; v_pod text;
  v_prim int; v_other int; v_claim int; v_var int;
BEGIN
  -- ANCHOR B BY PREDICATE (leg 151). B must be BLOCKED AT RUNG 1 WHILE GENUINELY SUPPLIED
  -- SOMEWHERE - that pairing is what makes rungs 2-6 worth walking, and it is precisely what
  -- seq 8 asserts. Pinning it to a uuid meant the fixture inherited the property; live stock
  -- moved and the property evaporated while the fixture kept claiming it.
  WITH cand AS (
    SELECT s.machine_id, s.shelf_id, s.pod_product_id, s.shelf_code, s.pod_name,
           m.official_name, m.primary_warehouse_id
      FROM public.v_shelf_state s
      JOIN public.machines m ON m.machine_id = s.machine_id
     WHERE s.pod_product_id IS NOT NULL
       -- rung 1 must fail on SUPPLY, not on sourcing policy
       AND s.sourcing IS DISTINCT FROM 'venue'
       -- never collide with anchors A or C
       AND s.shelf_id NOT IN ('48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,
                              '65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid)
  ),
  variants AS (
    SELECT c.shelf_id, v.boonz_product_id
      FROM cand c
      CROSS JOIN LATERAL (
        SELECT DISTINCT pm.boonz_product_id
          FROM public.product_mapping pm
         WHERE pm.pod_product_id = c.pod_product_id
           AND pm.status = 'Active'
           AND (pm.machine_id = c.machine_id OR pm.machine_id IS NULL)
      ) v
  ),
  claims AS (
    SELECT c.shelf_id, COALESCE(SUM(pr.qty), 0)::int AS claimed
      FROM cand c
      LEFT JOIN public.pod_refills pr
             ON pr.plan_date      = DATE '2026-07-30'
            AND pr.pod_product_id = c.pod_product_id
            AND pr.shelf_id IS DISTINCT FROM c.shelf_id
     GROUP BY c.shelf_id
  ),
  sup AS (
    SELECT c.shelf_id,
           COALESCE(SUM(w.warehouse_stock) FILTER (
              WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
                AND w.warehouse_id = c.primary_warehouse_id), 0)::int              AS real_primary,
           COALESCE(SUM(w.warehouse_stock) FILTER (
              WHERE w.batch_id NOT LIKE 'VOXSOURCE-%'
                AND w.warehouse_id IS DISTINCT FROM c.primary_warehouse_id), 0)::int AS real_other,
           count(DISTINCT vr.boonz_product_id)::int                                AS n_variants
      FROM cand c
      JOIN variants vr ON vr.shelf_id = c.shelf_id
      LEFT JOIN public.v_wh_pickable w
             ON w.boonz_product_id = vr.boonz_product_id
            AND (w.reserved_for_machine_id IS NULL OR w.reserved_for_machine_id = c.machine_id)
     GROUP BY c.shelf_id
  )
  SELECT c.machine_id, c.shelf_id, c.pod_product_id,
         c.official_name, c.shelf_code, c.pod_name,
         sup.real_primary, sup.real_other, cl.claimed, sup.n_variants
    INTO v_mid, v_sid, v_pid, v_name, v_code, v_pod, v_prim, v_other, v_claim, v_var
    FROM cand c
    JOIN sup    ON sup.shelf_id = c.shelf_id
    JOIN claims cl ON cl.shelf_id = c.shelf_id
   WHERE sup.real_primary + sup.real_other >= 1
     AND GREATEST(sup.real_primary - cl.claimed, 0) = 0
   ORDER BY sup.n_variants DESC, c.official_name, c.shelf_code, c.shelf_id
   LIMIT 1;

  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'FX40 setup: no pod-bound, non-venue shelf in the fleet is BLOCKED AT RUNG 1 (net primary = 0) while holding real non-sentinel stock somewhere in the network. Anchor B cannot be staged, so seq 8 has nothing true to assert. Do NOT weaken seq 8 - it is the S-200 non-vacuity proof that rungs 2-6 are exercised on a genuinely supplied pod rather than on a product that simply does not exist.';
  END IF;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (40, 'anchor_B', jsonb_build_object(
    'machine_id',     v_mid,
    'shelf_id',       v_sid,
    'pod_product_id', v_pid,
    'machine_name',   v_name,
    'shelf_code',     v_code,
    'pod_name',       v_pod,
    'real_primary',   v_prim,
    'real_other',     v_other,
    'claimed',        v_claim,
    'n_variants',     v_var));
END
$fx40b$;

DO $fx40d$$blk$),
         -- (2) B's shelf: all three sites (D's exclusion list, the anchors CTE, the ladder call)
         '''cfed8e4f-7cba-4129-90ac-56ab0af0cfa8''::uuid',
         '(SELECT (value->>''shelf_id'')::uuid FROM golden.scratch WHERE fixture_id = 40 AND key = ''anchor_B'')'),
         -- (3) B's pod: the anchors CTE and the ladder call
         '''ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239''::uuid',
         '(SELECT (value->>''pod_product_id'')::uuid FROM golden.scratch WHERE fixture_id = 40 AND key = ''anchor_B'')'),
         -- (4) B's machine in the anchors CTE (A shares the literal, so match B's row exactly)
         '(''B'', ''148c4fcf-b794-43f0-a2a8-e6f17605b045''::uuid,',
         '(''B'', (SELECT (value->>''machine_id'')::uuid FROM golden.scratch WHERE fixture_id = 40 AND key = ''anchor_B''),'),
         -- (5) B's machine in the ladder EXECUTE
         '(''B'',''148c4fcf-b794-43f0-a2a8-e6f17605b045''::uuid,',
         '(''B'',(SELECT (value->>''machine_id'')::uuid FROM golden.scratch WHERE fixture_id = 40 AND key = ''anchor_B''),')
 WHERE fixture_id = 40;

UPDATE golden.assertions
   SET description = 'NON-VACUITY (B), S-200 restated network-wide: anchor B holds real (non-sentinel) stock SOMEWHERE in the warehouse network, so its rung-1 failure means "blocked while genuinely supplied" rather than "blocked by absence" - which is what makes walking rungs 2-6 meaningful. Paired with seq 57, which proves anchor A fails this same test at 0 (A is starved by the sentinel exclusion instead). RE-ANCHORED at leg 151: B was pinned to shelf cfed8e4f (VOXMCC-1005 Vitamin Well) and went red when that pod ran out of real stock network-wide - an ordinary supply event that says nothing about the ladder. B is now selected BY PREDICATE from live state (real_primary + real_other >= 1 AND net primary = 0 AND sourcing <> venue), so this assertion is a property the scenario MAKES, not one it inherits; the selector RAISEs by name if the fleet stops supplying the case.'
 WHERE fixture_id = 40 AND seq = 8;

DO $post$
DECLARE v_src text;
BEGIN
  SELECT scenario_sql INTO v_src FROM golden.fixtures WHERE fixture_id = 40;

  IF position('DO $fx40b$' in v_src) = 0 THEN
    RAISE EXCEPTION 'post: the anchor_B resolver block was not inserted';
  END IF;
  IF position('DO $fx40b$' in v_src) > position('DO $fx40d$' in v_src) THEN
    RAISE EXCEPTION 'post: anchor_B resolves AFTER anchor_D - D cannot exclude B''s shelf';
  END IF;
  IF position('cfed8e4f-7cba-4129-90ac-56ab0af0cfa8' in v_src) > 0 THEN
    RAISE EXCEPTION 'post: a hard-coded anchor-B shelf uuid survived the substitution';
  END IF;
  IF position('ef8f3ea9-f121-4f8c-a4e6-6f9d0a39f239' in v_src) > 0 THEN
    RAISE EXCEPTION 'post: a hard-coded anchor-B pod uuid survived the substitution';
  END IF;
  IF position('(''B'', ''148c4fcf' in v_src) > 0 OR position('(''B'',''148c4fcf' in v_src) > 0 THEN
    RAISE EXCEPTION 'post: a hard-coded anchor-B machine uuid survived the substitution';
  END IF;
  -- anchor A must be untouched: it still names the same machine twice
  IF (length(v_src) - length(replace(v_src, '148c4fcf-b794-43f0-a2a8-e6f17605b045', '')))
     / length('148c4fcf-b794-43f0-a2a8-e6f17605b045') <> 2 THEN
    RAISE EXCEPTION 'post: anchor A no longer names its machine exactly twice - the substitution over-reached';
  END IF;
  -- seq 8 keeps its shape and its bar; only the anchor and the prose moved (S-272)
  IF NOT EXISTS (SELECT 1 FROM golden.assertions
                  WHERE fixture_id = 40 AND seq = 8 AND expect_op = 'gte' AND expect = '1'
                    AND description LIKE '%RE-ANCHORED at leg 151%') THEN
    RAISE EXCEPTION 'post: seq 8 did not keep (gte, 1) with the re-anchor note';
  END IF;
END
$post$;

SELECT 40 AS fixture_id,
       (SELECT count(*) FROM golden.assertions WHERE fixture_id = 40) AS n_assertions,
       (SELECT length(scenario_sql) FROM golden.fixtures WHERE fixture_id = 40) AS scenario_len;
