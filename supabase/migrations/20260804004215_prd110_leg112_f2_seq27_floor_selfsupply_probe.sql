-- PRD-110 leg 112 · S-200 red set · fixture 2 seq 27 (class (A), re-derived live and CONFIRMED)
--
-- WHY seq 27 was red, measured live this leg (NOT inherited from S-200's table):
--   v_shelf_instock_velocity_v3 emits only 'ok' (525) and 'out_of_canonical_scope' (143).
--   'below_floor' = 0. The branch is NOT dead code -- it is reachable and requires
--   (si.machine_id IS NOT NULL) AND (stock_hours IS NULL OR stock_hours < 48).
--   There ARE 19 real series with stock_hours < 48, but every one of them is
--   out_of_canonical_scope, so its velocity_instock is NULL for a SECOND reason
--   (units_30d IS NULL). Minimum in-scope stock_hours is 71.9996 -- just above the floor.
--
-- ⛔ THEREFORE A FLEET-WIDE RESTATEMENT (the class (B) remedy that closed 40/8) WOULD BE
--    A GREEN-AT-ZERO IN DISGUISE: "no sub-floor series receives a velocity" is satisfied
--    on all 19 without the floor ever being the operative denier. That is the exact
--    S-48/S-52/S-55 vacuity mode, burned four times. S-200 filed 2/27 as class (A) and
--    live measurement CONFIRMS it: the precondition must be SELF-SUPPLIED.
--
-- REMEDY: fixture 31 / fixture 24 rollback-probe idiom. Plant one chronically-empty
-- shelf on an ELIGIBLE machine inside a sub-transaction, measure into variables (they
-- survive the rollback), RAISE EXCEPTION, swallow. Rows vanish, measurements live.
--
-- ⛔ Do NOT set app.via_rpc in this probe (S-197): it would leave the canonical-writer
--    gate open for the remainder of the transaction.
-- ⛔ Do NOT relax seq 27 to gte 0 -- that converts the tripwire into the vacuous
--    assertion it exists to prevent.
--
-- Dry-proven read-only before this migration was written:
--   planted=2 · floor_before=0 · floor_after=1 · status=below_floor
--   · velocity_instock=NULL · stock_hours=0.0000 · elapsed_hours=23.9998
-- Residue after the aborted dry run: below_floor back to 0, machine back to 16 slots,
-- zero 'A99' rows, inventory_events 50 and shelf_composition 31 both unchanged.
-- weimi_device_status carries NO triggers (verified), so nothing can escape the rollback.

UPDATE golden.fixtures
SET scenario_sql = scenario_sql || $probeappend$

-- ── S-200 (A) SELF-SUPPLY PROBE for seq 27 (leg 112) ────────────────────────────
-- The 48h floor protects velocity_instock from a vanishing denominator. Its subject
-- population is "in-canonical-scope AND chronically empty", which the live fleet
-- currently has none of. We supply exactly one, measure, and roll it back.
DO $floorprobe$
DECLARE
  v_mach    uuid := '136771b4-060e-4fff-8959-980d1478570a';  -- USH-1008-0000-W1 (is_eligible_machine)
  v_pod     uuid := '6b9de2a2-6a05-4d08-a249-510d73869dec';  -- Al Ain Water 1.5L: unique name,
                                                             -- direct tier-1 match, NOT on this
                                                             -- machine, zero sales here in-window
  v_t1      timestamptz;
  v_t2      timestamptz;
  v_planted int     := 0;
  v_before  int;
  v_after   int;
  v_status  text;
  v_vi      numeric;
  v_sh      numeric;
  v_eh      numeric;
  v_floor   numeric;
  v_anchor  timestamptz;
BEGIN
  BEGIN
    SELECT count(*) INTO v_before
      FROM public.v_shelf_instock_velocity_v3
     WHERE velocity_status = 'below_floor';

    -- The two most recent snapshots. t1 (the latest) puts the shelf into
    -- v_live_shelf_stock -> v_shelf_sales_identity, which is what makes the series
    -- IN CANONICAL SCOPE. t2 supplies the interval whose t_i carries stock 0, which
    -- is what drives stock_hours to 0 (case A) rather than NULL.
    SELECT max(snapshot_at) INTO v_t1
      FROM public.weimi_device_status WHERE machine_id = v_mach;
    SELECT max(snapshot_at) INTO v_t2
      FROM public.weimi_device_status WHERE machine_id = v_mach AND snapshot_at < v_t1;

    UPDATE public.weimi_device_status ds
       SET door_statuses = jsonb_set(
             ds.door_statuses,
             '{0,layers,0,aisles}',
             (ds.door_statuses->0->'layers'->0->'aisles') || jsonb_build_object(
               'code',      '0-A99',
               'layer',     'A',
               'showName',  'A99',
               'goodsName', 'Al Ain Water 1.5L',
               'currStock', 0,
               'maxStock',  10,
               'isEnable',  true,
               'isBroken',  false,
               'price',     200,
               'currency',  'AED',
               'cabinet',   0,
               'order',     99))
     WHERE ds.machine_id = v_mach
       AND ds.snapshot_at IN (v_t1, v_t2);
    GET DIAGNOSTICS v_planted = ROW_COUNT;

    SELECT count(*) INTO v_after
      FROM public.v_shelf_instock_velocity_v3
     WHERE velocity_status = 'below_floor';

    SELECT velocity_status, velocity_instock, stock_hours, elapsed_hours, floor_hours, t_anchor
      INTO v_status, v_vi, v_sh, v_eh, v_floor, v_anchor
      FROM public.v_shelf_instock_velocity_v3
     WHERE machine_id = v_mach AND pod_product_id = v_pod;

    RAISE EXCEPTION 'ROLLBACK_PROBE' USING ERRCODE = '22023';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;  -- planted rows are gone; the variables above survive
  END;

  INSERT INTO golden.scratch (fixture_id, key, value)
  VALUES ({{fixture_id}}, 'pod_floor_probe', jsonb_build_object(
    'planted',        v_planted,
    'floor_before',   v_before,
    'floor_after',    v_after,
    'floor_delta',    v_after - v_before,
    'status',         coalesce(v_status, '<no row>'),
    'vi_is_null',     (v_vi IS NULL),
    'sh_under_floor', (v_sh IS NOT NULL AND v_floor IS NOT NULL AND v_sh < v_floor),
    'stock_hours',    coalesce(v_sh::text, 'NULL'),
    'elapsed_hours',  coalesce(v_eh::text, 'NULL'),
    -- ⛔ Cody Article 16 REQUIRED REVISION (METRICS_REGISTRY line 46, verbatim): "fixtures
    --    must record the anchor they ran against, so a later investigation can separate
    --    'the anchor moved' from 'the engine changed' without guessing." This view's
    --    t_anchor = max(weimi_device_status.snapshot_at) and is DELIBERATELY MOVING.
    --    Without this, a future red here would be unattributable.
    't_anchor',       coalesce(v_anchor::text, 'NULL'),
    'floor_hours',    coalesce(v_floor::text, 'NULL')));
END $floorprobe$;
$probeappend$
WHERE fixture_id = 2;

-- seq 27 RESTATED against the self-supplied precondition. Threshold stays gt 0.
UPDATE golden.assertions
SET check_sql   = 'SELECT value->>''floor_after'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod_floor_probe''',
    description = 'the floor actually binds on real rows (below_floor is not an empty branch). S-200 class (A), re-derived live leg 112: the live fleet has ZERO in-canonical-scope sub-floor series (all 19 real sub-floor series are out_of_canonical_scope, so their velocity_instock is NULL for a second reason). The precondition is therefore SELF-SUPPLIED inside a rollback probe rather than borrowed from ambient state. Paired with seq 98, which proves the row is the planted one and not an ambient accident.'
WHERE fixture_id = 2 AND seq = 27;

-- NEW: the earned-green guard. A green at zero is the defect (leg 111).
INSERT INTO golden.assertions (fixture_id, seq, check_sql, expect_op, expect, description, enabled, phase_required)
VALUES
 (2, 98,
  'SELECT value->>''floor_delta'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod_floor_probe''',
  'eq', '1',
  'EARNED-GREEN GUARD for seq 27: the below_floor row is the one this fixture PLANTED, not an ambient accident. Stated as a delta (after - before) so it survives the fleet later acquiring a genuine sub-floor series. If the plant silently fails, floor_delta is 0 and seq 27 and this both go red together.',
  true, 'P0'),
 (2, 99,
  'SELECT value->>''status'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod_floor_probe''',
  'eq', 'below_floor',
  'the classifier actually reaches the below_floor branch for the planted series -- it is neither out_of_canonical_scope (the plant lands in the LATEST snapshot of an eligible machine, so v_shelf_sales_identity resolves it) nor ok.',
  true, 'P0'),
 (2, 100,
  'SELECT value->>''vi_is_null'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod_floor_probe''',
  'eq', 'true',
  'and the floor DOES ITS JOB: an in-scope series below 48 in-stock hours is denied a velocity_instock, which is the whole point of the floor (it stops units_30d being divided by a vanishing denominator).',
  true, 'P0'),
 (2, 101,
  'SELECT value->>''sh_under_floor'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''pod_floor_probe''',
  'eq', 'true',
  'NON-VACUITY for seq 100: the denial is caused by the FLOOR comparison (stock_hours < floor_hours, both read from the view itself) and not by a NULL stock_hours taking the other arm of the same branch.',
  true, 'P0');
