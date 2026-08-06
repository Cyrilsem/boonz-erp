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
