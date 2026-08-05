-- PRD-110 P1.3 · golden fixture 24 "Sentinel retirement safety" — fixture row (assertions follow).
-- Additive: writes ONLY to golden.fixtures. No public object created, altered or dropped.
-- The scenario mutates 40 live warehouse_inventory rows inside a plpgsql subtransaction that ALWAYS
-- aborts (leg-9 RAISE/catch pattern); residue is asserted at seq 95-99.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  24,
  'Sentinel retirement safety',
  'SOA regression (PRD-110 P1.3)',
  'P1',
  DATE '2030-01-01' + 24,
  true,
  'passing',
  'ORIGINAL SPEC TEXT (GOLDEN-FIXTURES #24), preserved per the S-04 house pattern: "With sentinels deleted (P1.3): VOX SOA for a frozen month reproduces BNZ/MAFE/2026-06/001 numbers to the cent."'
  || E'\n\n' ||
  'CORRECTION 1 (leg 10, S-16): the DELETE is unexecutable. 255 inventory_audit_log rows reference the 40 sentinels under a NO ACTION FK, so the DELETE aborts. Encoded as a live proof at seq 24/28, not an assumption.'
  || E'\n\n' ||
  'CORRECTION 2 (leg 11, measured): retirement is NOT inactivate_warehouse_row either. That writer refuses any row with warehouse_stock > 0 (seq 26), and all 40 sentinels hold stock. Draining to 0 via apply_inventory_correction fires tg_propose_inactivate_on_zero_stock, which writes an auto-confirmed proposal and flips the row to Inactive itself, so a subsequent inactivate_warehouse_row call fails "already in status Inactive" (seq 27). Canonical retirement is therefore ONE call per row: apply_inventory_correction(id, NULL, NULL, NULL, 0, reason, cs). D-09 activation script corrected to match.'
  || E'\n\n' ||
  'Why the structural assertions (seq 10-12) are stronger than the behavioural one: they hold for every month, not just 2026-06. 25 revenue-shaped objects scanned, 0 read warehouse_inventory.'
  || E'\n\n' ||
  'CODY FINDING (leg 11, Article 6, PRE-EXISTING debt, not introduced by this fixture): Article 6 reads "No trigger, function, cron, n8n sync, or app flow may write it", yet tg_propose_inactivate_on_zero_stock is a trigger that UPDATEs warehouse_inventory.status directly, and the retirement path depends on it for the flip. Article 6 also names app.rpc_name=''set_warehouse_status'' as its enforcement hook, and that function does not exist: the live canonical writers are inactivate_warehouse_row / reactivate_warehouse_row / confirm_warehouse_status_proposal. Grandfathered (RC-14 Tier 2a) and recorded, not resolved here. seq 15 asserts the flip happened without any raw UPDATE from this fixture.'
  || E'\n\n' ||
  'The availability fingerprint (seq 19) is the load-bearing invariant: v_shelf_availability_v3 computes available_units with FILTER (WHERE NOT is_sentinel), so retiring all 40 sentinels changes no shelf plannable quantity at all.',
$sc$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'before', jsonb_build_object(
  'sent_rows',       (SELECT count(*) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)),
  'sent_active',     (SELECT count(*) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND wi.status = 'Active'),
  'sent_units',      (SELECT COALESCE(sum(wi.warehouse_stock),0) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)),
  'pickable_sent',   (SELECT count(*) FROM public.v_wh_pickable k JOIN public.warehouse_inventory wi ON wi.wh_inventory_id = k.wh_inventory_id WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)),
  'avail_rows',      (SELECT count(*) FROM public.v_shelf_availability_v3),
  'avail_fp',        (SELECT md5(string_agg(a.shelf_id::text||':'||COALESCE(a.available_units::text,'NULL'), ',' ORDER BY a.shelf_id)) FROM public.v_shelf_availability_v3 a),
  'would_block',     (SELECT count(*) FROM public.v_shelf_availability_v3 a WHERE a.would_block_on_retirement),
  'venue_notnull',   (SELECT count(*) FROM public.v_shelf_availability_v3 a WHERE NOT a.is_constrained AND a.available_units IS NOT NULL),
  'sentinel_backed', (SELECT count(*) FROM public.v_shelf_availability_v3 a WHERE a.sentinel_backed),
  'audit_total',     (SELECT count(*) FROM public.inventory_audit_log),
  'audit_sent',      (SELECT count(*) FROM public.inventory_audit_log l JOIN public.warehouse_inventory wi ON wi.wh_inventory_id = l.wh_inventory_id WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)),
  'proposals',       (SELECT count(*) FROM public.warehouse_inventory_status_proposal),
  'df_open',         (SELECT count(*) FROM public.driver_feedback WHERE resolved = false),
  'ev',              (SELECT count(*) FROM public.inventory_events),
  'comp',            (SELECT count(*) FROM public.shelf_composition),
  'anom',            (SELECT count(*) FROM public.inventory_anomalies));
DO $fx24$
DECLARE
  v_cs   uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';
  v_soa_before text; v_id uuid; v_payload jsonb; v_r record; v_n int := 0;
  v_err_stocked text := 'NOT_ATTEMPTED';
  v_err_delete  text := 'NOT_ATTEMPTED';
  v_err_inact   text := 'NOT_ATTEMPTED';
BEGIN
  v_soa_before := (public.get_vox_consumer_report(ARRAY['Mercato','Mirdif'], true, DATE '2026-05-01', DATE '2026-06-30', NULL)->'summary'->>'total_sales');

  SELECT wi.wh_inventory_id INTO v_id FROM public.warehouse_inventory wi
   WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND wi.status = 'Active'
   ORDER BY wi.wh_inventory_id LIMIT 1;

  BEGIN
    -- GUARD A: the canonical Article 6 writer refuses a stocked row (spec correction 2, first half)
    BEGIN
      PERFORM public.inactivate_warehouse_row(v_id,
        'golden fixture 24: retirement attempt on a still-stocked sentinel', v_cs);
      v_err_stocked := 'SUCCEEDED';
    EXCEPTION WHEN OTHERS THEN v_err_stocked := SQLERRM;
    END;

    -- GUARD B: the BUILD SPEC DELETE is unexecutable (spec correction 1). This statement MUST fail;
    -- seq 24 and seq 28 turn the fixture red if it ever stops failing. Never copy it as a pattern.
    BEGIN
      DELETE FROM public.warehouse_inventory wi
       WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date);
      v_err_delete := 'SUCCEEDED';
    EXCEPTION WHEN OTHERS THEN v_err_delete := SQLERRM;
    END;

    -- RETIREMENT, the way it will actually happen: one canonical call per row.
    -- tg_propose_inactivate_on_zero_stock performs the Active -> Inactive flip.
    FOR v_r IN
      SELECT wi.wh_inventory_id FROM public.warehouse_inventory wi
       WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND wi.status = 'Active'
       ORDER BY wi.wh_inventory_id
    LOOP
      PERFORM public.apply_inventory_correction(v_r.wh_inventory_id, NULL, NULL, NULL, 0,
        'PRD-110 P1.3 sentinel retirement: venue sourcing now makes this shelf unconstrained', v_cs);
      v_n := v_n + 1;
    END LOOP;

    -- GUARD C: the trigger already inactivated it, so the writer refuses a second time
    BEGIN
      PERFORM public.inactivate_warehouse_row(v_id,
        'golden fixture 24: second retirement attempt after the drain', v_cs);
      v_err_inact := 'SUCCEEDED';
    EXCEPTION WHEN OTHERS THEN v_err_inact := SQLERRM;
    END;

    v_payload := jsonb_build_object(
      'drained',            v_n::text,
      'soa_before',         v_soa_before,
      'soa_after',          (public.get_vox_consumer_report(ARRAY['Mercato','Mirdif'], true, DATE '2026-05-01', DATE '2026-06-30', NULL)->'summary'->>'total_sales'),
      'sent_active_after',  (SELECT count(*) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND wi.status = 'Active')::text,
      'sent_inactive_after',(SELECT count(*) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND wi.status = 'Inactive')::text,
      'sent_units_after',   (SELECT COALESCE(sum(wi.warehouse_stock),0) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date))::text,
      'pickable_sent_after',(SELECT count(*) FROM public.v_wh_pickable k JOIN public.warehouse_inventory wi ON wi.wh_inventory_id = k.wh_inventory_id WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date))::text,
      'avail_rows_after',   (SELECT count(*) FROM public.v_shelf_availability_v3)::text,
      'avail_fp_after',     (SELECT md5(string_agg(a.shelf_id::text||':'||COALESCE(a.available_units::text,'NULL'), ',' ORDER BY a.shelf_id)) FROM public.v_shelf_availability_v3 a),
      'would_block_after',  (SELECT count(*) FROM public.v_shelf_availability_v3 a WHERE a.would_block_on_retirement)::text,
      'venue_notnull_after',(SELECT count(*) FROM public.v_shelf_availability_v3 a WHERE NOT a.is_constrained AND a.available_units IS NOT NULL)::text,
      'sentinel_backed_after',(SELECT count(*) FROM public.v_shelf_availability_v3 a WHERE a.sentinel_backed)::text,
      'proposals_after',    (SELECT count(*) FROM public.warehouse_inventory_status_proposal)::text,
      'err_stocked',        v_err_stocked,
      'err_delete',         v_err_delete,
      'err_inact',          v_err_inact);
    RAISE EXCEPTION 'GP24:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP24:%' THEN v_payload := substring(SQLERRM from 'GP24:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;
  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx24$;
$sc$
);
