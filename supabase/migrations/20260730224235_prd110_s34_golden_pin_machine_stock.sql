-- PRD-110 · S-34 · relay leg 28
-- golden.pin_machine_stock / golden.restore_machine_stock
--
-- WHY. Fixtures 3 and 5 assert on live fleet stock through a live engine_add_pod call.
-- The daily WEIMI ingest (~22:00:40 UTC) moves that stock, so five P0 assertions flipped
-- red at leg 27 close with no engine change (R27-D6 / S-34). This is the same class
-- golden.arrange_shelf closed for fixtures 20/21/22 at leg 27: a fixture must own the
-- preconditions it asserts on.
--
-- SAFETY MODEL. The pin and the restore always execute inside the SAME transaction as
-- the engine call (golden.run_all is one transaction; plpgsql cannot commit). Under MVCC
-- no other session can ever observe the pinned value: it is created and reverted between
-- two commits of a single transaction. If anything raises, the transaction (or
-- golden.run_fixture's savepoint) rolls the pin back. Therefore this NEVER exposes a
-- mutated WEIMI count to cron 44, the estimator, the engine, or the FE.
-- RISK 75 is honoured: an un-restored pin is not merely unlikely, it is DETECTED --
-- golden.weimi_pin_backup must be empty when assertions run (seq 94).

CREATE TABLE IF NOT EXISTS golden.weimi_pin_backup (
  -- R1 (Cody, leg 28): machine_id is the PK, not status_id. restore_machine_stock looks up
  -- by machine_id; a status_id PK would let two rows exist for one machine and turn that
  -- into a bare 21000 "more than one row returned" with no diagnosis.
  machine_id    uuid PRIMARY KEY,
  status_id     uuid        NOT NULL,
  door_statuses jsonb       NOT NULL,
  -- The pre-pin total AS THE VIEW REPORTS IT. Summing the raw JSONB instead would count
  -- aisles that map to no non-phantom shelf, so a correct restore would fail comparison.
  pre_units     bigint      NOT NULL,
  pinned_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE golden.weimi_pin_backup IS
  'PRD-110 S-34. Transaction-scoped custody of the original weimi_device_status.door_statuses '
  'while a golden fixture pins shelf counts. NOT a materialised query result (Article 14 does '
  'not apply): it holds pre-image state no view can derive. Must be EMPTY outside a fixture '
  'scenario -- golden assertion seq 94 enforces that.';

ALTER TABLE golden.weimi_pin_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON golden.weimi_pin_backup FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION golden.pin_machine_stock(
  p_machine_id  uuid,
  p_curr_stock  integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, golden, pg_temp
AS $fn$
DECLARE
  v_status   uuid;
  v_orig     jsonb;
  v_aisles   int;
  v_before   bigint;
  v_pre_view bigint;
  v_after    bigint;
  v_updated  int := 0;
  v_offend   int;
  v_prev_via text;
  v_prev_rpc text;
BEGIN
  -- FIXTURE-ONLY GUARD (identical predicate to golden.arrange_shelf, leg 27).
  -- golden.run_fixture INSERTs its run row with finished_at NULL BEFORE executing
  -- scenario_sql and UPDATEs it at the end of the SAME transaction, so an unfinished row
  -- is visible if and only if a golden run is in flight. No production path ever has one.
  IF NOT EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL) THEN
    RAISE EXCEPTION 'golden.pin_machine_stock: REFUSED - no golden run is in flight. This '
      'function mutates a live WEIMI observation; it is legal only inside a golden fixture '
      'scenario, which restores it before the transaction commits.';
  END IF;

  IF p_curr_stock IS NULL OR p_curr_stock < 0 THEN
    RAISE EXCEPTION 'golden.pin_machine_stock: p_curr_stock must be >= 0, got %', p_curr_stock;
  END IF;

  -- The row v_live_shelf_stock reads: newest snapshot for this machine.
  SELECT status_id, door_statuses INTO v_status, v_orig
    FROM public.weimi_device_status
   WHERE machine_id = p_machine_id
   ORDER BY snapshot_at DESC
   LIMIT 1;

  IF v_status IS NULL THEN
    -- LAW 5: never silently do nothing.
    RAISE EXCEPTION 'golden.pin_machine_stock: machine % has no weimi_device_status row',
      p_machine_id;
  END IF;

  SELECT count(*), coalesce(sum(GREATEST(0,(ais.value->>'currStock')::int)),0)
    INTO v_aisles, v_before
    FROM jsonb_array_elements(v_orig) cab,
         jsonb_array_elements(cab.value->'layers') lay,
         jsonb_array_elements(lay.value->'aisles') ais;

  IF v_aisles = 0 THEN
    RAISE EXCEPTION 'golden.pin_machine_stock: machine % newest snapshot carries no aisles',
      p_machine_id;
  END IF;

  -- Pre-pin total through the SAME view the restore will check, so the two are comparable.
  SELECT coalesce(sum(si.current_stock),0) INTO v_pre_view
    FROM public.v_shelf_slot_identity si
    JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
   WHERE sc.machine_id = p_machine_id AND sc.is_phantom = false;

  -- Custody of the pre-image. ON CONFLICT DO NOTHING so a second pin in the same
  -- transaction cannot overwrite the ORIGINAL with an already-pinned image.
  INSERT INTO golden.weimi_pin_backup (machine_id, status_id, door_statuses, pre_units)
  VALUES (p_machine_id, v_status, v_orig, v_pre_view)
  ON CONFLICT (machine_id) DO NOTHING;

  -- ARTICLE 4 provenance, stamped and restored (the PRD-016B GUC-leak lesson).
  v_prev_via := current_setting('app.via_rpc',  true);
  v_prev_rpc := current_setting('app.rpc_name', true);
  PERFORM set_config('app.via_rpc',  'true',                     true);
  PERFORM set_config('app.rpc_name', 'golden.pin_machine_stock', true);

  -- snapshot_at is deliberately NOT touched: it is the estimator's idempotency key and
  -- the velocity view's anchor. Only currStock changes.
  UPDATE public.weimi_device_status w
     SET door_statuses = (
       SELECT jsonb_agg(
                CASE WHEN cab.value ? 'layers' THEN jsonb_set(cab.value,'{layers}',(
                       SELECT jsonb_agg(
                                CASE WHEN lay.value ? 'aisles' THEN jsonb_set(lay.value,'{aisles}',(
                                       SELECT jsonb_agg(ais.value || jsonb_build_object('currStock', p_curr_stock)
                                                        ORDER BY ais.ord)
                                         FROM jsonb_array_elements(lay.value->'aisles') WITH ORDINALITY ais(value,ord)
                                     )) ELSE lay.value END ORDER BY lay.ord)
                         FROM jsonb_array_elements(cab.value->'layers') WITH ORDINALITY lay(value,ord)
                     )) ELSE cab.value END ORDER BY cab.ord)
         FROM jsonb_array_elements(w.door_statuses) WITH ORDINALITY cab(value,ord))
   WHERE w.status_id = v_status;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  PERFORM set_config('app.via_rpc',  v_prev_via, true);
  PERFORM set_config('app.rpc_name', v_prev_rpc, true);

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'golden.pin_machine_stock: expected to update exactly 1 snapshot row, got %',
      v_updated;
  END IF;

  -- SELF-PROVING (RISK 75): read back through the SAME view the engine reads, so a pin
  -- that did not land can never be mistaken for a pin that did.
  -- R2 (Cody, leg 28): prove the pin UNCONDITIONALLY and per shelf. The earlier form only
  -- checked the p_curr_stock = 0 case, so a non-zero pin could return success having done
  -- nothing -- the vacuous-success class RISK 75 exists to prevent.
  SELECT count(*) FILTER (WHERE si.current_stock IS DISTINCT FROM p_curr_stock),
         coalesce(sum(si.current_stock),0)
    INTO v_offend, v_after
    FROM public.v_shelf_slot_identity si
    JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
   WHERE sc.machine_id = p_machine_id AND sc.is_phantom = false;

  IF v_offend <> 0 THEN
    RAISE EXCEPTION 'golden.pin_machine_stock: pin did not take - % non-phantom shelves on '
      'machine % still read a current_stock other than % through v_shelf_slot_identity',
      v_offend, p_machine_id, p_curr_stock;
  END IF;

  RETURN jsonb_build_object(
    'machine_id',      p_machine_id,
    'status_id',       v_status,
    'aisles_pinned',   v_aisles,
    'curr_stock',      p_curr_stock,
    'units_before_raw',v_before,
    'units_before_view',v_pre_view,
    'units_after_view',v_after);
END;
$fn$;

-- ---------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION golden.restore_machine_stock(p_machine_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, golden, pg_temp
AS $fn$
DECLARE
  v_status   uuid;
  v_orig     jsonb;
  v_updated  int := 0;
  v_after    bigint;
  v_expect   bigint;
  v_prev_via text;
  v_prev_rpc text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL) THEN
    RAISE EXCEPTION 'golden.restore_machine_stock: REFUSED - no golden run is in flight.';
  END IF;

  SELECT status_id, door_statuses, pre_units INTO v_status, v_orig, v_expect
    FROM golden.weimi_pin_backup WHERE machine_id = p_machine_id;

  IF v_status IS NULL THEN
    -- LAW 5. A restore with nothing to restore means the pin never happened, and the
    -- caller is about to assert on state it does not own.
    RAISE EXCEPTION 'golden.restore_machine_stock: no pin backup for machine % - nothing '
      'to restore. Did pin_machine_stock run?', p_machine_id;
  END IF;

  -- R3 (Cody, leg 28): v_expect is the pre-pin total the PIN recorded through the same
  -- view, not a re-sum of the raw JSONB (which counts aisles that map to no shelf).
  v_prev_via := current_setting('app.via_rpc',  true);
  v_prev_rpc := current_setting('app.rpc_name', true);
  PERFORM set_config('app.via_rpc',  'true',                         true);
  PERFORM set_config('app.rpc_name', 'golden.restore_machine_stock', true);

  UPDATE public.weimi_device_status SET door_statuses = v_orig WHERE status_id = v_status;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  PERFORM set_config('app.via_rpc',  v_prev_via, true);
  PERFORM set_config('app.rpc_name', v_prev_rpc, true);

  IF v_updated <> 1 THEN
    RAISE EXCEPTION 'golden.restore_machine_stock: expected 1 row, got %', v_updated;
  END IF;

  DELETE FROM golden.weimi_pin_backup WHERE status_id = v_status;

  SELECT coalesce(sum(si.current_stock),0) INTO v_after
    FROM public.v_shelf_slot_identity si
    JOIN public.shelf_configurations sc ON sc.shelf_id = si.shelf_id
   WHERE sc.machine_id = p_machine_id AND sc.is_phantom = false;

  IF v_after IS DISTINCT FROM v_expect THEN
    RAISE EXCEPTION 'golden.restore_machine_stock: restore did not land - machine % reads % '
      'units through v_shelf_slot_identity, pre-image says %', p_machine_id, v_after, v_expect;
  END IF;

  RETURN jsonb_build_object('machine_id', p_machine_id, 'status_id', v_status,
                            'restored', true, 'units_after_view', v_after,
                            'units_expected', v_expect);
END;
$fn$;

-- RISK 77: DROP/CREATE of a function silently re-grants anon from Supabase default
-- privileges. Restate the whole intended ACL explicitly for BOTH functions.
REVOKE ALL ON FUNCTION golden.pin_machine_stock(uuid, integer)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION golden.restore_machine_stock(uuid)          FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION golden.pin_machine_stock(uuid, integer)  TO service_role;
GRANT EXECUTE ON FUNCTION golden.restore_machine_stock(uuid)       TO service_role;
