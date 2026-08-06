-- PRD-110 · leg 139 · S-258
-- Fixture 45's rung-4 M2M had no donor whose SKU mix it could name, so seq 7..18 went red
-- on a precondition the fixture RENTED from live production instead of OWNING.
--
-- ⛔ THE RESIDUE HYPOTHESIS IS DISPROVEN. Leg 138 handed off the question "are the 08-06
--    20:40 / 21:40 shelf_composition rows on MPMCC-1058 genuine estimator output, or residue
--    from leg 137's committing fixture 41?". Answered three independent ways, all measured:
--      (a) all 31 rows were CREATED in ONE batch at 2026-07-30 18:40:00.117996Z - seven days
--          before fixture 41 existed; not one row was created on 08-06;
--      (b) the 20:40 batch's driving events are source_ref 'estimator:2026-08-06T20:29:29',
--          which ran 67 MINUTES BEFORE fixture 41 executed (21:36:49-21:36:52Z);
--      (c) the 21:40 batch carries NO new event at all - its last_event_id values point at
--          08-01 / 08-02 / 08-05 events; it is an age-decay touch on confidence already 0.
--    ⭐ So S-258 is not a residue incident. It is the SAME class as 16, 40, 41 and 24: a
--    fixture inheriting a live precondition that decayed. The remedy is the same shape.
--
-- ⭐ THE REMEDY IS THE ONE THE ENGINE ITSELF NAMES. resolve_m2m_donor_legs_v3 returns
--    note = '...widen shelf_composition coverage OR PLAN A REMOVE ON THE DONOR SHELF'.
--    The Remove path (v_lines_src = 'donor_remove_rows') is the PRODUCTION path and the
--    higher-confidence one - Remove rows carry boonz_product_id explicitly, where the
--    shelf_composition fallback only estimates. shelf_composition covers 16 of 656 shelves
--    (2.4%), all on ONE machine, so the composition path could never have been reachable
--    from this anchor; widening it would have been a re-baseline dressed as a fix.
--
-- ⛔ EVERYTHING IS SELECTED BY PREDICATE, NEVER BY LITERAL (S-255 / S-256 / S-257):
--      · the donor is the TOP row of list_m2m_donors_v3 - literally the same walk the
--        resolver performs, so the fixture cannot disagree with the code under test;
--      · the crossing SKU is drawn FROM the destination pod's Active assortment;
--      · the refused SKU is drawn from OUTSIDE it.
--    A hardcoded shelf or SKU would rot the next time the fleet moves. A predicate cannot.
--
-- ⛔ LAW 12 IS SATISFIED, NOT SIDESTEPPED. plan_date 2030-02-15 is the fixture's own
--    synthetic anchor (seq 1 pins it) and held 0 rows at design time. The plant is DELETED
--    again before the scenario returns, and NEW seq 22 asserts that it was - so the fixture
--    obeys S-258's own standing rule ("a committing fixture's residue proof must cover what
--    it wrote") applied reflexively to itself.
--
-- ⛔ NO ENGINE, RESOLVER, LADDER OR RPC IS TOUCHED. This migration writes golden.* only.
--    resolve_m2m_donor_legs_v3 and resolve_m2m_sku_legs_v3 are read, quoted and left alone;
--    the red was never an engine regression and is not being fixed by moving the engine.

BEGIN;

UPDATE golden.fixtures
   SET scenario_sql = $scen$
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
--     ⭐ Computed BEFORE the S-258 plant below, and safe there: list_m2m_donors_v3 reads
--        neither refill_plan_output nor shelf_composition (verified at leg 139), so the
--        plant cannot perturb the Art16 pins it feeds.
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

-- (3) THE SEAM, WITH ITS PRECONDITION SELF-SUPPLIED (S-258).
--     Plant -> call -> UNPLANT, in one block, so the Remove rows exist exactly as long as
--     the call that reads them. to_regprocedure-guarded so a RED baseline still lands every
--     fact above rather than dying as a scenario_error (S-254).
DO $do$
DECLARE
  v_dest_machine uuid := '148c4fcf-b794-43f0-a2a8-e6f17605b045';
  v_dest_shelf   uuid := '5949e4ac-5f03-43b5-98d4-2ebc157fcf65';
  v_pod          uuid := 'b1827ff7-ef99-4c85-8606-c089a9fc276d';
  v_plan_date    date := DATE '2030-02-15';
  v_marker       text := 'golden fixture 45 (S-258) synthetic donor Remove - deleted before this scenario returns';
  d              record;
  v_cross        uuid; v_cross_name   text;
  v_refused      uuid; v_refused_name text;
  v_pod_name     text;
  v_ids          uuid[] := '{}';
BEGIN
  -- ⛔ CLEAN BEFORE, not only after (Cody, Article 12 "forward-only AND idempotent").
  --    Fixtures 10, 33 and 63 all open with this idiom. run_fixture's subtransaction makes
  --    an orphaned plant very unlikely, but seq 22 would hard-fail on one and could not
  --    clear it itself, so the scenario must be re-runnable from ANY prior state.
  DELETE FROM public.refill_plan_output
   WHERE plan_date = v_plan_date AND comment LIKE 'golden fixture 45 (S-258)%';

  -- The donor: the TOP of the resolver's own walk. Preference by ORDER BY (inside the
  -- function, pinned green by seq 6), never by WHERE - a preference cannot rot.
  SELECT * INTO d FROM public.list_m2m_donors_v3(v_pod, v_dest_machine) LIMIT 1;

  -- The SKU that MAY cross: drawn from the destination pod's Active assortment, which is
  -- the exact set resolve_m2m_sku_legs_v3 calls 'elig'.
  SELECT pm.boonz_product_id, bp.boonz_product_name
    INTO v_cross, v_cross_name
    FROM public.product_mapping pm
    JOIN public.boonz_products bp ON bp.product_id = pm.boonz_product_id
   WHERE pm.pod_product_id = v_pod
     AND pm.status = 'Active'
     AND (pm.machine_id = v_dest_machine OR pm.machine_id IS NULL)
   ORDER BY pm.boonz_product_id
   LIMIT 1;

  -- The SKU that MAY NOT: drawn from OUTSIDE that set, so the split has something real to
  -- refuse. Without it, seq 13's "only transfer legs cross" is true but vacuous - it would
  -- be excluding an empty set. This is the incident class S-91 D4 exists to catch.
  SELECT bp.product_id, bp.boonz_product_name
    INTO v_refused, v_refused_name
    FROM public.boonz_products bp
   WHERE bp.product_id IS DISTINCT FROM v_cross
     AND NOT EXISTS (SELECT 1 FROM public.product_mapping pm
                      WHERE pm.boonz_product_id = bp.product_id
                        AND pm.pod_product_id = v_pod
                        AND pm.status = 'Active'
                        AND (pm.machine_id = v_dest_machine OR pm.machine_id IS NULL))
   ORDER BY bp.product_id
   LIMIT 1;

  SELECT s.pod_name INTO v_pod_name
    FROM public.v_shelf_state s WHERE s.shelf_id = d.donor_shelf_id;

  IF d.donor_shelf_id IS NOT NULL AND v_cross IS NOT NULL AND v_refused IS NOT NULL THEN
    WITH ins AS (
      INSERT INTO public.refill_plan_output
        (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name,
         action, quantity, source_origin,
         machine_id, shelf_id, pod_product_id, boonz_product_id, comment)
      SELECT v_plan_date, d.donor_machine_name, d.donor_shelf_code,
             COALESCE(v_pod_name, 'unknown'), x.nm,
             'Remove', x.q, 'warehouse'::source_origin_enum,
             d.donor_machine_id, d.donor_shelf_id, v_pod, x.sku, v_marker
        FROM (VALUES (v_cross::uuid,   v_cross_name::text,   6::int),
                     (v_refused::uuid, v_refused_name::text, 3::int)) AS x(sku, nm, q)
      RETURNING id
    )
    SELECT COALESCE(array_agg(id), '{}'::uuid[]) INTO v_ids FROM ins;
  END IF;

  -- ⭐ THE RECEIPT, banked UNCONDITIONALLY (S-259's rule, adopted here first): a plant that
  --    lands nothing must fail LOUDLY at its own seq, not surface three seqs later looking
  --    like an engine regression. seq 19 reads this.
  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES (45, 'plant', jsonb_build_object(
    'donor_shelf_id',   d.donor_shelf_id,
    'donor_shelf_code', d.donor_shelf_code,
    'donor_machine_id', d.donor_machine_id,
    'donor_excess',     d.excess_units,
    'cross_sku',        v_cross,   'cross_qty',   6,
    'refused_sku',      v_refused, 'refused_qty', 3,
    'rows_inserted',    COALESCE(array_length(v_ids, 1), 0)));

  IF to_regprocedure('public.resolve_m2m_donor_legs_v3(date,uuid,uuid,uuid,integer)') IS NOT NULL THEN
    INSERT INTO golden.scratch (fixture_id, key, value)
    SELECT 45, 'seam',
           public.resolve_m2m_donor_legs_v3(v_plan_date, v_dest_machine, v_dest_shelf, v_pod, 4);
  END IF;

  -- ⛔ THE PLANT NEVER OUTLIVES THE SCENARIO. run_fixture does NOT roll back - whatever a
  --    scenario writes COMMITS - so a fixture that plants into a plan table must clean up
  --    after itself. seq 22 proves it did.
  IF COALESCE(array_length(v_ids, 1), 0) > 0 THEN
    DELETE FROM public.refill_plan_output WHERE id = ANY(v_ids);
  END IF;
END
$do$;
$scen$
 WHERE fixture_id = 45;

-- ── NEW ASSERTIONS ────────────────────────────────────────────────────────────────────
-- Three of the four are PROPERTIES, not literals, for the reason S-257 recorded: a pinned
-- count proves nothing about safety and rots on its own. seq 19 and 22 pin the fixture's
-- own hygiene; seq 20 and 21 pin the two defects (D4, D3) that seq 13/11/12 could otherwise
-- satisfy vacuously.

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(45, 19,
 'S-258: the fixture SELF-SUPPLIES its donor SKU mix and the plant LANDED - a no-op plant fails HERE (expect rows_inserted=2 + donor/cross/refused all named), never three seqs later disguised as an engine regression',
 $q$SELECT (COALESCE((value->>'rows_inserted')::int, 0) = 2
        AND value->>'donor_shelf_id' IS NOT NULL
        AND value->>'cross_sku'      IS NOT NULL
        AND value->>'refused_sku'    IS NOT NULL)::text
      FROM golden.scratch WHERE fixture_id=45 AND key='plant'$q$,
 'eq', 'true', true, 'P3'),

(45, 20,
 'S-91 D4 non-vacuity: the split genuinely REFUSED something - at least one m2m leg is return_to_wh with reason not_assortable_at_destination, so seq 13''s "only transfer crosses" is excluding a real set rather than an empty one',
 $q$SELECT (EXISTS (SELECT 1
                     FROM golden.scratch s,
                          jsonb_array_elements(COALESCE(s.value#>'{m2m,legs}','[]'::jsonb)) m
                    WHERE s.fixture_id=45 AND s.key='seam'
                      AND m->>'leg'    = 'return_to_wh'
                      AND m->>'reason' = 'not_assortable_at_destination'))::text$q$,
 'eq', 'true', true, 'P3'),

(45, 21,
 'S-91 D3: placement is the IDENTITY units_placeable = LEAST(donor-excess cap, what the split could transfer) - stated as a property so it cannot rot the way a pinned unit count would (S-257)',
 $q$SELECT ((value->>'units_placeable')::int
          = LEAST((value->>'qty_cap')::int, (value->>'transfer_available')::int))::text
      FROM golden.scratch WHERE fixture_id=45 AND key='seam'$q$,
 'eq', 'true', true, 'P3'),

(45, 22,
 'S-258 residue rule applied REFLEXIVELY: run_fixture does not roll back, so this fixture deletes its own plant - no fixture-45 Remove row survives on the synthetic 2030-02-15 date (LAW 12)',
 $q$SELECT count(*)::text FROM public.refill_plan_output
      WHERE plan_date = DATE '2030-02-15'
        AND comment LIKE 'golden fixture 45 (S-258)%'$q$,
 'eq', '0', true, 'P3');

COMMIT;
