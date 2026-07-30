-- PRD-110 P0.5 - golden.scratch (harness addition) + fixture 105 "blocked demand is never silent".
-- Applied via Supabase MCP as `prd110_p05_fixture_105_blocked_demand` 2026-07-30.
--
-- LAW 1 FIXTURE FIRST. P0.5's verify clause is "shadow engine run inserts rows matching its JSON
-- gaps 1:1", which is a claim about TWO artifacts produced in the same run: the value
-- engine_add_pod RETURNS, and the rows record_blocked_demand_v3 WRITES. The harness had nowhere
-- to keep a returned value between the scenario and the assertions, so fixture authors could only
-- assert against persisted tables. golden.scratch closes that gap and is reusable by every later
-- fixture that must assert on an RPC's return value (26 needs it, 18 needs it).
--
-- WHY THE FIXTURE ASSERTS CONSISTENCY, NOT ABSOLUTE COUNTS: the size of the gap set is a function
-- of live warehouse stock, which moves every day. A fixture pinned to "20 gaps" would go red for
-- a legitimate stock change and teach the loop to ignore it. So fixture 105 pins the INVARIANT
-- (engine JSON == ledger rows, to the unit, by machine/shelf/product identity) plus a
-- non-vacuity floor (>= 1 gap) so it can never pass by finding nothing at all.
-- The absolute live number IS recorded, as a scoreboard datum rather than an assertion:
-- 2026-07-30 = 20 gaps / 107 units, which matches BUILD SPEC P0.5's "07-30's 20 gaps" exactly.

CREATE TABLE IF NOT EXISTS golden.scratch (
  fixture_id  int  NOT NULL REFERENCES golden.fixtures(fixture_id) ON DELETE CASCADE,
  key         text NOT NULL,
  value       jsonb NOT NULL,
  written_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fixture_id, key)
);
COMMENT ON TABLE golden.scratch IS
  'Per-fixture scratchpad for RPC RETURN values captured during scenario_sql, so assertions can '
  'compare what a function returned against what it wrote. Cleared by the scenario, not by the runner.';
ALTER TABLE golden.scratch ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON golden.scratch FROM PUBLIC;

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, baseline_status)
VALUES (
  105,
  'Blocked demand is never silent (P0.5 ledger 1:1)',
  'PRD-110 BUILD SPEC P0.5 + LAW 5. Live baseline 2026-07-30: 17 blocked_no_wh + 3 partial_wh_limited = 20 gap rows / 107 units, clamped and labelled but with nowhere to land.',
  'P0',
  DATE '2030-04-16',
  $scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch          WHERE fixture_id = {{fixture_id}};
DELETE FROM public.blocked_demand   WHERE plan_date  = {{plan_date}};
DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_105']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_105'
FROM public.machines
WHERE official_name IN ('MPMCC-1058-0000-R0','ACTIVATEMCC-1037-0000-L0','MPMCC-1054-0000-M0');
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'engine', public.engine_add_pod({{plan_date}}, 7);
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'ledger', public.record_blocked_demand_v3({{plan_date}});
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'ledger_rerun', public.record_blocked_demand_v3({{plan_date}});
$scenario$,
  'Machines chosen because they are the three live gap producers: ACTIVATEMCC-1037 carries the largest live blocks (Aquafina 9u, Vitamin Well 8u+7u), MPMCC-1058 is the fixture-3 machine whose 5 blocked_no_wh lines include its fastest mover (Aquafina 3.23/day), MPMCC-1054 was blind pre-P0.2. Gap size tracks live WH stock, so the assertions pin the invariant and a non-vacuity floor, never a hardcoded count.',
  'passing'
)
ON CONFLICT (fixture_id) DO UPDATE
  SET scenario_sql = EXCLUDED.scenario_sql,
      notes        = EXCLUDED.notes,
      plan_date    = EXCLUDED.plan_date;

DELETE FROM golden.assertions WHERE fixture_id = 105;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required)
VALUES
(105, 1,
 'Non-vacuity: the run produced at least one blocked gap (else the fixture proves nothing)',
 $sql$SELECT (value->>'procurement_gaps_count')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'engine'$sql$,
 'gte', '1', 'P0'),

(105, 2,
 'Ledger row count equals the engine procurement_gaps_count (1:1, the P0.5 verify clause)',
 $sql$SELECT (SELECT (value->>'procurement_gaps_count')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'engine')
           - (SELECT count(*)::int FROM public.blocked_demand WHERE plan_date = {{plan_date}})$sql$,
 'eq', '0', 'P0'),

(105, 3,
 'Writer self-report agrees with the engine: gaps_found = procurement_gaps_count',
 $sql$SELECT (SELECT (value->>'procurement_gaps_count')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'engine')
           - (SELECT (value->>'gaps_found')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'ledger')$sql$,
 'eq', '0', 'P0'),

(105, 4,
 'Identity + quantity match: every engine JSON gap (machine, shelf, product, units) has an identical ledger row',
 $sql$SELECT count(*)::int FROM (
        SELECT g->>'machine' AS m, g->>'shelf' AS s, g->>'product' AS p, (g->>'gap_units')::numeric AS u
          FROM golden.scratch sc, jsonb_array_elements(sc.value->'procurement_gaps') g
         WHERE sc.fixture_id = {{fixture_id}} AND sc.key = 'engine'
        EXCEPT
        SELECT m.official_name, sc2.shelf_code, pp.pod_product_name, bd.qty_blocked::numeric
          FROM public.blocked_demand bd
          JOIN public.machines             m   ON m.machine_id     = bd.machine_id
          JOIN public.shelf_configurations sc2 ON sc2.shelf_id     = bd.shelf_id
          JOIN public.pod_products         pp  ON pp.pod_product_id = bd.pod_product_id
         WHERE bd.plan_date = {{plan_date}} AND bd.resolved_at IS NULL
      ) unmatched$sql$,
 'eq', '0', 'P0'),

(105, 5,
 'Units conserved: sum(ledger qty_blocked) = sum(engine gap_units)',
 $sql$SELECT (SELECT COALESCE(sum((g->>'gap_units')::numeric),0)
                FROM golden.scratch sc, jsonb_array_elements(sc.value->'procurement_gaps') g
               WHERE sc.fixture_id = {{fixture_id}} AND sc.key = 'engine')
           - (SELECT COALESCE(sum(qty_blocked),0) FROM public.blocked_demand WHERE plan_date = {{plan_date}})$sql$,
 'eq', '0', 'P0'),

(105, 6,
 'LAW 5: no silent qty-0. Every qty=0 plan line is either in the ledger or an explicit strategic-intent skip',
 $sql$SELECT count(*)::int FROM public.pod_refills pr
       WHERE pr.plan_date = {{plan_date}} AND pr.qty = 0
         AND COALESCE(pr.clamp_reason,'') <> 'skipped_strategic_intent'
         AND NOT EXISTS (SELECT 1 FROM public.blocked_demand bd
                          WHERE bd.plan_date = pr.plan_date AND bd.machine_id = pr.machine_id
                            AND bd.shelf_id = pr.shelf_id AND bd.pod_product_id = pr.pod_product_id)$sql$,
 'eq', '0', 'P0'),

(105, 7,
 'Strategic-intent skips are NOT booked as procurement demand (they are a CS intent block, not a supply gap)',
 $sql$SELECT count(*)::int FROM public.blocked_demand bd
       JOIN public.pod_refills pr ON pr.plan_date = bd.plan_date AND pr.machine_id = bd.machine_id
                                 AND pr.shelf_id = bd.shelf_id AND pr.pod_product_id = bd.pod_product_id
      WHERE bd.plan_date = {{plan_date}} AND pr.clamp_reason = 'skipped_strategic_intent'$sql$,
 'eq', '0', 'P0'),

(105, 8,
 'Idempotent re-run: second writer call changes nothing (S4 property, and keeps the audit log honest)',
 $sql$SELECT ((value->>'rows_inserted')::int + (value->>'rows_updated')::int + (value->>'rows_closed_stale')::int)
        FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'ledger_rerun'$sql$,
 'eq', '0', 'P0'),

(105, 9,
 'Every ledger row carries a reason from the enum and a positive quantity (no placeholder rows)',
 $sql$SELECT count(*)::int FROM public.blocked_demand
       WHERE plan_date = {{plan_date}}
         AND (qty_blocked <= 0 OR reason NOT IN ('blocked_no_wh','partial_wh_limited','substitution_exhausted','routing_gap'))$sql$,
 'eq', '0', 'P0'),

(105, 10,
 'P1.1 target: zero venue-sourced products blocked on Boonz WH stock (S-06 Aquafina/Fade Fit thesis)',
 $sql$SELECT count(*)::int FROM public.blocked_demand bd
       JOIN public.machines m ON m.machine_id = bd.machine_id
      WHERE bd.plan_date = {{plan_date}} AND m.venue_group = 'VOX' AND bd.reason = 'blocked_no_wh'$sql$,
 'eq', '0', 'P1'),

(105, 11,
 'Fixture rows stay out of the live procurement worklist: the 2030 harness namespace is invisible to v_blocked_demand_open',
 $sql$SELECT count(*)::int FROM public.v_blocked_demand_open WHERE plan_date >= DATE '2030-01-01'$sql$,
 'eq', '0', 'P0');
