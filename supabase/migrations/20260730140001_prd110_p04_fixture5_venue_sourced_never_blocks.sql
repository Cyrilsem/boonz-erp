-- PRD-110 P0.4 / fixture 5 "Venue-sourced never blocks" (Fade Fit)
-- LAW 1: the fixture lands BEFORE the sentinel mint. Baseline is expected RED.
--
-- Fade Fit pod_product_id      : 733dcd39-dd50-4446-b1e4-5b36afbdf72a
-- Fade Fit boonz variants (4)  : Dark Chocolate / Hazelnut / Peanut Butter / Salted Caramel
-- Engine WH scope (proven from engine_add_pod body):
--   warehouse_id = ANY(ARRAY[machines.primary_warehouse_id, machines.secondary_warehouse_id])
-- => sentinels at WH_MCC/WH_MM are reachable ONLY by MCC/MM-served machines.
--    VOXMCC-1005-0201-B0 + ACTIVATE-2005-0000-W0 : primary WH_MCC   -> P0 scope
--    ACTIVATEMCC-1037-0000-L0                    : primary WH_CENTRAL, no secondary
--                                                  -> unreachable by any sentinel; needs
--                                                     P1.1 product_sourcing (seq 10, P1)
--
-- RED baseline recorded 2026-07-30 11:07 UTC : 3 pass / 4 fail (seq 2,3,4,6 red)
-- GREEN after mint                           : 7 pass / 0 fail (seq 10 skipped as P1)

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, baseline_status, scenario_sql, notes, enabled)
VALUES (
  5,
  'Venue-sourced never blocks (Fade Fit)',
  'Fade Fit chronically blocked_no_wh since 2026-06-12. Live 2026-07-30 plan: ACTIVATEMCC-1037 A02 (need 7) + A03 (need 3) + VOXMCC-1005 A04 (need 7) = 17 units blocked, wh_available_pod=0 on every line. Zero Active Boonz WH stock exists for all 4 mapped variants.',
  'P0',
  DATE '2030-01-06',
  'failing_expected',
$scenario$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'df_open_before',
       jsonb_build_object('n', (SELECT count(*) FROM public.driver_feedback WHERE resolved = false));
DELETE FROM public.machines_to_visit WHERE plan_date = {{plan_date}};
INSERT INTO public.machines_to_visit
 (plan_date, machine_id, official_name, status, add_source, is_included, service_track,
  picked_reasons, active_intent_count, is_ramping, priority_score, picked_at, picked_by,
  venue_group, location_type, confirmed_at, confirmed_by)
SELECT {{plan_date}}, machine_id, official_name, 'picked', 'operator', true,
       CASE WHEN venue_group='VOX' THEN 'vox' ELSE 'main' END,
       ARRAY['golden_fixture_5']::text[], 0, false, 100, now(),
       '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid, venue_group, location_type,
       now(), 'golden_fixture_5'
FROM public.machines
WHERE official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0','ACTIVATEMCC-1037-0000-L0');
SELECT public.engine_add_pod({{plan_date}}, 7);
SELECT public.record_blocked_demand_v3({{plan_date}});
$scenario$,
  'GOLDEN-FIXTURES #5 spec text: "Zero Boonz WH stock, sourcing=venue on co_managed. Assert qty>0 vox_at_venue lines, zero blocked_no_wh, never on any PO."'
  || E'\n\nSCOPE CORRECTION (evidence-based, P0.4): the spec mints sentinels at WH_MCC+WH_MM only.'
  || ' engine_add_pod scopes wh_avail to ARRAY[primary_warehouse_id, secondary_warehouse_id], so those'
  || ' sentinels are structurally invisible to the 3 VOX machines served by WH_CENTRAL'
  || ' (ACTIVATEMCC-1037, MPMCC-1054, MPMCC-1058). Minting Fade Fit at WH_CENTRAL was REJECTED:'
  || ' WH_CENTRAL serves 26 machines incl. fully-managed offices/AMZ, so a 999 row there would fake'
  || ' availability fleet-wide - the exact phantom-availability harm. Hence P0 assertions are scoped to'
  || ' the MCC-served pair and seq 10 holds the fleet-wide claim at P1 (product_sourcing).'
  || E'\n"never on any PO" is asserted as seq 6: a venue-sourced product must never land in blocked_demand'
  || ' (the procurement worklist), which is the ledger that would drive a PO.',
  true
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required, enabled) VALUES

(5, 1, 'Non-vacuity: the engine emits Fade Fit lines on the MCC-served VOX machines (cannot pass by finding nothing)',
$q$SELECT count(*)::text FROM public.pod_refills pr
   JOIN public.machines m ON m.machine_id = pr.machine_id
  WHERE pr.plan_date = {{plan_date}}
    AND pr.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
    AND m.official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0')$q$,
 'gte', '1', 'P0', true),

(5, 2, 'P0.4 CLAUSE: zero Fade Fit lines blocked_no_wh on sentinel-reachable (MCC-served) machines',
$q$SELECT count(*)::text FROM public.pod_refills pr
   JOIN public.machines m ON m.machine_id = pr.machine_id
  WHERE pr.plan_date = {{plan_date}}
    AND pr.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
    AND m.official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0')
    AND pr.clamp_reason = 'blocked_no_wh'$q$,
 'eq', '0', 'P0', true),

(5, 3, 'Fade Fit is actually refilled, not merely unblocked: max qty > 0 on the MCC-served pair',
$q$SELECT COALESCE(max(pr.qty),0)::text FROM public.pod_refills pr
   JOIN public.machines m ON m.machine_id = pr.machine_id
  WHERE pr.plan_date = {{plan_date}}
    AND pr.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
    AND m.official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0')$q$,
 'gt', '0', 'P0', true),

(5, 4, 'The sentinel is visible to the engine: every Fade Fit line on the MCC-served pair reports wh_available_pod > 0',
$q$SELECT COALESCE(min(pr.wh_available_pod),0)::text FROM public.pod_refills pr
   JOIN public.machines m ON m.machine_id = pr.machine_id
  WHERE pr.plan_date = {{plan_date}}
    AND pr.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
    AND m.official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0')$q$,
 'gt', '0', 'P0', true),

(5, 5, 'LAW 5: no silent qty-0 anywhere in the fixture plan (every qty=0 line carries a clamp_reason)',
$q$SELECT count(*)::text FROM public.pod_refills pr
  WHERE pr.plan_date = {{plan_date}}
    AND pr.qty = 0 AND (pr.clamp_reason IS NULL OR pr.clamp_reason = '')$q$,
 'eq', '0', 'P0', true),

(5, 6, 'Never on any PO: a venue-sourced product raises no procurement demand on sentinel-reachable machines',
$q$SELECT count(*)::text FROM public.blocked_demand bd
   JOIN public.machines m ON m.machine_id = bd.machine_id
  WHERE bd.plan_date = {{plan_date}}
    AND bd.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
    AND m.official_name IN ('VOXMCC-1005-0201-B0','ACTIVATE-2005-0000-W0')
    AND bd.resolved_at IS NULL$q$,
 'eq', '0', 'P0', true),

(5, 10, 'P1.1 TARGET: zero Fade Fit lines blocked_no_wh fleet-wide in this plan - incl. ACTIVATEMCC-1037 (WH_CENTRAL, structurally unreachable by any sentinel). RED until product_sourcing lands.',
$q$SELECT count(*)::text FROM public.pod_refills pr
  WHERE pr.plan_date = {{plan_date}}
    AND pr.pod_product_id = '733dcd39-dd50-4446-b1e4-5b36afbdf72a'::uuid
    AND pr.clamp_reason = 'blocked_no_wh'$q$,
 'eq', '0', 'P1', true),

(5, 90, 'HARNESS SAFETY: the fixture resolved no live driver_feedback (S-08 engine tail leaks past plan_date scope)',
$q$SELECT (SELECT count(*)::int FROM public.driver_feedback WHERE resolved = false)
        - (SELECT (value->>'n')::int FROM golden.scratch WHERE fixture_id = {{fixture_id}} AND key = 'df_open_before')$q$,
 'eq', '0', 'P0', true);
