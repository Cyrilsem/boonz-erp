-- ============================================================================
-- BATCH 2 / M2 — rc02_record_actual_refill_fix.sql
-- RC-02 backend: record_actual_refill (PRD-100 keystone) arithmetic, row
-- targeting, clamp-swallowing and jwt-forgery fixes.
--
-- DEPENDS ON: M1 (rc05_write_context_and_honest_provenance.sql) — uses
-- public.set_write_context and the 'refill_event' provenance value added to
-- wh_provenance_reason_enum there. Apply M1 first.
--
-- Closes (against the live body captured 2026-07-18, verbatim in
-- rollback/13_record_actual_refill.sql):
--   a) SET-MODE ARITHMETIC: the old body debited the warehouse by the
--      ABSOLUTE shelf level in set mode (v_whnew := wh_cur - v_qty where
--      v_qty was the full new shelf count), not the delta actually loaded.
--      Now the WH debit = GREATEST(new_shelf_qty - current_shelf_qty, 0),
--      i.e. the pod delta actually applied, in both set and delta modes.
--   b) NO SILENT CLAMPS: the old GREATEST(...,0) clamps swallowed
--      discrepancies. Every clamp/shortfall is now recorded in the new
--      refill_event_lines.discrepancy jsonb column AND raises a
--      monitoring_alerts row (source 'rc02_record_actual_refill_discrepancy'):
--        - pod_remove_exceeds_stock : removal larger than shelf stock
--        - set_below_current        : "refill" set-mode count BELOW current
--                                     shelf stock (pod decreases, no WH debit)
--        - wh_shortfall             : warehouse rows cannot explain the debit
--                                     (debits what physically exists, records
--                                     the unexplained remainder)
--   c) ROW TARGETING: the old body read the NEWEST Active WH row but nested
--      adjust_warehouse_stock then wrote the OLDEST row of ANY status and
--      force-flipped it Active (exposed 19 duplicate Active triples).
--      Now the function debits the SPECIFIC pickable rows it selects via the
--      Batch-1 canonical wh_fefo_for_line (machine-scoped, reservation- and
--      quarantine-aware, expiry >= plan_date), preferring rows whose
--      expiration_date matches the driver-declared line expiry, then FEFO.
--      Credits (wh_receive/wh_return) go to the newest ACTIVE matching row or
--      create a fresh Active row. Inactive rows are NEVER flipped as a side
--      effect. Each row-level move is recorded in refill_event_lines.wh_moves.
--   d) PROVENANCE: WH writes carry provenance 'refill_event' with
--      source_event_id = refill_events.event_id (M1 enum + event-required).
--   e) SECURITY (RC-11 partial): the old body FORGED request.jwt.claims from
--      caller-supplied p_actor to satisfy nested adjust_warehouse_stock role
--      gating. The nested call is gone (direct writes inside this SECURITY
--      DEFINER body), so the forgery is REMOVED. Actor of record is now
--      COALESCE(auth.uid(), p_actor): an authenticated caller can no longer
--      attribute to someone else, and must hold an inventory-manager role
--      (previously an authenticated caller with p_actor NULL bypassed gating
--      entirely). NULL-auth service calls (MCP/n8n) with p_actor as
--      attribution metadata still work: p_actor, when given, must reference
--      an inventory-manager profile. Full caller authentication for the
--      NULL-auth service path remains RC-11 scope (Batch 3).
--   f) Atomicity preserved: header insert survives; all pod + WH + line
--      writes ride one subtransaction; failure marks the event 'failed'.
--      p_dry_run defaults TRUE; dry-run now also previews discrepancies.
--
-- Additive DDL: refill_event_lines.discrepancy jsonb, refill_event_lines.wh_moves jsonb.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. Cody condition (FE unblock): extend refill_events_source_check with the
--    honest 'field_capture' label for the FE capture surface. Verified live
--    pre-state: CHECK (source = ANY (ARRAY['driver_app','cs','venue_team',
--    'reconcile'])). Strict superset -> re-validation cannot fail.
-- ----------------------------------------------------------------------------
ALTER TABLE public.refill_events
  DROP CONSTRAINT IF EXISTS refill_events_source_check;
ALTER TABLE public.refill_events
  ADD CONSTRAINT refill_events_source_check
  CHECK (source = ANY (ARRAY['driver_app'::text, 'cs'::text, 'venue_team'::text,
                             'reconcile'::text, 'field_capture'::text]));

-- ----------------------------------------------------------------------------
-- 1. Additive columns on refill_event_lines
-- ----------------------------------------------------------------------------
ALTER TABLE public.refill_event_lines
  ADD COLUMN IF NOT EXISTS discrepancy jsonb,
  ADD COLUMN IF NOT EXISTS wh_moves    jsonb;

COMMENT ON COLUMN public.refill_event_lines.discrepancy IS
  'RC-02: explicit record of clamps/shortfalls that the old code swallowed (pod_remove_exceeds_stock / set_below_current / wh_shortfall). NULL = clean line.';
COMMENT ON COLUMN public.refill_event_lines.wh_moves IS
  'RC-02: row-level warehouse_inventory movements applied for this line: [{wh_inventory_id, delta, expiration_date, batch_id}]. NULL = no WH effect.';

-- ----------------------------------------------------------------------------
-- 2. record_actual_refill v2
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_actual_refill(p_machine_name text, p_plan_date date, p_lines jsonb, p_source text DEFAULT 'cs'::text, p_actor uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_machine_id uuid;
  v_event_id   uuid;
  v_actor      uuid;
  v_line       jsonb;
  v_action     text;
  v_bpid       uuid;
  v_shelf_code text;
  v_shelf_id   uuid;
  v_qty        numeric;
  v_setmode    text;
  v_exp        date;
  v_wh         uuid;
  v_partner    text;
  v_partner_id uuid;
  v_notes      text;
  v_cur        numeric;
  v_newqty     numeric;
  v_pod_delta  numeric;
  v_pod_res    jsonb;
  v_pod_id     uuid;
  v_rpo_action text;
  v_applied    int := 0;
  v_lineno     int := 0;
  -- warehouse-effect working state
  v_debit_needed numeric;
  v_remaining    numeric;
  v_take         numeric;
  v_avail        numeric;
  v_pick         record;
  v_lock_id      uuid;
  v_lock_stock   numeric;
  v_credit_id    uuid;
  v_wh_moves     jsonb;
  v_discrepancy  jsonb;
  v_line_details jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.set_write_context('record_actual_refill',
    COALESCE(p_reason,'record_actual_refill'), NULL, NULL);

  -- resolve + validate machine
  SELECT machine_id INTO v_machine_id FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN RAISE EXCEPTION 'record_actual_refill: machine % not found', p_machine_name; END IF;
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'p_lines empty'; END IF;

  -- [RC-02/RC-11 EDIT] actor of record = auth.uid() when present (cannot be
  -- spoofed); p_actor is fallback attribution for NULL-auth service calls.
  -- Any non-NULL actor must hold an inventory-manager role. If both are set
  -- and disagree, the authenticated identity wins and p_actor is ignored.
  -- request.jwt.claims is NO LONGER forged (nested gated RPC call removed).
  v_actor := COALESCE(auth.uid(), p_actor);
  IF v_actor IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE id = v_actor
                   AND role = ANY (ARRAY['warehouse','operator_admin','superadmin','manager'])) THEN
      RAISE EXCEPTION 'record_actual_refill: actor % is not an inventory manager', v_actor;
    END IF;
  END IF;

  -- header (persists even if apply fails, so a failure is recorded)
  INSERT INTO refill_events (machine_id, plan_date, source, captured_by, status, reason)
  VALUES (v_machine_id, p_plan_date, p_source, v_actor,
          CASE WHEN p_dry_run THEN 'dry_run' ELSE 'pending' END, p_reason)
  RETURNING event_id INTO v_event_id;

  BEGIN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      v_lineno   := v_lineno + 1;
      v_action   := v_line->>'action';
      v_bpid     := (v_line->>'boonz_product_id')::uuid;
      v_shelf_code := v_line->>'shelf_code';
      v_qty      := (v_line->>'qty')::numeric;
      v_setmode  := COALESCE(v_line->>'set_mode','delta');
      v_exp      := NULLIF(v_line->>'expiration_date','')::date;
      v_wh       := NULLIF(v_line->>'warehouse_id','')::uuid;
      v_partner  := v_line->>'partner_machine';
      v_notes    := v_line->>'notes';
      v_shelf_id := NULL; v_pod_id := NULL; v_partner_id := NULL;
      v_cur := NULL; v_newqty := NULL; v_pod_delta := NULL;
      v_debit_needed := NULL; v_wh_moves := NULL; v_discrepancy := NULL;

      IF v_action IS NULL OR v_action NOT IN
         ('refill','remove','write_off','transfer_out','transfer_in','wh_return','wh_receive') THEN
        RAISE EXCEPTION 'line %: bad action %', v_lineno, v_action; END IF;
      IF v_bpid IS NULL THEN RAISE EXCEPTION 'line %: boonz_product_id required', v_lineno; END IF;
      IF NOT EXISTS (SELECT 1 FROM boonz_products WHERE product_id = v_bpid) THEN
        RAISE EXCEPTION 'line %: product % not found', v_lineno, v_bpid; END IF;
      IF v_partner IS NOT NULL THEN
        SELECT machine_id INTO v_partner_id FROM machines WHERE official_name = v_partner; END IF;

      -- resolve shelf for pod-affecting actions
      IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
        IF v_shelf_code IS NULL THEN RAISE EXCEPTION 'line %: shelf_code required for %', v_lineno, v_action; END IF;
        SELECT shelf_id INTO v_shelf_id FROM shelf_configurations
          WHERE machine_id = v_machine_id AND shelf_code = v_shelf_code;
        IF v_shelf_id IS NULL THEN RAISE EXCEPTION 'line %: shelf % not on machine', v_lineno, v_shelf_code; END IF;
      END IF;

      -- ------------------------------------------------------------------
      -- POD arithmetic (computed in BOTH modes so dry_run previews deltas)
      -- [RC-02 EDIT] current shelf stock is now read in set mode too — the
      -- pod delta (new - current) is what the warehouse must explain.
      -- ------------------------------------------------------------------
      IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
        SELECT current_stock INTO v_cur FROM pod_inventory
          WHERE machine_id = v_machine_id AND shelf_id = v_shelf_id AND boonz_product_id = v_bpid
            AND status='Active' AND (expiration_date = v_exp OR (expiration_date IS NULL AND v_exp IS NULL))
          LIMIT 1;
        IF v_setmode = 'set' THEN
          v_newqty := v_qty;
        ELSIF v_action IN ('remove','write_off','transfer_out') THEN
          v_newqty := GREATEST(COALESCE(v_cur,0) - v_qty, 0);
          -- [RC-02 EDIT] clamp no longer silent
          IF COALESCE(v_cur,0) < v_qty THEN
            v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
              'pod_remove_exceeds_stock', jsonb_build_object(
                'requested', v_qty, 'shelf_stock_before', COALESCE(v_cur,0)));
          END IF;
        ELSE
          v_newqty := COALESCE(v_cur,0) + v_qty;
        END IF;
        v_pod_delta := v_newqty - COALESCE(v_cur,0);
        -- [RC-02 EDIT] a set-mode "refill" whose count is BELOW current shelf
        -- stock means product left the shelf during a refill — flag it.
        IF v_action IN ('refill','transfer_in') AND v_setmode = 'set' AND v_pod_delta < 0 THEN
          v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
            'set_below_current', jsonb_build_object(
              'shelf_stock_before', COALESCE(v_cur,0), 'set_to', v_qty, 'pod_delta', v_pod_delta));
        END IF;
      END IF;

      -- ------------------------------------------------------------------
      -- WAREHOUSE debit planning (refill only; delta = pod units actually
      -- loaded, never the absolute shelf level)
      -- ------------------------------------------------------------------
      IF v_wh IS NOT NULL AND v_action = 'refill' THEN
        v_debit_needed := GREATEST(COALESCE(v_pod_delta,0), 0);
        IF p_dry_run AND v_debit_needed > 0 THEN
          -- preview physical availability via the canonical FEFO surface
          SELECT COALESCE(MAX(f.total_pickable), 0) INTO v_avail
            FROM public.wh_fefo_for_line(v_machine_id, v_bpid, p_plan_date, v_debit_needed, ARRAY[v_wh]) f;
          IF v_avail < v_debit_needed THEN
            v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
              'wh_shortfall', jsonb_build_object(
                'needed', v_debit_needed, 'pickable', v_avail,
                'short', v_debit_needed - v_avail, 'preview', true));
          END IF;
        END IF;
      END IF;

      IF NOT p_dry_run THEN
        -- POD effect (unchanged path: canonical pod RPC)
        IF v_action IN ('refill','remove','write_off','transfer_out','transfer_in') THEN
          SELECT public.adjust_pod_inventory(
            p_machine_name, p_plan_date,
            jsonb_build_array(jsonb_build_object(
              'boonz_product_id', v_bpid, 'new_qty', v_newqty,
              'expiration_date', v_exp, 'shelf_code', v_shelf_code,
              'batch_id', 'RECORD-'||to_char(p_plan_date,'YYYY-MM-DD'))),
            COALESCE(p_reason,'record_actual_refill')) INTO v_pod_res;
          v_pod_id := (v_pod_res->'details'->0->>'pod_inventory_id')::uuid;
        END IF;

        -- WAREHOUSE effect
        -- [RC-02 EDIT] direct, row-targeted writes with refill_event
        -- provenance replace the nested adjust_warehouse_stock call
        -- (which wrote the oldest row of ANY status and force-flipped it
        -- Active). Inactive rows are never touched.
        IF v_wh IS NOT NULL AND v_action = 'refill' AND v_debit_needed > 0 THEN
          PERFORM public.set_write_context('record_actual_refill',
            format('record_actual_refill event=%s line=%s refill %s x%s from wh %s',
                   v_event_id, v_lineno, v_shelf_code, v_qty, v_wh),
            'refill_event', v_event_id::text);
          v_remaining := v_debit_needed;
          v_wh_moves  := '[]'::jsonb;
          -- canonical machine-scoped FEFO picks, driver-declared expiry first
          FOR v_pick IN
            SELECT f.wh_inventory_id, f.expiration_date, f.batch_id
              FROM public.wh_fefo_for_line(v_machine_id, v_bpid, p_plan_date, v_debit_needed, ARRAY[v_wh]) f
             ORDER BY (f.expiration_date IS NOT DISTINCT FROM v_exp) DESC, f.pick_rank
          LOOP
            EXIT WHEN v_remaining <= 0;
            SELECT wh_inventory_id, warehouse_stock INTO v_lock_id, v_lock_stock
              FROM warehouse_inventory
             WHERE wh_inventory_id = v_pick.wh_inventory_id
               AND status = 'Active' AND warehouse_stock > 0
             FOR UPDATE;
            IF NOT FOUND THEN CONTINUE; END IF;
            v_take := LEAST(v_remaining, v_lock_stock);
            UPDATE warehouse_inventory
               SET warehouse_stock = warehouse_stock - v_take,
                   snapshot_date   = p_plan_date
             WHERE wh_inventory_id = v_lock_id;
            v_wh_moves := v_wh_moves || jsonb_build_object(
              'wh_inventory_id', v_lock_id, 'delta', -v_take,
              'expiration_date', v_pick.expiration_date, 'batch_id', v_pick.batch_id);
            v_remaining := v_remaining - v_take;
          END LOOP;
          IF v_remaining > 0 THEN
            -- [RC-02 EDIT] the warehouse cannot explain part of what was
            -- physically loaded: record it, do NOT silently clamp.
            v_discrepancy := COALESCE(v_discrepancy,'{}'::jsonb) || jsonb_build_object(
              'wh_shortfall', jsonb_build_object(
                'needed', v_debit_needed, 'debited', v_debit_needed - v_remaining,
                'short', v_remaining));
          END IF;
          IF jsonb_array_length(v_wh_moves) = 0 THEN v_wh_moves := NULL; END IF;

        ELSIF v_wh IS NOT NULL AND v_action IN ('wh_receive','wh_return') THEN
          PERFORM public.set_write_context('record_actual_refill',
            format('record_actual_refill event=%s line=%s %s x%s to wh %s',
                   v_event_id, v_lineno, v_action, v_qty, v_wh),
            'refill_event', v_event_id::text);
          SELECT wh_inventory_id INTO v_credit_id FROM warehouse_inventory
            WHERE boonz_product_id = v_bpid AND warehouse_id = v_wh AND status='Active'
              AND (expiration_date = v_exp OR (expiration_date IS NULL AND v_exp IS NULL))
            ORDER BY created_at DESC LIMIT 1
            FOR UPDATE;
          IF FOUND THEN
            UPDATE warehouse_inventory
               SET warehouse_stock = COALESCE(warehouse_stock,0) + v_qty,
                   snapshot_date   = p_plan_date
             WHERE wh_inventory_id = v_credit_id;
          ELSE
            INSERT INTO warehouse_inventory
              (boonz_product_id, warehouse_id, warehouse_stock, expiration_date, status,
               batch_id, snapshot_date)
            VALUES
              (v_bpid, v_wh, v_qty, v_exp, 'Active',
               format('REFILL-EVENT-%s', to_char(p_plan_date,'YYYY-MM-DD')), p_plan_date)
            RETURNING wh_inventory_id INTO v_credit_id;
          END IF;
          v_wh_moves := jsonb_build_array(jsonb_build_object(
            'wh_inventory_id', v_credit_id, 'delta', v_qty, 'expiration_date', v_exp));
        END IF;

        -- restore the generic write context for subsequent statements
        PERFORM public.set_write_context('record_actual_refill',
          COALESCE(p_reason,'record_actual_refill'), NULL, NULL);

        -- discrepancies never pass silently: one monitoring alert per line
        IF v_discrepancy IS NOT NULL THEN
          INSERT INTO monitoring_alerts (source, severity, payload)
          VALUES ('rc02_record_actual_refill_discrepancy', 'warning',
            jsonb_build_object(
              'event_id', v_event_id, 'line_no', v_lineno,
              'machine', p_machine_name, 'plan_date', p_plan_date,
              'boonz_product_id', v_bpid, 'action', v_action,
              'shelf_code', v_shelf_code, 'warehouse_id', v_wh,
              'discrepancy', v_discrepancy));
        END IF;

        -- LOG effect (refill_plan_output) for machine-facing actions only
        v_rpo_action := CASE
          WHEN v_action IN ('refill','transfer_in') THEN 'Refill'
          WHEN v_action IN ('remove','write_off','transfer_out') THEN 'Remove'
          ELSE NULL END;
        IF v_rpo_action IS NOT NULL THEN
          INSERT INTO refill_plan_output
            (plan_date, machine_name, shelf_code, pod_product_name, boonz_product_name,
             action, quantity, operator_status, operator_comment, reviewed_at, dispatched, comment)
          SELECT p_plan_date, p_machine_name, v_shelf_code,
                 bp.boonz_product_name, bp.boonz_product_name, v_rpo_action, v_qty,
                 'approved',
                 COALESCE(p_reason,'record_actual_refill')
                   || CASE WHEN v_partner IS NOT NULL THEN ' ('||v_action||' '||v_partner||')' ELSE '' END,
                 now(), false, 'record_actual_refill'
          FROM boonz_products bp WHERE bp.product_id = v_bpid;
        END IF;
      END IF;

      INSERT INTO refill_event_lines
        (event_id, action, boonz_product_id, shelf_id, qty, set_mode, expiration_date,
         warehouse_id, partner_machine_id, result_pod_inventory_id, applied, notes,
         discrepancy, wh_moves)
      VALUES
        (v_event_id, v_action, v_bpid, v_shelf_id, v_qty, v_setmode, v_exp,
         v_wh, v_partner_id, v_pod_id, (NOT p_dry_run), v_notes,
         v_discrepancy, v_wh_moves);
      v_applied := v_applied + 1;

      v_line_details := v_line_details || jsonb_build_object(
        'line_no', v_lineno, 'action', v_action, 'shelf_code', v_shelf_code,
        'pod_before', v_cur, 'pod_after', v_newqty, 'pod_delta', v_pod_delta,
        'wh_debit_needed', v_debit_needed, 'wh_moves', v_wh_moves,
        'discrepancy', v_discrepancy);
    END LOOP;

    IF p_dry_run THEN
      UPDATE refill_events SET status = 'dry_run' WHERE event_id = v_event_id;
    ELSE
      UPDATE refill_events SET status = 'applied', applied_at = now() WHERE event_id = v_event_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- subtransaction rolled back ALL target writes + line inserts; record the failure on the header
    UPDATE refill_events SET status = 'failed', error_text = SQLERRM WHERE event_id = v_event_id;
    RETURN jsonb_build_object('status','failed','event_id',v_event_id,'failed_at_line',v_lineno,'error',SQLERRM);
  END;

  RETURN jsonb_build_object(
    'status', CASE WHEN p_dry_run THEN 'dry_run_ok' ELSE 'applied' END,
    'event_id', v_event_id, 'machine', p_machine_name, 'plan_date', p_plan_date,
    'lines', v_applied,
    'line_details', v_line_details);
END;
$function$;

COMMENT ON FUNCTION public.record_actual_refill(text, date, jsonb, text, uuid, text, boolean) IS
  'RC-02 v2 (Batch 2): pod delta-true WH debits via machine-scoped FEFO (wh_fefo_for_line), refill_event provenance with event lineage, explicit discrepancy recording + monitoring alerts, no jwt-claims forgery. Dry-run default; header+lines atomic with pod/WH writes.';

COMMIT;
