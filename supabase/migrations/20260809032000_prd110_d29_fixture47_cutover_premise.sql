-- PRD-110 leg 163 · D-29 · FIXTURE 47 RE-BASELINED: its premise changed, so the fixture must
-- now establish that premise instead of assuming it.
--
-- ⭐ WHAT ACTUALLY HAPPENED. D-29 (20260809030500) landed and fixture 47 went RED 44/6 - seq
--    9/12/14/15/16/17. Every one of those six is "the stitch promotion recorded nothing", and it
--    recorded nothing because BOTH of fixture 47's anchor machines (MPMCC-1058, VOXMCC-1005) are
--    in cluster VOX, and VOX is on v19. Under D-29 stitch owns only the clusters flipped to v3.
--    The fixture was not broken by D-29; its premise was silently supplied by the old world.
--
-- ⛔ AND SIX WAS THE WRONG NUMBER TO BE COMFORTED BY. seq 13/19/24 kept passing over an EMPTY
--    ledger - NOT EXISTS over nothing is true (S-289). A re-baseline that "fixed the six" by
--    weakening them would have left three vacuous greens behind, which is worse than the red.
--    The fixture is therefore given the premise it needs, and all fifty assertions get their
--    meaning back.
--
-- ⭐⭐ WHY A PERSISTED FLIP IS SAFE HERE, AND WHY THE SAME DEVICE IS NOT USED IN FIXTURE 77:
--    golden.run_fixture EXECUTEs the whole scenario inside ONE transaction. The flip and the
--    revert both live in it, so NO OTHER SESSION EVER OBSERVES VOX AS AUTHORITATIVE - MVCC, not
--    timing luck. cron 13 and cron 45 cannot see the window because the window never commits.
--    What DOES commit is the end state (VOX back on v19) and the cutover audit rows, which are
--    honest history: a flip happened, a revert happened, both are labelled as fixture 47's.
--    Fixture 77 discards its whole probe instead because it has no assertions that must read
--    committed rows; fixture 47 has thirty-seven of them.
--
-- ⛔ S-316's LESSON APPLIED, NOT REPEATED: engine_cutover_audit_v3 carries Article-7 no-update /
--    no-delete policies. This fixture does NOT delete the audit rows it mints. Deleting audit
--    evidence to keep a fixture tidy is the probe being wrong, not the guard.
--    ⚠️ Consequence for every future reader: engine_cutover_audit_v3 accumulates two rows per
--    fixture-47 run. Filter `reason NOT LIKE 'golden fixture%'` when reading it as evidence -
--    the same discipline S-307 imposed on engine_forecast_error_v3 and S-244 on plan_date.
--
-- ⛔ S-307 IS OBEYED FOR THE PLANTED GATE EVIDENCE. The flip needs settled v3 measurement, which
--    means planting engine_forecast_error_v3 rows on a REAL 2026 date. Those rows would become
--    cutover evidence if they survived, so the fixture: (a) refuses to plant unless that exact
--    (plan_date, machine_id) slot is empty, (b) deletes precisely what it planted, (c) asserts
--    the slot is empty again. 2026-07-04 was verified to hold zero rows before this migration.
--
-- Article 12: forward-only. Cody: reviewed under Articles 7, 8, 16; the no-delete-of-audit
-- decision is his.

BEGIN;

DO $pre$
BEGIN
  IF (SELECT count(*) FROM public.engine_forecast_error_v3
       WHERE plan_date = DATE '2026-07-04'
         AND machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid) <> 0 THEN
    RAISE EXCEPTION 'fixture 47 re-baseline: the 2026-07-04 plant slot is not empty; pick another date rather than deleting real measurement';
  END IF;
  IF (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine = 'v3') <> 0 THEN
    RAISE EXCEPTION 'fixture 47 re-baseline: a cluster is already authoritative; this ships FLAG-OFF';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM golden.fixtures WHERE fixture_id = 47
                   AND scenario_sql LIKE '%public.record_blocked_demand_v3({{plan_date}}, ''stitch'')%') THEN
    RAISE EXCEPTION 'fixture 47 re-baseline: the scenario is not the image this migration was written against';
  END IF;
END $pre$;

-- ── (a) the caller becomes explicit, as in fixtures 75 and 77 ───────────────────────────────────
UPDATE golden.fixtures
   SET scenario_sql =
$NEW$SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
$NEW$ || scenario_sql
 WHERE fixture_id = 47;

-- ── (b) THE PREMISE D-29 now requires: VOX is authoritative while stitch is promoted ───────────
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$-- (3) THE PROMOTION, through the canonical writer.$OLD$,
$NEW$-- (2.5) ⭐⭐ D-29's PREMISE. stitch owns a machine's demand only while that machine's cluster is
--       authoritative for v3. Both anchors are VOX, so VOX is flipped for the duration of the
--       promotion and reverted in (6). The whole scenario is one transaction, so this window is
--       invisible to every other session.
DO $fx47flip$
DECLARE
  v_vox uuid := '148c4fcf-b794-43f0-a2a8-e6f17605b045';  -- a VOX machine; both anchors are VOX
  v_pod uuid;
BEGIN
  SELECT pod_product_id INTO v_pod FROM public.engine_forecast_error_v3 LIMIT 1;
  IF v_pod IS NULL THEN
    RAISE EXCEPTION 'fixture 47: engine_forecast_error_v3 is empty; the flip below would be vacuous';
  END IF;
  -- ⛔ S-307: refuse to plant over real measurement rather than delete it later.
  IF (SELECT count(*) FROM public.engine_forecast_error_v3
       WHERE plan_date = DATE '2026-07-04' AND machine_id = v_vox) <> 0 THEN
    RAISE EXCEPTION 'fixture 47: the 2026-07-04 plant slot is occupied; refusing to overwrite measurement';
  END IF;
  -- abs_error / signed_error are GENERATED ALWAYS - the miss is engineered through the forecast.
  INSERT INTO public.engine_forecast_error_v3
    (plan_date, engine_tag, machine_id, pod_product_id, horizon_days, horizon_end, n_shelves,
     dc_variants, forecast_units, actual_units, actuals_settled, velocity_basis, measured_at)
  VALUES
    (DATE '2026-07-04','v3',  v_vox, v_pod, 7, DATE '2026-07-11', 1, 1, 110, 100, true, 'velocity_instock', now()),
    (DATE '2026-07-04','v19', v_vox, v_pod, 7, DATE '2026-07-11', 1, 1, 140, 100, true, 'velocity_instock', now());

  INSERT INTO golden.scratch (fixture_id, key, value)
  SELECT {{fixture_id}}, 'flip', public.flip_cluster_to_v3_v3('VOX', 'golden fixture 47 supplies D-29 premise');
END
$fx47flip$;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'premise', jsonb_build_object(
  'anchor_p_auth', public.is_cluster_authoritative_v3('9acce2bf-0e65-48f4-bf44-cefa0326f2c5'::uuid),
  'anchor_f_auth', public.is_cluster_authoritative_v3('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid),
  'clusters_on_v3',(SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine='v3'));

-- (3) THE PROMOTION, through the canonical writer.$NEW$)
 WHERE fixture_id = 47;

-- ── (c) the revert and the S-307 cleanup, after the ledger has been captured ────────────────────
UPDATE golden.fixtures
   SET scenario_sql = scenario_sql ||
$NEW$

-- (6) ⭐ THE REVERT. Never evidence-gated, and the fixture may not leave a cluster flipped.
--     ⛔ The cutover AUDIT rows this fixture minted are deliberately NOT deleted (S-316): they
--        are true, they are labelled, and the table is Article-7 append-only by policy.
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'revert', public.revert_cluster_to_v19_v3('VOX', 'golden fixture 47 restores the registry');

-- (7) ⛔ S-307: the planted gate evidence is removed with the exact key it was planted under, so
--     synthetic measurement can never be read as a v3 series.
DELETE FROM public.engine_forecast_error_v3
 WHERE plan_date = DATE '2026-07-04'
   AND machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid;

INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'all_v19_after', (SELECT count(*) FROM public.engine_cutover_authority_v3 WHERE authoritative_engine<>'v19'),
  'planted_gone',  (SELECT count(*) FROM public.engine_forecast_error_v3
                     WHERE plan_date = DATE '2026-07-04'
                       AND machine_id = '148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid),
  'anchor_f_auth_after', public.is_cluster_authoritative_v3('148c4fcf-b794-43f0-a2a8-e6f17605b045'::uuid));$NEW$
 WHERE fixture_id = 47;

-- ── (d) the new assertions: the premise is proven, not assumed; the residue is measured ─────────
DELETE FROM golden.assertions WHERE fixture_id = 47 AND seq IN (51,52,53,54,55,56);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, phase_required) VALUES
(47, 51, '⭐⭐ D-29 PREMISE: the flip was ACCEPTED, so every ledger assertion below is measured on a genuinely authoritative cluster rather than on the old fleet-wide behaviour',
 $q$SELECT value->>'outcome' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='flip'$q$, 'eq', 'applied', 'P4'),
(47, 52, '⭐ PREMISE: anchor P''s machine is authoritative for v3 at promotion time',
 $q$SELECT value->>'anchor_p_auth' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$q$, 'eq', 'true', 'P4'),
(47, 53, '⭐ PREMISE: anchor F''s machine is too - both anchors are VOX, which is why ONE flip supplies the whole premise',
 $q$SELECT value->>'anchor_f_auth' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$q$, 'eq', 'true', 'P4'),
(47, 54, '⛔ LAW 4: the fixture flipped exactly ONE cluster, never the fleet',
 $q$SELECT value->>'clusters_on_v3' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='premise'$q$, 'eq', '1', 'P4'),
(47, 55, '⛔ LAW 4 AFTER THE FACT: every cluster is back on v19 and the anchor is no longer authoritative - the fixture leaves the registry exactly as it found it',
 $q$SELECT (value->>'all_v19_after')||'/'||(value->>'anchor_f_auth_after') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='after'$q$, 'eq', '0/false', 'P4'),
(47, 56, '⛔ S-307: the planted gate evidence is GONE - a fixture''s synthetic measurement must never survive to be read as a v3 series',
 $q$SELECT value->>'planted_gone' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key='after'$q$, 'eq', '0', 'P4');

-- ── (e) FIXTURE 77 seq 64 is re-scoped: a GLOBAL emptiness check on the audit log was coupling
--        fixture 77 to every other fixture, and fixture 47 is about to mint two honest rows. ──────
UPDATE golden.fixtures
   SET scenario_sql = replace(scenario_sql,
$OLD$  'audit_gone',     (SELECT count(*) FROM public.engine_cutover_audit_v3)$OLD$,
$NEW$  'audit_gone',     (SELECT count(*) FROM public.engine_cutover_audit_v3
                       WHERE reason LIKE '%fixture 77%')$NEW$)
 WHERE fixture_id = 77;

UPDATE golden.assertions
   SET description = '⛔ Residue: fixture 77 minted NO cutover audit row - its flip lived in a discarded subtransaction. ⭐ Scoped to this fixture''s own reason string: a global emptiness check would couple fixture 77 to every other fixture that legitimately flips.'
 WHERE fixture_id = 77 AND seq = 64;

DO $verify$
DECLARE v_s text; v_n int;
BEGIN
  SELECT scenario_sql INTO v_s FROM golden.fixtures WHERE fixture_id = 47;
  IF v_s NOT LIKE '%flip_cluster_to_v3_v3(''VOX''%'  THEN RAISE EXCEPTION 'fixture 47: the flip did not land'; END IF;
  IF v_s NOT LIKE '%revert_cluster_to_v19_v3(''VOX''%' THEN RAISE EXCEPTION 'fixture 47: the revert did not land'; END IF;
  IF v_s NOT LIKE '%DELETE FROM public.engine_forecast_error_v3%' THEN RAISE EXCEPTION 'fixture 47: the S-307 cleanup did not land'; END IF;
  -- ⛔ the revert must come AFTER the ledger capture, or the promotion runs unflipped
  IF position('flip_cluster_to_v3_v3' in v_s) > position('revert_cluster_to_v19_v3' in v_s) THEN
    RAISE EXCEPTION 'fixture 47: the revert precedes the flip';
  END IF;
  IF position('record_blocked_demand_v3({{plan_date}}, ''stitch'')' in v_s) < position('flip_cluster_to_v3_v3' in v_s) THEN
    RAISE EXCEPTION 'fixture 47: the promotion precedes the flip';
  END IF;

  SELECT scenario_sql INTO v_s FROM golden.fixtures WHERE fixture_id = 77;
  IF v_s NOT LIKE '%fixture 77%''%' AND v_s NOT LIKE '%reason LIKE%' THEN
    RAISE EXCEPTION 'fixture 77: seq 64 was not re-scoped';
  END IF;

  SELECT count(*) INTO v_n FROM golden.assertions WHERE fixture_id = 47;
  IF v_n <> 56 THEN RAISE EXCEPTION 'fixture 47: expected 56 assertions, found %', v_n; END IF;
END $verify$;

COMMIT;
