-- PRD-110 S-50 · leg 43 · L43-U1 migration B
-- Fix the RETIREMENT PATH, not the assertions. seq 15/16/18 are the P1.3 contract and
-- are left at 40/0/40 untouched - they go green because the path now works, not because
-- the expectation was lowered. seq 25 is the separate S-47 ambient-state problem and is
-- re-expressed against fixture-owned state.
--
-- Editing method (leg-42 doctrine): surgical replace() with a per-anchor pre-guard
-- requiring each anchor to occur EXACTLY ONCE. The ~150-line scenario is never retyped,
-- so it cannot be silently truncated.

DO $mig$
DECLARE
  v_sql       text;
  v_a1 constant text := E'  ''anom'',            (SELECT count(*) FROM public.inventory_anomalies));';
  v_a2 constant text := E'  v_err_inact   text := ''NOT_ATTEMPTED'';';
  v_a3 constant text := E'    -- RETIREMENT, the way it will actually happen: one canonical call per row.';
  v_a4 constant text := E'      ''err_stocked'',        v_err_stocked,';
  v_n         int;
BEGIN
  SELECT scenario_sql INTO v_sql FROM golden.fixtures WHERE fixture_id = 24;
  IF v_sql IS NULL THEN RAISE EXCEPTION 'fixture 24 missing'; END IF;

  -- ---- pre-guards: every anchor must occur exactly once ----
  v_n := (length(v_sql) - length(replace(v_sql, v_a1, ''))) / length(v_a1);
  IF v_n <> 1 THEN RAISE EXCEPTION 'anchor A1 occurs % times, expected exactly 1', v_n; END IF;
  v_n := (length(v_sql) - length(replace(v_sql, v_a2, ''))) / length(v_a2);
  IF v_n <> 1 THEN RAISE EXCEPTION 'anchor A2 occurs % times, expected exactly 1', v_n; END IF;
  v_n := (length(v_sql) - length(replace(v_sql, v_a3, ''))) / length(v_a3);
  IF v_n <> 1 THEN RAISE EXCEPTION 'anchor A3 occurs % times, expected exactly 1', v_n; END IF;
  v_n := (length(v_sql) - length(replace(v_sql, v_a4, ''))) / length(v_a4);
  IF v_n <> 1 THEN RAISE EXCEPTION 'anchor A4 occurs % times, expected exactly 1', v_n; END IF;

  -- idempotency: refuse to double-apply
  IF v_sql LIKE '%drain_consumer_stock_phantom_v3%' THEN
    RAISE NOTICE 'fixture 24 already carries the S-50 consumer-drain leg; skipping';
    RETURN;
  END IF;

  -- ---- A1: measure the phantom consumer stock the retirement must account for ----
  v_sql := replace(v_sql, v_a1,
E'  ''anom'',            (SELECT count(*) FROM public.inventory_anomalies),
  ''sent_consumer'',      (SELECT COALESCE(sum(wi.consumer_stock),0) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)),
  ''sent_consumer_rows'', (SELECT count(*) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND COALESCE(wi.consumer_stock,0) > 0));');

  -- ---- A2: locals for the consumer-drain leg ----
  v_sql := replace(v_sql, v_a2,
E'  v_err_inact   text := ''NOT_ATTEMPTED'';
  v_cr record; v_cd_rows int := 0; v_cd_units numeric := 0;');

  -- ---- A3: S-50 - drain phantom consumer_stock BEFORE the warehouse drain ----
  v_sql := replace(v_sql, v_a3,
E'    -- S-50 LEG 1 of 2: drain phantom consumer_stock FIRST, through the canonical
    -- writer. tg_propose_inactivate_on_zero_stock fires only when BOTH warehouse_stock=0
    -- AND consumer_stock=0, so without this leg every sentinel carrying consumer stock is
    -- left Active with zero warehouse stock - a real production defect, not a fixture one.
    -- Consumer-FIRST is deliberate: warehouse_stock stays non-zero through this loop, so
    -- no row is ever observable as "Active with zero warehouse stock" even transiently.
    -- NB: drain_consumer_stock_phantom_v3, NOT drain_phantom_consumer_stock (S-51).
    FOR v_cr IN
      SELECT wi.wh_inventory_id, COALESCE(wi.consumer_stock,0) AS cs
        FROM public.warehouse_inventory wi
       WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)
         AND COALESCE(wi.consumer_stock,0) > 0
       ORDER BY wi.wh_inventory_id
    LOOP
      PERFORM public.drain_consumer_stock_phantom_v3(v_cr.wh_inventory_id,
        ''PRD-110 P1.3 sentinel retirement: phantom consumer stock originating from dispatch_pack of sentinel units'', v_cs);
      v_cd_rows  := v_cd_rows + 1;
      v_cd_units := v_cd_units + v_cr.cs;
    END LOOP;

    -- RETIREMENT, the way it will actually happen: one canonical call per row.');

  -- ---- A4: new observables ----
  v_sql := replace(v_sql, v_a4,
E'      ''consumer_drained_rows'',  v_cd_rows::text,
      ''consumer_drained_units'', v_cd_units::text,
      ''sent_consumer_after'',  (SELECT COALESCE(sum(wi.consumer_stock),0) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date))::text,
      ''stranded_after'',       (SELECT count(*) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND wi.status = ''Active'' AND COALESCE(wi.warehouse_stock,0) = 0)::text,
      ''audit_txn_rows'',       (SELECT count(DISTINCT l.wh_inventory_id) FROM public.inventory_audit_log l JOIN public.warehouse_inventory wi ON wi.wh_inventory_id = l.wh_inventory_id WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date) AND golden.written_by_this_txn(l.xmin))::text,
      ''audit_txn_consumer_rows'', (SELECT count(DISTINCT l.wh_inventory_id) FROM public.inventory_audit_log l WHERE l.reason LIKE ''consumer_phantom_drain:%'' AND golden.written_by_this_txn(l.xmin))::text,
      ''err_stocked'',        v_err_stocked,');

  UPDATE golden.fixtures SET scenario_sql = v_sql WHERE fixture_id = 24;

  -- post-guards: every insertion actually landed
  IF v_sql NOT LIKE '%drain_consumer_stock_phantom_v3%' THEN RAISE EXCEPTION 'post-guard: drain leg missing'; END IF;
  IF v_sql NOT LIKE '%sent_consumer_rows%'             THEN RAISE EXCEPTION 'post-guard: precondition missing'; END IF;
  IF v_sql NOT LIKE '%stranded_after%'                 THEN RAISE EXCEPTION 'post-guard: stranded_after missing'; END IF;
  IF v_sql NOT LIKE '%audit_txn_consumer_rows%'        THEN RAISE EXCEPTION 'post-guard: audit attribution missing'; END IF;
END
$mig$;

-- ============================================================================
-- Assertions. seq 15/16/18 deliberately UNTOUCHED.
-- ============================================================================

-- seq 25: S-47 re-expression. The old form asserted an ABSOLUTE live count (255),
-- which drifts every time ambient packing touches a sentinel - it read 267 today.
-- The invariant it was really testing is "sentinels carry audit history, which is WHY
-- the DELETE aborts on the FK". That is now stated against fixture-owned state.
UPDATE golden.assertions SET
  check_sql = 'SELECT ((SELECT (value->>''audit_sent'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before'') > 0)::text',
  expect_op = 'eq',
  expect    = 'true',
  description = 'SPEC CORRECTION 1 (S-47 re-expression): sentinel rows carry inventory_audit_log history, which is WHY the BUILD SPEC DELETE aborts on the FK. Was an absolute 255; that constant drifts with ambient packing, so the invariant is now fixture-owned.'
WHERE fixture_id = 24 AND seq = 25;

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
 (24, 29, 'PRECONDITION (non-vacuity): at least one sentinel carries phantom consumer_stock, so the S-50 drain leg is genuinely exercised rather than silently skipped',
  'SELECT (value->>''sent_consumer_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''',
  'gt', '0', true, 'P1'),

 (24, 30, 'S-50: zero phantom consumer_stock remains on any sentinel after retirement',
  'SELECT (value->>''sent_consumer_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
  'eq', '0', true, 'P1'),

 (24, 31, 'S-50 CORE INVARIANT: no sentinel is left Active with zero warehouse stock. This is the exact production defect S-50 found - 5 rows would have been stranded, Active and unsellable, with live consumer stock.',
  'SELECT (value->>''stranded_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
  'eq', '0', true, 'P1'),

 (24, 32, 'S-50: every sentinel that carried phantom consumer_stock went through the canonical writer - the drained count equals the measured precondition count, so none was skipped',
  'SELECT ((SELECT (value->>''consumer_drained_rows'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs'') = (SELECT (value->>''sent_consumer_rows'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text',
  'eq', 'true', true, 'P1'),

 (24, 33, 'S-48 shape: each consumer drain left exactly one semantic audit row, attributed by xmin to THIS txn (not a created_at window). Guards Article 7 provenance on the new writer.',
  'SELECT ((SELECT (value->>''audit_txn_consumer_rows'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs'') = (SELECT (value->>''consumer_drained_rows'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''))::text',
  'eq', 'true', true, 'P1'),

 (24, 34, 'S-48 shape: every retired sentinel is provenanced by at least one audit row written by THIS txn - 40 distinct rows, so no row was flipped without a trail',
  'SELECT ((SELECT (value->>''audit_txn_rows'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs'') = (SELECT (value->>''drained'')::int FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''))::text',
  'eq', 'true', true, 'P1'),

 (24, 94, 'RESIDUE: sentinel consumer_stock total restored exactly after rollback (the phantom drains left no trace on live state)',
  'SELECT ((SELECT COALESCE(sum(wi.consumer_stock),0) FROM public.warehouse_inventory wi WHERE public._is_sentinel_wh_row_v3(wi.batch_id, wi.expiration_date)) = (SELECT (value->>''sent_consumer'')::numeric FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''before''))::text',
  'eq', 'true', true, 'P1')
ON CONFLICT (fixture_id, seq) DO UPDATE SET
  description = EXCLUDED.description, check_sql = EXCLUDED.check_sql,
  expect_op = EXCLUDED.expect_op, expect = EXCLUDED.expect,
  enabled = EXCLUDED.enabled, phase_required = EXCLUDED.phase_required;

-- guard: the P1.3 contract assertions must NOT have been weakened by this migration
DO $c$
DECLARE r record;
BEGIN
  FOR r IN SELECT seq, expect FROM golden.assertions WHERE fixture_id=24 AND seq IN (15,16,18) LOOP
    IF (r.seq = 15 AND r.expect <> '40')
    OR (r.seq = 16 AND r.expect <> '0')
    OR (r.seq = 18 AND r.expect <> '40') THEN
      RAISE EXCEPTION 'guard: seq % was weakened (expect=%) - seq 15/16/18 are the P1.3 contract', r.seq, r.expect;
    END IF;
  END LOOP;
END
$c$;
