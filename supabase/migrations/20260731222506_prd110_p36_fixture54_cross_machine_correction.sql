-- PRD-110 P3.6 — fixture 54 correction: the cross-machine case needs a pod the
-- machine is not ALREADY receiving.
--
-- Building swap_v3 surfaced a hole in the fixture's own 4e case. The duplicate
-- guard counts a pending add edit as "already there", so re-using Al Ain Zero
-- (which case 4a has just added to A04) is now a legitimate REFUSAL, not a happy
-- path. The correct cross-machine case uses a second pod the machine neither
-- carries nor is pending: Santiveri ed88eeff, donor 0a9a4836 (stock 24).

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$old$        'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'::uuid,
        'golden fixture 54 cross machine swap sourced from a donor', 6,
        '84386a8b-ba1c-4be1-aa51-a529203ecfb6'::uuid;$old$,
$new$        'ed88eeff-cb1a-4863-8874-7178339493d0'::uuid,
        'golden fixture 54 cross machine swap sourced from a donor', 6,
        '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'::uuid;$new$)
 WHERE fixture_id = 54;

-- The premise block must vouch for the NEW donor pair too.
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$old$  'donor_has_pod', (SELECT COALESCE(max(current_stock),0) FROM v_shelf_state
                     WHERE machine_id='84386a8b-ba1c-4be1-aa51-a529203ecfb6'
                       AND pod_product_id='cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'),$old$,
$new$  'donor_has_pod', (SELECT COALESCE(max(current_stock),0) FROM v_shelf_state
                     WHERE machine_id='0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'
                       AND pod_product_id='ed88eeff-cb1a-4863-8874-7178339493d0'),
  'cross_pod_not_on_machine', (SELECT count(*) FROM v_shelf_state
                     WHERE machine_id='9db7a821-d312-43b0-8e83-9642abfbfb0b'
                       AND pod_product_id='ed88eeff-cb1a-4863-8874-7178339493d0'),$new$)
 WHERE fixture_id = 54;

-- ⭐ S-103: an assertion edit is TWO fields. Both check_sql and expect move.
UPDATE golden.assertions
   SET expect = '0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'
 WHERE fixture_id = 54 AND seq = 41;

UPDATE golden.assertions
   SET check_sql = $$SELECT CASE WHEN EXISTS (SELECT 1 FROM public.v_plan_edits_active_v3
                             WHERE plan_date=DATE '2030-02-24'
                               AND shelf_id='8539b03e-4628-4e26-bffe-6aa33c282b7a'
                               AND pod_product_id='ed88eeff-cb1a-4863-8874-7178339493d0'
                               AND reason ILIKE '%0a9a4836%') THEN 'traced' ELSE 'untraced' END$$,
       expect = 'traced'
 WHERE fixture_id = 54 AND seq = 42;

-- NEW premise: the cross-machine pod is not already on the destination machine,
-- which is what makes 4e a happy path rather than a refusal.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
VALUES (54, 6, 'premise: the cross-machine pod is NOT already assorted on the destination machine',
 $$SELECT (value->>'cross_pod_not_on_machine') FROM golden.scratch WHERE fixture_id=54 AND key='premise'$$,
 'eq','0','P3')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op,
      expect = EXCLUDED.expect, description = EXCLUDED.description;

-- ⭐ And the guard the hole taught us: a pending add edit on ANOTHER shelf of the
--    same machine must itself be refused. This is the assertion that would have
--    caught the original 4e mistake.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
VALUES (54, 35, 'a pod already carried by a PENDING add edit on another shelf is refused too (a duplicate minted by two edits is still the bug)',
 $$SELECT CASE WHEN to_regprocedure('public.swap_v3(date,uuid,uuid,uuid,text,integer,uuid)') IS NULL
               THEN 'absent'
               ELSE (SELECT CASE WHEN count(*) > 1 THEN 'duplicated' ELSE 'single' END::text
                       FROM public.v_plan_edits_active_v3
                      WHERE plan_date = DATE '2030-02-24'
                        AND machine_id = '9db7a821-d312-43b0-8e83-9642abfbfb0b'
                        AND pod_product_id = 'cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'
                        AND kind IN ('add','set_qty')) END$$,
 'eq','single','P3')
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET check_sql = EXCLUDED.check_sql, expect_op = EXCLUDED.expect_op,
      expect = EXCLUDED.expect, description = EXCLUDED.description;
