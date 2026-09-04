-- PRD-119 P2 / D0: retire the sales-cycle decrement of pod_inventory. D0 makes the
-- shelf record a dated lot ledger written only by human touch; sales never write it.
-- auto_decrement_pod_inventory matches a sale to pod_inventory by product name ACROSS
-- THE WHOLE MACHINE (no goods_slot/shelf predicate), FEFO order — last-30-day
-- evidence: 4,385 sale decrements, 5,016 units, 34 machines; 1,158 of 4,187 resolvable
-- events (28%) drained a row on a DIFFERENT lane than the sale actually came from; 697
-- events flipped a row Inactive. Called ~520x/day by edge function refresh-stage1 (via
-- run_pod_inventory_decrement()), not pg_cron — located this session via a read-only
-- sweep of pg_trigger/cron.job/edge functions.
--
-- Kill-switch: a new refill_qa.feature_flag row 'pod_sales_decrement_enabled',
-- default 'off', checked at the top of the function so the (external, ~520/day)
-- caller becomes a clean no-op — zero rows returned, sales_history.pod_inv_decremented
-- left untouched, nothing marked. Reuses the already-established refill_qa.flag()
-- mechanism (the same one engine_add_pod already reads for add_abs_floor_v1 etc.)
-- rather than inventing a parallel flag system. Function body is kept fully intact
-- below the guard for rollback — flip the flag back to 'on', nothing to reapply.
--
-- Verified live: with the flag off, auto_decrement_pod_inventory() returns 0 rows.
--
-- Cody: approve, Articles 1/4/12 — additive flag row (idempotent insert), md5-guarded
-- function patch, no data mutation, full rollback path preserved.
INSERT INTO refill_qa.feature_flag (flag, value) VALUES ('pod_sales_decrement_enabled', 'off')
ON CONFLICT (flag) DO NOTHING;

DO $mig$ DECLARE v_def text; v_new text; BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname='auto_decrement_pod_inventory' AND p.pronamespace='public'::regnamespace;
  IF md5(v_def) <> '0ec7a52af5c572d3a02e7880039890e5' THEN RAISE EXCEPTION 'auto_decrement_pod_inventory drifted (md5 %)', md5(v_def); END IF;
  v_new := replace(v_def,
    E'  PERFORM set_config(\'app.via_rpc\',  \'true\', true);\n  PERFORM set_config(\'app.rpc_name\', \'auto_decrement_pod_inventory\', true);\n\n  FOR sale IN',
    E'  PERFORM set_config(\'app.via_rpc\',  \'true\', true);\n  PERFORM set_config(\'app.rpc_name\', \'auto_decrement_pod_inventory\', true);\n\n  -- PRD-119 P2 kill-switch (default off): the sales-cycle decrement matches a sale to\n  -- pod_inventory by product name ACROSS THE WHOLE MACHINE (no goods_slot/shelf\n  -- predicate), FEFO order. Last-30-day evidence: 4,385 sale decrements, 5,016 units,\n  -- 34 machines - 1,158 of 4,187 resolvable events (28%) drained a row on a DIFFERENT\n  -- lane than the sale actually came from; 697 events flipped a row Inactive. Called\n  -- ~520x/day by edge function refresh-stage1 (via run_pod_inventory_decrement()), not\n  -- pg_cron. D0 retires this decrement entirely - live quantity on a lane is WEIMI, the\n  -- lot ledger is human-touch only. Function is kept intact below (rollback: flip the\n  -- flag back to \'\'on\'\', nothing to reapply).\n  IF COALESCE(refill_qa.flag(\'pod_sales_decrement_enabled\'), \'off\') <> \'on\' THEN\n    RETURN;\n  END IF;\n\n  FOR sale IN');
  IF v_new = v_def THEN RAISE EXCEPTION 'auto_decrement_pod_inventory: pattern not found'; END IF;
  EXECUTE v_new;
END $mig$;
