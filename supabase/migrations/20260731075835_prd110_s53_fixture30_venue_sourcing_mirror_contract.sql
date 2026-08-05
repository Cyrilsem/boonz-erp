-- PRD-110 S-53 - fixture 30, LAW 1 (FIXTURE FIRST). Applied BEFORE the sourcing correction, so
-- the S-53 assertions are RED on purpose and that failing baseline is recorded in the EXECUTION-LOG.
--
-- What it pins: the ONE-DIRECTIONAL venue-sourcing mirror. On a co_managed machine, an Active
-- product_mapping row with source_of_supply='venue_team' AT ANY SCOPE MUST carry an Active
-- product_sourcing edge with source='venue' at the same (machine, pod, boonz_product) triple.
--
-- ⛔ ANY SCOPE IS THE WHOLE POINT. METRICS_REGISTRY (P1.1) ratifies the rule as "on a co_managed
-- machine, a venue_team mapping at ANY scope wins", and names the alternative - resolving from the
-- MOST SPECIFIC product_mapping row - as the single most expensive inference bug PRD-110 exists to
-- delete (S-10, and the Aquafina half of S-06). So fx30_intent below reads global-default rows
-- (machine_id IS NULL) alongside machine-scoped ones. A join that drops the global rows encodes
-- the banned rule; it happens to measure the same 30-triple gap today, which is exactly what makes
-- it dangerous.
--
-- ⛔ The converse is NOT asserted, and must never be. 75 triples on co_managed machines have a
-- machine-scoped 'boonz' mapping and a 'venue' edge - Fade Fit (44), VOX Popcorn/Lollies/Cotton
-- Candy (20), Aquafina (11). Those edges are CORRECT: each also carries a global-default
-- venue_team row, so ANY-scope resolves them to venue. Measured at leg 47, all 116 venue edges in
-- the table are justified this way. seq 8 is the standing tripwire that a future backfill has not
-- reverted to "most specific wins" and re-sourced VOX-supplied goods to Boonz WH.
--
-- ⛔ Nor is the flip done at POD grain. The "Soft Drinks Mix" pod on 3 machines is genuinely
-- mixed: Pepsi variants come from the venue, Coca-Cola variants and Mountain Dew from Boonz WH.
-- seq 9 pins those 12 SKU edges at boonz_wh so the pod keeps resolving to 'mixed' and therefore
-- stays is_constrained - which is what keeps the P2.3 expiry ceiling applying to that shelf.
--
-- Scope measured live 2026-07-31 on the 11 co_managed machines: 146 ANY-scope venue_team triples
-- carry an edge, of which 30 are mis-edged - Pepsi - Black (8), Red Bull - Regular (11), Red Bull
-- - Diet (11). Those 30 have venue_global=false and boonz_scoped=false: their venue_team mapping
-- is machine-scoped (this is where the CS correction landed) with no competing boonz row, so they
-- are an unambiguous supersede.
-- ⚠️ Two parking-lot claims did NOT survive live measurement and are corrected here: the scope is
-- not 28 rows; and Pepsi - Black is NOT missing an edge - it carries 8 boonz_wh edges that must be
-- SUPERSEDED. Zero rows need minting.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  30,
  'Venue sourcing mirrors the CS correction (S-53)',
  'PRD-110 S-53. The CS correction of 2026-07-31 (Pepsi Black, Ice Tea Peach and Red Bull are VENUE-sourced on ALL VOX machines) landed in product_mapping but its loop obligation - supersede the matching product_sourcing edges via set_product_sourcing_v3 - was never executed. product_sourcing feeds v_shelf_state.sourcing, which feeds v_shelf_availability_v3, which is the basis P2.3 gates the expiry ceiling on. So 22 Red Bull and 8 Pepsi Black edges were BOTH sized against Boonz WH stock AND capped by a Boonz WH expiry date, for stock the venue supplies. LAW 2 (truth before intelligence) exists to prevent exactly this coupling; it arrived late.',
  'P1',
  '2030-01-31',
  true,
  'failing_expected',
  'P1 truth layer. Reads product_mapping, product_sourcing, v_product_sourcing_current, v_shelf_state and machines; writes only golden.scratch. Cheap - no engine run, no velocity object, not subject to RISK 88. Intent is read under the RATIFIED ANY-SCOPE rule (a venue_team mapping at global OR machine scope wins on a co_managed machine); resolving from the most specific row is the banned S-10 inference. Asserts the mirror in ONE direction only (venue_team => venue) and carries two standing guards against over-correction: the 75 VOX-supplied edges (S-10 tripwire) and the 12 mixed-pod Coca-Cola edges.',
$fx30body$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
DO $fx30$
DECLARE
  v_payload        jsonb;
  v_scope          bigint;
  v_gap_not_venue  bigint;
  v_gap_no_edge    bigint;
  v_cs3_total      bigint;
  v_cs3_boonz      bigint;
  v_vox_venue      bigint;
  v_mixed_boonz    bigint;
  v_pods_boonz     bigint;
  v_pods_affected  bigint;
  v_ss_boonz       bigint;
  v_ss_disagree    bigint;
  v_softdrinks_mix bigint;
  v_dup_active     bigint;
  v_bad_pair       bigint;
  v_superseded     bigint;
  v_manual_origin  bigint;
  v_reason_tagged  bigint;
  v_changed_by     bigint;
  v_fm_venue       bigint;
  v_pm_boonz       bigint;
BEGIN
  -- The mapping-side intent on co_managed machines, under the RATIFIED ANY-SCOPE rule: a
  -- venue_team row at global scope (machine_id IS NULL) counts for every co_managed machine, and
  -- a machine-scoped boonz row does NOT override it. Resolving from the most specific row instead
  -- is S-10 / the Aquafina half of S-06 - see the header. Everything below is measured against this.
  CREATE TEMP TABLE fx30_intent ON COMMIT DROP AS
  SELECT co.machine_id, pm.pod_product_id, pm.boonz_product_id
    FROM public.product_mapping pm
    CROSS JOIN (SELECT machine_id FROM public.machines WHERE operating_model = 'co_managed') co
   WHERE pm.status = 'Active'
     AND (pm.machine_id IS NULL OR pm.machine_id = co.machine_id)
   GROUP BY co.machine_id, pm.pod_product_id, pm.boonz_product_id
  HAVING bool_or(pm.source_of_supply = 'venue_team');

  CREATE TEMP TABLE fx30_edge ON COMMIT DROP AS
  SELECT machine_id, pod_product_id, boonz_product_id, source, origin, reason, changed_by
    FROM public.product_sourcing
   WHERE status = 'Active';

  -- A triple only OWES an edge when its pod is actually assorted on that machine. Under ANY-scope
  -- most global-default rows describe products that machine does not carry (477 intent triples,
  -- 70 assorted at leg 47); demanding an edge for those would be a permanent false red.
  CREATE TEMP TABLE fx30_assorted ON COMMIT DROP AS
  SELECT i.machine_id, i.pod_product_id, i.boonz_product_id
    FROM fx30_intent i
   WHERE EXISTS (SELECT 1 FROM public.v_shelf_state ss
                  WHERE ss.machine_id = i.machine_id
                    AND ss.pod_product_id = i.pod_product_id);

  SELECT count(*) INTO v_scope FROM fx30_assorted;

  -- CORE (S-53): a venue_team mapping whose Active edge is anything other than venue.
  SELECT count(*) INTO v_gap_not_venue
    FROM fx30_intent i
    JOIN fx30_edge e ON e.machine_id = i.machine_id
                    AND e.pod_product_id = i.pod_product_id
                    AND e.boonz_product_id = i.boonz_product_id
   WHERE e.source <> 'venue';

  -- The mint case, over ASSORTED triples only. Measured 0 at leg 47 - the parking lot predicted 8
  -- missing Pepsi Black edges and was wrong: they exist and are boonz_wh.
  SELECT count(*) INTO v_gap_no_edge
    FROM fx30_assorted i
   WHERE NOT EXISTS (
     SELECT 1 FROM fx30_edge e
      WHERE e.machine_id = i.machine_id
        AND e.pod_product_id = i.pod_product_id
        AND e.boonz_product_id = i.boonz_product_id);

  -- The CS decision stated by product name, so the fixture still means something if the
  -- product_mapping vocabulary is ever refactored underneath it.
  SELECT count(*), count(*) FILTER (WHERE e.source = 'boonz_wh')
    INTO v_cs3_total, v_cs3_boonz
    FROM fx30_edge e
    JOIN public.machines m  ON m.machine_id = e.machine_id
    JOIN public.boonz_products bp ON bp.product_id = e.boonz_product_id
   WHERE m.operating_model = 'co_managed'
     AND bp.boonz_product_name IN ('Pepsi - Black','Red Bull - Regular','Red Bull - Diet');

  -- S-10 TRIPWIRE. VOX-supplied goods keep their venue edges. Each carries a global-default
  -- venue_team row AND a machine-scoped boonz row, so ANY-scope resolves them to venue and
  -- most-specific-wins resolves them to boonz. A backfill that reverts to the latter breaks this.
  SELECT count(*) INTO v_vox_venue
    FROM fx30_edge e
    JOIN public.machines m ON m.machine_id = e.machine_id
    JOIN public.boonz_products bp ON bp.product_id = e.boonz_product_id
   WHERE m.operating_model = 'co_managed'
     AND e.source = 'venue'
     AND (bp.boonz_product_name LIKE 'Fade Fit -%'
       OR bp.boonz_product_name LIKE 'VOX %'
       OR bp.boonz_product_name = 'Aquafina - Regular');

  -- MIXED-POD GUARD. The Coca-Cola family and Mountain Dew on the Soft Drinks Mix pod stay
  -- Boonz-sourced. If a pod-grain flip is ever attempted these 12 go to venue and this reds.
  SELECT count(*) INTO v_mixed_boonz
    FROM fx30_edge e
    JOIN public.machines m ON m.machine_id = e.machine_id
    JOIN public.pod_products pp ON pp.pod_product_id = e.pod_product_id
    JOIN public.boonz_products bp ON bp.product_id = e.boonz_product_id
   WHERE m.operating_model = 'co_managed'
     AND e.source = 'boonz_wh'
     AND pp.pod_product_name = 'Soft Drinks Mix'
     AND bp.boonz_product_name IN ('Coca Cola - Diet','Coca Cola - Regular','Coca Cola - Zero','Mountain Dew - Regular');

  -- Pod-grain resolution as v_shelf_state computes it, restricted to the pods S-53 touches.
  CREATE TEMP TABLE fx30_pods ON COMMIT DROP AS
  SELECT DISTINCT i.machine_id, i.pod_product_id
    FROM fx30_intent i
    JOIN public.boonz_products bp ON bp.product_id = i.boonz_product_id
   WHERE bp.boonz_product_name IN ('Pepsi - Black','Red Bull - Regular','Red Bull - Diet');

  SELECT count(*) INTO v_pods_affected FROM fx30_pods;

  SELECT count(*) INTO v_pods_boonz
    FROM fx30_pods p
    JOIN ( SELECT c.machine_id, c.pod_product_id,
                  CASE WHEN count(DISTINCT c.source) = 1 THEN min(c.source) ELSE 'mixed' END AS pod_source
             FROM public.v_product_sourcing_current c GROUP BY 1,2) s
      ON s.machine_id = p.machine_id AND s.pod_product_id = p.pod_product_id
   WHERE s.pod_source = 'boonz_wh';

  -- R3 (Cody, leg 47): the two assertions above re-derive the pod rollup INLINE. That is the
  -- house fixture pattern - re-derive so a change of MEANING is caught rather than mirrored - but
  -- on its own it proves nothing about the object the engines actually read. So also read
  -- v_shelf_state.sourcing itself, and assert the two AGREE. If they ever diverge, either
  -- v_shelf_state stopped rolling edges up the documented way or it started re-deriving sourcing
  -- from somewhere else, and Article 16 is broken.
  SELECT count(*) FILTER (WHERE ss.sourcing = 'boonz_wh'),
         count(*) FILTER (WHERE ss.sourcing IS DISTINCT FROM s.pod_source)
    INTO v_ss_boonz, v_ss_disagree
    FROM public.v_shelf_state ss
    JOIN fx30_pods p ON p.machine_id = ss.machine_id AND p.pod_product_id = ss.pod_product_id
    JOIN ( SELECT c.machine_id, c.pod_product_id,
                  CASE WHEN count(DISTINCT c.source) = 1 THEN min(c.source) ELSE 'mixed' END AS pod_source
             FROM public.v_product_sourcing_current c GROUP BY 1,2) s
      ON s.machine_id = ss.machine_id AND s.pod_product_id = ss.pod_product_id;

  -- and the Soft Drinks Mix pods must REMAIN mixed - not flip wholesale to venue.
  SELECT count(*) INTO v_softdrinks_mix
    FROM ( SELECT c.machine_id, c.pod_product_id,
                  CASE WHEN count(DISTINCT c.source) = 1 THEN min(c.source) ELSE 'mixed' END AS pod_source
             FROM public.v_product_sourcing_current c GROUP BY 1,2) s
    JOIN public.pod_products pp ON pp.pod_product_id = s.pod_product_id
    JOIN public.machines m ON m.machine_id = s.machine_id
   WHERE m.operating_model = 'co_managed'
     AND pp.pod_product_name = 'Soft Drinks Mix'
     AND s.pod_source = 'mixed';

  -- Append-only integrity, independent of who wrote the rows.
  SELECT count(*) INTO v_dup_active FROM (
    SELECT machine_id, pod_product_id, COALESCE(boonz_product_id,'00000000-0000-0000-0000-000000000000'::uuid) AS b
      FROM fx30_edge GROUP BY 1,2,3 HAVING count(*) > 1) q;

  SELECT count(*) INTO v_bad_pair
    FROM public.product_sourcing
   WHERE NOT ((status = 'Active' AND valid_to IS NULL) OR (status = 'Superseded' AND valid_to IS NOT NULL));

  -- Provenance: the correction must be visible as SUPERSEDED history plus a manual, reasoned,
  -- attributed Active row. A raw UPDATE would leave no superseded row and no manual origin.
  SELECT count(*) INTO v_superseded
    FROM public.product_sourcing ps
    JOIN public.machines m ON m.machine_id = ps.machine_id
    JOIN public.boonz_products bp ON bp.product_id = ps.boonz_product_id
   WHERE m.operating_model = 'co_managed'
     AND ps.status = 'Superseded' AND ps.source = 'boonz_wh'
     AND bp.boonz_product_name IN ('Pepsi - Black','Red Bull - Regular','Red Bull - Diet');

  SELECT count(*) FILTER (WHERE e.origin = 'manual'),
         count(*) FILTER (WHERE e.reason LIKE '%S-53%'),
         count(*) FILTER (WHERE e.changed_by = '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d'::uuid)
    INTO v_manual_origin, v_reason_tagged, v_changed_by
    FROM fx30_edge e
    JOIN public.machines m ON m.machine_id = e.machine_id
    JOIN public.boonz_products bp ON bp.product_id = e.boonz_product_id
   WHERE m.operating_model = 'co_managed'
     AND e.source = 'venue'
     AND bp.boonz_product_name IN ('Pepsi - Black','Red Bull - Regular','Red Bull - Diet');

  -- The WS-J1 model guard, re-asserted fleetwide from the data rather than from the trigger.
  SELECT count(*) INTO v_fm_venue
    FROM fx30_edge e JOIN public.machines m ON m.machine_id = e.machine_id
   WHERE m.operating_model = 'fully_managed' AND e.source = 'venue';

  SELECT count(*) INTO v_pm_boonz
    FROM fx30_edge e JOIN public.machines m ON m.machine_id = e.machine_id
   WHERE m.operating_model = 'partner_managed' AND e.source = 'boonz_wh';

  v_payload := jsonb_build_object(
    'scope_venue_team',   v_scope::text,
    'gap_not_venue',      v_gap_not_venue::text,
    'gap_no_edge',        v_gap_no_edge::text,
    'cs3_edges_total',    v_cs3_total::text,
    'cs3_boonz_wh',       v_cs3_boonz::text,
    'vox_venue_edges',    v_vox_venue::text,
    'mixed_pod_boonz_wh', v_mixed_boonz::text,
    'pods_affected',      v_pods_affected::text,
    'pods_still_boonz',   v_pods_boonz::text,
    'shelf_state_boonz',  v_ss_boonz::text,
    'shelf_state_disagree', v_ss_disagree::text,
    'softdrinks_mixed',   v_softdrinks_mix::text,
    'dup_active_triples', v_dup_active::text,
    'bad_status_pair',    v_bad_pair::text,
    'superseded_cs3',     v_superseded::text,
    'manual_origin_cs3',  v_manual_origin::text,
    'reason_tagged_cs3',  v_reason_tagged::text,
    'changed_by_cs3',     v_changed_by::text,
    'fully_managed_venue',v_fm_venue::text,
    'partner_boonz_wh',   v_pm_boonz::text);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx30$;
$fx30body$
);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES
(30, 1, 'NON-VACUITY: co_managed machines actually carry ASSORTED venue_team triples under the ANY-scope rule (70 at leg 47). If operating_model or the source_of_supply vocabulary ever drifts this hits 0 and every mismatch=0 assertion below would go vacuously green',
 'SELECT value->>''scope_venue_team'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P1'),
(30, 2, 'S-53 CORE: every ANY-SCOPE venue_team mapping on a co_managed machine carries an Active venue edge at the same (machine, pod, boonz_product) triple. RED at 30 before the correction - that failing baseline is the point (LAW 1)',
 'SELECT value->>''gap_not_venue'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 3, 'NO ORPHANS: no ASSORTED venue_team triple on a co_managed machine lacks an edge entirely. Measured 0 at leg 47 - the parking lot predicted 8 missing Pepsi Black edges and was wrong, they exist and are boonz_wh',
 'SELECT value->>''gap_no_edge'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 4, 'CS DECISION BY NAME, non-vacuity: Pepsi - Black, Red Bull - Regular and Red Bull - Diet hold Active edges on co_managed machines at all',
 'SELECT value->>''cs3_edges_total'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P1'),
(30, 5, 'CS DECISION BY NAME: none of those three products is sourced boonz_wh on any co_managed machine. This is the CS correction of 2026-07-31 stated in the vocabulary CS used',
 'SELECT value->>''cs3_boonz_wh'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 6, 'P2.3 COUPLING: no pod carrying one of the three CS products still resolves to boonz_wh in the v_shelf_state sense. While it does, that shelf is both sized against Boonz WH stock and capped by a Boonz WH expiry for stock the venue supplies',
 'SELECT value->>''pods_still_boonz'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 7, 'P2.3 COUPLING, non-vacuity: those pods exist (19 measured at leg 47), so seq 6 is earned rather than empty',
 'SELECT value->>''pods_affected'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gt', '0', true, 'P1'),
(30, 8, 'S-10 TRIPWIRE, the guard against over-correction: the 75 VOX-supplied edges (Fade Fit 44, VOX Popcorn/Lollies/Cotton Candy 20, Aquafina 11) on co_managed machines stay venue. Each carries a GLOBAL-DEFAULT venue_team row plus a machine-scoped boonz row, so they are correct under ANY-scope and wrong under most-specific-wins. A backfill that reverts to most-specific-wins re-sources VOX goods to Boonz WH and undoes P0.4. Never fix this by weakening the assertion',
 'SELECT value->>''vox_venue_edges'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '75', true, 'P1'),
(30, 9, 'MIXED-POD GUARD: the 12 Coca-Cola and Mountain Dew edges on the Soft Drinks Mix pod stay boonz_wh. That pod is genuinely mixed - Pepsi from the venue, Coke from Boonz WH - and only per-SKU edges can express it. A pod-grain flip reds this',
 'SELECT value->>''mixed_pod_boonz_wh'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '12', true, 'P1'),
(30, 10, 'MIXED-POD GUARD: and those 3 pods still RESOLVE to mixed, so they stay is_constrained and the P2.3 expiry ceiling keeps applying to their Boonz-supplied share',
 'SELECT value->>''softdrinks_mixed'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '3', true, 'P1'),
(30, 11, 'APPEND-ONLY: no triple holds more than one Active edge. The partial unique index enforces it; this asserts it independently so a future index change cannot pass unnoticed',
 'SELECT value->>''dup_active_triples'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 12, 'APPEND-ONLY: status and valid_to stay paired on every row in the table - Active implies valid_to NULL, Superseded implies valid_to set',
 'SELECT value->>''bad_status_pair'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 13, 'PROVENANCE: the superseded boonz_wh history survives the correction. A raw UPDATE of source would leave zero Superseded rows - this is what proves the canonical writer was used',
 'SELECT value->>''superseded_cs3'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gte', '30', true, 'P1'),
(30, 14, 'PROVENANCE: every resulting Active venue edge for the three CS products carries origin=manual, i.e. it came through set_product_sourcing_v3 rather than a backfill',
 'SELECT value->>''manual_origin_cs3'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gte', '30', true, 'P1'),
(30, 15, 'PROVENANCE: each of those rows names S-53 in its reason, so the audit trail points back at the decision that caused it',
 'SELECT value->>''reason_tagged_cs3'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gte', '30', true, 'P1'),
(30, 16, 'PROVENANCE: and each is attributed to the operator_admin, not to a NULL service-role caller',
 'SELECT value->>''changed_by_cs3'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'gte', '30', true, 'P1'),
(30, 17, 'WS-J1 MODEL GUARD from the data: no fully_managed machine holds a venue edge. The constraint trigger enforces this on write; this catches a row that predates or bypasses it',
 'SELECT value->>''fully_managed_venue'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 18, 'WS-J1 MODEL GUARD from the data: no partner_managed machine holds a boonz_wh edge',
 'SELECT value->>''partner_boonz_wh'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 19, 'CONSUMER PATH (R3): v_shelf_state.sourcing - the object the engines actually read - shows no affected shelf still sourced boonz_wh. seq 6 proves the fixture''s own rollup; this proves the real one. RED at 9 before the correction (4 Red Bull + 5 Pepsi Black shelves)',
 'SELECT value->>''shelf_state_boonz'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1'),
(30, 20, 'ARTICLE 16 (R3): v_shelf_state.sourcing agrees with the fixture''s independent rollup of v_product_sourcing_current on every affected shelf. A divergence means v_shelf_state stopped rolling edges up the documented way, or started deriving sourcing from somewhere else',
 'SELECT value->>''shelf_state_disagree'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '0', true, 'P1');
