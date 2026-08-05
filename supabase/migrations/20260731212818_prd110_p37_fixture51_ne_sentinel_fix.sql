-- PRD-110 P3.7 — fixture 51, second vacuous-green catch.
-- ⛔ Seq 42 used the `ne` operator against the sentinel: 'no_pipeline' <> 'none'
--    is TRUE, so the assertion went green in a world with no approver at all.
--    A sentinel defeats `eq` but FEEDS `ne`. The probe now names the run whose
--    approval was retired and the assertion demands it be the right one, which
--    no sentinel can satisfy.
-- ⭐ Rule earned: in this suite an assertion may use `ne`/`not_null` only when
--    the sentinel itself would fail it. Otherwise state the positive.

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$old$      v := v || jsonb_build_object('switch', r->>'status')
             || jsonb_build_object('switch_superseded', COALESCE(r->>'superseded_approval_of','none'));$old$,
$new$      v := v || jsonb_build_object('switch', r->>'status')
             || jsonb_build_object('switch_retired_the_standing_approval',
                  (COALESCE(r->>'superseded_approval_of','none') = p2::text)::text);$new$)
 WHERE fixture_id = 51;

UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$old$                                 'switch','no_pipeline','switch_superseded','no_pipeline',$old$,
$new$                                 'switch','no_pipeline',
                                 'switch_retired_the_standing_approval','no_pipeline',$new$)
 WHERE fixture_id = 51;

UPDATE golden.assertions
   SET check_sql = $c$SELECT value->>'switch_retired_the_standing_approval' FROM golden.scratch WHERE fixture_id=51 AND key='approve'$c$,
       expect_op = 'eq',
       expect    = 'true',
       description = '...but it RETIRES the standing approval, naming the exact run it retired -- never silently, never two plans for one night'
 WHERE fixture_id = 51 AND seq = 42;
