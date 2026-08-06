-- PRD-110 DR-3 — FIXTURE 67, authored BEFORE the guard it proves (LAW 1).
-- ⛔ It is EXPECTED to run RED on its first fire: the dial column, the guard trigger and the
--    report view do not exist yet, so the scenario raises and `scenario_error` is non-null.
--    Per S-254 that means the whole assertion list is untrustworthy on that run — which is the
--    honest red baseline, and the reason both run ids get recorded in the log.
--
-- ⭐ THE DESIGN POINT (D-47 / S-173 doctrine): every level of the dial is EXECUTED, not
--    inspected. A guard proven only from its own source text is not a guard proven.

INSERT INTO golden.fixtures (fixture_id, name, source_incident, phase_required, plan_date, scenario_sql, notes, enabled, baseline_status)
VALUES (67,
 'DR-3 pod_inventory write-freeze: the two verbs nothing guarded are guarded, the dial is executed at every level (off/warn/block/frozen), the INSERT guard is byte-untouched, and the freeze report tells the truth about whether the replacement is carrying the load',
 'PRD-110 DR-3 (CS ruling 2026-08-04) + BUILD SPEC P1.4 line 68',
 'P1', DATE '2030-04-17',
$scn$
SELECT set_config('request.jwt.claims','{"sub":"82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d","role":"authenticated"}', false);
DELETE FROM golden.scratch WHERE fixture_id = {{fixture_id}};

-- ── STATIC HALF: live structure reads, nothing written ────────────────────────
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'static', jsonb_build_object(
  'auth_insert',   has_table_privilege('authenticated','public.pod_inventory','INSERT'),
  'auth_update',   has_table_privilege('authenticated','public.pod_inventory','UPDATE'),
  'auth_delete',   has_table_privilege('authenticated','public.pod_inventory','DELETE'),
  'auth_truncate', has_table_privilege('authenticated','public.pod_inventory','TRUNCATE'),
  'auth_select',   has_table_privilege('authenticated','public.pod_inventory','SELECT'),
  'anon_insert',   has_table_privilege('anon','public.pod_inventory','INSERT'),
  'anon_select',   has_table_privilege('anon','public.pod_inventory','SELECT'),
  'svc_update',    has_table_privilege('service_role','public.pod_inventory','UPDATE'),
  'rls_on',        (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pod_inventory'::regclass),
  'pod_rows',      (SELECT count(*) FROM public.pod_inventory),
  'writers_definer_postgres',
                   (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                     WHERE n.nspname = 'public' AND p.prosecdef
                       AND pg_get_userbyid(p.proowner) = 'postgres'
                       AND p.proname IN ('adjust_pod_inventory','approve_pod_inventory_edit',
                            'auto_decrement_pod_inventory','bulk_upsert_pod_inventory_from_log',
                            'create_field_add_edit','log_manual_refill','propose_pod_inventory_add',
                            'receive_dispatch_line','reconcile_pod_inventory_shelf',
                            'record_variant_correction','remove_pod_inventory_batch',
                            'resync_pod_inventory_from_weimi','sweep_expired_inventory',
                            'upsert_pod_snapshot')),
  'insert_guard_md5', (SELECT md5(prosrc) FROM pg_proc WHERE proname = 'block_direct_pod_inventory_insert'),
  'insert_guard_trg', (SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.pod_inventory'::regclass
                                                         AND tgname = 'trg_block_direct_pod_inventory_insert'),
  'guard_trg_def',    (SELECT pg_get_triggerdef(oid) FROM pg_trigger
                        WHERE tgrelid = 'public.pod_inventory'::regclass
                          AND tgname = 'trg_guard_pod_inventory_write'),
  'dial_live',        (SELECT pod_inventory_write_freeze FROM public.refill_policy_params LIMIT 1),
  'dial_check',       (SELECT pg_get_constraintdef(oid) FROM pg_constraint
                        WHERE conname = 'chk_pod_inventory_write_freeze'),
  'view_rows',        (SELECT count(*) FROM public.v_pod_inventory_daily_delta_v3),
  'view_max_writes',  (SELECT max(pod_inventory_writes) FROM public.v_pod_inventory_daily_delta_v3),
  'view_events_30d',  (SELECT COALESCE(sum(inventory_events_writes),0) FROM public.v_pod_inventory_daily_delta_v3),
  'view_notready_days',(SELECT count(*) FROM public.v_pod_inventory_daily_delta_v3
                         WHERE freeze_readiness = 'not_ready'),
  'view_dial_passthru',(SELECT DISTINCT freeze_dial FROM public.v_pod_inventory_daily_delta_v3 LIMIT 1)
);

-- ── EXECUTED HALF: every dial level actually driven, inside a rolled-back probe ──
DO $fx67$
DECLARE
  v_id             uuid;
  v_payload        jsonb;
  v_err_off        text := 'NOT_ATTEMPTED';
  v_err_warn       text := 'NOT_ATTEMPTED';
  v_err_block      text := 'NOT_ATTEMPTED';
  v_err_block_rpc  text := 'NOT_ATTEMPTED';
  v_err_block_del  text := 'NOT_ATTEMPTED';
  v_err_frozen_rpc text := 'NOT_ATTEMPTED';
BEGIN
  SELECT pod_inventory_id INTO v_id FROM public.pod_inventory ORDER BY pod_inventory_id LIMIT 1;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'fixture 67 setup: pod_inventory holds no row, so every guard probe below would pass vacuously';
  END IF;

  BEGIN
    -- ⛔ EVERYTHING INSIDE THIS BLOCK IS DISCARDED. The dial flips, the pod_inventory writes and
    --    the GUC changes all roll back when the RAISE at the end fires. Only v_payload escapes,
    --    smuggled out through the error message (the fixture-24 idiom).

    -- (1) 'off' — the shipped state. A non-RPC UPDATE must still succeed, or DR-3 shipped armed.
    UPDATE public.refill_policy_params SET pod_inventory_write_freeze = 'off';
    PERFORM set_config('app.via_rpc', '', true);
    BEGIN
      UPDATE public.pod_inventory SET current_stock = current_stock WHERE pod_inventory_id = v_id;
      v_err_off := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_err_off := SQLSTATE; END;

    -- (2) 'warn' — still succeeds; the WARNING is the whole difference from 'block'.
    UPDATE public.refill_policy_params SET pod_inventory_write_freeze = 'warn';
    PERFORM set_config('app.via_rpc', '', true);
    BEGIN
      UPDATE public.pod_inventory SET current_stock = current_stock WHERE pod_inventory_id = v_id;
      v_err_warn := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_err_warn := SQLSTATE; END;

    -- (3) 'block' without app.via_rpc — REFUSED. This is the gap DR-3 exists to close: today
    --     UPDATE on pod_inventory is guarded by nothing at all.
    UPDATE public.refill_policy_params SET pod_inventory_write_freeze = 'block';
    PERFORM set_config('app.via_rpc', '', true);
    BEGIN
      UPDATE public.pod_inventory SET current_stock = current_stock WHERE pod_inventory_id = v_id;
      v_err_block := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_err_block := SQLSTATE; END;

    -- (4) 'block' WITH app.via_rpc — the 14 canonical writers must still work, or DR-3 has
    --     broken production rather than guarded it.
    PERFORM set_config('app.via_rpc', 'true', true);
    BEGIN
      UPDATE public.pod_inventory SET current_stock = current_stock WHERE pod_inventory_id = v_id;
      v_err_block_rpc := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_err_block_rpc := SQLSTATE; END;

    -- (5) 'block', DELETE verb. UPDATE and DELETE were BOTH unguarded; proving one is not proving
    --     the other.
    PERFORM set_config('app.via_rpc', '', true);
    BEGIN
      DELETE FROM public.pod_inventory WHERE pod_inventory_id = v_id;
      v_err_block_del := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_err_block_del := SQLSTATE; END;

    -- (6) 'frozen' WITH app.via_rpc — refused anyway. ⭐ THIS IS THE ONLY THING THAT
    --     DISTINGUISHES 'frozen' FROM 'block', and it is what "read-only historical" means.
    UPDATE public.refill_policy_params SET pod_inventory_write_freeze = 'frozen';
    PERFORM set_config('app.via_rpc', 'true', true);
    BEGIN
      UPDATE public.pod_inventory SET current_stock = current_stock WHERE pod_inventory_id = v_id;
      v_err_frozen_rpc := 'NONE';
    EXCEPTION WHEN OTHERS THEN v_err_frozen_rpc := SQLSTATE; END;

    v_payload := jsonb_build_object(
      'err_off',        v_err_off,
      'err_warn',       v_err_warn,
      'err_block',      v_err_block,
      'err_block_rpc',  v_err_block_rpc,
      'err_block_del',  v_err_block_del,
      'err_frozen_rpc', v_err_frozen_rpc,
      'probe_row',      v_id::text,
      'dial_in_probe',  (SELECT pod_inventory_write_freeze FROM public.refill_policy_params LIMIT 1));
    RAISE EXCEPTION 'GP67:%', v_payload::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'GP67:%' THEN v_payload := substring(SQLERRM from 'GP67:(.*)$')::jsonb; ELSE RAISE; END IF;
  END;

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES ({{fixture_id}}, 'obs', v_payload);
END
$fx67$;

-- ── RESIDUE: the probe must have left nothing behind (S-197 GUC leak included) ──
INSERT INTO golden.scratch (fixture_id, key, value)
SELECT {{fixture_id}}, 'after', jsonb_build_object(
  'dial_after',     (SELECT pod_inventory_write_freeze FROM public.refill_policy_params LIMIT 1),
  'pod_rows_after', (SELECT count(*) FROM public.pod_inventory),
  'via_rpc_after',  COALESCE(NULLIF(current_setting('app.via_rpc', true), ''), 'UNSET')
);
$scn$,
 'DR-3. Ships with the dial at ''off''. seq 20-25 are the executed-behaviour core; seq 30-32 are the residue proof. ⛔ Do not soften seq 22/25 into not_null — the SQLSTATE is the claim.',
 true, 'failing_expected');
-- PRD-110 DR-3 — fixture 67 assertions.
-- Grouping: 1-10 the REVOKE · 11-18 the STRUCTURE · 20-25 the EXECUTED dial (the core) ·
--           26-29 the REPORT · 30-33 the RESIDUE.

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ── THE REVOKE (Article 3) ───────────────────────────────────────────────────
(67, 1, 'DR-3 acceptance: `authenticated` cannot INSERT into pod_inventory. Before DR-3 it held INSERT/UPDATE/DELETE/TRUNCATE on a protected entity — a standing Article 3 violation.',
 'SELECT (value->>''auth_insert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 2, 'DR-3 acceptance: `authenticated` cannot UPDATE pod_inventory.',
 'SELECT (value->>''auth_update'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 3, 'DR-3 acceptance: `authenticated` cannot DELETE from pod_inventory.',
 'SELECT (value->>''auth_delete'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 4, 'DR-3 acceptance: `authenticated` cannot TRUNCATE pod_inventory.',
 'SELECT (value->>''auth_truncate'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 5, '⛔ THE READ PATH SURVIVES: `authenticated` still holds SELECT. All five FE call sites (products page, field page x2, field/pod-inventory, AddProductDialog) are .select() only — this assertion is what stops a future over-revoke from silently blanking the field PWA.',
 'SELECT (value->>''auth_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 6, 'DR-3: `anon` holds no INSERT (it never did; the REVOKE is defensive and this pins it).',
 'SELECT (value->>''anon_insert'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'false', true, 'P1'),
(67, 7, 'DR-3: `anon` retains SELECT — the revoke targeted write verbs only.',
 'SELECT (value->>''anon_select'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 8, '⭐ DELIBERATE, AND ASSERTED SO IT STAYS DELIBERATE: `service_role` KEEPS its write privileges. It is the n8n / break-glass path, this build cannot read the n8n flows to prove none of them writes, and revoking a privilege whose consumers are unverifiable is how a nightly job dies silently at 02:00. The write-guard covers service_role instead. A future silent revoke fails here and has to be argued for.',
 'SELECT (value->>''svc_update'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 9, 'Article 2: RLS stays enabled on pod_inventory. DR-3 neither disables nor weakens it.',
 'SELECT (value->>''rls_on'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'true', true, 'P1'),
(67, 10, 'NON-VACUITY: pod_inventory holds rows, so the executed probes at seq 20-25 act on something real rather than on an empty table.',
 'SELECT (value->>''pod_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gt', '0', true, 'P1'),

-- ── THE STRUCTURE ────────────────────────────────────────────────────────────
(67, 11, '⛔ NON-VACUITY FOR THE WHOLE REVOKE: all 14 pod_inventory writer functions are SECURITY DEFINER owned by postgres. That is the ONLY reason revoking from `authenticated` does not break production — a definer runs as its owner and never consults the caller''s table grant. If this ever reads < 14, a writer has been converted to INVOKER and the revoke has silently become an outage.',
 'SELECT (value->>''writers_definer_postgres'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '14', true, 'P1'),
(67, 12, 'The pre-existing INSERT guard trg_block_direct_pod_inventory_insert still exists. DR-3 adds to it, never replaces it.',
 'SELECT (value->>''insert_guard_trg'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '1', true, 'P1'),
(67, 13, '⛔ THE INSERT GUARD IS BYTE-UNTOUCHED. Folding INSERT into DR-3''s dial would have made it BYPASSABLE at ''off'' — a downgrade dressed as a unification. This md5 is what forbids that refactor.',
 'SELECT (value->>''insert_guard_md5'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'a9274436e61d0316d35010fa738c2b97', true, 'P1'),
(67, 14, 'The new guard covers the two verbs nothing guarded before: BEFORE UPDATE OR DELETE.',
 'SELECT (value->>''guard_trg_def'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'BEFORE UPDATE OR DELETE', true, 'P1'),
(67, 15, 'The new guard is FOR EACH ROW — a statement-level trigger would miss which rows were touched and could not gate per-write.',
 'SELECT (value->>''guard_trg_def'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'FOR EACH ROW', true, 'P1'),
(67, 16, 'The new trigger is bound to guard_pod_inventory_write, not to some other function that happens to exist.',
 'SELECT (value->>''guard_trg_def'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', 'guard_pod_inventory_write', true, 'P1'),
(67, 17, '⛔ LAW 4: DR-3 SHIPS FLAG-OFF. The dial reads ''off'' in production. ⛔ Do NOT re-baseline this to arm the guard — arming it is a CS decision that needs the seq 26-29 report to have run for two weeks first (BUILD SPEC P1.4 line 68).',
 'SELECT (value->>''dial_live'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'off', true, 'P1'),
(67, 18, 'The CHECK constrains the dial to exactly the four defined levels. This is what stops a ''blocked'' typo from silently disarming the guard (the DR-4 seq-6 lesson).',
 'SELECT (value->>''dial_check'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'contains', '''off''::text, ''warn''::text, ''block''::text, ''frozen''::text', true, 'P1'),

-- ── THE EXECUTED DIAL — the core (D-47 / S-173: a guard passed by inspection is not passed) ──
(67, 20, '⭐ EXECUTED at ''off'': a non-RPC UPDATE still SUCCEEDS. If this ever reads a SQLSTATE, DR-3 shipped ARMED and every direct pod_inventory write in production is being refused.',
 'SELECT (value->>''err_off'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'NONE', true, 'P1'),
(67, 21, '⭐ EXECUTED at ''warn'': a non-RPC UPDATE still SUCCEEDS. The WARNING is the entire difference from ''block'', which is what makes ''warn'' a safe burn-in step.',
 'SELECT (value->>''err_warn'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'NONE', true, 'P1'),
(67, 22, '⭐⭐ EXECUTED at ''block'': a non-RPC UPDATE is REFUSED with 42501 (insufficient_privilege). ⛔ THIS IS THE GAP DR-3 EXISTS TO CLOSE — before this migration, UPDATE on pod_inventory was guarded by NOTHING, while INSERT had been guarded since PRD-012. ⛔ Do not soften to not_null: the SQLSTATE is the claim, and a 23503 here would mean the guard did not fire and an FK caught the write instead.',
 'SELECT (value->>''err_block'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '42501', true, 'P1'),
(67, 23, '⭐⭐ EXECUTED at ''block'' WITH app.via_rpc=''true'': the UPDATE SUCCEEDS. This is the assertion that proves DR-3 GUARDED production rather than BROKE it — the 14 canonical writers all set this GUC.',
 'SELECT (value->>''err_block_rpc'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'NONE', true, 'P1'),
(67, 24, '⭐ EXECUTED at ''block'', DELETE verb: REFUSED with 42501. UPDATE and DELETE were BOTH unguarded, and proving one is not proving the other.',
 'SELECT (value->>''err_block_del'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '42501', true, 'P1'),
(67, 25, '⭐⭐ EXECUTED at ''frozen'' WITH app.via_rpc=''true'': REFUSED anyway with 42501. ⛔ THIS IS THE ONLY THING THAT DISTINGUISHES ''frozen'' FROM ''block'', and it is precisely what "pod_inventory becomes read-only historical" means in BUILD SPEC P1.4. If this ever reads NONE, ''frozen'' has silently degraded into a second ''block'' and the freeze does not exist.',
 'SELECT (value->>''err_frozen_rpc'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', '42501', true, 'P1'),

-- ── THE REPORT ───────────────────────────────────────────────────────────────
(67, 26, 'The daily-delta report covers a 30-day rolling window with no gaps (days with no writes appear as zero rows, never as absent rows — an absent day reads as "quiet" when it may mean "the report broke").',
 'SELECT (value->>''view_rows'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', '30', true, 'P1'),
(67, 27, 'NON-VACUITY: the report actually sees pod_inventory writes. A report that reads zero everywhere would make the freeze look safe for the worst possible reason.',
 'SELECT (value->>''view_max_writes'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gt', '0', true, 'P1'),
(67, 28, '⭐ THE HONEST HEADLINE: at least one day reads freeze_readiness=''not_ready''. inventory_events holds ~65 rows against ~150-215 pod_inventory writes PER DAY — the replacement is NOT yet carrying the load, and the report is built to keep saying so. ⚠️ When this legitimately goes to 0, that is the signal the freeze is worth discussing, not a fixture failure — re-baseline it THEN, with the readiness evidence, never before.',
 'SELECT (value->>''view_notready_days'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'gt', '0', true, 'P1'),
(67, 29, 'The report surfaces the live dial, so a reader of the board can never mistake which enforcement level produced the numbers.',
 'SELECT (value->>''view_dial_passthru'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''', 'eq', 'off', true, 'P1'),

-- ── THE RESIDUE ──────────────────────────────────────────────────────────────
(67, 30, 'RESIDUE: the dial is back at ''off'' after the probe. The probe drove it through warn/block/frozen; if any of that survived, this fixture would have armed a production guard as a side effect.',
 'SELECT (value->>''dial_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', 'off', true, 'P1'),
(67, 31, 'RESIDUE: pod_inventory row count is unchanged. The probe issued a real DELETE at seq 24 — this proves it was discarded rather than committed.',
 'SELECT (((SELECT value->>''pod_rows_after'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after'') = (SELECT value->>''pod_rows'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''static''))::text)', 'eq', 'true', true, 'P1'),
(67, 32, 'RESIDUE (S-197): app.via_rpc does not leak out of the probe. A leaked ''true'' would silently disarm the guard for every later statement in the session — the exact GUC-leak class S-197 records.',
 'SELECT (value->>''via_rpc_after'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''after''', 'eq', 'UNSET', true, 'P1'),
(67, 33, 'NON-VACUITY FOR seq 25: the probe really did reach the ''frozen'' level. Without this, a probe that aborted early would leave err_frozen_rpc at its initial value and seq 25 could never distinguish "refused" from "never attempted".',
 'SELECT (value->>''dial_in_probe'') FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''', 'eq', 'frozen', true, 'P1');
