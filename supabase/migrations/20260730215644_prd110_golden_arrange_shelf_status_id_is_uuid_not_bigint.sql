-- PRD-110 · relay leg 27 · one-line type fix to golden.arrange_shelf
--
-- prd110_golden_arrange_shelf_release_by_update_not_insert declared the snapshot row key as
--   v_status bigint
-- but public.weimi_device_status.status_id is a **uuid**. Every call raised
--   invalid input syntax for type bigint: "01f8d1d7-..."
-- which run_fixture swallowed into detail as a scenario_error (see the companion migration
-- prd110_golden_runner_scenario_error_is_a_hard_fail for why that was nearly invisible).
--
-- Only the DECLARE line changes; the body is otherwise identical to the reviewed version.

CREATE OR REPLACE FUNCTION golden.arrange_shelf(
  p_shelf_id          uuid,
  p_release_snapshot  boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_machine  uuid;
  v_status   uuid;          -- weimi_device_status.status_id is uuid, NOT bigint (leg 27 fix)
  v_deleted  int := 0;
  v_bumped   int := 0;
  v_old_ref  timestamptz;
  v_new_ref  timestamptz;
  v_prev_via text;
  v_prev_rpc text;
BEGIN
  -- FIXTURE-ONLY GUARD. golden.run_fixture INSERTs its run row (finished_at NULL) BEFORE
  -- executing scenario_sql and UPDATEs finished_at at the end of the SAME transaction, so an
  -- unfinished row is visible if and only if a golden run is in flight right now. No
  -- production path (cron 44, the estimator, any engine) ever has one.
  IF NOT EXISTS (SELECT 1 FROM golden.runs WHERE finished_at IS NULL) THEN
    RAISE EXCEPTION 'golden.arrange_shelf: REFUSED - no golden run is in flight. This '
      'function resets derived belief and re-dates a WEIMI snapshot; it is legal only inside '
      'a golden fixture scenario subtransaction.';
  END IF;

  SELECT machine_id INTO v_machine
    FROM public.shelf_configurations WHERE shelf_id = p_shelf_id;
  IF v_machine IS NULL THEN
    RAISE EXCEPTION 'golden.arrange_shelf: shelf_id % does not exist', p_shelf_id;
  END IF;

  -- ARTICLE 4 (Cody). shelf_composition carries tg_audit_shelf_composition -> audit_log_write,
  -- a LOGGER not a gate: without provenance the DELETE still succeeds but lands an
  -- UNATTRIBUTED row in write_audit_log. Stamp it, and RESTORE the prior values before
  -- returning -- a transaction-local set_config leaks into every later statement of the same
  -- fixture (the PRD-016B provenance-GUC leak).
  v_prev_via := current_setting('app.via_rpc',  true);
  v_prev_rpc := current_setting('app.rpc_name', true);
  PERFORM set_config('app.via_rpc',  'true',                 true);
  PERFORM set_config('app.rpc_name', 'golden.arrange_shelf', true);

  -- (B) drop DERIVED belief only. These rows are reconstructible from inventory_events,
  -- which is append-only and untouched. Without this the fixture inherits the estimator's
  -- fleet-wide cold-start buckets (confidence 0.30) instead of starting from its own.
  DELETE FROM public.shelf_composition WHERE shelf_id = p_shelf_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  IF p_release_snapshot THEN
    -- (A) re-date the machine's newest observation so the estimator's source_ref is
    -- unconsumed and it will actually process this shelf. Counts are NOT touched, no row is
    -- added, and snapshot_date is deliberately left alone (unique_device_status is
    -- UNIQUE (weimi_device_id, snapshot_date) -- one row per device per DAY).
    SELECT status_id, snapshot_at INTO v_status, v_old_ref
      FROM public.weimi_device_status
     WHERE machine_id = v_machine
     ORDER BY snapshot_at DESC
     LIMIT 1;

    IF v_status IS NULL THEN
      -- LAW 5: never silently do nothing. A fixture that needs a live snapshot and has
      -- none must fail loudly rather than pass by accident.
      RAISE EXCEPTION
        'golden.arrange_shelf: machine % has no weimi_device_status row to re-date', v_machine;
    END IF;

    v_new_ref := greatest(now(), v_old_ref + interval '1 second');

    UPDATE public.weimi_device_status
       SET snapshot_at = v_new_ref
     WHERE status_id = v_status;
    GET DIAGNOSTICS v_bumped = ROW_COUNT;

    IF v_bumped <> 1 THEN
      RAISE EXCEPTION 'golden.arrange_shelf: expected to re-date exactly 1 snapshot row, got %',
        v_bumped;
    END IF;
  END IF;

  -- ARTICLE 4: restore provenance before returning, so nothing downstream inherits this
  -- function's stamp. On any RAISE path above the subtransaction abort rolls the GUCs back
  -- for us -- set_config(..., is_local => true) is transactional.
  PERFORM set_config('app.via_rpc',  v_prev_via, true);
  PERFORM set_config('app.rpc_name', v_prev_rpc, true);

  RETURN jsonb_build_object(
    'shelf_id',          p_shelf_id,
    'machine_id',        v_machine,
    'belief_rows_reset', v_deleted,
    'snapshot_released', p_release_snapshot,
    'snapshot_rows_bumped', v_bumped,
    'snapshot_from',     v_old_ref,
    'snapshot_to',       v_new_ref);
END;
$$;

REVOKE ALL ON FUNCTION golden.arrange_shelf(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION golden.arrange_shelf(uuid, boolean) FROM anon, authenticated;

DO $verify$
DECLARE v_acl text; v_raised boolean := false;
BEGIN
  SELECT coalesce(proacl::text,'<null>') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='golden' AND p.proname='arrange_shelf';
  IF v_acl LIKE '%anon=%' OR v_acl LIKE '%authenticated=%' THEN
    RAISE EXCEPTION 'golden.arrange_shelf ACL still exposes anon/authenticated: %', v_acl;
  END IF;
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
