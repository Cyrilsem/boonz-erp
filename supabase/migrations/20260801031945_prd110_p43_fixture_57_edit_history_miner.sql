SET LOCAL statement_timeout = '600s';

-- ============================================================================
-- PRD-110 fixture 57 — the WS-H2 edit-history miner (P4.3a).
--
-- The assertion that matters most is the INVERSION GUARD (seq 10/11): CS
-- trimming a line three times must produce NO proposal, because every pin kind
-- is a FLOOR and the only pin available would pin the quantity CS was cutting.
-- On live data there are ZERO trim clusters, so that branch is unreachable and
-- unprovable outside a fixture — exactly the vacuity S-132 warns about. This
-- fixture plants one.
--
-- Hermeticity: the miner's 90-day window anchored at a 2030 plan_date would
-- otherwise sweep in EVERY other fixture's planted edits (2030-01-02 ..
-- 2030-02-26). The fixture therefore mines under an explicit machine scope, on
-- a machine chosen because it carries no plan_edits_v3 rows and no 2029+
-- pod_refill_plan_audit rows at all. If a future fixture contaminates that
-- machine the setup RAISEs rather than drifting silently.
-- ============================================================================

DELETE FROM golden.assertions WHERE fixture_id = 57;
DELETE FROM golden.fixtures   WHERE fixture_id = 57;

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes)
VALUES (57,
  'The WS-H2 edit-history miner learns only what it can honestly target: a recurring raise becomes a depth pin, a recurring TRIM becomes nothing at all (every pin kind is a floor), a never_stock is not minted dead-on-arrival, and a pod that maps to several boonz products is reported rather than guessed at (P4.3a)',
  'PRD-110 P4.3 / charter WS-H2+H3; the pod-vs-product grain gap raised as D-39',
  'P4', DATE '2030-02-27', true, 'passing',
  'Mines pod_refill_plan_audit + plan_edits_v3. Machine-scoped for hermeticity. Leaves 3 ledger rows and 3 pending proposals behind by design, reclaimed by marker on every re-run, so the counters are stable.');

UPDATE golden.fixtures SET scenario_sql = $SCEN$
DO $fx57$
DECLARE
  mA uuid; mB uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid;
  pA uuid; pB uuid; pC uuid; pD uuid; pF uuid; pG uuid; pH uuid; pI uuid; pE uuid;
  admin_uuid uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  d1 date := DATE '2030-01-10'; d2 date := DATE '2030-01-17'; d3 date := DATE '2030-01-24';
  r1 jsonb; r2 jsonb; rdry jsonb; rscope jsonb;
  n_ledger_before int; n_ledger_after_dry int; v_refused text;
  e1 uuid; e2 uuid;
BEGIN
  ---------------------------------------------------------------- reclaim ----
  -- children before parents; the miner composes its own note text, so the
  -- marker is the fixture-owned MACHINE rather than a string prefix.
  SELECT sc.machine_id INTO mA
    FROM public.shelf_configurations sc
   WHERE NOT EXISTS (SELECT 1 FROM public.plan_edits_v3 e
                      WHERE e.machine_id = sc.machine_id AND e.reason NOT LIKE 'FX57%')
     AND NOT EXISTS (SELECT 1 FROM public.pod_refill_plan_audit a
                      WHERE a.machine_id = sc.machine_id AND a.plan_date >= DATE '2029-01-01'
                        AND a.reason NOT LIKE 'FX57%')
   GROUP BY sc.machine_id HAVING count(*) >= 4
   ORDER BY sc.machine_id LIMIT 1;

  SELECT sc.machine_id INTO mB
    FROM public.shelf_configurations sc
   WHERE sc.machine_id <> mA
     AND NOT EXISTS (SELECT 1 FROM public.plan_edits_v3 e WHERE e.machine_id = sc.machine_id)
     AND NOT EXISTS (SELECT 1 FROM public.pod_refill_plan_audit a
                      WHERE a.machine_id = sc.machine_id AND a.plan_date >= DATE '2029-01-01')
   GROUP BY sc.machine_id HAVING count(*) >= 1
   ORDER BY sc.machine_id LIMIT 1;

  IF mA IS NULL OR mB IS NULL THEN
    RAISE EXCEPTION 'FX57 setup: no clean machine available (mA=% mB=%) - another fixture has contaminated the anchor and this fixture would assert over nothing', mA, mB;
  END IF;

  DELETE FROM public.planning_pins_v3      WHERE machine_id = mA;
  DELETE FROM public.feedback_proposals_v3 WHERE machine_id = mA;
  DELETE FROM public.feedback_ledger_v3    WHERE machine_id = mA;
  DELETE FROM public.pod_refill_plan_audit WHERE reason LIKE 'FX57%';
  -- ⛔ plan_edits_v3 refuses DELETE (append-only). Supersede instead - which is
  --    also how the H3 "the author took it back" exclusion is expressed.
  UPDATE public.plan_edits_v3 SET superseded_at = now(), superseded_by = admin_uuid
   WHERE reason LIKE 'FX57%' AND superseded_at IS NULL;
  DELETE FROM golden.scratch WHERE fixture_id = 57;

  ---------------------------------------------------------------- anchors ----
  SELECT shelf_id INTO s1 FROM public.shelf_configurations WHERE machine_id = mA ORDER BY shelf_id LIMIT 1;
  SELECT shelf_id INTO s2 FROM public.shelf_configurations WHERE machine_id = mA ORDER BY shelf_id OFFSET 1 LIMIT 1;
  SELECT shelf_id INTO s3 FROM public.shelf_configurations WHERE machine_id = mA ORDER BY shelf_id OFFSET 2 LIMIT 1;
  SELECT shelf_id INTO s4 FROM public.shelf_configurations WHERE machine_id = mA ORDER BY shelf_id OFFSET 3 LIMIT 1;

  -- pods that resolve to EXACTLY ONE active boonz product under the house rule
  CREATE TEMP TABLE _fx57_single ON COMMIT DROP AS
    SELECT pp.pod_product_id, row_number() OVER (ORDER BY pp.pod_product_id) AS rn
      FROM public.pod_products pp
     WHERE (SELECT count(DISTINCT pm.boonz_product_id) FROM public.product_mapping pm
             WHERE pm.pod_product_id = pp.pod_product_id AND pm.status = 'Active'
               AND pm.boonz_product_id IS NOT NULL
               AND (pm.machine_id = mA OR pm.machine_id IS NULL)) = 1;

  SELECT pod_product_id INTO pA FROM _fx57_single WHERE rn = 1;
  SELECT pod_product_id INTO pB FROM _fx57_single WHERE rn = 2;
  SELECT pod_product_id INTO pC FROM _fx57_single WHERE rn = 3;
  SELECT pod_product_id INTO pD FROM _fx57_single WHERE rn = 4;
  SELECT pod_product_id INTO pF FROM _fx57_single WHERE rn = 5;
  SELECT pod_product_id INTO pG FROM _fx57_single WHERE rn = 6;
  SELECT pod_product_id INTO pH FROM _fx57_single WHERE rn = 7;
  SELECT pod_product_id INTO pI FROM _fx57_single WHERE rn = 8;

  -- a pod that resolves to SEVERAL — the D-39 grain gap
  SELECT pp.pod_product_id INTO pE
    FROM public.pod_products pp
   WHERE (SELECT count(DISTINCT pm.boonz_product_id) FROM public.product_mapping pm
           WHERE pm.pod_product_id = pp.pod_product_id AND pm.status = 'Active'
             AND pm.boonz_product_id IS NOT NULL
             AND (pm.machine_id = mA OR pm.machine_id IS NULL)) > 1
   ORDER BY pp.pod_product_id LIMIT 1;

  IF pI IS NULL OR pE IS NULL OR s4 IS NULL THEN
    RAISE EXCEPTION 'FX57 setup: anchors incomplete (pI=% pE=% s4=%) - the fixture would assert over nothing', pI, pE, s4;
  END IF;

  INSERT INTO golden.scratch(fixture_id,key,value) VALUES
    (57,'mA', to_jsonb(mA::text)), (57,'mB', to_jsonb(mB::text)),
    (57,'pA', to_jsonb(pA::text)), (57,'pB', to_jsonb(pB::text)),
    (57,'pC', to_jsonb(pC::text)), (57,'pD', to_jsonb(pD::text)),
    (57,'pE', to_jsonb(pE::text)), (57,'pF', to_jsonb(pF::text)),
    (57,'pG', to_jsonb(pG::text)), (57,'pH', to_jsonb(pH::text)),
    (57,'pI', to_jsonb(pI::text));

  ------------------------------------------------- plant the edit history ----
  -- A: recurring ADD of a line the engine never planned, 2 distinct dates -> always_stock
  INSERT INTO public.pod_refill_plan_audit
    (plan_date, machine_id, shelf_id, pod_product_id, action, edited_at, edited_by, edit_type, before_state, after_state, reason)
  VALUES
    (d1, mA, s1, pA, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 8}'::jsonb,  'FX57 A CS keeps adding this line back, occasion one'),
    (d2, mA, s1, pA, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 10}'::jsonb, 'FX57 A CS keeps adding this line back, occasion two'),

  -- B: recurring RAISE, 2 distinct dates, to 9 and 11 -> protect_depth at floor(median)=10
    (d1, mA, s2, pB, 'REFILL', now(), 'FX57', 'qty', '{"qty": 6}'::jsonb, '{"qty": 9}'::jsonb,  'FX57 B CS raises this depth every time, occasion one'),
    (d2, mA, s2, pB, 'REFILL', now(), 'FX57', 'qty', '{"qty": 7}'::jsonb, '{"qty": 11}'::jsonb, 'FX57 B CS raises this depth every time, occasion two'),

  -- C: THE INVERSION CASE. Recurring TRIM on 3 distinct dates. A floor pin here
  --    would pin the very quantity CS was cutting. Must yield NO proposal.
    (d1, mA, s3, pC, 'REFILL', now(), 'FX57', 'qty', '{"qty": 10}'::jsonb, '{"qty": 7}'::jsonb, 'FX57 C CS trims this line down every single time, occasion one'),
    (d2, mA, s3, pC, 'REFILL', now(), 'FX57', 'qty', '{"qty": 10}'::jsonb, '{"qty": 7}'::jsonb, 'FX57 C CS trims this line down every single time, occasion two'),
    (d3, mA, s3, pC, 'REFILL', now(), 'FX57', 'qty', '{"qty": 11}'::jsonb, '{"qty": 6}'::jsonb, 'FX57 C CS trims this line down every single time, occasion three'),

  -- D: recurring STOP -> would be never_stock, refused at approve (S-128(b)), so never minted
    (d1, mA, s4, pD, 'REMOVE', now(), 'FX57', 'stop', '{"qty": 5}'::jsonb, '{"qty": 0}'::jsonb, 'FX57 D CS stops this line repeatedly, occasion one'),
    (d2, mA, s4, pD, 'REMOVE', now(), 'FX57', 'stop', '{"qty": 4}'::jsonb, '{"qty": 0}'::jsonb, 'FX57 D CS stops this line repeatedly, occasion two'),

  -- E: recurring ADD on a MULTI-SKU pod -> reported, never guessed at (D-39)
    (d1, mA, s1, pE, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 6}'::jsonb, 'FX57 E multi mapped pod added back, occasion one'),
    (d2, mA, s1, pE, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 6}'::jsonb, 'FX57 E multi mapped pod added back, occasion two'),

  -- F: THREE edits on ONE plan_date. One occasion, not three. Must not cluster.
    (d3, mA, s2, pF, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 3}'::jsonb, 'FX57 F three edits on a single date, first'),
    (d3, mA, s2, pF, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 4}'::jsonb, 'FX57 F three edits on a single date, second'),
    (d3, mA, s2, pF, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 5}'::jsonb, 'FX57 F three edits on a single date, third'),

  -- G: recurring ADD but UNEXPLAINED (reason under 10 chars) -> H3 excludes it
    (d1, mA, s3, pG, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 7}'::jsonb, 'FX57 g'),
    (d2, mA, s3, pG, 'REFILL', now(), 'FX57', 'add', '{}'::jsonb, '{"qty": 7}'::jsonb, 'FX57 g');

  -- H: the v3-NATIVE source. Two live adds on 2 distinct dates -> always_stock,
  --    and the receipt must name plan_edits_v3 among its sources.
  INSERT INTO public.plan_edits_v3 (plan_date, machine_id, shelf_id, pod_product_id, kind, qty, "lock", author, reason, base_qty_at_edit)
  VALUES (d1, mA, s4, pH, 'add', 5, 'hard', admin_uuid, 'FX57 H v3 native edit, occasion one', 0),
         (d2, mA, s4, pH, 'add', 6, 'hard', admin_uuid, 'FX57 H v3 native edit, occasion two', 0);

  -- I: two SUPERSEDED v3 edits -> the author took them back, H3 excludes them
  INSERT INTO public.plan_edits_v3 (plan_date, machine_id, shelf_id, pod_product_id, kind, qty, "lock", author, reason, base_qty_at_edit)
  VALUES (d1, mA, s1, pI, 'add', 9, 'hard', admin_uuid, 'FX57 I self corrected edit, occasion one', 0)
  RETURNING edit_id INTO e1;
  INSERT INTO public.plan_edits_v3 (plan_date, machine_id, shelf_id, pod_product_id, kind, qty, "lock", author, reason, base_qty_at_edit)
  VALUES (d2, mA, s1, pI, 'add', 9, 'hard', admin_uuid, 'FX57 I self corrected edit, occasion two', 0)
  RETURNING edit_id INTO e2;
  UPDATE public.plan_edits_v3 SET superseded_at = now(), superseded_by = admin_uuid
   WHERE edit_id IN (e1, e2);

  ------------------------------------------------------------------- run ----
  -- ⭐ impersonate: as postgres auth.uid() is NULL and the role gate would
  --    short-circuit, proving the gate exists but never that it ADMITS (S-121).
  PERFORM set_config('request.jwt.claims',
    '{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', true);

  SELECT count(*) INTO n_ledger_before FROM public.feedback_ledger_v3;

  -- dry run first: must compute the same answer and write nothing
  rdry := public.mine_edit_history_v3({{plan_date}}, 90, 2, mA, 25, true);
  SELECT count(*) INTO n_ledger_after_dry FROM public.feedback_ledger_v3;

  r1 := public.mine_edit_history_v3({{plan_date}}, 90, 2, mA, 25, false);
  INSERT INTO golden.scratch(fixture_id,key,value)
    VALUES (57,'rpc_name_after_run', to_jsonb(current_setting('app.rpc_name', true)));

  -- second run, unchanged inputs: must learn nothing new
  r2 := public.mine_edit_history_v3({{plan_date}}, 90, 2, mA, 25, false);

  -- a clean machine the fixture planted nothing on: the scope must actually bite
  rscope := public.mine_edit_history_v3({{plan_date}}, 90, 2, mB, 25, true);

  -- min_occurrences of 1 must be refused by name
  BEGIN
    PERFORM public.mine_edit_history_v3({{plan_date}}, 90, 1, mA, 25, true);
    v_refused := 'NOT_REFUSED';
  EXCEPTION WHEN OTHERS THEN
    v_refused := SQLERRM;
  END;

  INSERT INTO golden.scratch(fixture_id,key,value) VALUES
    (57,'run1', r1), (57,'run2', r2), (57,'dry', rdry), (57,'scope', rscope),
    (57,'ledger_before',   to_jsonb(n_ledger_before)),
    (57,'ledger_after_dry',to_jsonb(n_ledger_after_dry)),
    (57,'min_occ_1_refusal', to_jsonb(v_refused));
END $fx57$;
$SCEN$
WHERE fixture_id = 57;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

(57, 1, 'The scenario ran and left a receipt (guard: everything below reads this row)',
 $$SELECT count(*)::text FROM golden.scratch WHERE fixture_id=57 AND key='run1'$$, 'eq', '1', true, 'P4'),

(57, 2, 'Six clusters cleared the recurrence bar: A raise, B raise, C trim, D stop, E multi-SKU, H v3-native',
 $$SELECT value->>'clusters_found' FROM golden.scratch WHERE fixture_id=57 AND key='run1'$$, 'eq', '6', true, 'P4'),

(57, 3, 'Exactly three of them became proposals (A, B, H) - the other three were refused BY NAME, not dropped',
 $$SELECT value->>'proposals_made' FROM golden.scratch WHERE fixture_id=57 AND key='run1'$$, 'eq', '3', true, 'P4'),

(57, 4, 'and exactly three were skipped: nothing mined is ever silently discarded',
 $$SELECT value->>'clusters_skipped' FROM golden.scratch WHERE fixture_id=57 AND key='run1'$$, 'eq', '3', true, 'P4'),

(57, 5, 'A recurring ADD becomes an always_stock proposal',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'pin_kind'='always_stock'
     AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pA')$$,
 'eq', '1', true, 'P4'),

(57, 6, 'an always_stock proposal carries NO value (the CHECK demands it, and the floor is a fixed 1 unit)',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'pin_kind'='always_stock' AND e->>'pin_value' IS NOT NULL$$,
 'eq', '0', true, 'P4'),

(57, 7, 'A recurring RAISE becomes a protect_depth proposal',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'pin_kind'='protect_depth'
     AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pB')$$,
 'eq', '1', true, 'P4'),

(57, 8, 'and its depth is floor(median(9,11)) = 10 - the depth CS actually restored, rounded DOWN because a floor that overshoots orders stock nobody asked for',
 $$SELECT e->>'pin_value' FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'pin_kind'='protect_depth'$$, 'eq', '10', true, 'P4'),

(57, 9, 'The v3-native source is genuinely mined: one proposal names plan_edits_v3 among its sources',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'sources' LIKE '%plan_edits_v3%'$$, 'eq', '1', true, 'P4'),

(57, 10, '⭐ THE INVERSION GUARD: CS trimmed this line on THREE occasions and the miner proposed NOTHING for it. Every pin kind is a floor; the only pin available would have pinned the quantity CS was cutting',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='run1'
     AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pC')$$,
 'eq', '0', true, 'P4'),

(57, 11, '⛔ NON-VACUITY for seq 10: the trim cluster WAS mined and WAS refused by name. Without this, seq 10 would pass just as well on a cluster that was never planted',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'reason'='no_ceiling_pin_kind_exists'
     AND e->>'occasions'='3'
     AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pC')$$,
 'eq', '1', true, 'P4'),

(57, 12, 'A recurring STOP is NOT minted as never_stock: S-128(b) refuses it at approve, so the proposal would be dead on arrival and would only depress the G12 acceptance rate',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'reason'='never_stock_refused_at_approve_s128b'
     AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pD')$$,
 'eq', '1', true, 'P4'),

(57, 13, '⛔ NON-VACUITY for seq 12: no never_stock proposal reached the queue from this run',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'pin_kind'='never_stock'$$, 'eq', '0', true, 'P4'),

(57, 14, 'D-39: a pod that resolves to SEVERAL boonz products is reported, never guessed at. Edit history is at pod grain; pins are at product grain',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'reason'='pod_maps_to_multiple_boonz_products'
     AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pE')$$,
 'eq', '1', true, 'P4'),

(57, 15, 'and the refusal carries the actual count, so the D-39 coverage gap is measurable rather than anecdotal',
 $$SELECT (e->>'n_boonz')::int > 1 FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
   WHERE s.fixture_id=57 AND s.key='run1' AND e->>'reason'='pod_maps_to_multiple_boonz_products'$$,
 'eq', 'true', true, 'P4'),

(57, 16, 'THREE edits on ONE plan_date are ONE occasion, not three: the cluster never reaches the recurrence bar and appears nowhere',
 $$SELECT (
     (SELECT count(*) FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
       WHERE s.fixture_id=57 AND s.key='run1'
         AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pF'))
   + (SELECT count(*) FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
       WHERE s.fixture_id=57 AND s.key='run1'
         AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pF')))::text$$,
 'eq', '0', true, 'P4'),

(57, 17, '⛔ NON-VACUITY for seq 16: those three same-date edits really are on disk',
 $$SELECT count(*)::text FROM public.pod_refill_plan_audit WHERE reason LIKE 'FX57 F%'$$, 'eq', '3', true, 'P4'),

(57, 18, 'H3: an UNEXPLAINED edit is not evidence of a preference - the cluster is excluded before it can cluster',
 $$SELECT (
     (SELECT count(*) FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
       WHERE s.fixture_id=57 AND s.key='run1'
         AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pG'))
   + (SELECT count(*) FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
       WHERE s.fixture_id=57 AND s.key='run1'
         AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pG')))::text$$,
 'eq', '0', true, 'P4'),

(57, 19, '⛔ NON-VACUITY for seq 18: the two unexplained edits exist, and their reason really is under the 10-character bar',
 $$SELECT count(*)::text FROM public.pod_refill_plan_audit
   WHERE reason LIKE 'FX57 g%' AND char_length(btrim(reason)) < 10$$, 'eq', '2', true, 'P4'),

(57, 20, 'H3: a SUPERSEDED v3 edit is one the author took back, and is never learned from',
 $$SELECT (
     (SELECT count(*) FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
       WHERE s.fixture_id=57 AND s.key='run1'
         AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pI'))
   + (SELECT count(*) FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
       WHERE s.fixture_id=57 AND s.key='run1'
         AND e->>'pod_product_id' = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='pI')))::text$$,
 'eq', '0', true, 'P4'),

(57, 21, '⛔ NON-VACUITY for seq 20: both self-corrected edits exist and are genuinely superseded',
 $$SELECT count(*)::text FROM public.plan_edits_v3
   WHERE reason LIKE 'FX57 I%' AND superseded_at IS NOT NULL$$, 'eq', '2', true, 'P4'),

(57, 22, 'PROVENANCE: every proposal the miner made cites a feedback row on the miner channel - nothing is minted without evidence',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   JOIN public.feedback_ledger_v3 f ON f.feedback_id = (e->>'feedback_id')::uuid
   WHERE s.fixture_id=57 AND s.key='run1' AND f.channel='miner'$$, 'eq', '3', true, 'P4'),

(57, 23, 'and the evidence names the actual occasion dates, so a human can audit what the miner claims to have seen',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3 f
   WHERE f.machine_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=57 AND key='mA')
     AND f.channel='miner' AND f.note LIKE '%2030-01-10%'$$, 'gte', '2', true, 'P4'),

(57, 24, 'THE CS GATE HOLDS: every proposal is pending. The miner proposes, it never applies',
 $$SELECT count(*)::text FROM public.feedback_proposals_v3
   WHERE machine_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=57 AND key='mA')
     AND status <> 'pending'$$, 'eq', '0', true, 'P4'),

(57, 25, '⛔ NON-VACUITY for seq 24: there ARE three pending proposals to gate',
 $$SELECT count(*)::text FROM public.feedback_proposals_v3
   WHERE machine_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=57 AND key='mA')
     AND status = 'pending'$$, 'eq', '3', true, 'P4'),

(57, 26, 'and NOT ONE pin was minted: only CS approval mints a pin',
 $$SELECT count(*)::text FROM public.planning_pins_v3
   WHERE machine_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=57 AND key='mA')$$,
 'eq', '0', true, 'P4'),

(57, 27, 'IDEMPOTENCY: a second run on unchanged inputs learns nothing new',
 $$SELECT value->>'proposals_made' FROM golden.scratch WHERE fixture_id=57 AND key='run2'$$, 'eq', '0', true, 'P4'),

(57, 28, 'and it says WHY - three targets already have an identical proposal waiting, so no fresh evidence was spent',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'skipped') e
   WHERE s.fixture_id=57 AND s.key='run2' AND e->>'reason'='already_pending_identical'$$, 'eq', '3', true, 'P4'),

(57, 29, 'the ledger did NOT grow on the second run: exactly three miner rows for this machine, not six',
 $$SELECT count(*)::text FROM public.feedback_ledger_v3
   WHERE machine_id = (SELECT (value #>> '{}')::uuid FROM golden.scratch WHERE fixture_id=57 AND key='mA')
     AND channel='miner'$$, 'eq', '3', true, 'P4'),

(57, 30, 'DRY RUN computes the same three proposals...',
 $$SELECT value->>'proposals_made' FROM golden.scratch WHERE fixture_id=57 AND key='dry'$$, 'eq', '3', true, 'P4'),

(57, 31, '...and writes absolutely nothing while doing it',
 $$SELECT ((SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='ledger_before')
        = (SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='ledger_after_dry'))::text$$,
 'eq', 'true', true, 'P4'),

(57, 32, 'and a dry run mints no proposal_id, because it minted no proposal',
 $$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'proposals') e
   WHERE s.fixture_id=57 AND s.key='dry' AND e->>'proposal_id' IS NOT NULL$$, 'eq', '0', true, 'P4'),

(57, 33, 'THE MACHINE SCOPE ACTUALLY BITES: the same call on a clean machine finds nothing. This is what keeps the fixture hermetic against every other 2030-dated fixture',
 $$SELECT value->>'clusters_found' FROM golden.scratch WHERE fixture_id=57 AND key='scope'$$, 'eq', '0', true, 'P4'),

(57, 34, 'min_occurrences of 1 is refused by name: one edit is not a recurrence',
 $$SELECT (value #>> '{}') LIKE '%one edit is not a recurrence%' FROM golden.scratch WHERE fixture_id=57 AND key='min_occ_1_refusal'$$,
 'eq', 'true', true, 'P4'),

(57, 35, 'ATTRIBUTION IS RESTORED after the inner canonical verbs: without the re-stamp every write in this transaction would be audited as propose_pin_from_feedback_v3 (the fixture-56 seq-24 landmine)',
 $$SELECT value #>> '{}' FROM golden.scratch WHERE fixture_id=57 AND key='rpc_name_after_run'$$,
 'eq', 'mine_edit_history_v3', true, 'P4'),

(57, 36, 'ARTICLE 16: the miner asks "is a pin in force?" and therefore reads the canonical view, never the base table whose allow-list covers only the two uniqueness-slot verbs',
 $$SELECT (prosrc ~ 'v_planning_pins_active_v3' AND prosrc !~ 'FROM public\.planning_pins_v3')::text
   FROM pg_proc WHERE proname='mine_edit_history_v3'$$, 'eq', 'true', true, 'P4'),

(57, 37, 'ARTICLE 1: the miner writes neither queue table directly - both keep exactly one canonical writer',
 $$SELECT (prosrc !~ 'INSERT INTO public\.feedback_proposals_v3' AND prosrc !~ 'INSERT INTO public\.feedback_ledger_v3')::text
   FROM pg_proc WHERE proname='mine_edit_history_v3'$$, 'eq', 'true', true, 'P4'),

(57, 38, 'S-104 ACL: anon holds nothing on the miner, matching its P4.1 siblings',
 $$SELECT (COALESCE(array_to_string(proacl,' ; '),'') NOT LIKE '%anon=%')::text
   FROM pg_proc WHERE proname='mine_edit_history_v3'$$, 'eq', 'true', true, 'P4'),

(57, 39, 'exactly ONE overload exists - a second signature would be a silent foot-gun',
 $$SELECT count(*)::text FROM pg_proc WHERE proname='mine_edit_history_v3'$$, 'eq', '1', true, 'P4');
