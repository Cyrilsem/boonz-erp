-- ============================================================================
-- BATCH 2 / M1 — rc05_write_context_and_honest_provenance.sql
-- RC-05: GUC write-context split-brain / inherited-provenance lie
--
-- Closes:
--   1. set_warehouse_inventory_provenance silently KEPT the previous row
--      provenance_reason/source_event_id on stock-changing UPDATEs when the
--      writer did not set app.provenance_reason. The AFTER audit trigger then
--      stamped that inherited lie into inventory_audit_log (why ~95% of manual
--      edits wear dispatch_receive/po_receive). Now such writes are stamped
--      with the sentinel 'unattributed_write' (+ source_event_id NULL) so gaps
--      are VISIBLE instead of camouflaged. Non-stock updates (status flips,
--      pin releases, quarantine metadata) keep the row's stock provenance.
--   2. One canonical helper public.set_write_context() sets all five write
--      GUCs txn-locally in one call, so no writer can half-set the context.
--   3. apply_inventory_correction (called by attempt_inventory_correction /
--      FE inline edits) now declares provenance 'manual_adjust' and carries
--      the inventory_control_attempt.attempt_id as source_event_id when
--      called through attempt_inventory_correction (threaded via GUC).
--      Direct calls carry source_event_id NULL (allowed for manual_adjust).
--   4. adjust_warehouse_stock no longer stamps the row's OWN wh_inventory_id
--      as app.source_event_id (self-pointer lineage). Its explicit, detailed
--      audit inserts are kept as the canonical log (they capture consumer
--      stock / status / location / expiry detail the generic trigger cannot),
--      now with provenance columns; the generic audit triggers SKIP rows
--      written by rpc_name='adjust_warehouse_stock' to end the double-log
--      (previously: 1 detailed row + 1 trigger row labelled
--      'authenticated_write_no_reason_set').
--   5. Every remaining stock-changing writer that did not set
--      app.provenance_reason is fixed here so nothing legitimately stamps
--      'unattributed_write' in normal flows:
--        - apply_inventory_correction        -> manual_adjust (+attempt id)
--        - approve_pod_inventory_edit        -> m2m_return  (+edit id)
--            (also fixes a LATENT BUG: its return_to_warehouse INSERT branch
--             wrote provenance_reason='pod_return_via_edit_<id>' which
--             VIOLATES the validated wh_provenance_reason_enum CHECK — that
--             branch could never have succeeded)
--        - drain_phantom_consumer_stock(+batch_run) -> manual_adjust
--        - reactivate_warehouse_row          -> manual_adjust
--        - receive_purchase_order_addition   -> po_receive (+addition id)
--        - reject_return                     -> manual_adjust
--      Status-only writers (auto_expire_old_warehouse_stock,
--      inactivate_warehouse_row, sweep_inactivate_stale_zero_stock,
--      propose_* triggers, release_stale_wh_pins, release_wh_quarantine,
--      reject_warehouse_status_proposal) do NOT change stock columns and are
--      untouched — the sentinel only fires on stock-changing updates.
--   6. wh_provenance_reason_enum extended with 'unattributed_write' (sentinel)
--      and 'refill_event' (consumed by M2 record_actual_refill).
--      wh_provenance_event_required exempts 'unattributed_write' (its whole
--      point is that no event is known); 'refill_event' REQUIRES an event id.
--
-- Explicitly NOT done here (parked, per validate-flow-before-tightening):
--   - enforce_provenance_on_warehouse_inventory_insert stays Phase-1
--     RAISE WARNING. The Phase-2 RAISE EXCEPTION cutover remains PARKED.
--   - The '' (empty-string) app.source_event_id "inherit row's old event"
--     semantics on reason-set updates is preserved byte-for-byte because
--     approve_return depends on it (dispatch_return + inherited event
--     satisfies wh_provenance_event_required). Named follow-up RC-05b.
--
-- All edits to existing bodies are marked with  -- [RC-05 EDIT]  and are
-- otherwise byte-faithful to the live bodies captured 2026-07-18 (verbatim
-- pre-images + md5s in rollback/).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Constraints: allow the sentinel + the M2 refill_event provenance
--    (both constraints were validated; all existing values remain legal)
-- ----------------------------------------------------------------------------
ALTER TABLE public.warehouse_inventory DROP CONSTRAINT wh_provenance_reason_enum;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT wh_provenance_reason_enum
  CHECK (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY[
    'po_receive'::text, 'dispatch_return'::text, 'dispatch_pack'::text,
    'dispatch_receive'::text, 'm2m_return'::text, 'wh_transfer'::text,
    'manual_adjust'::text, 'snapshot'::text, 'status_flip'::text,
    'unknown_pre_migration'::text, 'dispatch_return_unverified'::text,
    'dispatch_partial_remainder'::text, 'expiry_writeoff'::text,
    'unattributed_write'::text,   -- [RC-05 EDIT] sentinel for GUC-less stock writes
    'refill_event'::text          -- [RC-05 EDIT] M2 record_actual_refill lineage
  ]))));

ALTER TABLE public.warehouse_inventory DROP CONSTRAINT wh_provenance_event_required;
ALTER TABLE public.warehouse_inventory ADD CONSTRAINT wh_provenance_event_required
  CHECK (((provenance_reason IS NULL) OR (provenance_reason = ANY (ARRAY[
    'manual_adjust'::text, 'snapshot'::text, 'status_flip'::text,
    'unknown_pre_migration'::text,
    'unattributed_write'::text    -- [RC-05 EDIT] sentinel carries no event by definition
  ])) OR (source_event_id IS NOT NULL)));

-- ----------------------------------------------------------------------------
-- 2. NEW: public.set_write_context — the one way to declare write context.
--    Always sets ALL five GUCs (txn-local) so successive RPC calls inside one
--    transaction can never leak a stale reason/provenance/event into each
--    other's trigger-visible context.
--    Semantics preserved from existing writers:
--      provenance ''  = unset  -> BEFORE trigger applies sentinel on stock change
--      source_event '' = unset -> BEFORE trigger leaves row's old event alone
--                                 (approve_return depends on this inherit)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_write_context(
  p_rpc          text,
  p_reason       text DEFAULT NULL,
  p_provenance   text DEFAULT NULL,
  p_source_event text DEFAULT NULL
) RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF p_rpc IS NULL OR p_rpc = '' THEN
    RAISE EXCEPTION 'set_write_context: p_rpc is required';
  END IF;
  PERFORM set_config('app.via_rpc',           'true',                       true);
  PERFORM set_config('app.rpc_name',          p_rpc,                        true);
  PERFORM set_config('app.mutation_reason',   COALESCE(p_reason, ''),       true);
  PERFORM set_config('app.provenance_reason', COALESCE(p_provenance, ''),   true);
  PERFORM set_config('app.source_event_id',   COALESCE(p_source_event, ''), true);
END $function$;

COMMENT ON FUNCTION public.set_write_context(text, text, text, text) IS
  'RC-05 canonical write-context helper. Sets app.via_rpc/app.rpc_name/app.mutation_reason/app.provenance_reason/app.source_event_id transaction-locally in one call. NULL reason/provenance/source_event clear to '''' (= unset for the provenance triggers).';

-- ----------------------------------------------------------------------------
-- 3. set_warehouse_inventory_provenance: stop inheriting the previous
--    provenance on unattributed stock-changing UPDATEs — stamp the sentinel.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_warehouse_inventory_provenance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text := current_setting('app.provenance_reason', true);
  v_event  text := current_setting('app.source_event_id', true);
BEGIN
  IF v_reason IS NOT NULL AND v_reason <> '' THEN
    NEW.provenance_reason := v_reason;
  -- [RC-05 EDIT] no write-context provenance on a stock-changing UPDATE:
  -- previously the row KEPT its old provenance_reason/source_event_id and the
  -- AFTER audit trigger stamped that inherited lie into inventory_audit_log.
  -- Stamp an explicit sentinel instead so unattributed writes are visible.
  -- Guard on NEW/OLD equality so a writer that deliberately sets the column
  -- directly in its UPDATE statement is respected.
  ELSIF TG_OP = 'UPDATE'
        AND (OLD.warehouse_stock IS DISTINCT FROM NEW.warehouse_stock
             OR OLD.consumer_stock IS DISTINCT FROM NEW.consumer_stock)
        AND NEW.provenance_reason IS NOT DISTINCT FROM OLD.provenance_reason THEN
    NEW.provenance_reason := 'unattributed_write';
    NEW.source_event_id   := NULL;
    RETURN NEW;  -- [RC-05 EDIT] do not let a half-set event GUC re-stamp below
  END IF;
  IF v_event IS NOT NULL AND v_event <> '' THEN
    BEGIN
      NEW.source_event_id := v_event::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      NEW.source_event_id := NULL;
    END;
  END IF;
  RETURN NEW;
END $function$;

-- ----------------------------------------------------------------------------
-- 4. auto_audit_warehouse_inventory (UPDATE audit):
--    a) skip rows written by adjust_warehouse_stock (it writes its own richer
--       audit lines — ends the double-log)
--    b) NULLIF('') on app.mutation_reason so a cleared context falls back to
--       the honest 'authenticated_write_no_reason_set' label instead of ''
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_audit_warehouse_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text;
  v_uid uuid;
BEGIN
  IF OLD.warehouse_stock IS DISTINCT FROM NEW.warehouse_stock
     OR OLD.consumer_stock IS DISTINCT FROM NEW.consumer_stock THEN
    -- [RC-05 EDIT] adjust_warehouse_stock writes its own detailed audit lines
    -- (warehouse_stock, consumer_stock, status, location, expiry deltas which
    -- this generic trigger cannot capture). Skip to end the double-log.
    IF current_setting('app.rpc_name', true) = 'adjust_warehouse_stock' THEN
      RETURN NEW;
    END IF;
    v_uid := (SELECT auth.uid());
    v_reason := COALESCE(
      NULLIF(current_setting('app.mutation_reason', true), ''),  -- [RC-05 EDIT] NULLIF('')
      CASE WHEN v_uid IS NULL THEN 'service_role_write_unattributed' ELSE 'authenticated_write_no_reason_set' END
    );
    INSERT INTO inventory_audit_log
      (wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
    VALUES
      (NEW.wh_inventory_id, NEW.boonz_product_id, v_uid, OLD.warehouse_stock, NEW.warehouse_stock, v_reason, now(), NEW.provenance_reason, NEW.source_event_id);
  END IF;
  RETURN NEW;
END $function$;

-- ----------------------------------------------------------------------------
-- 5. auto_audit_warehouse_inventory_insert (INSERT audit): same two fixes —
--    adjust_warehouse_stock's '[new_row]' explicit insert double-logged here.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_audit_warehouse_inventory_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text;
  v_uid uuid;
BEGIN
  IF COALESCE(NEW.warehouse_stock, 0) > 0 OR COALESCE(NEW.consumer_stock, 0) > 0 THEN
    -- [RC-05 EDIT] adjust_warehouse_stock writes its own '[new_row]' audit line
    IF current_setting('app.rpc_name', true) = 'adjust_warehouse_stock' THEN
      RETURN NEW;
    END IF;
    v_uid := (SELECT auth.uid());
    v_reason := COALESCE(
      NULLIF(current_setting('app.mutation_reason', true), ''),  -- [RC-05 EDIT] NULLIF('')
      CASE WHEN v_uid IS NULL THEN 'service_role_insert_unattributed'
           ELSE 'authenticated_insert_no_reason_set' END
    );
    INSERT INTO inventory_audit_log
      (wh_inventory_id, boonz_product_id, adjusted_by,
       old_qty, new_qty, reason, audited_at,
       provenance_reason, source_event_id)
    VALUES
      (NEW.wh_inventory_id, NEW.boonz_product_id, v_uid,
       0,
       COALESCE(NEW.warehouse_stock, 0) + COALESCE(NEW.consumer_stock, 0),
       v_reason, now(),
       NEW.provenance_reason, NEW.source_event_id);
  END IF;
  RETURN NEW;
END;
$function$;

-- ----------------------------------------------------------------------------
-- 6. apply_inventory_correction: full write context + honest provenance.
--    Logic otherwise byte-identical to the Batch-1 live body.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_inventory_correction(p_wh_inventory_id uuid DEFAULT NULL::uuid, p_boonz_product_id uuid DEFAULT NULL::uuid, p_warehouse_id uuid DEFAULT NULL::uuid, p_expiration_date date DEFAULT NULL::date, p_new_warehouse_stock numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text, p_corrected_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_row warehouse_inventory%ROWTYPE;
  v_inserted boolean := false;
BEGIN
  IF p_new_warehouse_stock IS NULL OR p_new_warehouse_stock < 0 THEN
    RAISE EXCEPTION 'p_new_warehouse_stock must be >= 0';
  END IF;
  IF COALESCE(p_reason, '') = '' THEN
    RAISE EXCEPTION 'p_reason is required for inventory corrections';
  END IF;

  -- [RC-05 EDIT] was: 3x set_config (via_rpc/rpc_name/mutation_reason) with NO
  -- provenance -> rows+audit inherited stale dispatch_receive/po_receive.
  -- Now: full context with provenance 'manual_adjust'. source_event passes
  -- through app.source_event_id when an upstream wrapper set it —
  -- attempt_inventory_correction threads its attempt_id this way, so inline
  -- FE edits land as (manual_adjust, <inventory_control_attempt.attempt_id>).
  -- Direct calls carry NULL (legal for manual_adjust).
  PERFORM public.set_write_context(
    'apply_inventory_correction',
    format('inventory correction by %s: %s',
           COALESCE(p_corrected_by::text, 'cs'), p_reason),
    'manual_adjust',
    NULLIF(current_setting('app.source_event_id', true), ''));

  -- Path A: row id provided → direct update
  IF p_wh_inventory_id IS NOT NULL THEN
    SELECT * INTO v_row FROM warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'wh_inventory_id % not found', p_wh_inventory_id; END IF;
    UPDATE warehouse_inventory
    SET warehouse_stock = p_new_warehouse_stock,
        -- If row was Inactive AND now has stock, re-activate
        status = CASE
          WHEN p_new_warehouse_stock > 0 AND status IN ('Inactive') THEN 'Active'
          WHEN p_new_warehouse_stock = 0 AND status = 'Active' THEN status -- leave Active, manager will inactivate separately
          ELSE status END,
        -- If we're setting an expiry on a row that didn't have one, allow it
        expiration_date = COALESCE(expiration_date, p_expiration_date)
    WHERE wh_inventory_id = p_wh_inventory_id;

  -- Path B: identify by (product, warehouse, expiry)
  ELSIF p_boonz_product_id IS NOT NULL AND p_warehouse_id IS NOT NULL THEN
    IF p_expiration_date IS NULL THEN
      RAISE EXCEPTION 'p_expiration_date required when correcting by (product, warehouse). Never create NULL-expiry rows.';
    END IF;
    SELECT * INTO v_row FROM warehouse_inventory
    WHERE boonz_product_id = p_boonz_product_id
      AND warehouse_id = p_warehouse_id
      AND expiration_date = p_expiration_date
    ORDER BY (status = 'Active') DESC, created_at DESC
    LIMIT 1 FOR UPDATE;

    IF FOUND THEN
      UPDATE warehouse_inventory
      SET warehouse_stock = p_new_warehouse_stock,
          status = CASE
            WHEN p_new_warehouse_stock > 0 AND status IN ('Inactive') THEN 'Active'
            ELSE status END
      WHERE wh_inventory_id = v_row.wh_inventory_id;
    ELSE
      INSERT INTO warehouse_inventory
        (boonz_product_id, warehouse_id, warehouse_stock, expiration_date, status,
         batch_id, snapshot_date)
      VALUES
        (p_boonz_product_id, p_warehouse_id, p_new_warehouse_stock, p_expiration_date, 'Active',
         format('CORRECTION-%s', CURRENT_DATE), CURRENT_DATE)
      RETURNING wh_inventory_id INTO v_row.wh_inventory_id;
      v_inserted := true;
    END IF;
  ELSE
    RAISE EXCEPTION 'Provide either p_wh_inventory_id OR (p_boonz_product_id + p_warehouse_id + p_expiration_date)';
  END IF;

  RETURN jsonb_build_object(
    'status', 'corrected',
    'wh_inventory_id', v_row.wh_inventory_id,
    'inserted', v_inserted,
    'new_warehouse_stock', p_new_warehouse_stock,
    'reason', p_reason
  );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 7. attempt_inventory_correction: thread the attempt_id through the GUC so
--    apply_inventory_correction stamps it as source_event_id.
--    (v_attempt_id is generated before the nested call; the matching
--    inventory_control_attempt row is inserted later in the SAME transaction;
--    warehouse_inventory.source_event_id has no FK, so ordering is safe.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.attempt_inventory_correction(p_session_id uuid, p_wh_inventory_id uuid, p_new_warehouse_stock numeric, p_reason text, p_client_correlation_id uuid, p_attempted_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id        uuid;
  v_caller_role    text;
  v_session_status text;
  v_old_row        public.warehouse_inventory%ROWTYPE;
  v_rpc_response   jsonb;
  v_attempt_id     uuid := gen_random_uuid();
  v_terminal       text;
  v_error_message  text;
BEGIN
  v_user_id := COALESCE(p_attempted_by, auth.uid());
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'attempt_inventory_correction: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;
  SELECT status INTO v_session_status FROM public.inventory_control_session WHERE session_id = p_session_id;
  IF v_session_status IS NULL THEN
    RAISE EXCEPTION 'attempt_inventory_correction: session % not found', p_session_id;
  END IF;
  IF v_session_status <> 'open' THEN
    RAISE EXCEPTION 'attempt_inventory_correction: session % is %, not open', p_session_id, v_session_status;
  END IF;
  SELECT * INTO v_old_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'attempt_inventory_correction', true);
  -- [RC-05 EDIT] thread the attempt id so apply_inventory_correction stamps it
  -- as source_event_id on the row + audit line (honest lineage for inline edits)
  PERFORM set_config('app.source_event_id', v_attempt_id::text, true);
  BEGIN
    v_rpc_response := public.apply_inventory_correction(
      p_wh_inventory_id      => p_wh_inventory_id,
      p_boonz_product_id     => NULL,
      p_warehouse_id         => NULL,
      p_expiration_date      => NULL,
      p_new_warehouse_stock  => p_new_warehouse_stock,
      p_reason               => p_reason,
      p_corrected_by         => v_user_id
    );
    v_terminal := 'success';
  EXCEPTION
    WHEN insufficient_privilege THEN v_terminal := 'blocked_rls';      v_error_message := SQLERRM;
    WHEN check_violation       THEN v_terminal := 'blocked_trigger';   v_error_message := SQLERRM;
    WHEN raise_exception       THEN v_terminal := 'validation_error';  v_error_message := SQLERRM;
    WHEN OTHERS                THEN v_terminal := 'rpc_error';         v_error_message := SQLERRM;
  END;
  INSERT INTO public.inventory_control_attempt (
    attempt_id, session_id, attempted_by,
    target_path, wh_inventory_id,
    field_changed, old_value, new_value,
    rpc_called, rpc_response, result, error_message,
    client_correlation_id, reason
  ) VALUES (
    v_attempt_id, p_session_id, v_user_id,
    'by_id', p_wh_inventory_id,
    'warehouse_stock',
    CASE WHEN v_old_row.wh_inventory_id IS NOT NULL
      THEN jsonb_build_object('warehouse_stock', v_old_row.warehouse_stock, 'status', v_old_row.status)
      ELSE NULL END,
    jsonb_build_object('warehouse_stock', p_new_warehouse_stock),
    'apply_inventory_correction',
    v_rpc_response,
    v_terminal,
    v_error_message,
    p_client_correlation_id,
    p_reason
  );
  RETURN jsonb_build_object(
    'attempt_id',   v_attempt_id,
    'result',       v_terminal,
    'rpc_response', v_rpc_response,
    'error',        v_error_message
  );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 8. adjust_warehouse_stock:
--    a) no more self-pointer source_event_id (row's own PK is not an event)
--    b) explicit detailed audit inserts become the single canonical log
--       (generic triggers now skip this rpc) and carry provenance columns
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adjust_warehouse_stock(p_warehouse_id uuid, p_lines jsonb, p_snapshot_date date DEFAULT CURRENT_DATE, p_reason text DEFAULT 'physical_count_reconciliation'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role text; v_caller_id uuid;
  v_line jsonb; v_boonz_id uuid; v_new_wh numeric; v_new_cs numeric;
  v_exp_date date; v_batch text; v_status_val text; v_wh_inv_id uuid;
  v_new_loc text; v_loc_provided boolean;
  v_old_wh numeric; v_old_cs numeric; v_old_exp date;
  v_old_loc text; v_old_status text;
  v_found boolean;
  v_updated int := 0; v_inserted int := 0; v_unchanged int := 0;
  v_details jsonb := '[]'::jsonb; v_wh_name text;
BEGIN
  -- [RC-05 EDIT] was: 3x set_config incl. provenance; mutation_reason was NOT
  -- set (trigger rows read 'authenticated_write_no_reason_set'). Now one call.
  PERFORM public.set_write_context('adjust_warehouse_stock', p_reason, 'manual_adjust', NULL);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  v_caller_id := auth.uid();
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'adjust_warehouse_stock: forbidden for role %', COALESCE(v_caller_role,'anon');
  END IF;

  SELECT name INTO v_wh_name FROM warehouses WHERE warehouse_id = p_warehouse_id;
  IF v_wh_name IS NULL THEN
    RAISE EXCEPTION 'adjust_warehouse_stock: warehouse % not found', p_warehouse_id;
  END IF;

  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'adjust_warehouse_stock: p_lines must be a non-empty array';
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_boonz_id   := (v_line->>'boonz_product_id')::uuid;
    v_new_wh     := COALESCE((v_line->>'new_warehouse_stock')::numeric, 0);
    v_new_cs     := COALESCE((v_line->>'new_consumer_stock')::numeric, 0);
    v_exp_date   := (v_line->>'expiration_date')::date;
    v_batch      := v_line->>'batch_id';
    v_status_val := COALESCE(v_line->>'status', 'Active');
    v_wh_inv_id  := (v_line->>'wh_inventory_id')::uuid;
    v_loc_provided := (v_line ? 'wh_location');
    v_new_loc    := v_line->>'wh_location';

    v_found := false;

    IF v_wh_inv_id IS NOT NULL THEN
      SELECT warehouse_stock, consumer_stock, expiration_date, wh_location, status
        INTO v_old_wh, v_old_cs, v_old_exp, v_old_loc, v_old_status
        FROM warehouse_inventory
        WHERE wh_inventory_id = v_wh_inv_id AND warehouse_id = p_warehouse_id;
      IF FOUND THEN v_found := true; END IF;
    ELSE
      SELECT wh_inventory_id, warehouse_stock, consumer_stock, expiration_date, wh_location, status
        INTO v_wh_inv_id, v_old_wh, v_old_cs, v_old_exp, v_old_loc, v_old_status
        FROM warehouse_inventory
        WHERE warehouse_id = p_warehouse_id
          AND boonz_product_id = v_boonz_id
          AND expiration_date IS NOT DISTINCT FROM v_exp_date
        ORDER BY created_at ASC
        LIMIT 1;
      IF FOUND THEN v_found := true; END IF;
    END IF;

    IF v_found THEN
      IF v_old_wh = v_new_wh
         AND COALESCE(v_old_cs,0) = v_new_cs
         AND (v_exp_date IS NULL OR v_old_exp IS NOT DISTINCT FROM v_exp_date)
         AND (NOT v_loc_provided OR v_old_loc IS NOT DISTINCT FROM v_new_loc)
         AND v_old_status IS NOT DISTINCT FROM v_status_val THEN
        v_unchanged := v_unchanged + 1;
        v_details := v_details || jsonb_build_object(
          'boonz_product_id', v_boonz_id,
          'wh_inventory_id',  v_wh_inv_id,
          'action',           'unchanged'
        );
        CONTINUE;
      END IF;

      -- [RC-05 EDIT] removed: set_config('app.source_event_id', v_wh_inv_id)
      -- (self-pointer lineage — the row's own PK stamped as its "source event")

      UPDATE warehouse_inventory
         SET warehouse_stock = v_new_wh,
             consumer_stock  = v_new_cs,
             snapshot_date   = p_snapshot_date,
             expiration_date = COALESCE(v_exp_date, expiration_date),
             batch_id        = COALESCE(v_batch, batch_id),
             status          = v_status_val,
             wh_location     = CASE WHEN v_loc_provided THEN v_new_loc ELSE wh_location END
       WHERE wh_inventory_id = v_wh_inv_id;

      IF v_old_wh IS DISTINCT FROM v_new_wh THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_old_wh, v_new_wh, p_reason||' [warehouse_stock]', now(), 'manual_adjust', NULL);
      END IF;
      IF COALESCE(v_old_cs,0) IS DISTINCT FROM v_new_cs THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, COALESCE(v_old_cs,0), v_new_cs, p_reason||' [consumer_stock]', now(), 'manual_adjust', NULL);
      END IF;
      IF v_loc_provided AND v_old_loc IS DISTINCT FROM v_new_loc THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_new_wh, v_new_wh,
                p_reason||' [wh_location: '||COALESCE(v_old_loc,'(null)')||' -> '||COALESCE(v_new_loc,'(null)')||']', now(), 'manual_adjust', NULL);
      END IF;
      IF v_old_status IS DISTINCT FROM v_status_val THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_new_wh, v_new_wh,
                p_reason||' [status: '||COALESCE(v_old_status,'(null)')||' -> '||COALESCE(v_status_val,'(null)')||']', now(), 'manual_adjust', NULL);
      END IF;
      IF v_exp_date IS NOT NULL AND v_old_exp IS DISTINCT FROM v_exp_date THEN
        INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
        VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, v_new_wh, v_new_wh,
                p_reason||' [expiration_date: '||COALESCE(v_old_exp::text,'(null)')||' -> '||COALESCE(v_exp_date::text,'(null)')||']', now(), 'manual_adjust', NULL);
      END IF;

      v_updated := v_updated + 1;
      v_details := v_details || jsonb_build_object(
        'boonz_product_id', v_boonz_id,
        'wh_inventory_id',  v_wh_inv_id,
        'action',           'updated',
        'old_wh',           v_old_wh,
        'new_wh',           v_new_wh
      );
    ELSE
      v_wh_inv_id := gen_random_uuid();
      -- [RC-05 EDIT] removed: set_config('app.source_event_id', v_wh_inv_id)

      INSERT INTO warehouse_inventory (
        wh_inventory_id, boonz_product_id, snapshot_date, warehouse_stock,
        consumer_stock, expiration_date, batch_id, status, warehouse_id,
        wh_location, created_at
      )
      VALUES (
        v_wh_inv_id, v_boonz_id, p_snapshot_date, v_new_wh,
        v_new_cs, v_exp_date, v_batch, v_status_val, p_warehouse_id,
        CASE WHEN v_loc_provided THEN v_new_loc ELSE NULL END, now()
      );

      INSERT INTO inventory_audit_log (audit_id, wh_inventory_id, boonz_product_id, adjusted_by, old_qty, new_qty, reason, audited_at, provenance_reason, source_event_id)
      VALUES (gen_random_uuid(), v_wh_inv_id, v_boonz_id, v_caller_id, 0, v_new_wh, p_reason||' [new_row]', now(), 'manual_adjust', NULL);

      v_inserted := v_inserted + 1;
      v_details := v_details || jsonb_build_object(
        'boonz_product_id', v_boonz_id,
        'wh_inventory_id',  v_wh_inv_id,
        'action',           'inserted',
        'warehouse_stock',  v_new_wh,
        'expiration_date',  v_exp_date
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'status',           'ok',
    'warehouse',        v_wh_name,
    'warehouse_id',     p_warehouse_id,
    'lines_processed',  v_updated + v_inserted + v_unchanged,
    'lines_updated',    v_updated,
    'lines_inserted',   v_inserted,
    'lines_unchanged',  v_unchanged,
    'reason',           p_reason,
    'details',          v_details
  );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 9. approve_pod_inventory_edit: the return_to_warehouse branch credits
--    warehouse_inventory with NO provenance GUC (update path would now stamp
--    the sentinel) and its INSERT branch wrote the enum-violating literal
--    'pod_return_via_edit_<id>' (latent hard failure). Both branches now
--    carry provenance 'm2m_return' + source_event_id = edit_id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_pod_inventory_edit(p_edit_id uuid, p_approver_id uuid DEFAULT NULL::uuid, p_decision_note text DEFAULT NULL::text, p_expiry_override_accepted boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id              uuid;
  v_caller_role          text;
  v_edit                 public.pod_inventory_edits%ROWTYPE;
  v_pod                  public.pod_inventory%ROWTYPE;
  v_shelf_code           text;
  v_new_pod_inventory_id uuid;
  v_batch_id             text;
  v_new_stock            numeric;
  v_new_est              numeric;
  v_pod_status_after     text;
  v_wh_dest              uuid;
  v_existing_wh_id       uuid;
  v_wh_inventory_id_credited uuid;
  v_conflict_product_id  uuid;
  v_conflict_product     text;
  v_open_session_id      uuid;
  v_supported_types      text[] := ARRAY['expired','sold','partial_sold','return_to_warehouse','add_new_product','add_stock'];
BEGIN
  v_user_id := COALESCE(p_approver_id, auth.uid());
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: no caller identity'; END IF;
  SELECT role INTO v_caller_role FROM public.user_profiles WHERE id = v_user_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;
  SELECT * INTO v_edit FROM public.pod_inventory_edits WHERE edit_id = p_edit_id FOR UPDATE;
  IF v_edit.edit_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: edit % not found', p_edit_id; END IF;
  IF v_edit.status <> 'pending' THEN RAISE EXCEPTION 'approve_pod_inventory_edit: edit % is %, not pending', p_edit_id, v_edit.status; END IF;
  IF NOT (v_edit.edit_type = ANY(v_supported_types)) THEN
    RAISE EXCEPTION 'approve_pod_inventory_edit: edit_type % not supported (supported: %)', v_edit.edit_type, v_supported_types;
  END IF;
  PERFORM set_config('app.via_rpc',         'true', true);
  PERFORM set_config('app.rpc_name',        'approve_pod_inventory_edit', true);
  PERFORM set_config('app.mutation_reason', format('pod_edit_approval edit_id=%s type=%s by=%s', p_edit_id, v_edit.edit_type, v_user_id), true);
  IF v_edit.edit_type NOT IN ('add_new_product','add_stock') THEN
    IF v_edit.pod_inventory_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: edit % type=% has no pod_inventory_id', p_edit_id, v_edit.edit_type; END IF;
    SELECT * INTO v_pod FROM public.pod_inventory WHERE pod_inventory_id = v_edit.pod_inventory_id FOR UPDATE;
    IF v_pod.pod_inventory_id IS NULL THEN RAISE EXCEPTION 'approve_pod_inventory_edit: pod_inventory % not found', v_edit.pod_inventory_id; END IF;
  END IF;
  IF v_edit.edit_type = 'expired' THEN
    UPDATE public.pod_inventory SET current_stock=0, estimated_remaining=0, status='Inactive',
           removal_reason=format('expired_validated_via_edit_%s', p_edit_id), last_decremented_at=now()
     WHERE pod_inventory_id=v_pod.pod_inventory_id;
    v_pod_status_after := 'Inactive';
  ELSIF v_edit.edit_type = 'sold' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN RAISE EXCEPTION 'approve_pod_inventory_edit: sold edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update; END IF;
    v_new_stock := GREATEST(0, COALESCE(v_pod.current_stock, 0) - v_edit.quantity_update);
    v_new_est   := GREATEST(0, COALESCE(v_pod.estimated_remaining, 0) - v_edit.quantity_update);
    IF v_new_stock <= 0 AND v_new_est <= 0 THEN
      UPDATE public.pod_inventory SET current_stock=0, estimated_remaining=0, status='Inactive',
             removal_reason=format('sold_drained_via_edit_%s', p_edit_id), last_decremented_at=now()
       WHERE pod_inventory_id=v_pod.pod_inventory_id;
      v_pod_status_after := 'Inactive';
    ELSE
      UPDATE public.pod_inventory SET current_stock=v_new_stock, estimated_remaining=v_new_est, last_decremented_at=now()
       WHERE pod_inventory_id=v_pod.pod_inventory_id;
      v_pod_status_after := v_pod.status;
    END IF;
  ELSIF v_edit.edit_type = 'partial_sold' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN RAISE EXCEPTION 'approve_pod_inventory_edit: partial_sold edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update; END IF;
    UPDATE public.pod_inventory SET current_stock=GREATEST(0, COALESCE(current_stock,0) - v_edit.quantity_update),
           estimated_remaining=GREATEST(0, COALESCE(estimated_remaining,0) - v_edit.quantity_update), last_decremented_at=now()
     WHERE pod_inventory_id=v_pod.pod_inventory_id;
    v_pod_status_after := v_pod.status;
  ELSIF v_edit.edit_type = 'return_to_warehouse' THEN
    IF v_edit.quantity_update IS NULL OR v_edit.quantity_update <= 0 THEN RAISE EXCEPTION 'approve_pod_inventory_edit: return_to_warehouse edit % has invalid quantity_update %', p_edit_id, v_edit.quantity_update; END IF;
    SELECT primary_warehouse_id INTO v_wh_dest FROM public.machines WHERE machine_id=v_edit.machine_id;
    IF v_wh_dest IS NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: machine % has no primary_warehouse_id configured; ops must set it before approving return_to_warehouse', v_edit.machine_id;
    END IF;
    -- [RC-05 EDIT] declare provenance for the WH credit: stock returning from
    -- a machine to the warehouse, evidenced by this approved edit.
    PERFORM set_config('app.provenance_reason', 'm2m_return', true);
    PERFORM set_config('app.source_event_id',   p_edit_id::text, true);
    SELECT wh_inventory_id INTO v_existing_wh_id FROM public.warehouse_inventory
     WHERE warehouse_id=v_wh_dest AND boonz_product_id=v_pod.boonz_product_id
       AND COALESCE(expiration_date, DATE '1970-01-01') = COALESCE(v_pod.expiration_date, DATE '1970-01-01')
     LIMIT 1;
    IF v_existing_wh_id IS NOT NULL THEN
      UPDATE public.warehouse_inventory SET warehouse_stock=COALESCE(warehouse_stock,0) + v_edit.quantity_update
       WHERE wh_inventory_id=v_existing_wh_id;
      v_wh_inventory_id_credited := v_existing_wh_id;
    ELSE
      -- [RC-05 EDIT] removed explicit provenance_reason column: the literal
      -- format('pod_return_via_edit_%s', ...) violates wh_provenance_reason_enum
      -- (validated CHECK) — the BEFORE trigger now stamps m2m_return + edit id.
      INSERT INTO public.warehouse_inventory (warehouse_id, boonz_product_id, snapshot_date, warehouse_stock, expiration_date, batch_id, status)
      VALUES (v_wh_dest, v_pod.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_pod.expiration_date, format('POD_RETURN-%s', p_edit_id), 'Inactive')
      RETURNING wh_inventory_id INTO v_wh_inventory_id_credited;
    END IF;
    UPDATE public.pod_inventory SET current_stock=0, estimated_remaining=0, status='Inactive',
           removal_reason=format('returned_to_warehouse_via_edit_%s', p_edit_id), last_decremented_at=now()
     WHERE pod_inventory_id=v_pod.pod_inventory_id;
    v_pod_status_after := 'Inactive';
  ELSIF v_edit.edit_type = 'add_new_product' THEN
    SELECT pi.boonz_product_id, bp.boonz_product_name INTO v_conflict_product_id, v_conflict_product
      FROM public.pod_inventory pi JOIN public.boonz_products bp ON bp.product_id=pi.boonz_product_id
      WHERE pi.shelf_id=v_edit.destination_shelf_id AND pi.status='Active' LIMIT 1;
    IF v_conflict_product_id IS NOT NULL THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: shelf now in use by %. Reject or escalate.', v_conflict_product;
    END IF;
    IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: expiry % is now in the past; set p_expiry_override_accepted=true to approve anyway', v_edit.requested_expiration_date;
    END IF;
    SELECT shelf_code INTO v_shelf_code FROM public.shelf_configurations WHERE shelf_id=v_edit.destination_shelf_id;
    v_batch_id := format('POD_ADD-%s', p_edit_id);
    BEGIN
      INSERT INTO public.pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, expiration_date, batch_id, status, snapshot_at)
      VALUES (v_edit.machine_id, v_edit.destination_shelf_id, v_edit.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_edit.requested_expiration_date, v_batch_id, 'Active', now())
      RETURNING pod_inventory_id INTO v_new_pod_inventory_id;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: shelf raced into use by another Active row between re-validation and INSERT';
    END;
    v_pod_status_after := 'Active';
  ELSIF v_edit.edit_type = 'add_stock' THEN
    IF v_edit.requested_expiration_date <= CURRENT_DATE AND NOT p_expiry_override_accepted THEN
      RAISE EXCEPTION 'approve_pod_inventory_edit: expiry % is in the past; pass p_expiry_override_accepted=true', v_edit.requested_expiration_date;
    END IF;
    SELECT * INTO v_pod FROM public.pod_inventory
     WHERE machine_id=v_edit.machine_id
       AND shelf_id=v_edit.destination_shelf_id
       AND boonz_product_id=v_edit.boonz_product_id
       AND status='Active'
     FOR UPDATE;
    IF v_pod.pod_inventory_id IS NOT NULL THEN
      UPDATE public.pod_inventory
         SET current_stock       = COALESCE(current_stock,0)       + v_edit.quantity_update,
             estimated_remaining = COALESCE(estimated_remaining,0) + v_edit.quantity_update,
             expiration_date     = LEAST(expiration_date, v_edit.requested_expiration_date),
             snapshot_at         = now()
       WHERE pod_inventory_id = v_pod.pod_inventory_id;
      v_new_pod_inventory_id := v_pod.pod_inventory_id;
    ELSE
      v_batch_id := format('POD_ADD-%s', p_edit_id);
      INSERT INTO public.pod_inventory (machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock, estimated_remaining, expiration_date, batch_id, status, snapshot_at)
      VALUES (v_edit.machine_id, v_edit.destination_shelf_id, v_edit.boonz_product_id, CURRENT_DATE, v_edit.quantity_update, v_edit.quantity_update, v_edit.requested_expiration_date, v_batch_id, 'Active', now())
      RETURNING pod_inventory_id INTO v_new_pod_inventory_id;
    END IF;
    v_pod_status_after := 'Active';
  END IF;
  UPDATE public.pod_inventory_edits
  SET status='approved', reviewed_by=v_user_id, reviewed_at=now(),
      pod_inventory_id=COALESCE(pod_inventory_id, v_new_pod_inventory_id),
      notes=CASE WHEN p_decision_note IS NULL OR length(trim(p_decision_note))=0 THEN notes
                 ELSE COALESCE(notes||E'\n[approval] ','[approval] ') || trim(p_decision_note) END
  WHERE edit_id=p_edit_id;
  SELECT session_id INTO v_open_session_id FROM public.inventory_control_session WHERE started_by=v_user_id AND status='open' LIMIT 1;
  IF v_open_session_id IS NOT NULL THEN
    INSERT INTO public.inventory_control_attempt (session_id, attempted_by, target_path, pod_inventory_id, edit_id, boonz_product_id,
      field_changed, old_value, new_value, rpc_called, rpc_response, result, client_correlation_id, reason)
    VALUES (v_open_session_id, v_user_id, 'pod_by_id', COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id), p_edit_id,
      COALESCE(v_pod.boonz_product_id, v_edit.boonz_product_id), 'pod_add_approved',
      CASE WHEN v_edit.edit_type IN ('add_new_product','add_stock') THEN NULL
           ELSE jsonb_build_object('status', v_pod.status, 'current_stock', v_pod.current_stock, 'estimated_remaining', v_pod.estimated_remaining) END,
      jsonb_build_object('status', v_pod_status_after, 'edit_type', v_edit.edit_type),
      'approve_pod_inventory_edit',
      jsonb_build_object('edit_id', p_edit_id, 'edit_type', v_edit.edit_type,
        'pod_inventory_id', COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id),
        'wh_inventory_id_credited', v_wh_inventory_id_credited),
      'success', gen_random_uuid(),
      COALESCE(NULLIF(trim(COALESCE(p_decision_note,'')), ''), 'pod_edit_approval'));
  END IF;
  RETURN jsonb_build_object(
    'result','success','edit_id',p_edit_id,'edit_type',v_edit.edit_type,
    'pod_inventory_id',COALESCE(v_edit.pod_inventory_id, v_new_pod_inventory_id),
    'pod_status_after',v_pod_status_after,'wh_inventory_id_credited',v_wh_inventory_id_credited,
    'session_id',v_open_session_id,'batch_id',v_batch_id);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 10. drain_phantom_consumer_stock: consumer-stock correction — manual_adjust
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.drain_phantom_consumer_stock(p_wh_inventory_id uuid, p_units numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_row public.warehouse_inventory%ROWTYPE;
  v_new_consumer numeric;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'drain_phantom_consumer_stock: no caller identity'; END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role NOT IN ('operator_admin','superadmin') THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: role % cannot drain', v_role;
  END IF;
  IF p_units IS NULL OR p_units <= 0 THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: p_units must be positive (got %)', p_units;
  END IF;
  IF length(trim(coalesce(p_reason,''))) < 10 THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: p_reason min 10 chars';
  END IF;

  -- [RC-05 EDIT] was: 3x set_config with NO provenance -> stock-changing
  -- update would inherit stale provenance (now: sentinel). Declare it.
  PERFORM public.set_write_context(
    'drain_phantom_consumer_stock',
    format('drain phantom %s units wh=%s by=%s reason=%s', p_units, p_wh_inventory_id, v_uid, p_reason),
    'manual_adjust', NULL);

  SELECT * INTO v_row FROM public.warehouse_inventory
   WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF v_row.wh_inventory_id IS NULL THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: wh % not found', p_wh_inventory_id;
  END IF;
  IF coalesce(v_row.consumer_stock, 0) < p_units THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock: consumer_stock=% < p_units=% on wh %',
      v_row.consumer_stock, p_units, p_wh_inventory_id;
  END IF;

  v_new_consumer := coalesce(v_row.consumer_stock,0) - p_units;

  UPDATE public.warehouse_inventory
     SET consumer_stock = v_new_consumer
   WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'result','success',
    'wh_inventory_id', p_wh_inventory_id,
    'previous_consumer_stock', v_row.consumer_stock,
    'new_consumer_stock', v_new_consumer,
    'units_drained', p_units,
    'drained_by', v_uid,
    'drained_at', now()
  );
END $function$;

-- ----------------------------------------------------------------------------
-- 11. drain_phantom_consumer_stock_batch_run: same fix inside the loop
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.drain_phantom_consumer_stock_batch_run(p_caller_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  r record;
  v_drained_rows int := 0;
  v_drained_units numeric := 0;
  v_failed int := 0;
BEGIN
  IF p_caller_id IS NULL THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock_batch_run: p_caller_id required';
  END IF;
  SELECT role INTO v_role FROM public.user_profiles WHERE id = p_caller_id;
  IF coalesce(v_role,'') NOT IN ('operator_admin','superadmin') THEN
    RAISE EXCEPTION 'drain_phantom_consumer_stock_batch_run: role % cannot drain', coalesce(v_role,'unknown');
  END IF;

  FOR r IN
    SELECT wh_inventory_id, phantom_units, consumer_stock
    FROM public.v_consumer_stock_leaks
    WHERE phantom_units > 0
  LOOP
    BEGIN
      -- [RC-05 EDIT] was: 3x set_config with NO provenance. Declare it.
      PERFORM public.set_write_context(
        'drain_phantom_consumer_stock_batch_run',
        format('drain phantom %s units wh=%s by=%s reason=%s',
          r.phantom_units, r.wh_inventory_id, p_caller_id,
          'bug006_phantom_drain_2026-05-30_audit-finding-F3'),
        'manual_adjust', NULL);

      UPDATE public.warehouse_inventory
         SET consumer_stock = greatest(coalesce(consumer_stock,0) - r.phantom_units, 0)
       WHERE wh_inventory_id = r.wh_inventory_id
         AND coalesce(consumer_stock,0) >= r.phantom_units;

      IF FOUND THEN
        v_drained_rows := v_drained_rows + 1;
        v_drained_units := v_drained_units + r.phantom_units;
      ELSE
        v_failed := v_failed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'result','success',
    'rows_drained', v_drained_rows,
    'units_drained', v_drained_units,
    'failed', v_failed,
    'ran_at', now(),
    'ran_by', p_caller_id
  );
END $function$;

-- ----------------------------------------------------------------------------
-- 12. reactivate_warehouse_row: manual reactivation with a counted stock —
--     manual_adjust
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reactivate_warehouse_row(p_wh_inventory_id uuid, p_new_warehouse_stock numeric, p_reason text, p_source_doc text DEFAULT NULL::text, p_reactivated_by uuid DEFAULT NULL::uuid, p_new_expiration_date date DEFAULT NULL::date, p_new_wh_location text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_row warehouse_inventory%ROWTYPE;
BEGIN
  IF p_new_warehouse_stock IS NULL OR p_new_warehouse_stock <= 0 THEN
    RAISE EXCEPTION 'p_new_warehouse_stock must be > 0 (use apply_inventory_correction for 0-stock writes)';
  END IF;
  IF COALESCE(p_reason, '') = '' THEN
    RAISE EXCEPTION 'p_reason is required (e.g. "WEIMI miscount confirmed by manual count", "supplier delivered replacement batch", "auto-inactivation was premature")';
  END IF;

  -- [RC-05 EDIT] was: 3x set_config with NO provenance. Declare it.
  PERFORM public.set_write_context(
    'reactivate_warehouse_row',
    format('reactivate_warehouse_row by %s: %s%s',
      COALESCE(p_reactivated_by::text, 'system'),
      p_reason,
      CASE WHEN p_source_doc IS NOT NULL THEN ' [src: ' || p_source_doc || ']' ELSE '' END),
    'manual_adjust', NULL);

  SELECT * INTO v_row FROM warehouse_inventory
  WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'wh_inventory_id % not found', p_wh_inventory_id;
  END IF;

  -- Refuse to reactivate a row whose product is on an active decommission intent
  IF EXISTS (
    SELECT 1 FROM strategic_intents si
    WHERE si.intent_type = 'decommission'
      AND si.status IN ('queued','in_progress')
      AND si.scope_boonz_product_id = v_row.boonz_product_id
      AND (si.scope_machine_ids IS NULL OR true)
  ) THEN
    RAISE EXCEPTION
      'Cannot reactivate %: product is on an active decommission intent. Close the intent first or use apply_inventory_correction with explicit override.',
      v_row.boonz_product_id;
  END IF;

  UPDATE warehouse_inventory
  SET warehouse_stock = p_new_warehouse_stock,
      status = 'Active',
      expiration_date = COALESCE(p_new_expiration_date, expiration_date),
      wh_location = COALESCE(p_new_wh_location, wh_location)
  WHERE wh_inventory_id = p_wh_inventory_id;

  RETURN jsonb_build_object(
    'status', 'reactivated',
    'wh_inventory_id', p_wh_inventory_id,
    'old_stock', v_row.warehouse_stock,
    'new_stock', p_new_warehouse_stock,
    'reason', p_reason,
    'source_doc', p_source_doc
  );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 13. receive_purchase_order_addition: PO-receive path (n8n/FE) inserted new
--     stock rows with NO provenance (rows landed as the column default and
--     tripped the Phase-1 insert warning). Now: po_receive + addition id.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_purchase_order_addition(p_addition_id uuid, p_warehouse_id uuid, p_expiry date DEFAULT NULL::date, p_batch_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role text;
  v_addition    po_additions%ROWTYPE;
  v_today       date := (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Dubai')::date;
  v_wh_id       uuid;
BEGIN
  -- [RC-05 EDIT] was: 2x set_config (via_rpc/rpc_name) with NO provenance.
  PERFORM public.set_write_context(
    'receive_purchase_order_addition',
    format('receive PO addition %s into warehouse %s', p_addition_id, p_warehouse_id),
    'po_receive',
    p_addition_id::text);

  SELECT role INTO v_caller_role FROM user_profiles WHERE id = auth.uid();
  IF v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RETURN jsonb_build_object('status','error','error','Insufficient role');
  END IF;

  IF p_addition_id IS NULL OR p_warehouse_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','p_addition_id and p_warehouse_id are required');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM warehouses WHERE warehouse_id = p_warehouse_id) THEN
    RETURN jsonb_build_object('status','error','error','Unknown warehouse_id');
  END IF;

  SELECT * INTO v_addition FROM po_additions WHERE addition_id = p_addition_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','error','error','PO addition not found');
  END IF;

  IF v_addition.status = 'received' THEN
    RETURN jsonb_build_object('status','already_received',
      'message','PO addition already received — no duplicate created');
  END IF;

  INSERT INTO warehouse_inventory (
    boonz_product_id, warehouse_stock, status, snapshot_date,
    expiration_date, warehouse_id, batch_id
  ) VALUES (
    v_addition.boonz_product_id, v_addition.qty, 'Active', v_today,
    COALESCE(p_expiry, v_addition.expiry_date),
    p_warehouse_id,
    COALESCE(p_batch_id, format('PO-ADDITION-%s', substring(p_addition_id::text, 1, 8)))
  );

  UPDATE po_additions
  SET status      = 'received',
      received_at = now(),
      received_by = auth.uid()
  WHERE addition_id = p_addition_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'addition_id', p_addition_id,
    'warehouse_id', p_warehouse_id,
    'qty', v_addition.qty,
    'expiry', COALESCE(p_expiry, v_addition.expiry_date)
  );
END;
$function$;

-- ----------------------------------------------------------------------------
-- 14. reject_return: write-off of a rejected return zeroes warehouse_stock —
--     manual_adjust (manager decision; enum has no writeoff value that is
--     exempt from source_event_id, and there is no event object here)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_return(p_wh_inventory_id uuid, p_approver_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_role text; v_uid uuid; v_before jsonb; v_after jsonb; v_row warehouse_inventory%ROWTYPE; v_inact jsonb; v_status_now text;
BEGIN
  v_uid := COALESCE(p_approver_id, auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'reject_return: forbidden for role % (inventory-manager only)', COALESCE(v_role,'unknown'); END IF;
  IF COALESCE(p_reason,'') = '' OR length(trim(p_reason)) < 4 THEN RAISE EXCEPTION 'reject_return: p_reason required (min 4 chars)'; END IF;
  SELECT * INTO v_row FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'reject_return: wh_inventory_id % not found', p_wh_inventory_id; END IF;
  v_before := to_jsonb(v_row);
  -- [RC-05 EDIT] was: 3x set_config with NO provenance. Declare it.
  PERFORM public.set_write_context(
    'reject_return',
    format('reject_return by %s: %s', v_uid, p_reason),
    'manual_adjust', NULL);
  UPDATE public.warehouse_inventory SET warehouse_stock = 0, disposal_reason = 'Waste' WHERE wh_inventory_id = p_wh_inventory_id;
  SELECT status INTO v_status_now FROM public.warehouse_inventory WHERE wh_inventory_id = p_wh_inventory_id;
  IF v_status_now = 'Active' THEN
    v_inact := public.inactivate_warehouse_row(p_wh_inventory_id, 'reject_return: '||p_reason, v_uid);
  ELSE
    v_inact := jsonb_build_object('status','already_'||lower(v_status_now)||'_skipped_inactivate');
  END IF;
  SELECT to_jsonb(w.*) INTO v_after FROM public.warehouse_inventory w WHERE wh_inventory_id = p_wh_inventory_id;
  INSERT INTO public.return_approval_log(wh_inventory_id, action, approver_id, approver_role, note, before_row, after_row)
  VALUES (p_wh_inventory_id, 'reject', v_uid, v_role, p_reason, v_before, v_after);
  RETURN jsonb_build_object('status','rejected','wh_inventory_id',p_wh_inventory_id,'written_off',true,'inactivate',v_inact);
END $function$;

COMMIT;
