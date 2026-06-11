-- PRD-018 BUG-C — packed items not appearing in dispatch list (approve→dispatch bridge drops rows)
--
-- ROOT CAUSE (data-confirmed: many machines carry approved + dispatched=false rows, e.g.
-- 2026-05-17 AMZ-1068=33, AMZ-1038=39 — whole-machine bridge losses):
--   1. trg_fire_dispatch_on_approval wraps push_plan_to_dispatch in EXCEPTION WHEN OTHERS ... RAISE NOTICE,
--      silently swallowing any bridge failure: operator's approve persists (operator_status='approved')
--      but ZERO refill_dispatching rows are written and dispatched stays false, with no surfaced error.
--   2. push_plan_to_dispatch v5 loops ALL approved+undispatched rows for a machine in ONE transaction,
--      so a single row raising (block_orphan_internal_transfer — push is NOT in its allow-list;
--      prevent_duplicate_unstarted_dispatch; a NULL shelf) aborts the ENTIRE machine's bridge.
--
-- FIX (push_plan_to_dispatch -> v6_resilient_bridge):
--   - Per-row BEGIN/EXCEPTION sub-block: one bad row is counted + logged to monitoring_alerts and the
--     plan row stays dispatched=false (visible in the coverage query), but siblings still bridge.
--   - internal_transfer plan rows are skipped (counted) — they bridge via swap_between_machines, never
--     via push, and would otherwise guarantee a whole-loop abort via block_orphan_internal_transfer.
--   - Idempotency: if a live (non-cancelled, non-returned) dispatch row already covers a plan row, link
--     it instead of inserting a duplicate (prevent_duplicate_unstarted_dispatch safe; re-run safe).
--   - trg_fire_dispatch_on_approval now records non-ok push results AND exceptions to monitoring_alerts
--     (no more silent NOTICE), while still NOT rolling back the operator's approve.
--
-- EDGE CASES (PRD-018 BUG-C, all preserved/covered):
--   (1) manual/edited rows bridge — v5 created_by_edit/edit_count/cancelled/skipped preservation kept.
--   (2) multi-variant rows each bridge — each refill_plan_output row is per-variant; per-row loop bridges
--       each independently (one failing variant no longer blocks its siblings).
--   (3) source_origin/from_machine_id propagate — v5 INSERT column set preserved verbatim.
--   (4) a machine confirmed AFTER others still bridges — push is scoped to one (plan_date, machine_name);
--       no cross-machine state. Per-row resilience + idempotency make repeated trigger fires safe.
--   (5) idempotent — WHERE dispatched=false + cover-link guard + dispatched=true marking.
--   (6) post-bridge coverage (approved EXCEPT dispatched) returns empty for warehouse-sourced rows that
--       resolve; un-resolvable rows are surfaced (monitoring_alerts) instead of silently dropped.
--
-- Canonical writer (Article 1): sets app.via_rpc/app.rpc_name. push_plan_to_dispatch stays on the
-- enforce_canonical_dispatch_write allow-list. Identity signature (p_plan_date date, p_machine_name text)
-- unchanged. Article 12 forward-only. Cody-reviewed.

CREATE OR REPLACE FUNCTION public.push_plan_to_dispatch(p_plan_date date, p_machine_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id              uuid;
  v_machine_id           uuid;
  v_primary_warehouse_id uuid;
  v_count                int := 0;
  v_skipped              int := 0;
  v_pinned_count         int := 0;
  v_procurement_gaps     int := 0;
  v_preserved            int := 0;
  v_failed               int := 0;   -- BUG-C v6
  v_skipped_transfer     int := 0;   -- BUG-C v6
  line                   RECORD;
  v_shelf_id             uuid;
  v_pod_product_id       uuid;
  v_boonz_product_id     uuid;
  v_normalized_shelf     text;
  v_action               text;
  v_dispatch_comment     text;
  v_new_dispatch_id      uuid;
  v_existing_edit_id     uuid;
  v_existing_cover_id    uuid;        -- BUG-C v6
  v_pinned_wh_id         uuid;
  v_pinned_expiry        date;
  v_pin_eligible         boolean;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'push_plan_to_dispatch', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = v_user_id AND role = ANY (ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'push_plan_to_dispatch: caller % lacks required role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RETURN jsonb_build_object('status','error','error','p_plan_date is required'); END IF;
  IF p_machine_name IS NULL OR length(trim(p_machine_name)) = 0 THEN
    RETURN jsonb_build_object('status','error','error','p_machine_name is required');
  END IF;

  SELECT machine_id, primary_warehouse_id INTO v_machine_id, v_primary_warehouse_id
    FROM machines WHERE official_name = p_machine_name;
  IF v_machine_id IS NULL THEN
    RETURN jsonb_build_object('status','error','error','Machine not found: '||p_machine_name);
  END IF;

  FOR line IN
    SELECT * FROM refill_plan_output
    WHERE plan_date = p_plan_date AND machine_name = p_machine_name
      AND operator_status = 'approved' AND dispatched = false
  LOOP
    -- BUG-C v6: per-row sub-block so one bad row never aborts the whole machine bridge.
    BEGIN
      -- internal_transfer rows bridge via swap_between_machines, never via push
      -- (block_orphan_internal_transfer would otherwise abort the entire loop). Skip + count.
      IF COALESCE(line.source_origin::text, 'warehouse') = 'internal_transfer' THEN
        v_skipped_transfer := v_skipped_transfer + 1;
        CONTINUE;
      END IF;

      v_normalized_shelf := regexp_replace(line.shelf_code, '^([A-Z])([0-9])$', '\1' || '0' || '\2');
      SELECT shelf_id INTO v_shelf_id FROM shelf_configurations WHERE machine_id=v_machine_id AND shelf_code=v_normalized_shelf;
      SELECT pod_product_id INTO v_pod_product_id FROM pod_products WHERE lower(trim(pod_product_name))=lower(trim(line.pod_product_name)) LIMIT 1;
      SELECT product_id INTO v_boonz_product_id FROM boonz_products WHERE lower(trim(boonz_product_name))=lower(trim(line.boonz_product_name)) LIMIT 1;

      IF v_boonz_product_id IS NULL OR v_pod_product_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

      -- Preserve manually-added/edited dispatch rows (unchanged from v5).
      SELECT rd.dispatch_id INTO v_existing_edit_id
        FROM refill_dispatching rd
       WHERE rd.machine_id     = v_machine_id
         AND rd.dispatch_date  = line.plan_date
         AND rd.shelf_id       = v_shelf_id
         AND rd.pod_product_id = v_pod_product_id
         AND (rd.created_by_edit OR rd.edit_count > 0 OR rd.cancelled OR rd.skipped)
       ORDER BY rd.created_at DESC NULLS LAST
       LIMIT 1;
      IF v_existing_edit_id IS NOT NULL THEN
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_edit_id WHERE id = line.id;
        v_preserved := v_preserved + 1;
        CONTINUE;
      END IF;

      v_action := CASE upper(trim(line.action))
        WHEN 'REFILL' THEN 'Refill' WHEN 'ADD NEW' THEN 'Add New'
        WHEN 'REMOVE' THEN 'Remove' WHEN 'MACHINE TO WAREHOUSE' THEN 'Machine To Warehouse'
        WHEN 'SWAP' THEN 'Add New' ELSE trim(line.action)
      END;

      -- BUG-C v6 idempotency: if a live (non-cancelled, non-returned) dispatch row already covers this
      -- plan row, link it instead of inserting a duplicate (prevent_duplicate_unstarted_dispatch safe).
      SELECT rd.dispatch_id INTO v_existing_cover_id
        FROM refill_dispatching rd
       WHERE rd.machine_id       = v_machine_id
         AND rd.dispatch_date    = line.plan_date
         AND rd.shelf_id IS NOT DISTINCT FROM v_shelf_id
         AND rd.pod_product_id   = v_pod_product_id
         AND rd.boonz_product_id = v_boonz_product_id
         AND rd.action           = v_action
         AND COALESCE(rd.cancelled, false) = false
         AND COALESCE(rd.returned, false)  = false
       ORDER BY rd.created_at DESC NULLS LAST
       LIMIT 1;
      IF v_existing_cover_id IS NOT NULL THEN
        UPDATE refill_plan_output SET dispatched = true, dispatch_id = v_existing_cover_id WHERE id = line.id;
        v_preserved := v_preserved + 1;
        CONTINUE;
      END IF;

      v_dispatch_comment := CASE
        WHEN line.operator_comment IS NOT NULL AND trim(line.operator_comment) != '' THEN
          COALESCE(NULLIF(trim(line.comment), '') || E'\n', '') || E'\U0001F4AC ' || trim(line.operator_comment)
        ELSE line.comment
      END;

      v_pin_eligible := (v_action IN ('Refill','Add New'))
                        AND (COALESCE(line.source_origin::text, 'warehouse') = 'warehouse');
      v_pinned_wh_id := NULL;
      v_pinned_expiry := NULL;

      IF v_pin_eligible AND v_primary_warehouse_id IS NOT NULL THEN
        SELECT wh_inventory_id, expiration_date INTO v_pinned_wh_id, v_pinned_expiry
        FROM warehouse_inventory
         WHERE warehouse_id = v_primary_warehouse_id
           AND boonz_product_id = v_boonz_product_id
           AND status = 'Active'
           AND coalesce(warehouse_stock, 0) > 0
         ORDER BY expiration_date ASC NULLS LAST, wh_inventory_id ASC
         LIMIT 1;

        IF v_pinned_wh_id IS NULL THEN
          v_procurement_gaps := v_procurement_gaps + 1;
          INSERT INTO public.monitoring_alerts (source, severity, payload)
          VALUES (
            'procurement_gap', 'warning',
            jsonb_build_object(
              'title', format('Procurement gap: %s at %s', line.boonz_product_name, p_machine_name),
              'plan_date', p_plan_date, 'machine_name', p_machine_name, 'machine_id', v_machine_id,
              'boonz_product_id', v_boonz_product_id, 'boonz_product_name', line.boonz_product_name,
              'wh_id', v_primary_warehouse_id, 'action', v_action, 'qty_needed', line.quantity,
              'detected_by', 'push_plan_to_dispatch_FEFO_pin', 'detected_at', now()
            )
          );
        ELSE
          v_pinned_count := v_pinned_count + 1;
        END IF;
      END IF;

      INSERT INTO refill_dispatching (
        machine_id, shelf_id, pod_product_id, boonz_product_id,
        dispatch_date, action, quantity, include, comment,
        from_warehouse_id, from_wh_inventory_id, expiry_date, pinned_at_plan_time,
        source_origin, from_machine_id,
        packed, picked_up, dispatched, returned, item_added
      ) VALUES (
        v_machine_id, v_shelf_id, v_pod_product_id, v_boonz_product_id,
        line.plan_date, v_action, line.quantity, true, v_dispatch_comment,
        v_primary_warehouse_id, v_pinned_wh_id, v_pinned_expiry, v_pin_eligible,
        COALESCE(line.source_origin, 'warehouse'::public.source_origin_enum),
        CASE WHEN line.source_origin='internal_transfer' THEN line.from_machine_id ELSE NULL END,
        false, false, false, false, false
      ) RETURNING dispatch_id INTO v_new_dispatch_id;

      UPDATE refill_plan_output SET dispatched=true, dispatch_id=v_new_dispatch_id WHERE id=line.id;
      v_count := v_count + 1;

    EXCEPTION WHEN OTHERS THEN
      -- BUG-C v6: surface the per-row failure, keep going. Plan row stays dispatched=false (visible
      -- in the approved-EXCEPT-dispatched coverage query) instead of silently vanishing.
      v_failed := v_failed + 1;
      INSERT INTO public.monitoring_alerts (source, severity, payload)
      VALUES (
        'dispatch_bridge_failure', 'critical',  -- monitoring_alerts.severity CHECK ∈ (info,warning,critical)
        jsonb_build_object(
          'title', format('Dispatch bridge failure: %s at %s', line.boonz_product_name, p_machine_name),
          'plan_date', p_plan_date, 'machine_name', p_machine_name, 'plan_row_id', line.id,
          'boonz_product_name', line.boonz_product_name, 'shelf_code', line.shelf_code,
          'action', line.action, 'qty', line.quantity, 'sqlerrm', SQLERRM,
          'detected_by', 'push_plan_to_dispatch_v6', 'detected_at', now()
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status',                         CASE WHEN v_failed > 0 THEN 'partial' ELSE 'ok' END,
    'machine',                        p_machine_name,
    'lines_pushed',                   v_count,
    'lines_skipped_null_product',     v_skipped,
    'lines_preserved_manual_edit',    v_preserved,
    'lines_pinned_at_plan_time',      v_pinned_count,
    'procurement_gaps_logged',        v_procurement_gaps,
    'lines_failed',                   v_failed,
    'lines_skipped_internal_transfer',v_skipped_transfer,
    'rpc_version',                    'v6_resilient_bridge'
  );
END $function$;

-- Bridge trigger: stop swallowing failures silently — record to monitoring_alerts so the coverage
-- gap is visible, while still NOT rolling back the operator's approve action.
CREATE OR REPLACE FUNCTION public.trg_fire_dispatch_on_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_push_result jsonb;
BEGIN
  IF NEW.operator_status = 'approved'
     AND OLD.operator_status IS DISTINCT FROM 'approved'
     AND COALESCE(NEW.dispatched, false) = false
  THEN
    BEGIN
      v_push_result := public.push_plan_to_dispatch(NEW.plan_date, NEW.machine_name);
      IF COALESCE(v_push_result->>'status','') <> 'ok' THEN
        -- BUG-C: surface non-ok (partial/error) results instead of a silent NOTICE.
        INSERT INTO public.monitoring_alerts (source, severity, payload)
        VALUES ('dispatch_bridge_nonok', 'warning',
          jsonb_build_object('plan_date', NEW.plan_date, 'machine_name', NEW.machine_name,
                             'push_result', v_push_result, 'detected_at', now()));
        RAISE NOTICE 'approve_to_dispatch trigger: push_plan_to_dispatch returned %', v_push_result;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Bridge failures must not roll back the operator's approve, but must be visible.
      INSERT INTO public.monitoring_alerts (source, severity, payload)
      VALUES ('dispatch_bridge_exception', 'critical',
        jsonb_build_object('plan_date', NEW.plan_date, 'machine_name', NEW.machine_name,
                           'sqlerrm', SQLERRM, 'detected_at', now()));
      RAISE NOTICE 'approve_to_dispatch trigger: exception in push_plan_to_dispatch for % %: %',
                   NEW.plan_date, NEW.machine_name, SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;
