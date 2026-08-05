-- PRD-110 leg 24 · S-28 EXPANDED — make the estimator fixtures immune to D-08 fleet-wide
--
-- WHY (all measured live at leg 24, none inferred):
-- D-08 is CS-pre-approved to expand cron 44 from MPMCC-1058 to the whole fleet after 3
-- clean days (~2026-08-02), with no further ask. Simulating that expansion exactly
-- (estimate_shelf_composition_v3(NULL,false) inside a rollback envelope, then run_all('P1'))
-- reds **15 assertions across THREE fixtures**: 20 (seq 2,4,8,9,10,15), 21 (seq 4,6,7),
-- 22 (seq 1,2,3,4,5,6).
--
-- S-28 recorded the exposure as "one assertion, fixture 22 seq 1", and recorded fixtures 20
-- and 21 as safe. All three of those claims are false, and S-28's proposed fix (re-express
-- seq 1 as a delta) would not have repaired a single one of the other 14.
--
-- TWO ROOT CAUSES, both properties of the fixtures, not of the estimator:
--
--   A. SNAPSHOT CONSUMPTION (fixtures 20, 22). estimate_shelf_composition_v3 keys
--      idempotency on source_ref = 'estimator:<stock_as_of>' and CONTINUEs past any shelf
--      that already has an event with that ref. Once the production cron has processed a
--      shelf for the current WEIMI snapshot, the fixture's OWN estimator call is a total
--      no-op: count_drops_allocated 0, events_written 0, shelves_confidence_decayed 0.
--      The fixture stops testing the thing it names.
--
--   B. PRE-EXISTING SEEDED BELIEF (fixtures 20, 21, 22). Each fixture assumes the shelf
--      starts with only the buckets the fixture itself creates. A fleet-wide cold start
--      seeds every pod-bound shelf across its whole mapping at confidence 0.30 (the pod on
--      NISSAN-0804 A09 is Barebells with SEVEN mapped SKUs, not the two the fixture picks),
--      so bucket counts, zeroed-bucket counts, event counts and the entire confidence
--      trajectory shift.
--
-- THE FIX is one harness primitive that restores the fixture's own preconditions, and
-- deliberately NOT an edit to any assertion: if the arrange step is right, every existing
-- assertion is right in BOTH worlds, which is the proof that the fixtures were always
-- asserting the correct thing and merely borrowing preconditions they did not own.
--
-- NOTHING IS FABRICATED. The snapshot release re-presents the machine's newest existing
-- door_statuses verbatim under a later snapshot_at — a replay of the current observation,
-- which is exactly what the real ingest writes on a cycle where nothing changed. No stock
-- number is invented. Belief reset deletes only DERIVED rows the estimator rebuilds from
-- events; inventory_events is append-only (Article 7) and is never touched.
--
-- ENVELOPE: every caller is a golden fixture scenario, which runs inside a subtransaction
-- that always rolls back. Nothing here can commit. Proven by the residue assertions each
-- fixture already carries.

CREATE OR REPLACE FUNCTION golden.arrange_shelf(
  p_shelf_id          uuid,
  p_release_snapshot  boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_machine  uuid;
  v_device   text;
  v_deleted  int := 0;
  v_old_ref  timestamptz;
  v_new_ref  timestamptz;
BEGIN
  SELECT machine_id INTO v_machine
    FROM public.shelf_configurations WHERE shelf_id = p_shelf_id;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'golden.arrange_shelf: shelf_id % does not exist', p_shelf_id;
  END IF;

  -- (B) drop DERIVED belief only. These rows are reconstructible from inventory_events,
  -- which is append-only and untouched. Without this the fixture inherits the estimator's
  -- cold-start buckets (confidence 0.30) instead of starting from its own.
  DELETE FROM public.shelf_composition WHERE shelf_id = p_shelf_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  IF p_release_snapshot THEN
    -- (A) re-present the machine's newest observation under a later snapshot_at so the
    -- estimator's source_ref is unconsumed and it will actually process this shelf.
    -- Counts are copied verbatim: this is a replay, not a synthetic reading.
    SELECT device_name, snapshot_at INTO v_device, v_old_ref
      FROM public.weimi_device_status
     WHERE machine_id = v_machine
     ORDER BY snapshot_at DESC
     LIMIT 1;

    IF v_device IS NULL THEN
      -- LAW 5: never silently do nothing. A fixture that needs a live snapshot and has
      -- none must fail loudly rather than pass by accident.
      RAISE EXCEPTION
        'golden.arrange_shelf: machine % has no weimi_device_status row to replay', v_machine;
    END IF;

    v_new_ref := greatest(now(), v_old_ref + interval '1 second');

    INSERT INTO public.weimi_device_status
      (machine_id, weimi_device_id, device_code, device_name, is_covered, is_running,
       total_curr_stock, cabinet_count, door_statuses, snapshot_at, snapshot_date)
    SELECT machine_id, weimi_device_id, device_code, device_name, is_covered, is_running,
           total_curr_stock, cabinet_count, door_statuses,
           v_new_ref, (v_new_ref AT TIME ZONE 'UTC')::date
      FROM public.weimi_device_status
     WHERE device_name = v_device
     ORDER BY snapshot_at DESC
     LIMIT 1;
  END IF;

  RETURN jsonb_build_object(
    'shelf_id',          p_shelf_id,
    'machine_id',        v_machine,
    'belief_rows_reset', v_deleted,
    'snapshot_released', p_release_snapshot,
    'snapshot_from',     v_old_ref,
    'snapshot_to',       v_new_ref);
END;
$$;

COMMENT ON FUNCTION golden.arrange_shelf(uuid, boolean) IS
  'PRD-110 leg 24 (S-28 EXPANDED). Gives a golden fixture ownership of its shelf preconditions '
  'so it behaves identically whether or not the production estimator (cron 44) has already '
  'processed that shelf for the current WEIMI snapshot. Resets DERIVED shelf_composition rows '
  'and replays the machine newest door_statuses under a later snapshot_at. Fabricates no stock '
  'value and never touches append-only inventory_events. Fixture-only: every caller runs inside '
  'a subtransaction that rolls back.';

REVOKE ALL ON FUNCTION golden.arrange_shelf(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION golden.arrange_shelf(uuid, boolean) FROM anon, authenticated;
