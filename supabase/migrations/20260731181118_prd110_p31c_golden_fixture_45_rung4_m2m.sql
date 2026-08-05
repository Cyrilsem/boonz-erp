-- PRD-110 P3.1c · GOLDEN FIXTURE 45 — the rung-4 m2m path (S-89, S-91, S-92)
--
-- LAW 1: incident closed <=> fixture exists. S-89 ("the m2m branch has never executed") is
-- closed by this fixture plus the recorded end-to-end proof in the EXECUTION-LOG.
--
-- ⛔ WHY THIS ASSERTS THE SEAM AND NOT stitch_v3 END-TO-END. Rung 4 is UNREACHABLE through
--    the ladder on live data: all 544 shelves with a pod terminate at rung 1 (383) or rung 2
--    (161), and rung 2 shadows rung 4 even for partner_managed machines. Driving stitch_v3
--    into rung 4 requires neutralising find_substitutes_for_shelf_v3, which is only legal
--    inside a rolled-back envelope -- not something a fixture may leave behind. So the
--    fixture asserts the SEAM (resolve_m2m_donor_legs_v3), which carries the whole rung-4
--    decision and IS reachable, and stitch_v3's own call into it is one line.
--
-- Assertions are STRUCTURAL and self-consistent (A vs B computed two ways), never pinned to
-- today's unit counts, so ordinary fleet movement does not flake them -- but a genuine
-- regression in donor choice, the clamp, or the transfer-only filter does turn them red.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql)
VALUES (45,
'rung-4 m2m resolves a donor whose SKU mix is actually knowable, clamps to THAT donor''s excess rather than the fleet-wide sum, and lets only assortable units cross - the three defects that hid behind a branch no input could reach (P3.1c / S-89, S-91, S-92)',
'PRD-110 S-89/S-91/S-92 (2026-07-31): the rung-4 m2m branch had never executed and could not have',
'P3', DATE '2030-02-15',
$scenario$
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- (1) THE LADDER'S OWN rung-4 log, for the Article 16 parity pin. Emitted on EVERY ladder
--     call regardless of which rung wins, so this is reachable even though rung 4 is not.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'ladder_rung4',
       (public.resolve_supply_ladder_v3(
          {{plan_date}},
          '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,
          '5949e4ac-5f03-43b5-98d4-2ebc157fcf65'::uuid,
          'b1827ff7-ef99-4c85-8606-c089a9fc276d'::uuid, 4, 5) -> 'ladder') -> 3;

-- (2) The SAME donor set via the named function. ⛔ Article 16: list_m2m_donors_v3 is a
--     deliberate MIRROR of the ladder's inline rung-4 predicate (both read
--     COALESCE(velocity_instock, velocity_raw, 0) off v_shelf_state, which per S-73 means
--     velocity_raw in practice). The mirror is only tolerable while it is PINNED - that is
--     what assertions 4 and 5 are for. If either object's rule moves, this fixture goes red
--     instead of the two drifting apart silently.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'donors', jsonb_build_object(
  'machines',   count(DISTINCT d.donor_machine_id),
  'excess_sum', COALESCE(SUM(d.excess_units), 0),
  'shelves',    count(*),
  'top_excess', COALESCE(MAX(d.excess_units), 0),
  'first_excess', COALESCE((SELECT d2.excess_units
                              FROM public.list_m2m_donors_v3(
                                     'b1827ff7-ef99-4c85-8606-c089a9fc276d'::uuid,
                                     '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid) d2
                             LIMIT 1), 0))
FROM public.list_m2m_donors_v3(
       'b1827ff7-ef99-4c85-8606-c089a9fc276d'::uuid,
       '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid) d;

-- (3) THE SEAM. to_regprocedure-guarded so a RED baseline still lands every fact above.
DO $do$
BEGIN
  IF to_regprocedure('public.resolve_m2m_donor_legs_v3(date,uuid,uuid,uuid,integer)') IS NOT NULL THEN
    EXECUTE $x$
      INSERT INTO golden.scratch (fixture_id, key, value)
      SELECT 45, 'seam', public.resolve_m2m_donor_legs_v3(
        DATE '2030-02-15',
        '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid,
        '5949e4ac-5f03-43b5-98d4-2ebc157fcf65'::uuid,
        'b1827ff7-ef99-4c85-8606-c089a9fc276d'::uuid, 4)
    $x$;
  END IF;
END
$do$;
$scenario$);

INSERT INTO golden.assertions
  (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES

(45, 1, 'Drift guard: {{plan_date}} still renders as the fixture-45 anchor 2030-02-15',
 'SELECT {{plan_date}}::text', 'eq', '2030-02-15', true, 'P3'),

(45, 2, 'Anchor guard: destination shelf 5949e4ac is still on machine 148c4fcf carrying pod b1827ff7',
 $q$SELECT (s.machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid
            AND s.pod_product_id = 'b1827ff7-ef99-4c85-8606-c089a9fc276d'::uuid)::text
      FROM public.v_shelf_state s WHERE s.shelf_id = '5949e4ac-5f03-43b5-98d4-2ebc157fcf65'::uuid$q$,
 'eq', 'true', true, 'P3'),

(45, 3, 'The ladder log entry read for the pin is genuinely rung 4 (array index 3), not a neighbour',
 $q$SELECT value->>'rung' FROM golden.scratch WHERE fixture_id=45 AND key='ladder_rung4'$q$,
 'eq', 'm2m', true, 'P3'),

-- ⛔ Article 16 PIN (Cody, binding). Two objects, one rule.
(45, 4, 'Art16 pin: list_m2m_donors_v3 names exactly as many donor MACHINES as the ladder counted',
 $q$SELECT ((SELECT value->>'machines' FROM golden.scratch WHERE fixture_id=45 AND key='donors')
          = (SELECT value#>>'{detail,donor_machines}' FROM golden.scratch WHERE fixture_id=45 AND key='ladder_rung4'))::text$q$,
 'eq', 'true', true, 'P3'),

(45, 5, 'Art16 pin: the two objects agree on TOTAL donor excess, so the overstock rule cannot drift',
 $q$SELECT ((SELECT (value->>'excess_sum')::numeric FROM golden.scratch WHERE fixture_id=45 AND key='donors')
          = (SELECT (value#>>'{detail,donor_excess_units}')::numeric FROM golden.scratch WHERE fixture_id=45 AND key='ladder_rung4'))::text$q$,
 'eq', 'true', true, 'P3'),

(45, 6, 'Donor ordering is excess-DESC and total: the first row returned IS the maximum excess',
 $q$SELECT ((SELECT (value->>'first_excess')::int FROM golden.scratch WHERE fixture_id=45 AND key='donors')
          = (SELECT (value->>'top_excess')::int FROM golden.scratch WHERE fixture_id=45 AND key='donors'))::text$q$,
 'eq', 'true', true, 'P3'),

-- The seam itself.
(45, 7, 'S-89: the rung-4 seam RESOLVES - the branch that had never executed now returns ok',
 $q$SELECT value->>'status' FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'ok', true, 'P3'),

(45, 8, 'S-91 D1: a donor MACHINE is actually named (the old payload carried only a count, so this was always NULL)',
 $q$SELECT (value#>>'{donor,donor_machine_id}' IS NOT NULL)::text
      FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'true', true, 'P3'),

(45, 9, 'P3.1d precondition: every emitted leg is SKU-bound - no leg carries a NULL boonz_product_id',
 $q$SELECT COALESCE(count(*) FILTER (WHERE e->>'boonz_product_id' IS NULL), 0)::text
      FROM golden.scratch s, jsonb_array_elements(COALESCE(s.value->'legs','[]'::jsonb)) e
     WHERE s.fixture_id=45 AND s.key='seam'$q$,
 'eq', '0', true, 'P3'),

(45, 10, 'LAW 5: no leg is a silent qty-0 - every emitted leg moves at least one unit',
 $q$SELECT COALESCE(count(*) FILTER (WHERE COALESCE((e->>'qty')::int,0) <= 0), 0)::text
      FROM golden.scratch s, jsonb_array_elements(COALESCE(s.value->'legs','[]'::jsonb)) e
     WHERE s.fixture_id=45 AND s.key='seam'$q$,
 'eq', '0', true, 'P3'),

(45, 11, 'S-91 D3: units placed never exceed the CHOSEN donor''s own excess (not the fleet-wide sum the ladder reports)',
 $q$SELECT ((value->>'units_placeable')::int <= (value#>>'{donor,excess_units}')::int)::text
      FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'true', true, 'P3'),

(45, 12, 'S-91 D3: the cap is LEAST(qty_needed, donor excess) and the legs sum to exactly units_placeable',
 $q$SELECT ((value->>'qty_cap')::int = LEAST((value->>'qty_needed')::int, (value#>>'{donor,excess_units}')::int)
          AND (value->>'units_placeable')::int
              = (SELECT COALESCE(SUM((e->>'qty')::int),0)
                   FROM jsonb_array_elements(COALESCE(value->'legs','[]'::jsonb)) e))::text
      FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'true', true, 'P3'),

-- ⛔ D4: the defect that would have pushed non-assortable stock into a machine.
(45, 13, 'S-91 D4: ONLY leg=transfer crosses - every emitted SKU is a transfer leg in the underlying m2m split',
 $q$SELECT COALESCE(count(*) FILTER (WHERE NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(COALESCE(s.value#>'{m2m,legs}','[]'::jsonb)) m
           WHERE m->>'boonz_product_id' = e->>'boonz_product_id' AND m->>'leg' = 'transfer')), 0)::text
      FROM golden.scratch s, jsonb_array_elements(COALESCE(s.value->'legs','[]'::jsonb)) e
     WHERE s.fixture_id=45 AND s.key='seam'$q$,
 'eq', '0', true, 'P3'),

(45, 14, 'S-91 D4: units the callee refused are REPORTED, never dropped and never re-placed',
 $q$SELECT (jsonb_typeof(value->'not_transferred') = 'array')::text
      FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'true', true, 'P3'),

-- S-92: the resolvable-donor walk.
(45, 15, 'S-92: every donor attempt is recorded - attempts length equals donors_tried, so a block can name what it tried',
 $q$SELECT ((SELECT jsonb_array_length(COALESCE(value->'attempts','[]'::jsonb))
             FROM golden.scratch WHERE fixture_id=45 AND key='seam')
          = (SELECT (value->>'donors_tried')::int
               FROM golden.scratch WHERE fixture_id=45 AND key='seam'))::text$q$,
 'eq', 'true', true, 'P3'),

(45, 16, 'S-92: the donor actually used is the LAST attempt and the only one whose outcome is ok',
 $q$SELECT ((value->'attempts'->-1->>'donor_shelf_id' = value#>>'{donor,donor_shelf_id}')
          AND (SELECT count(*) FROM jsonb_array_elements(COALESCE(value->'attempts','[]'::jsonb)) a
                WHERE a->>'outcome' = 'ok') = 1)::text
      FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'true', true, 'P3'),

(45, 17, 'S-92: donors skipped before the winner were skipped for a NAMED reason, never silently',
 $q$SELECT COALESCE(count(*) FILTER (WHERE COALESCE(a->>'outcome','') = ''), 0)::text
      FROM golden.scratch s, jsonb_array_elements(COALESCE(s.value->'attempts','[]'::jsonb)) a
     WHERE s.fixture_id=45 AND s.key='seam'$q$,
 'eq', '0', true, 'P3'),

(45, 18, 'The donor is on a DIFFERENT machine than the destination - m2m means machine to machine',
 $q$SELECT ((value#>>'{donor,donor_machine_id}')
          <> '148c4fcf-b794-43f0-a2a8-e6f17605b045')::text
      FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'true', true, 'P3');
