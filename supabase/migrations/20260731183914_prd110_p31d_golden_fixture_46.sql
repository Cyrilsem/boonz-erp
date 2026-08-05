-- PRD-110 P3.1d — golden fixture 46: FEFO SKU binding.
--
-- ⛔ LAW 1, FIXTURE FIRST: the incident this closes is that EVERY warehouse-rung stitch_v3
-- row shipped with boonz_product_id NULL and a 'deferred_to_p31d' marker - a plan that named
-- a pod but never a product, so no picker could be told which flavour, and no batch could be
-- reserved. This fixture proves the binding, its FEFO order, its expiry refusal, and the
-- marker's removal.
--
-- ⭐ WHY THE ASSERTIONS ARE INVARIANTS, NOT PINNED NUMBERS: warehouse stock moves every day,
-- so an assertion like "binds exactly 34 units" would go red on ordinary trading, not on a
-- defect. Every assertion below is a property that must hold for ANY stock: conservation,
-- monotone FEFO order, no expired batch, no sentinel, no duplicate SKU, named reasons.
--
-- ⛔ THE HORIZON SPLIT IS THE POINT (and it is why this fixture calls the seam TWICE). The
-- fixture's own plan_date is 2030-02-16; the newest real non-sentinel batch in the warehouse
-- expires 2027-12-29. So on the fixture's own date LAW 7 must refuse EVERY batch - which is
-- exactly what assertions 15-17 pin - while the "today" call proves the same seam binds
-- happily when the stock is genuinely in date. A fixture that only ran on 2030 would have
-- proved nothing but the refusal.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (
  46,
  'FEFO SKU binding: stitch_v3 warehouse rungs bind a real boonz_product_id and a real batch, oldest stock first ACROSS every variant of the pod, refusing anything expired by the plan date - replacing the blanket deferred_to_p31d NULL (P3.1d)',
  'PRD-110 P3.1d (2026-07-31): every stitch_v3 warehouse-rung row landed with boonz_product_id NULL and reasoning.sku_binding=deferred_to_p31d, so the plan named a pod but never a SKU or a batch',
  'P3',
  DATE '2030-02-16',
$FX46$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- (1) THE SEAM ON A REAL HORIZON. Machine 0a9a4836 / shelf 48d19499 carries pod abc20f95,
--     which has 7 Active variants and (at build time) 6 of them stocked across 8 real
--     batches at the primary warehouse - the widest multi-SKU case on the fleet, so the
--     cross-variant FEFO merge is genuinely exercised rather than trivially satisfied.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'seam_today',
       public.resolve_fefo_sku_legs_v3(
         (now() AT TIME ZONE 'Asia/Dubai')::date,
         '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'::uuid,
         '48d19499-5d25-495f-8ffc-78842b5d30e2'::uuid,
         'abc20f95-9180-4d4f-bc0b-223bbd6eed16'::uuid,
         20, 'variant');

-- (2) THE SAME CALL ON THE FIXTURE'S OWN 2030 HORIZON. ⛔ LAW 7: nothing in the warehouse is
--     still in date in 2030, so not one unit may bind, and the refusal must be NAMED.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'seam_2030',
       public.resolve_fefo_sku_legs_v3(
         {{plan_date}},
         '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'::uuid,
         '48d19499-5d25-495f-8ffc-78842b5d30e2'::uuid,
         'abc20f95-9180-4d4f-bc0b-223bbd6eed16'::uuid,
         20, 'variant');

-- (3) END TO END THROUGH stitch_v3, on a synthetic source run of this fixture's own. A fresh
--     run_id per execution (recorded in scratch first, then read back as a separate
--     statement - ⛔ S-93: a sibling subquery could not see this write).
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'src_run', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   current_stock, max_stock, wh_available_pod, availability_basis, reasoning)
SELECT ((SELECT s.value FROM golden.scratch s
          WHERE s.fixture_id = {{fixture_id}} AND s.key = 'src_run') #>> '{}')::uuid,
       'golden_fx46', {{plan_date}},
       '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'::uuid,
       '48d19499-5d25-495f-8ffc-78842b5d30e2'::uuid,
       'abc20f95-9180-4d4f-bc0b-223bbd6eed16'::uuid,
       12, 0, 12, 34, 'boonz_wh',
       jsonb_build_object('source','golden fixture 46', 'note','synthetic source line for the P3.1d binding proof');

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'stitch',
       public.stitch_v3({{plan_date}},
         ((SELECT s.value FROM golden.scratch s
            WHERE s.fixture_id = {{fixture_id}} AND s.key = 'src_run') #>> '{}')::uuid);
$FX46$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

(46, 1, 'Drift guard: {{plan_date}} still renders as fixture 46''s own date',
 $A$SELECT ({{plan_date}})::text$A$, 'eq', '2030-02-16', true, 'P3'),

(46, 2, 'Anchor guard: shelf 48d19499 is still on machine 0a9a4836 carrying pod abc20f95',
 $A$SELECT (EXISTS (SELECT 1 FROM public.v_shelf_state ss
                    WHERE ss.shelf_id = '48d19499-5d25-495f-8ffc-78842b5d30e2'
                      AND ss.machine_id = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'
                      AND ss.pod_product_id = 'abc20f95-9180-4d4f-bc0b-223bbd6eed16'))::text$A$,
 'eq', 'true', true, 'P3'),

(46, 3, 'Anchor guard: the pod still carries more than one Active variant, so the cross-SKU merge is a real merge',
 $A$SELECT count(DISTINCT pm.boonz_product_id)::text FROM public.product_mapping pm
    WHERE pm.pod_product_id = 'abc20f95-9180-4d4f-bc0b-223bbd6eed16' AND pm.status = 'Active'
      AND (pm.machine_id = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04' OR pm.machine_id IS NULL)$A$,
 'gte', '2', true, 'P3'),

-- ---- the seam on a real horizon: it binds, and what it binds is coherent ----------------
(46, 4, 'On a real horizon the seam BINDS: qty_bound > 0 (the whole point of P3.1d)',
 $A$SELECT (value->>'qty_bound') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'seam_today'$A$,
 'gt', '0', true, 'P3'),

(46, 5, 'LAW 5 conservation: qty_bound + qty_unbound = qty_in, so no unit is lost in the binding step',
 $A$SELECT (((value->>'qty_bound')::int + (value->>'qty_unbound')::int) = (value->>'qty_in')::int)::text
    FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'seam_today'$A$,
 'eq', 'true', true, 'P3'),

(46, 6, 'The legs account for exactly the bound units: SUM(leg.qty) = qty_bound',
 $A$SELECT ((SELECT COALESCE(SUM((t.e->>'qty')::int),0)
             FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS t(e)
            WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today')
          = (SELECT (value->>'qty_bound')::int FROM golden.scratch
              WHERE fixture_id = {{fixture_id}} AND key = 'seam_today'))::text$A$,
 'eq', 'true', true, 'P3'),

(46, 7, 'The merge really is cross-SKU: 20 units draw on at least 2 distinct SKUs',
 $A$SELECT (value->>'n_legs') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'seam_today'$A$,
 'gte', '2', true, 'P3'),

(46, 8, 'Every leg names a SKU: zero legs carry a NULL boonz_product_id',
 $A$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS t(e)
    WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today'
      AND COALESCE(t.e->>'boonz_product_id','') = ''$A$,
 'eq', '0', true, 'P3'),

(46, 9, 'No product_mapping fan-out: one leg per SKU, never the same SKU twice',
 $A$SELECT ((SELECT count(DISTINCT t.e->>'boonz_product_id')
             FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS t(e)
            WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today')
          = (SELECT jsonb_array_length(value->'legs') FROM golden.scratch
              WHERE fixture_id = {{fixture_id}} AND key = 'seam_today'))::text$A$,
 'eq', 'true', true, 'P3'),

(46, 10, 'LAW 6 FEFO: the legs come back in non-decreasing expiry order ACROSS SKUs (oldest stock leaves first)',
 $A$SELECT (ARRAY(SELECT (t.e->>'earliest_expiry')::date
                   FROM golden.scratch s, jsonb_array_elements(s.value->'legs') WITH ORDINALITY AS t(e, ord)
                  WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today' ORDER BY t.ord)
          = ARRAY(SELECT (t.e->>'earliest_expiry')::date
                    FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS t(e)
                   WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today'
                   ORDER BY 1 ASC NULLS LAST))::text$A$,
 'eq', 'true', true, 'P3'),

(46, 11, 'LAW 7 expiry iron rule: not one bound batch expires before the date it was bound for',
 $A$SELECT count(*)::text
    FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS l(e),
         jsonb_array_elements(l.e->'batches') AS b(x)
   WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today'
     AND (b.x->>'expiration_date')::date < (now() AT TIME ZONE 'Asia/Dubai')::date$A$,
 'eq', '0', true, 'P3'),

(46, 12, 'S-63 sentinels are not supply: no VOXSOURCE phantom batch is ever bound',
 $A$SELECT count(*)::text
    FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS l(e),
         jsonb_array_elements(l.e->'batches') AS b(x)
   WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today'
     AND b.x->>'batch_id' LIKE 'VOXSOURCE-%'$A$,
 'eq', '0', true, 'P3'),

(46, 13, 'Each leg''s batch detail adds up to that leg''s qty (the batch trail is real, not decorative)',
 $A$SELECT count(*)::text FROM (
     SELECT (l.e->>'qty')::int AS leg_qty,
            (SELECT COALESCE(SUM((b.x->>'qty_taken')::int),0)
               FROM jsonb_array_elements(l.e->'batches') AS b(x)) AS batch_qty
       FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS l(e)
      WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today') z
   WHERE z.leg_qty <> z.batch_qty$A$,
 'eq', '0', true, 'P3'),

(46, 14, 'Every leg names the batch the picker should pull: preferred_wh_inventory_id is never NULL',
 $A$SELECT count(*)::text FROM golden.scratch s, jsonb_array_elements(s.value->'legs') AS t(e)
    WHERE s.fixture_id = {{fixture_id}} AND s.key = 'seam_today'
      AND COALESCE(t.e->>'preferred_wh_inventory_id','') = ''$A$,
 'eq', '0', true, 'P3'),

(46, 15, 'Article 16 pin: the seam CONVERGES on the canonical FEFO walker rather than mirroring it',
 $A$SELECT (value->>'canonical_walker') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'seam_today'$A$,
 'eq', 'public.wh_fefo_for_line', true, 'P3'),

-- ---- the same seam on the 2030 horizon: LAW 7 refuses, and says why --------------------
(46, 16, 'LAW 7 on the fixture''s own 2030 date: every real batch has expired, so the seam binds NOTHING',
 $A$SELECT (value->>'qty_bound') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'seam_2030'$A$,
 'eq', '0', true, 'P3'),

(46, 17, 'and it refuses out loud: status is unbound',
 $A$SELECT (value->>'status') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'seam_2030'$A$,
 'eq', 'unbound', true, 'P3'),

(46, 18, 'LAW 5: the refusal carries a NAMED reason, never a bare NULL',
 $A$SELECT (value->>'unbound_reason') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'seam_2030'$A$,
 'eq', 'no_pickable_batch_in_scope', true, 'P3'),

-- ---- end to end through stitch_v3 ------------------------------------------------------
(46, 19, 'stitch_v3 now reports FEFO binding in its return contract',
 $A$SELECT (value->>'sku_binding') FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$A$,
 'eq', 'fefo_v3', true, 'P3'),

(46, 20, 'THE MARKER IS GONE: not one row of the run still carries deferred_to_p31d',
 $A$SELECT count(*)::text FROM public.refill_plan_output_shadow o
    WHERE o.run_id = ((SELECT value FROM golden.scratch
                        WHERE fixture_id = {{fixture_id}} AND key = 'stitch')->>'run_id')::uuid
      AND o.reasoning::text LIKE '%deferred_to_p31d%'$A$,
 'eq', '0', true, 'P3'),

(46, 21, 'Every warehouse-rung row declares its binding state: fefo_bound or unbound, nothing else and nothing absent',
 $A$SELECT count(*)::text FROM public.refill_plan_output_shadow o
    WHERE o.run_id = ((SELECT value FROM golden.scratch
                        WHERE fixture_id = {{fixture_id}} AND key = 'stitch')->>'run_id')::uuid
      AND o.action <> 'Blocked'
      AND COALESCE(o.reasoning->>'sku_binding','') NOT IN ('fefo_bound','unbound')$A$,
 'eq', '0', true, 'P3'),

(46, 22, 'LAW 5 on every unbound row: a named unbound_reason, never silence',
 $A$SELECT count(*)::text FROM public.refill_plan_output_shadow o
    WHERE o.run_id = ((SELECT value FROM golden.scratch
                        WHERE fixture_id = {{fixture_id}} AND key = 'stitch')->>'run_id')::uuid
      AND o.reasoning->>'sku_binding' = 'unbound'
      AND COALESCE(o.reasoning->>'unbound_reason','') = ''$A$,
 'eq', '0', true, 'P3'),

(46, 23, 'Every bound row names both the SKU and the batch (a plan a picker can actually execute)',
 $A$SELECT count(*)::text FROM public.refill_plan_output_shadow o
    WHERE o.run_id = ((SELECT value FROM golden.scratch
                        WHERE fixture_id = {{fixture_id}} AND key = 'stitch')->>'run_id')::uuid
      AND o.reasoning->>'sku_binding' = 'fefo_bound'
      AND (o.boonz_product_id IS NULL OR o.preferred_wh_inventory_id IS NULL)$A$,
 'eq', '0', true, 'P3'),

(46, 24, 'stitch conservation still holds through the split: units_in = units_placed + units_blocked',
 $A$SELECT (((value->>'units_placed')::int + (value->>'units_blocked')::int) = (value->>'units_in')::int)::text
    FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$A$,
 'eq', 'true', true, 'P3'),

(46, 25, 'The ladder keeps placement authority: the seam never places more than the ladder resolved',
 $A$SELECT (((value->>'units_sku_bound')::int + (value->>'units_sku_unbound')::int)
          <= (value->>'units_in')::int)::text
    FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$A$,
 'eq', 'true', true, 'P3'),

(46, 26, 'Regression: on the 2030 horizon nothing binds, so the row count is unchanged from the pre-P3.1d shape (no row inflation)',
 $A$SELECT ((value->>'rows_out')::int = (value->>'lines_in')::int)::text
    FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$A$,
 'eq', 'true', true, 'P3'),

(46, 27, 'The ladder''s line-level shortfall is never multiplied across a split: at most one row per source line carries it',
 $A$SELECT count(*)::text FROM (
     SELECT o.machine_id, o.shelf_id, o.anchor_pod_product_id, count(*) FILTER (WHERE o.qty_shortfall > 0) AS n
       FROM public.refill_plan_output_shadow o
      WHERE o.run_id = ((SELECT value FROM golden.scratch
                          WHERE fixture_id = {{fixture_id}} AND key = 'stitch')->>'run_id')::uuid
        AND o.action <> 'Blocked'
      GROUP BY 1,2,3) z
   WHERE z.n > 1$A$,
 'eq', '0', true, 'P3');
