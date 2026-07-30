-- PRD-110 P1.1 - fixture 5 gains the assertions that actually bind P1.1, and seq 10 is re-phased.
--
-- SPEC / POINTER CORRECTION (LAW 13 "verify, then act"; house pattern per S-04 and P0.6(d)):
--   The leg-4 RESUME POINTER states "fixture 5 seq 10 (phase_required='P1') goes green the moment
--   P1.1 lands - that assertion is your acceptance test". MEASURED: it does not, and it cannot.
--   seq 10 asserts `pod_refills.clamp_reason <> 'blocked_no_wh'` fleet-wide, i.e. it asserts ENGINE
--   BEHAVIOUR. The engine is `engine_add_pod`, which computes wh_avail inline as
--     SUM(warehouse_inventory) via product_mapping WHERE warehouse_id = ANY(primary, secondary)
--   and reads product_sourcing nowhere. Making it read the sourcing edge means editing a frozen
--   Family-A engine body, which LAW 3 forbids (versioned additions only) and which the BUILD SPEC
--   schedules as `engine_add_pod_v3` in PHASE 2 (P2.1-P2.6).
--   Therefore seq 10 is a PHASE-2 acceptance test that was mis-phased as P1. Left enabled and
--   honestly red-until-P2 rather than weakened: it is still the real proof that S-10 is dead.
--   Original wording preserved verbatim in golden.fixtures.notes.
--
--   What P1.1 genuinely delivers is the TRUTH LAYER, so its acceptance test belongs at that layer:
--   the sourcing edge must resolve to 'venue' for exactly the products that were structurally
--   unreachable, and must NEVER hand out unconstrained availability by accident. seq 11-14 assert
--   precisely that, and they are engine-independent (no plan_date dependency, no S-08 exposure).

UPDATE golden.assertions
   SET phase_required = 'P2',
       description = 'P2 TARGET (re-phased from P1 at P1.1, see migration 20260730150005): zero '
                     'Fade Fit lines blocked_no_wh fleet-wide incl. ACTIVATEMCC-1037. Needs '
                     'engine_add_pod_v3 to consume product_sourcing; the frozen v19 engine reads '
                     'warehouse scope only. RED until P2.'
 WHERE fixture_id = 5 AND seq = 10;

UPDATE golden.fixtures
   SET notes = COALESCE(notes,'') ||
       E'\n\n[P1.1 2026-07-30] seq 10 re-phased P1 -> P2. ORIGINAL TEXT, preserved verbatim: '
       '"P1.1 TARGET: zero Fade Fit lines blocked_no_wh fleet-wide in this plan - incl. '
       'ACTIVATEMCC-1037 (WH_CENTRAL, structurally unreachable by any sentinel). RED until '
       'product_sourcing lands." REASON: the assertion reads pod_refills.clamp_reason, i.e. engine '
       'behaviour. product_sourcing landed at P1.1 and resolves ACTIVATEMCC-1037 Fade Fit to '
       '''venue'' (proved by seq 11), but engine_add_pod v19 does not read product_sourcing and '
       'editing it is barred by LAW 3 / the Family-A freeze. Consumption is engine_add_pod_v3 = '
       'PHASE 2. seq 11-14 are the P1-layer acceptance tests P1.1 actually satisfies.'
 WHERE fixture_id = 5;

-- seq 11 - S-10 CLOSED at the truth layer. The 4 Fade Fit variants on ACTIVATEMCC-1037 (primary
-- WH_CENTRAL, no secondary, so no sentinel can ever reach it) must resolve to 'venue', which means
-- unconstrained BY DEFINITION rather than by a fake 999 warehouse row.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, enabled)
VALUES (5, 11,
  'P1.1 (S-10): every Fade Fit variant on ACTIVATEMCC-1037 resolves to source=venue - unconstrained by definition, not by warehouse routing',
$sql$SELECT count(*)::text FROM public.product_mapping pm
      JOIN public.machines m ON m.machine_id = pm.machine_id
     WHERE m.official_name = 'ACTIVATEMCC-1037-0000-L0'
       AND pm.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
       AND pm.status = 'Active'
       AND public.resolve_product_sourcing_v3(m.machine_id, pm.pod_product_id, pm.boonz_product_id) <> 'venue'$sql$,
  'eq','0','P1',true)
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description=EXCLUDED.description, check_sql=EXCLUDED.check_sql,
      expect_op=EXCLUDED.expect_op, expect=EXCLUDED.expect, phase_required=EXCLUDED.phase_required;

-- seq 12 - the Aquafina half of S-06. MPMCC-1058's fastest mover (3.23/day) was blocked_no_wh on a
-- co-managed VOX machine. Global mapping says venue_team, the machine-scoped row says boonz: the
-- BOTH-rows case. On a co_managed machine that must resolve to venue.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, enabled)
VALUES (5, 12,
  'P1.1 (S-06 Aquafina half): Aquafina on MPMCC-1058 resolves to source=venue - the BOTH-rows lesson (global venue_team beats a machine-scoped boonz row on a co_managed machine)',
$sql$SELECT COALESCE(string_agg(DISTINCT ps.source, ','),'MISSING')
       FROM public.v_product_sourcing_current ps
      WHERE ps.machine_name = 'MPMCC-1058-0000-R0' AND ps.pod_product_name = 'Aquafina'$sql$,
  'eq','venue','P1',true)
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description=EXCLUDED.description, check_sql=EXCLUDED.check_sql,
      expect_op=EXCLUDED.expect_op, expect=EXCLUDED.expect, phase_required=EXCLUDED.phase_required;

-- seq 13 - the WS-J1 containment invariant, and the anti-S-10 guard. A venue edge means
-- unconstrained, so a venue edge on a fully-managed office would be phantom availability
-- fleet-wide: exactly the failure that made minting a WH_CENTRAL sentinel unacceptable.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, enabled)
VALUES (5, 13,
  'P1.1 (WS-J1 containment): no fully_managed machine holds a venue sourcing edge - a venue edge is unconstrained, so one on an office would be phantom availability',
$sql$SELECT count(*)::text FROM public.v_product_sourcing_current
      WHERE operating_model = 'fully_managed' AND source = 'venue'$sql$,
  'eq','0','P1',true)
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description=EXCLUDED.description, check_sql=EXCLUDED.check_sql,
      expect_op=EXCLUDED.expect_op, expect=EXCLUDED.expect, phase_required=EXCLUDED.phase_required;

-- seq 14 - fail-safe direction. An unknown (machine, pod, sku) must fall back to the CONSTRAINED
-- answer. If the resolver ever defaults to 'venue', every unmapped product silently becomes
-- infinitely available and the planner dispatches drivers against stock that does not exist.
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, enabled)
VALUES (5, 14,
  'P1.1 fail-safe: an unknown sourcing edge resolves to boonz_wh (constrained), never venue - an unknown must never grant phantom availability',
$sql$SELECT public.resolve_product_sourcing_v3(
        '00000000-0000-0000-0000-000000000001'::uuid,
        '00000000-0000-0000-0000-000000000002'::uuid, NULL)$sql$,
  'eq','boonz_wh','P1',true)
ON CONFLICT (fixture_id, seq) DO UPDATE
  SET description=EXCLUDED.description, check_sql=EXCLUDED.check_sql,
      expect_op=EXCLUDED.expect_op, expect=EXCLUDED.expect, phase_required=EXCLUDED.phase_required;
