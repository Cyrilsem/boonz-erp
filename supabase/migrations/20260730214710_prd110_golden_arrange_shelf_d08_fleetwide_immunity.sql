-- PRD-110 · relay leg 27 · S-28 CLOSE (root cause B) · golden.arrange_shelf
--
-- PROVENANCE. The body below is the leg-24 file
-- `20260730203000_prd110_golden_arrange_shelf_d08_fleetwide_immunity.sql`, found UNAPPLIED
-- on disk at leg-27 STEP R (recorded as S-31 — the second instance of S-30's class, a file
-- without an apply). Its premise was RE-MEASURED live before any of it was trusted.
--
-- PREMISE, RE-MEASURED AT LEG 27 (not inherited). Simulating D-08's fleet-wide expansion
-- exactly — estimate_shelf_composition_v3(NULL,false) then golden.run_all('P1'), inside a
-- rollback envelope — reds 17 assertions across THREE fixtures:
--   fixture 20 seq 2,4,8,9,10,15 + 89   fixture 21 seq 4,6,7   fixture 22 seq 1,2,3,4,5,6 + 89
-- Leg 24 predicted exactly the 15 non-seq-89 members; seq 89 did not exist when it measured.
-- The estimator's own report is the mechanism: already_processed_skipped = 0 but
-- cold_start_seeded = 525. The reds are therefore ROOT CAUSE B (pre-existing seeded belief),
-- which `p_force_rederive` (leg 26, root cause A) does not address — and fixture 21 never
-- calls the estimator at all, so no force path could ever reach it.
--
-- TWO ROOT CAUSES, both properties of the fixtures, not of the estimator:
--   A. SNAPSHOT CONSUMPTION (fixtures 20, 22). estimate_shelf_composition_v3 keys idempotency
--      on source_ref='estimator:<stock_as_of>' and CONTINUEs past a shelf already carrying an
--      event with that ref. Once the production cron has processed the shelf for the current
--      WEIMI snapshot the fixture's OWN estimator call is a total no-op.
--   B. PRE-EXISTING SEEDED BELIEF (fixtures 20, 21, 22). Each fixture assumes the shelf starts
--      with only the buckets the fixture itself creates. A fleet-wide cold start seeds every
--      pod-bound shelf across its whole mapping at confidence 0.30 (the pod on NISSAN-0804 A09
--      is Barebells with SEVEN mapped SKUs, not the two the fixture picks), so bucket counts,
--      zeroed-bucket counts, event counts and the whole confidence trajectory shift.
--
-- THE FIX is one harness primitive that restores the fixture's own preconditions, and
-- deliberately NOT an edit to any assertion: if the arrange step is right, every existing
-- assertion is right in BOTH worlds, which is the proof that the fixtures were always
-- asserting the correct thing and merely borrowing preconditions they did not own.
--
-- NOTHING IS FABRICATED. The snapshot release re-presents the machine's newest existing
-- door_statuses verbatim under a later snapshot_at — a replay of the current observation,
-- exactly what the real ingest writes on a cycle where nothing changed. No stock number is
-- invented. Belief reset deletes only DERIVED rows the estimator rebuilds from events;
-- inventory_events is append-only (Article 7) and is never touched.

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
  v_prev_via text;
  v_prev_rpc text;
BEGIN
  -- FIXTURE-ONLY GUARD (leg 27, new — the leg-24 draft asserted the envelope in prose only).
  -- This function mutates derived belief and appends a WEIMI snapshot row. Both are safe
  -- ONLY inside a fixture scenario, which runs in a subtransaction that always rolls back.
  -- golden.run_fixture INSERTs its run row (finished_at NULL) BEFORE executing scenario_sql
  -- and UPDATEs finished_at at the end of the SAME transaction, so an unfinished row is
  -- visible if and only if a golden run is in flight right now. No production path
  -- (cron 44, the estimator, any engine) ever has one.
  IF NOT EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL) THEN
    RAISE EXCEPTION 'golden.arrange_shelf: REFUSED - no golden run is in flight. This '
      'function resets derived belief and replays a WEIMI snapshot; it is legal only inside '
      'a golden fixture scenario subtransaction.';
  END IF;

  SELECT machine_id INTO v_machine
    FROM public.shelf_configurations WHERE shelf_id = p_shelf_id;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'golden.arrange_shelf: shelf_id % does not exist', p_shelf_id;
  END IF;

  -- ARTICLE 4 (Cody, leg 27). shelf_composition carries tg_audit_shelf_composition ->
  -- audit_log_write, which is a LOGGER, not a gate: without provenance the DELETE still
  -- succeeds but lands an UNATTRIBUTED row in write_audit_log. Stamp it.
  -- ⚠️ The prior values are captured and RESTORED before every RETURN path: a
  -- transaction-local set_config leaks into every later statement of the same fixture
  -- (the PRD-016B provenance-GUC leak), which would silently stamp the fixture's
  -- subsequent writes as golden.arrange_shelf.
  v_prev_via := current_setting('app.via_rpc',  true);
  v_prev_rpc := current_setting('app.rpc_name', true);
  PERFORM set_config('app.via_rpc',  'true',                 true);
  PERFORM set_config('app.rpc_name', 'golden.arrange_shelf', true);

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

  -- ARTICLE 4 (Cody, leg 27): restore provenance before returning, so nothing downstream
  -- inherits this function's stamp. On any RAISE path above, the subtransaction abort
  -- rolls the GUCs back for us -- set_config(..., is_local => true) is transactional.
  PERFORM set_config('app.via_rpc',  v_prev_via, true);
  PERFORM set_config('app.rpc_name', v_prev_rpc, true);

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
  'PRD-110 leg 24 body, guarded and applied at leg 27 (S-28 root cause B / S-31). Gives a '
  'golden fixture ownership of its shelf preconditions so it behaves identically whether or '
  'not the production estimator (cron 44) has already processed that shelf for the current '
  'WEIMI snapshot. Resets DERIVED shelf_composition rows and replays the machine newest '
  'door_statuses under a later snapshot_at. Fabricates no stock value and never touches '
  'append-only inventory_events. REFUSES unless a golden run is in flight. '
  'ARTICLE 1/8 NOTE (Cody, leg 27): public.weimi_device_status has NO canonical writer '
  'function (the n8n ingest writes it directly) and NO triggers of any kind, including no '
  'audit trigger -- so this is the first in-database writer to the sensor table and its '
  'INSERT is invisible to write_audit_log. That is accepted only because the function is '
  'fixture-only and refuses outside a golden run. The shelf_composition DELETE IS audited, '
  'and is stamped app.rpc_name = golden.arrange_shelf.';

REVOKE ALL ON FUNCTION golden.arrange_shelf(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION golden.arrange_shelf(uuid, boolean) FROM anon, authenticated;

-- ── PROOFS (RISK 77: a CREATE re-grants from Supabase default privileges; assert, do not assume)
DO $verify$
DECLARE v_acl text; v_raised boolean := false;
BEGIN
  SELECT coalesce(proacl::text,'<null>') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='golden' AND p.proname='arrange_shelf';
  IF v_acl LIKE '%anon=%' OR v_acl LIKE '%authenticated=%' THEN
    RAISE EXCEPTION 'golden.arrange_shelf ACL still exposes anon/authenticated: %', v_acl;
  END IF;

  -- The guard must BIND. This migration is not a golden run, so the call must be refused.
  BEGIN
    PERFORM golden.arrange_shelf(
      (SELECT shelf_id FROM public.shelf_configurations LIMIT 1), false);
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%no golden run is in flight%' THEN v_raised := true; ELSE RAISE; END IF;
  END;
  IF NOT v_raised THEN
    RAISE EXCEPTION 'golden.arrange_shelf: fixture-only guard did NOT bind outside a run';
  END IF;

  RAISE NOTICE 'golden.arrange_shelf verified: acl=% guard=binds', v_acl;
END
$verify$;
