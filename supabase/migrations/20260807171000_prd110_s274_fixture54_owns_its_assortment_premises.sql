-- PRD-110 · leg 146 · S-274
-- FIXTURE 54 OWNS ITS ASSORTMENT PREMISES INSTEAD OF INHERITING THEM.
--
-- WHY. Fixture 54 went red on 2026-08-07 (33/41) with its FIRST assertion - seq 2,
-- "premise: the incoming pod is NOT already assorted on the machine" - reading 1.
-- HUAWEI-2003 A03 had been re-podded to "Al Ain Zero", which is the fixture's incoming
-- pod, so swap_v3 CORRECTLY refused the same-machine swap and six downstream assertions
-- read `absent`. swap_v3 is not the defect: its body is byte-unchanged (md5(prosrc)
-- ffff8485) across every green run from leg 126 to leg 138 and the red run at 16:15Z.
--
-- The defect is that the fixture READ its premises off live assortment instead of
-- OWNING them (the S-34 class). This migration closes that class for fixture 54 with
-- the leg-114/115 self-supply idiom, and NOT by loosening an assertion or by re-pointing
-- the anchors at whatever pod happens to be free today - either would buy one day and
-- re-arm the same trap.
--
-- WHAT SHIPS
--   1. golden.plant_shelf_identity(shelf, pod, stock) - the named, reusable planter for
--      slot IDENTITY, the sibling of golden.plant_shelf_stock (leg 136, S-249). Identity
--      in this system is WEIMI's `goodsName` resolved through the four tiers of
--      v_live_shelf_stock, so planting an identity is exactly the same class of write as
--      planting a stock level, on exactly the same row, under the same fixture-only guard.
--      It takes CUSTODY of the pre-image in golden.weimi_pin_backup so the existing
--      golden.restore_machine_stock puts it back byte-for-byte.
--   2. golden.evict_pod_from_machine(machine, pod) - vacates every shelf of a machine that
--      currently carries a pod. This is what makes "pod X is NOT on this machine" a
--      CONSTRUCTION rather than an observation.
--   3. Fixture 54 step (0b), which plants all five of its assortment premises, and step
--      (7), which restores both machines and proves live WEIMI came back unchanged.
--   4. Three new assertions: 7 (the plants read back), 8 (custody released), 9 (live state
--      byte-identical before and after). Fixture 54: 41 -> 44 assertions.
--
-- NOT A LOOSENING: seq 2 keeps `eq 0` verbatim. It now measures a premise the fixture
-- MADE. If a plant silently fails to land, the planter raises and seq 2 still goes red.
--
-- SAFETY. Both planters refuse unless a golden run is in flight (S-252 - enforcement, not
-- a comment). golden.run_fixture wraps scenario_sql in a PL/pgSQL BEGIN..EXCEPTION block,
-- i.e. a subtransaction, so an error ANYWHERE between the plant and the restore rolls the
-- plants back automatically; the scenario cannot strand a mutated WEIMI observation. The
-- restore in step (7) is deliberately NOT wrapped in its own handler for the same reason:
-- if a restore fails, the correct outcome is the whole scenario rolling back, which is
-- itself a restore. Zero writes to any Appendix-A protected entity.

-- ============================================================================
-- 1. golden.plant_shelf_identity
-- ============================================================================
CREATE OR REPLACE FUNCTION golden.plant_shelf_identity(
  p_shelf_id       uuid,
  p_pod_product_id uuid,
  p_stock          integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $fn$
DECLARE
  v_mid        uuid;
  v_code       text;
  v_show       text;
  v_sid        uuid;
  v_orig       jsonb;
  v_pre_units  bigint;
  v_ci int; v_li int; v_ai int;
  v_matches    int;
  v_name       text;
  v_names      int;
  v_goods      text;
  v_rows       int := 0;
  v_seen_pod   uuid;
  v_seen_stk   int;
  v_present    boolean;
  v_prev_via   text;
  v_prev_rpc   text;
BEGIN
  -- FIXTURE-ONLY GUARD. Identical predicate to golden.arrange_shelf (leg 27),
  -- golden.pin_machine_stock (leg 28) and golden.plant_shelf_stock (leg 136).
  -- golden.run_fixture INSERTs its run row with finished_at NULL BEFORE executing
  -- scenario_sql and UPDATEs it at the end of the SAME transaction, so an unfinished
  -- row is visible if and only if a golden run is in flight. No production path has one.
  IF NOT EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL) THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: REFUSED - no golden run is in flight. '
      'This function mutates a live WEIMI observation; it is legal only inside a golden '
      'fixture scenario, which restores it before the transaction commits.';
  END IF;

  IF p_shelf_id IS NULL THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: p_shelf_id is required';
  END IF;
  IF p_stock IS NOT NULL AND p_stock < 0 THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: p_stock must be >= 0, got %', p_stock;
  END IF;

  SELECT sc.machine_id, sc.shelf_code
    INTO v_mid, v_code
    FROM public.shelf_configurations sc
   WHERE sc.shelf_id = p_shelf_id AND sc.is_phantom = false;

  IF v_mid IS NULL THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: shelf % is not a non-phantom shelf_configurations row',
      p_shelf_id;
  END IF;

  -- ZERO-PAD LAW, applied in reverse: shelf_code 'A03' is WEIMI showName 'A3'.
  -- Same expression as golden.plant_shelf_stock, and the inverse of the join
  -- v_shelf_slot_identity uses (left(code,1) || substr(code,2)::integer::text).
  v_show := pg_catalog.regexp_replace(v_code, '^([A-Za-z]+)0*([0-9]+)$', '\1\2');

  ----------------------------------------------------------------------------
  -- The goods name to plant.
  ----------------------------------------------------------------------------
  IF p_pod_product_id IS NULL THEN
    -- VACATE. A sentinel that must resolve to NOTHING, so the shelf reads
    -- pod_product_id NULL through v_shelf_state ('unmatched' is a real live state -
    -- six aisles in the fleet carry it today, so this is not an impossible shape).
    v_goods := 'GOLDEN-VACANT-' || pg_catalog.replace(p_shelf_id::text, '-', '');

    IF EXISTS (SELECT 1 FROM public.pod_products pp
                WHERE pg_catalog.lower(pg_catalog.btrim(pp.pod_product_name))
                    = pg_catalog.lower(pg_catalog.btrim(v_goods)))
       OR EXISTS (SELECT 1 FROM public.product_name_conventions c WHERE c.original_name = v_goods)
       OR EXISTS (SELECT 1 FROM public.weimi_product_alias a WHERE a.weimi_name = v_goods) THEN
      RAISE EXCEPTION 'golden.plant_shelf_identity: the vacancy sentinel % resolves to a '
        'product through one of the four tiers - refusing to plant a name that is not vacant',
        v_goods;
    END IF;
  ELSE
    SELECT pp.pod_product_name INTO v_name
      FROM public.pod_products pp WHERE pp.pod_product_id = p_pod_product_id;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'golden.plant_shelf_identity: pod_product % does not exist', p_pod_product_id;
    END IF;
    -- Tier 1 ('direct') joins on the NAME. If two pod_products share it, the identity
    -- we plant is not the identity we asked for, and the read-back below would be a
    -- coin toss rather than a proof.
    SELECT count(*) INTO v_names FROM public.pod_products pp WHERE pp.pod_product_name = v_name;
    IF v_names <> 1 THEN
      RAISE EXCEPTION 'golden.plant_shelf_identity: pod name % is carried by % pod_products '
        'rows - the direct-match tier would be ambiguous', v_name, v_names;
    END IF;
    v_goods := v_name;
  END IF;

  ----------------------------------------------------------------------------
  -- The exact row v_shelf_slot_identity reads: newest per device_name (that is
  -- v_live_shelf_stock's latest_snapshots), then newest overall for this machine
  -- among the rows that actually carry the slot (that is v_shelf_slot_identity's
  -- DISTINCT ON ... ORDER BY snapshot_at DESC). ⛔ A machine can carry rows under
  -- several historical device_names - NOVO-1023 has three - so keying the planter
  -- on official_name alone would sometimes edit a row no view reads.
  ----------------------------------------------------------------------------
  SELECT ls.status_id, ls.door_statuses
    INTO v_sid, v_orig
    FROM (SELECT DISTINCT ON (w.device_name)
                 w.status_id, w.machine_id, w.device_name, w.snapshot_at, w.door_statuses
            FROM public.weimi_device_status w
           ORDER BY w.device_name, w.snapshot_at DESC) ls
   WHERE ls.machine_id = v_mid
     AND EXISTS (SELECT 1
                   FROM pg_catalog.jsonb_array_elements(ls.door_statuses) cab,
                        pg_catalog.jsonb_array_elements(cab.value->'layers') lay,
                        pg_catalog.jsonb_array_elements(lay.value->'aisles') ais
                  WHERE ais.value->>'showName' = v_show)
   ORDER BY ls.snapshot_at DESC
   LIMIT 1;

  IF v_sid IS NULL THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: machine % has no live WEIMI snapshot '
      'carrying showName % (shelf_code %, shelf %)', v_mid, v_show, v_code, p_shelf_id;
  END IF;

  SELECT count(*) INTO v_matches
    FROM pg_catalog.jsonb_array_elements(v_orig) cab,
         pg_catalog.jsonb_array_elements(cab.value->'layers') lay,
         pg_catalog.jsonb_array_elements(lay.value->'aisles') ais
   WHERE ais.value->>'showName' = v_show;

  IF v_matches <> 1 THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: machine % showName % (shelf_code %) matched '
      '% aisles, need exactly 1', v_mid, v_show, v_code, v_matches;
  END IF;

  SELECT cab.ci - 1, lay.li - 1, ais.ai - 1
    INTO v_ci, v_li, v_ai
    FROM pg_catalog.jsonb_array_elements(v_orig) WITH ORDINALITY cab(value, ci),
         LATERAL pg_catalog.jsonb_array_elements(cab.value->'layers') WITH ORDINALITY lay(value, li),
         LATERAL pg_catalog.jsonb_array_elements(lay.value->'aisles') WITH ORDINALITY ais(value, ai)
   WHERE ais.value->>'showName' = v_show;

  ----------------------------------------------------------------------------
  -- CUSTODY of the pre-image, shared with golden.restore_machine_stock. Same table,
  -- same key, same pre_units recipe as golden.pin_machine_stock, so a fixture may
  -- compose the two and still restore with ONE call per machine.
  ----------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM golden.weimi_pin_backup b
              WHERE b.machine_id = v_mid AND b.status_id <> v_sid) THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: machine % is already under custody of a '
      'DIFFERENT snapshot row (% held, % wanted) - restoring one would leak the other',
      v_mid, (SELECT b.status_id FROM golden.weimi_pin_backup b WHERE b.machine_id = v_mid), v_sid;
  END IF;

  SELECT coalesce(sum(si.current_stock), 0) INTO v_pre_units
    FROM public.v_shelf_slot_identity si
    JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
   WHERE sc.machine_id = v_mid AND sc.is_phantom = false;

  -- ON CONFLICT DO NOTHING: a second plant on the same machine must not overwrite the
  -- ORIGINAL pre-image with an already-planted one.
  INSERT INTO golden.weimi_pin_backup (machine_id, status_id, door_statuses, pre_units)
  VALUES (v_mid, v_sid, v_orig, v_pre_units)
  ON CONFLICT (machine_id) DO NOTHING;

  ----------------------------------------------------------------------------
  -- THE PLANT. snapshot_at is deliberately NOT touched: it is the estimator's
  -- idempotency key and the velocity view's anchor.
  ----------------------------------------------------------------------------
  v_prev_via := pg_catalog.current_setting('app.via_rpc',  true);
  v_prev_rpc := pg_catalog.current_setting('app.rpc_name', true);
  PERFORM pg_catalog.set_config('app.via_rpc',  'true', true);
  PERFORM pg_catalog.set_config('app.rpc_name', 'golden.plant_shelf_identity', true);

  UPDATE public.weimi_device_status w
     SET door_statuses = CASE
           WHEN p_stock IS NULL THEN
             pg_catalog.jsonb_set(w.door_statuses,
               ARRAY[v_ci::text,'layers',v_li::text,'aisles',v_ai::text,'goodsName'],
               pg_catalog.to_jsonb(v_goods))
           ELSE
             pg_catalog.jsonb_set(
               pg_catalog.jsonb_set(w.door_statuses,
                 ARRAY[v_ci::text,'layers',v_li::text,'aisles',v_ai::text,'goodsName'],
                 pg_catalog.to_jsonb(v_goods)),
               ARRAY[v_ci::text,'layers',v_li::text,'aisles',v_ai::text,'currStock'],
               pg_catalog.to_jsonb(p_stock))
         END
   WHERE w.status_id = v_sid;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  PERFORM pg_catalog.set_config('app.via_rpc',  v_prev_via, true);
  PERFORM pg_catalog.set_config('app.rpc_name', v_prev_rpc, true);

  ----------------------------------------------------------------------------
  -- SELF-PROVING (RISK 75). Read back through the SAME view every engine reads.
  -- ⛔ The presence check is separate from the value check: for a VACATE both the
  -- wanted pod and a missing row read NULL, so without it a shelf on a machine that
  -- has dropped out of v_shelf_state would report a successful plant having done
  -- nothing - the vacuous-success class.
  ----------------------------------------------------------------------------
  SELECT true, vs.pod_product_id, vs.current_stock
    INTO v_present, v_seen_pod, v_seen_stk
    FROM public.v_shelf_state vs WHERE vs.shelf_id = p_shelf_id;

  IF NOT coalesce(v_present, false) THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: shelf % is not visible in v_shelf_state '
      '(machine not Active / not include_in_refill?) - the plant proves nothing', p_shelf_id;
  END IF;

  IF v_rows <> 1
     OR v_seen_pod IS DISTINCT FROM p_pod_product_id
     OR (p_stock IS NOT NULL AND v_seen_stk IS DISTINCT FROM p_stock) THEN
    RAISE EXCEPTION 'golden.plant_shelf_identity: plant did not reach v_shelf_state '
      '(rows=%, pod seen=%, pod wanted=%, stock seen=%, stock wanted=%)',
      v_rows, v_seen_pod, p_pod_product_id, v_seen_stk, p_stock;
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'shelf_id',   p_shelf_id,
    'machine_id', v_mid,
    'shelf_code', v_code,
    'show_name',  v_show,
    'status_id',  v_sid,
    'goods_name', v_goods,
    'pod_seen',   v_seen_pod,
    'stock_seen', v_seen_stk,
    'vacated',    (p_pod_product_id IS NULL));
END;
$fn$;

COMMENT ON FUNCTION golden.plant_shelf_identity(uuid, uuid, integer) IS
  'PRD-110 S-274. Golden-harness planter for slot IDENTITY (and, optionally, stock in the '
  'same write). Sibling of golden.plant_shelf_stock: identity is WEIMI goodsName resolved '
  'through the four tiers of v_live_shelf_stock, so this is the same class of write on the '
  'same row. p_pod_product_id NULL vacates the shelf with a sentinel proven to match no '
  'tier. Takes custody of the machine pre-image in golden.weimi_pin_backup so '
  'golden.restore_machine_stock puts it back; the caller MUST restore. REFUSES unless a '
  'golden run is in flight. Verifies every plant through v_shelf_state, presence first.';

REVOKE ALL ON FUNCTION golden.plant_shelf_identity(uuid, uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION golden.plant_shelf_identity(uuid, uuid, integer) FROM anon, authenticated;

-- ============================================================================
-- 2. golden.evict_pod_from_machine
-- ============================================================================
CREATE OR REPLACE FUNCTION golden.evict_pod_from_machine(
  p_machine_id     uuid,
  p_pod_product_id uuid)
RETURNS integer
LANGUAGE plpgsql
SET search_path = ''
AS $fn$
DECLARE
  v_shelf uuid;
  v_n     int := 0;
BEGIN
  IF p_machine_id IS NULL OR p_pod_product_id IS NULL THEN
    RAISE EXCEPTION 'golden.evict_pod_from_machine: machine and pod are both required';
  END IF;

  -- The guard lives in plant_shelf_identity; this loop simply never writes when the
  -- machine already satisfies the premise, which is the common case and is not a failure.
  FOR v_shelf IN
    SELECT vs.shelf_id FROM public.v_shelf_state vs
     WHERE vs.machine_id = p_machine_id AND vs.pod_product_id = p_pod_product_id
     ORDER BY vs.shelf_id
  LOOP
    PERFORM golden.plant_shelf_identity(v_shelf, NULL, NULL);
    v_n := v_n + 1;
  END LOOP;

  -- Non-vacuity of the EVICTION itself: after the loop the pod must be gone. A shelf
  -- whose vacancy did not land would already have raised inside the planter, but a pod
  -- reachable through a row the loop never enumerated would not.
  IF EXISTS (SELECT 1 FROM public.v_shelf_state vs
              WHERE vs.machine_id = p_machine_id AND vs.pod_product_id = p_pod_product_id) THEN
    RAISE EXCEPTION 'golden.evict_pod_from_machine: pod % still reads as assorted on machine % '
      'after vacating % shelves', p_pod_product_id, p_machine_id, v_n;
  END IF;

  RETURN v_n;
END;
$fn$;

COMMENT ON FUNCTION golden.evict_pod_from_machine(uuid, uuid) IS
  'PRD-110 S-274. Vacates every shelf of a machine that currently carries a pod, so a '
  'fixture can MAKE the premise "this pod is not on this machine" instead of observing it. '
  'Golden harness only - inherits golden.plant_shelf_identity''s run-in-flight guard and '
  'its custody, so the caller restores with golden.restore_machine_stock.';

REVOKE ALL ON FUNCTION golden.evict_pod_from_machine(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION golden.evict_pod_from_machine(uuid, uuid) FROM anon, authenticated;

-- ============================================================================
-- 3. FIXTURE 54 - step (0b) plant, step (7) restore
--    Edited by NAMED SUBSTITUTION rather than by re-writing the whole scenario,
--    and both edits are asserted to have landed.
-- ============================================================================
DO $edit$
DECLARE
  v_src   text;
  v_new   text;
  v_plant text;
  v_rest  text;
BEGIN
  SELECT f.scenario_sql INTO v_src FROM golden.fixtures f WHERE f.fixture_id = 54;
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'fixture 54 has no scenario_sql';
  END IF;
  IF pg_catalog.strpos(v_src, 'golden.plant_shelf_identity') > 0 THEN
    RAISE EXCEPTION 'fixture 54 already carries the S-274 plant - refusing to double-apply';
  END IF;
  IF pg_catalog.strpos(v_src, '-- (1) STRUCTURAL PROBE') = 0 THEN
    RAISE EXCEPTION 'fixture 54: the step-(1) anchor comment is gone; the substitution '
      'would silently no-op';
  END IF;

  v_plant :=
'-- (0b) THE FIXTURE OWNS ITS ASSORTMENT PREMISES (S-274, leg-114/115 idiom).
--      Every premise asserted by seq 1/2/3/4/6 is MADE here. Before this step the
--      fixture INHERITED them from live assortment, and on 2026-08-07 the fleet
--      re-podded HUAWEI-2003 A03 to the incoming pod, which made swap_v3 refuse
--      correctly and took eight assertions red with it.
--      Restored in step (7). Any error in between rolls these plants back inside
--      golden.run_fixture''s own subtransaction, so a mutated WEIMI row can never commit.
DO $plant$
DECLARE v jsonb := ''{}''::jsonb;
BEGIN
  -- The live pre-image, read through the view every consumer reads. Step (7) re-derives
  -- it and seq 9 compares the two, so a leaked plant is a red assertion, not a rumour.
  v := v || jsonb_build_object(''pre_state'', (
    SELECT md5(COALESCE(string_agg(
             s.shelf_id::text || '':'' || COALESCE(s.pod_product_id::text, ''-'') ||
             '':'' || COALESCE(s.current_stock::text, ''-''), ''|'' ORDER BY s.shelf_id), ''''))
      FROM public.v_shelf_state s
     WHERE s.machine_id IN (''9db7a821-d312-43b0-8e83-9642abfbfb0b'',
                            ''0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'')));

  -- (a) IDENTITIES FIRST, so the evictions below see the final assortment.
  --     seq 1: the outgoing pod sits on the anchor shelf.
  v := v || jsonb_build_object(''plant_out'',
         golden.plant_shelf_identity(''b6454a65-f4da-4c07-8570-b8791f687ee2'',
                                     ''31186e1c-b61b-4d13-b520-052fb86725a3''));
  --     seq 3: the duplicate pod is genuinely assorted somewhere on the machine.
  v := v || jsonb_build_object(''plant_dup'',
         golden.plant_shelf_identity(''0b3cc2d5-8dce-495c-a6c0-278722bebd1f'',
                                     ''27444f0d-7d3c-4480-bbdc-4faf60acbdbc''));
  --     the cross-machine destination shelf must CARRY a pod, or step 4e emits one leg
  --     instead of two and seq 54''s edit count drops without anything naming why.
  v := v || jsonb_build_object(''plant_a07'',
         golden.plant_shelf_identity(''8539b03e-4628-4e26-bffe-6aa33c282b7a'',
                                     ''8b8cc695-b5cc-4b9b-ac67-c7994f260243''));

  -- (b) THE EVICTIONS. seq 2 and seq 6 are now constructions, not observations.
  v := v || jsonb_build_object(''evicted_in'',
         golden.evict_pod_from_machine(''9db7a821-d312-43b0-8e83-9642abfbfb0b'',
                                       ''cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77''));
  v := v || jsonb_build_object(''evicted_cross'',
         golden.evict_pod_from_machine(''9db7a821-d312-43b0-8e83-9642abfbfb0b'',
                                       ''ed88eeff-cb1a-4863-8874-7178339493d0''));

  -- (c) seq 4: the donor really holds the cross pod, in stock. swap_v3 step (4) refuses
  --     a donor at zero, so the stock half of this premise is load-bearing.
  v := v || jsonb_build_object(''plant_donor'',
         golden.plant_shelf_identity(''27c8430e-fa1f-4dba-98fd-1430b130a711'',
                                     ''ed88eeff-cb1a-4863-8874-7178339493d0'', 6));

  v := v || jsonb_build_object(''plant_ok'', ''yes'');
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (54, ''plant'', v);
END $plant$;

';

  v_rest :=
'
-- (7) RESTORE. ⛔ Deliberately NOT wrapped in an exception handler: if a restore fails,
--     the correct outcome is golden.run_fixture rolling the whole scenario back, which is
--     itself a complete restore. Catching it here would risk committing a planted WEIMI row.
--     ⛔ CODY R2: custody is keyed by machine_id and golden.restore_machine_stock DELETEs the
--     row, so the two machines below MUST be distinct. If a future edit ever makes the donor
--     the anchor, the second call raises "no pin backup" - loud, but only if you know why.
DO $rest$
DECLARE v jsonb := ''{}''::jsonb;
BEGIN
  v := v || jsonb_build_object(''anchor'',
         golden.restore_machine_stock(''9db7a821-d312-43b0-8e83-9642abfbfb0b''));
  v := v || jsonb_build_object(''donor'',
         golden.restore_machine_stock(''0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04''));
  v := v || jsonb_build_object(''backup_rows_left'', (
    SELECT count(*) FROM golden.weimi_pin_backup b
     WHERE b.machine_id IN (''9db7a821-d312-43b0-8e83-9642abfbfb0b'',
                            ''0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'')));
  v := v || jsonb_build_object(''post_state'', (
    SELECT md5(COALESCE(string_agg(
             s.shelf_id::text || '':'' || COALESCE(s.pod_product_id::text, ''-'') ||
             '':'' || COALESCE(s.current_stock::text, ''-''), ''|'' ORDER BY s.shelf_id), ''''))
      FROM public.v_shelf_state s
     WHERE s.machine_id IN (''9db7a821-d312-43b0-8e83-9642abfbfb0b'',
                            ''0a9a4836-0bed-48f9-80b8-5c7fa5cd5f04'')));
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES (54, ''restore'', v);
END $rest$;
';

  v_new := pg_catalog.replace(v_src, '-- (1) STRUCTURAL PROBE', v_plant || '-- (1) STRUCTURAL PROBE')
           || v_rest;

  IF v_new = v_src THEN
    RAISE EXCEPTION 'fixture 54: substitution produced an identical body';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 54;
END
$edit$;

-- ============================================================================
-- 4. THE THREE ASSERTIONS THAT PROVE THE PLANT, AND PROVE IT LEFT NOTHING BEHIND
-- ============================================================================
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(54, 7,
 'S-274 ownership: every assortment premise below was PLANTED by this fixture and read back through v_shelf_state - seq 1/2/3/4/6 measure a state the fixture MADE, not one it inherited',
 'SELECT COALESCE((SELECT value->>''plant_ok'' FROM golden.scratch
                    WHERE fixture_id=54 AND key=''plant''),''absent'')',
 'eq', 'yes', true, 'P3'),
(54, 8,
 'S-274 residue: custody was released - golden.weimi_pin_backup is empty. CODY R1: this reads the TABLE LIVE and counts ALL of it, never golden.scratch. A scenario that RAISEs rolls back its own scratch DELETE (S-266), so a scratch-derived custody sensor would go green off the previous run''s snapshot exactly when a leak is most likely; and a two-machine filter would miss a third plant whose restore was forgotten',
 'SELECT (SELECT count(*)::text FROM golden.weimi_pin_backup)',
 'eq', '0', true, 'P3'),
(54, 9,
 'S-274 residue: live shelf state on BOTH the anchor and the donor machine is byte-identical before the plant and after the restore - a planter that leaked would rewrite live assortment for every later fixture in the same sweep',
 'SELECT CASE
           WHEN (SELECT value->>''pre_state'' FROM golden.scratch WHERE fixture_id=54 AND key=''plant'') IS NULL
             OR (SELECT value->>''post_state'' FROM golden.scratch WHERE fixture_id=54 AND key=''restore'') IS NULL
             THEN ''absent''
           WHEN (SELECT value->>''pre_state'' FROM golden.scratch WHERE fixture_id=54 AND key=''plant'')
              = (SELECT value->>''post_state'' FROM golden.scratch WHERE fixture_id=54 AND key=''restore'')
             THEN ''restored''
           ELSE ''residue'' END',
 'eq', 'restored', true, 'P3');
