-- PRD-110 · P3.1e · migration C — golden fixture 47
--
-- Proves the blocked_demand promotion for source='stitch' end to end AND pins the mapping
-- decision that P3.1e exists to make.
--
-- ⛔ S-94 IS THE REASON THIS FIXTURE HAS TWO HALVES. Leg 66's lesson was that a fixture which
--    exercises only one horizon can go green while proving nothing. The same trap applies to a
--    mapping: the end-to-end run on this fleet can only produce TWO of the seventeen named
--    reasons ('partial_wh_limited' and 'no_pickable_batch_in_scope'), because the ladder stops
--    at rung 1 or 2 on live data. A fixture that only ran the pipeline would leave fifteen
--    mappings - including every m2m and FEFO reason - completely unproven. So the mapping is
--    asserted DIRECTLY, reason by reason, against its own named function.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, notes, enabled)
VALUES (
  47,
  'stitch_v3''s stranded units reach the procurement ledger: Blocked rows and FEFO-unbound rows are promoted into blocked_demand under source=''stitch'' through the canonical writer, merged one row per shelf on the ANCHOR pod, with every rich named reason mapped onto the four-value enum and preserved verbatim alongside it (P3.1e)',
  'BUILD SPEC P0.5 names three writers of the ledger - engine_add_pod, stitch, and the FEFO-bind step. Only engine_add existed (cron 43). Every stranded unit stitch_v3 computed since P3.1c carried the marker blocked_demand_promotion=''source=stitch writer lands with the live cutover (P3.1e)'' and reached no human: the plan knew the demand was unmet and procurement never heard about it.',
  'P3',
  DATE '2030-02-17',
  'Two halves by design (S-94): the pipeline half proves the promotion on real ladder output, which can only exercise 2 of 17 named reasons; the mapping half asserts all 17 plus the unknown-reason default and the LIKE-escape guard directly.',
  true
)
ON CONFLICT (fixture_id) DO UPDATE
  SET name = EXCLUDED.name, source_incident = EXCLUDED.source_incident,
      phase_required = EXCLUDED.phase_required, plan_date = EXCLUDED.plan_date,
      notes = EXCLUDED.notes, enabled = EXCLUDED.enabled;

UPDATE golden.fixtures SET scenario_sql = $scenario$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ---------------------------------------------------------------------------
-- (1) A FRESH SOURCE RUN. pod_refills_shadow is append-only by trigger, so a new
--     run_id per execution is the only way to re-run; recorded in scratch FIRST and
--     read back as a separate statement (⛔ S-93: a sibling subquery cannot see it).
--
--     Both anchors are asked for 900 units - far beyond anything the fleet holds - so
--     the ladder is GUARANTEED to leave a shortfall and therefore a Blocked row. The
--     premise is not assumed: assertion 6 fails loudly if it ever stops holding.
--     Anchor P (MPMCC-1058 / A02) resolves at rung 1 'variant'.
--     Anchor F (VOXMCC-1005 / A04) resolves at rung 2 'substitute', which is what makes
--     the ANCHOR-vs-emitted pod distinction testable at all.
-- ---------------------------------------------------------------------------
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'src_run', to_jsonb(gen_random_uuid());

INSERT INTO public.pod_refills_shadow
  (run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id, qty,
   current_stock, max_stock, wh_available_pod, availability_basis, reasoning)
SELECT ((SELECT s.value FROM golden.scratch s
          WHERE s.fixture_id = {{fixture_id}} AND s.key = 'src_run') #>> '{}')::uuid,
       'golden_fx47', {{plan_date}}, a.mid, a.sid, a.pid, 900, 0, 900, 0, 'boonz_wh',
       jsonb_build_object('source','golden fixture 47',
                          'note','deliberately unsatisfiable ask, so a Blocked row is structural')
FROM (VALUES
  ('9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid,'65d699ab-441c-43e7-9a5d-bbd90d0da08e'::uuid,
   'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'::uuid),
  ('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,'48907909-7b0c-438b-8183-95ceaf1b4b81'::uuid,
   '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid)
) AS a(mid,sid,pid);

-- (2) THE PIPELINE UNDER TEST.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'stitch',
       public.stitch_v3({{plan_date}},
         ((SELECT s.value FROM golden.scratch s
            WHERE s.fixture_id = {{fixture_id}} AND s.key = 'src_run') #>> '{}')::uuid);

-- (3) THE PROMOTION, through the canonical writer. ⛔ Never a direct INSERT into
--     blocked_demand - record_blocked_demand_v3 is the only write path (Article 1).
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'promote_1', public.record_blocked_demand_v3({{plan_date}}, 'stitch');

-- (4) IMMEDIATELY AGAIN, same stitch run, nothing else changed: the writer must be a
--     no-op. This is the assertion that catches an upsert key that does not actually
--     dedupe, which would grow the ledger without bound under cron.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'promote_2', public.record_blocked_demand_v3({{plan_date}}, 'stitch');

-- (5) The ledger rows themselves, captured for the structural assertions.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'ledger', COALESCE(jsonb_agg(to_jsonb(bd) ORDER BY bd.shelf_id), '[]'::jsonb)
  FROM public.blocked_demand bd
 WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL;
$scenario$
WHERE fixture_id = 47;

DELETE FROM golden.assertions WHERE fixture_id = 47;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES

--------------------------------------------------------------------------------------
-- GUARDS — the fixture's own premises, so a green run can never rest on a stale anchor
--------------------------------------------------------------------------------------
(47, 1, 'Drift guard: {{plan_date}} still renders as fixture 47''s own date',
 $q$SELECT ({{plan_date}})::text$q$, 'eq', '2030-02-17', 'P3'),

(47, 2, 'Anchor guard: shelf 65d699ab is still on machine 9acce2bf carrying pod a602c923',
 $q$SELECT (EXISTS (SELECT 1 FROM public.v_shelf_state ss
                     WHERE ss.shelf_id = '65d699ab-441c-43e7-9a5d-bbd90d0da08e'
                       AND ss.machine_id = '9acce2bf-0e65-48f4-bf44-cefa0326f2c5'
                       AND ss.pod_product_id = 'a602c923-c4c0-4ecc-b5f7-3c13a1960beb'))::text$q$,
 'eq', 'true', 'P3'),

(47, 3, 'Anchor guard: shelf 48907909 is still on machine 148c4fcf carrying pod 733dcd39',
 $q$SELECT (EXISTS (SELECT 1 FROM public.v_shelf_state ss
                     WHERE ss.shelf_id = '48907909-7b0c-438b-8183-95ceaf1b4b81'
                       AND ss.machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'
                       AND ss.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'))::text$q$,
 'eq', 'true', 'P3'),

(47, 4, 'The stitch run itself succeeded',
 $q$SELECT value->>'status' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$q$,
 'eq', 'ok', 'P3'),

(47, 5, 'Both source lines were consumed',
 $q$SELECT value->>'lines_in' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$q$,
 'eq', '2', 'P3'),

(47, 6, 'PREMISE: the 900-unit ask really is unsatisfiable, so Blocked rows are structural and not a lucky snapshot',
 $q$SELECT ((value->>'units_blocked')::int > 0)::text
      FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$q$,
 'eq', 'true', 'P3'),

(47, 7, '⛔ S-94: the run carries BOTH row kinds - unplaced AND FEFO-unbound - so the merge path is genuinely exercised',
 $q$SELECT (((value->>'units_blocked')::int > 0)
           AND ((value->>'units_sku_unbound')::int > 0))::text
      FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'$q$,
 'eq', 'true', 'P3'),

--------------------------------------------------------------------------------------
-- THE PROMOTION — plumbing, conservation, idempotency, isolation
--------------------------------------------------------------------------------------
(47, 8, 'The writer accepted source=stitch at all (it raised for anything but engine_add before P3.1e)',
 $q$SELECT value->>'source' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'promote_1'$q$,
 'eq', 'stitch', 'P3'),

(47, 9, 'One ledger row per affected shelf: gaps_found = 2',
 $q$SELECT value->>'gaps_found' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'promote_1'$q$,
 'eq', '2', 'P3'),

(47, 10, 'Every gap landed: inserted + updated = gaps_found (the fixture is re-runnable, so a second execution updates rather than inserts)',
 $q$SELECT (((value->>'rows_inserted')::int + (value->>'rows_updated')::int) = (value->>'gaps_found')::int)::text
      FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'promote_1'$q$,
 'eq', 'true', 'P3'),

(47, 11, 'Nothing was wrongly retired: rows_closed_stale = 0',
 $q$SELECT value->>'rows_closed_stale' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'promote_1'$q$,
 'eq', '0', 'P3'),

(47, 12, '⛔ CONSERVATION: ledger units = stitch''s unplaced + unbound units exactly. A unit stranded by the engine cannot go missing on the way to procurement',
 $q$SELECT ((SELECT COALESCE(SUM(bd.qty_blocked),0) FROM public.blocked_demand bd
              WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL)
          = (SELECT (value->>'units_blocked')::int + (value->>'units_sku_unbound')::int
               FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'stitch'))::text$q$,
 'eq', 'true', 'P3'),

(47, 13, 'The decomposition survives the merge: on every row qty_unplaced + qty_unbound = qty_blocked',
 $q$SELECT (NOT EXISTS (
        SELECT 1 FROM public.blocked_demand bd
         WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL
           AND ((bd.reasoning->>'qty_unplaced')::int + (bd.reasoning->>'qty_unbound')::int)
               IS DISTINCT FROM bd.qty_blocked))::text$q$,
 'eq', 'true', 'P3'),

(47, 14, '⭐ THE MERGE IS REAL: the rung-1 shelf carries BOTH an unplaced and an unbound component in one row, not two rows',
 $q$SELECT (EXISTS (
        SELECT 1 FROM public.blocked_demand bd
         WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL
           AND bd.shelf_id = '65d699ab-441c-43e7-9a5d-bbd90d0da08e'
           AND (bd.reasoning->>'qty_unplaced')::int > 0
           AND (bd.reasoning->>'qty_unbound')::int  > 0))::text$q$,
 'eq', 'true', 'P3'),

(47, 15, '⭐ THE UNITS TIEBREAK: on that merged row the larger component (unplaced, partial_wh_limited) wins the enum over the smaller unbound one',
 $q$SELECT bd.reason FROM public.blocked_demand bd
       WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL
         AND bd.shelf_id = '65d699ab-441c-43e7-9a5d-bbd90d0da08e'$q$,
 'eq', 'partial_wh_limited', 'P3'),

(47, 16, '⛔ ANCHOR KEYING: the rung-2 shelf substituted onto a different pod, and the ledger row is keyed on the ANCHOR the shelf actually wanted',
 $q$SELECT bd.pod_product_id::text FROM public.blocked_demand bd
       WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL
         AND bd.shelf_id = '48907909-7b0c-438b-8183-95ceaf1b4b81'$q$,
 'eq', '733dcd39-dd50-4446-b1e4-5b36afbdf72a', 'P3'),

(47, 17, '...and the substitute pod that was actually emitted is still recorded, in the component, so nothing is hidden by the anchor keying',
 $q$SELECT (EXISTS (
        SELECT 1 FROM public.blocked_demand bd, jsonb_array_elements(bd.reasoning->'components') AS t(e)
         WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL
           AND bd.shelf_id = '48907909-7b0c-438b-8183-95ceaf1b4b81'
           AND t.e->>'emitted_pod_product_id' IS DISTINCT FROM bd.pod_product_id::text))::text$q$,
 'eq', 'true', 'P3'),

(47, 18, 'The rich named reason is preserved verbatim next to the lossy enum, so a diagnosis never depends on the enum alone',
 $q$SELECT (NOT EXISTS (
        SELECT 1 FROM public.blocked_demand bd
         WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(bd.reasoning->'components') AS t(e)
                            WHERE COALESCE(t.e->>'named_reason','') <> '')))::text$q$,
 'eq', 'true', 'P3'),

(47, 19, '⛔ RUN SCOPING: every row names the stitch run it came from, so a stale run can never be promoted as if it were current',
 $q$SELECT (NOT EXISTS (
        SELECT 1 FROM public.blocked_demand bd
         WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch' AND bd.resolved_at IS NULL
           AND bd.reasoning->>'run_id' IS DISTINCT FROM (
                 SELECT s.value->>'run_id' FROM golden.scratch s
                  WHERE s.fixture_id = {{fixture_id}} AND s.key = 'stitch')))::text$q$,
 'eq', 'true', 'P3'),

(47, 20, '⭐ IDEMPOTENT: an immediate second call inserts nothing',
 $q$SELECT value->>'rows_inserted' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'promote_2'$q$,
 'eq', '0', 'P3'),

(47, 21, '⭐ IDEMPOTENT: an immediate second call updates nothing either - the upsert key really dedupes, so cron cannot grow the ledger without bound',
 $q$SELECT value->>'rows_updated' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'promote_2'$q$,
 'eq', '0', 'P3'),

(47, 22, 'The pod_refills ''legacy'' diagnostic is an engine_add notion and is not reported for a stitch run',
 $q$SELECT value->>'legacy_skipped' FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'promote_1'$q$,
 'eq', '0', 'P3'),

(47, 23, '⛔ SOURCE ISOLATION: promoting stitch rows left every engine_add row on this date untouched',
 $q$SELECT count(*)::text FROM public.blocked_demand bd
       WHERE bd.plan_date = {{plan_date}} AND bd.source = 'engine_add'$q$,
 'eq', '0', 'P3'),

(47, 24, 'Every promoted row satisfies the four-value enum the CHECK constraint enforces',
 $q$SELECT (NOT EXISTS (
        SELECT 1 FROM public.blocked_demand bd
         WHERE bd.plan_date = {{plan_date}} AND bd.source = 'stitch'
           AND bd.reason NOT IN ('blocked_no_wh','partial_wh_limited','substitution_exhausted','routing_gap')))::text$q$,
 'eq', 'true', 'P3'),

(47, 25, '⛔ LAW 4: the promotion never reached the live procurement worklist - v_blocked_demand_open excludes synthetic 2030 dates',
 $q$SELECT count(*)::text FROM public.v_blocked_demand_open v WHERE v.plan_date = {{plan_date}}$q$,
 'eq', '0', 'P3'),

--------------------------------------------------------------------------------------
-- THE MAPPING — asserted directly, because the pipeline can only reach 2 of 17 (S-94)
--------------------------------------------------------------------------------------
(47, 26, 'Mapping: blocked_no_wh is identity',
 $q$SELECT public._blocked_demand_reason_map_v3('blocked_no_wh')$q$, 'eq', 'blocked_no_wh', 'P3'),
(47, 27, 'Mapping: partial_wh_limited is identity',
 $q$SELECT public._blocked_demand_reason_map_v3('partial_wh_limited')$q$, 'eq', 'partial_wh_limited', 'P3'),
(47, 28, 'Mapping: substitution_exhausted is identity',
 $q$SELECT public._blocked_demand_reason_map_v3('substitution_exhausted')$q$, 'eq', 'substitution_exhausted', 'P3'),
(47, 29, 'Mapping: routing_gap is identity',
 $q$SELECT public._blocked_demand_reason_map_v3('routing_gap')$q$, 'eq', 'routing_gap', 'P3'),
(47, 30, 'Mapping: rung 5 spot_buy_candidate means none on hand -> BUY it',
 $q$SELECT public._blocked_demand_reason_map_v3('spot_buy_candidate')$q$, 'eq', 'blocked_no_wh', 'P3'),
(47, 31, 'Mapping: m2m_no_donor - warehouses empty AND no sibling holds a spare -> BUY it',
 $q$SELECT public._blocked_demand_reason_map_v3('m2m_no_donor')$q$, 'eq', 'blocked_no_wh', 'P3'),
(47, 32, 'Mapping: m2m_no_donor_excess -> BUY it',
 $q$SELECT public._blocked_demand_reason_map_v3('m2m_no_donor_excess')$q$, 'eq', 'blocked_no_wh', 'P3'),
(47, 33, 'Mapping: m2m_donor_capped - a donor EXISTS, the units cannot cross -> MOVE it',
 $q$SELECT public._blocked_demand_reason_map_v3('m2m_donor_capped')$q$, 'eq', 'routing_gap', 'P3'),
(47, 34, 'Mapping: m2m_no_transferable_legs -> MOVE it',
 $q$SELECT public._blocked_demand_reason_map_v3('m2m_no_transferable_legs')$q$, 'eq', 'routing_gap', 'P3'),
(47, 35, 'Mapping: m2m_unresolved -> MOVE it',
 $q$SELECT public._blocked_demand_reason_map_v3('m2m_unresolved')$q$, 'eq', 'routing_gap', 'P3'),
(47, 36, 'Mapping: FEFO no_pickable_batch_in_scope - stock on paper, no batch to pick -> BUY it',
 $q$SELECT public._blocked_demand_reason_map_v3('no_pickable_batch_in_scope')$q$, 'eq', 'blocked_no_wh', 'P3'),
(47, 37, 'Mapping: FEFO all_batches_sentinel - ⛔ S-63, sentinels are not supply -> BUY it',
 $q$SELECT public._blocked_demand_reason_map_v3('all_batches_sentinel')$q$, 'eq', 'blocked_no_wh', 'P3'),
(47, 38, 'Mapping: FEFO no_primary_warehouse - nowhere to come FROM -> MOVE it',
 $q$SELECT public._blocked_demand_reason_map_v3('no_primary_warehouse')$q$, 'eq', 'routing_gap', 'P3'),
(47, 39, 'Mapping: FEFO no_warehouse_in_scope -> MOVE it',
 $q$SELECT public._blocked_demand_reason_map_v3('no_warehouse_in_scope')$q$, 'eq', 'routing_gap', 'P3'),
(47, 40, 'Mapping: FEFO fefo_ceiling_exhausted - some units bound, not enough',
 $q$SELECT public._blocked_demand_reason_map_v3('fefo_ceiling_exhausted')$q$, 'eq', 'partial_wh_limited', 'P3'),
(47, 41, 'Mapping: FEFO fefo_short -> partial',
 $q$SELECT public._blocked_demand_reason_map_v3('fefo_short')$q$, 'eq', 'partial_wh_limited', 'P3'),
(47, 42, 'Mapping: no_active_variants - the pod has no SKU it could even BE; an assortment decision, not a supply one',
 $q$SELECT public._blocked_demand_reason_map_v3('no_active_variants')$q$, 'eq', 'substitution_exhausted', 'P3'),
(47, 43, 'Mapping: an unrecognised reason falls back to substitution_exhausted rather than guessing a supply verdict',
 $q$SELECT public._blocked_demand_reason_map_v3('some_reason_invented_next_year')$q$, 'eq', 'substitution_exhausted', 'P3'),

(47, 44, '⛔ LIKE-ESCAPE GUARD: in LIKE, _ is a single-character WILDCARD. An unescaped ''m2m_%'' would swallow ''m2mXanything'' and silently label it routing_gap',
 $q$SELECT public._blocked_demand_reason_map_v3('m2mXnot_an_m2m_reason')$q$, 'eq', 'substitution_exhausted', 'P3'),

(47, 45, 'NULL in, safe default out - the mapping never returns NULL into a NOT NULL, CHECKed column',
 $q$SELECT COALESCE(public._blocked_demand_reason_map_v3(NULL), '(null)')$q$, 'eq', 'substitution_exhausted', 'P3'),

--------------------------------------------------------------------------------------
-- STRUCTURE — the constitutional shape, pinned so a later edit cannot quietly undo it
--------------------------------------------------------------------------------------
(47, 46, '⭐ CODY REVISION PINNED: record_blocked_demand_v3 is no longer executable by anon (S-88 - the GRANT is the write guard, not RLS)',
 $q$SELECT (p.proacl::text NOT LIKE '%anon=%')::text
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3'$q$,
 'eq', 'true', 'P3'),

(47, 47, 'The gap sources are read-only helpers: SECURITY INVOKER, never DEFINER',
 $q$SELECT (NOT bool_or(p.prosecdef))::text
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('_blocked_demand_reason_map_v3','_blocked_demand_gaps_stitch_v3',
                          '_blocked_demand_gaps_for_source_v3')$q$,
 'eq', 'true', 'P3'),

(47, 48, '⛔ Article 1: record_blocked_demand_v3 keeps its 2-arg / 1-default signature, so cron 43''s single-argument call still binds',
 $q$SELECT (p.pronargs::text || '/' || p.pronargdefaults::text)
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3'$q$,
 'eq', '2/1', 'P3'),

-- ⛔ ''pack'' must REFUSE, not quietly record nothing - a writer that returned zero rows for an
--    unimplemented source is indistinguishable from a clean night. This is pinned by SOURCE
--    INSPECTION rather than by calling it: the harness has no ''raises'' operator, and a
--    check_sql that threw would abort the entire fixture run instead of failing one assertion.
--    The BEHAVIOUR was proven live in the pre-apply dry-run (P0001, both raises fired).
(47, 49, '⛔ ''pack'' still REFUSES: both the writer guard and the dispatcher carry an explicit RAISE, so an unimplemented source can never masquerade as a clean run',
 $q$SELECT (
     (SELECT p.prosrc LIKE '%pack lands with P4.4b%'
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'record_blocked_demand_v3')
     AND
     (SELECT p.prosrc LIKE '%no gap source implemented for source%'
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = '_blocked_demand_gaps_for_source_v3')
   )::text$q$,
 'eq', 'true', 'P3'),

(47, 50, '⛔ The engine_add gap source is byte-untouched by P3.1e: routing through the dispatcher returns exactly what calling it directly returns',
 $q$SELECT (NOT EXISTS (
        (SELECT * FROM public._blocked_demand_gaps_v3(DATE '2026-07-30')
         EXCEPT SELECT * FROM public._blocked_demand_gaps_for_source_v3(DATE '2026-07-30','engine_add'))
        UNION ALL
        (SELECT * FROM public._blocked_demand_gaps_for_source_v3(DATE '2026-07-30','engine_add')
         EXCEPT SELECT * FROM public._blocked_demand_gaps_v3(DATE '2026-07-30'))))::text$q$,
 'eq', 'true', 'P3');
