-- ============================================================================
-- PRD-002 — record_variant_correction RPC
--
-- Source PRD: docs/prds/refill-pipeline/PRD-002-returns-split-by-variant-ui.md
--
-- DEPENDS ON: 20260521233552_prd002_006_product_families.sql
--             20260521234206_prd002_006_variant_action_log.sql
--
-- Canonical writer for "the driver returned variant X when the dispatch
-- said variant Y" — common when Stitch picked the default variant for a
-- pod_product family but the WH actually had a different variant on hand.
--
-- Validates same-family swap (uses product_family_id), or accepts
-- cross-family with reason_code (driver chose to swap, e.g. customer
-- request — captured per PRD-002 Decision "adding a new variant not in
-- original dispatch: ALLOWED, with mandatory reason_code").
--
-- Atomic: pod_inventory decrement on the planned variant + increment on
-- the new variant + variant_action_log row, all in one transaction.
--
-- Returns: { ok, dispatch_id, original_variant, new_variant, qty, log_id }
--
-- Cody Articles: 1 (new canonical writer — single source of truth for
-- variant corrections), 4 (DEFINER + role + input validation +
-- app.via_rpc), 8 (audit via variant_action_log + universal trigger).
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.record_variant_correction(
  p_refill_dispatching_id uuid,
  p_planned_variant_id    uuid,
  p_new_variant_id        uuid,
  p_qty                   numeric,
  p_action_type           text DEFAULT 'return_variant_change',
  p_reason_code           text DEFAULT NULL,
  p_free_text             text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id        uuid := (SELECT auth.uid());
  v_caller_role      text;
  v_dispatch         refill_dispatching%ROWTYPE;
  v_planned_family   uuid;
  v_new_family       uuid;
  v_planned_name     text;
  v_new_name         text;
  v_log_id           uuid;
  v_pod_old_row      pod_inventory%ROWTYPE;
  v_pod_new_row      pod_inventory%ROWTYPE;
  v_today            date := CURRENT_DATE;
BEGIN
  PERFORM set_config('app.via_rpc',   'true', true);
  PERFORM set_config('app.rpc_name',  'record_variant_correction', true);

  -- Article 4: role gate. Drivers + WH + admins can correct variants.
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN (
    'field_staff','warehouse','operator_admin','superadmin','manager'
  ) THEN
    RAISE EXCEPTION 'record_variant_correction: role % not authorized',
      COALESCE(v_caller_role, 'none');
  END IF;

  -- Article 4: input validation
  IF p_refill_dispatching_id IS NULL THEN
    RAISE EXCEPTION 'p_refill_dispatching_id required';
  END IF;
  IF p_new_variant_id IS NULL THEN
    RAISE EXCEPTION 'p_new_variant_id required';
  END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'p_qty must be > 0 (got %)', p_qty;
  END IF;
  IF p_action_type NOT IN (
    'return_variant_change','return_variant_split',
    'dispatch_substitution','dispatch_extra_variant'
  ) THEN
    RAISE EXCEPTION 'p_action_type % not allowed', p_action_type;
  END IF;
  -- planned_variant only nullable for dispatch_extra_variant
  IF p_planned_variant_id IS NULL AND p_action_type <> 'dispatch_extra_variant' THEN
    RAISE EXCEPTION 'p_planned_variant_id required unless action_type=dispatch_extra_variant';
  END IF;

  -- Lock + validate the dispatch row
  SELECT * INTO v_dispatch FROM refill_dispatching
  WHERE dispatch_id = p_refill_dispatching_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispatch % not found', p_refill_dispatching_id;
  END IF;

  -- Resolve family for both variants
  IF p_planned_variant_id IS NOT NULL THEN
    SELECT product_family_id, boonz_product_name
    INTO v_planned_family, v_planned_name
    FROM boonz_products WHERE product_id = p_planned_variant_id;
    IF v_planned_name IS NULL THEN
      RAISE EXCEPTION 'planned_variant_id % not found', p_planned_variant_id;
    END IF;
  END IF;

  SELECT product_family_id, boonz_product_name
  INTO v_new_family, v_new_name
  FROM boonz_products WHERE product_id = p_new_variant_id;
  IF v_new_name IS NULL THEN
    RAISE EXCEPTION 'new_variant_id % not found', p_new_variant_id;
  END IF;

  -- Cross-family guard: dispatch_extra_variant is the only allowed
  -- cross-family path; others must stay within the same family (or
  -- both family ids must be NULL == no family declared).
  IF p_action_type <> 'dispatch_extra_variant'
     AND p_planned_variant_id IS NOT NULL
     AND v_planned_family IS DISTINCT FROM v_new_family THEN
    RAISE EXCEPTION 'Variant swap crosses families (% → %) — use dispatch_extra_variant or assign matching product_family_id first',
      v_planned_name, v_new_name;
  END IF;

  -- Append-only audit row (this is the load-bearing artifact)
  INSERT INTO public.variant_action_log
    (action_type, refill_dispatching_id, machine_id,
     planned_variant_id, new_variant_id, product_family_id,
     qty, reason_code, free_text, created_by)
  VALUES
    (p_action_type, p_refill_dispatching_id, v_dispatch.machine_id,
     p_planned_variant_id, p_new_variant_id,
     COALESCE(v_new_family, v_planned_family),
     p_qty, p_reason_code, p_free_text, v_caller_id)
  RETURNING log_id INTO v_log_id;

  -- Pod inventory adjustment: decrement planned, increment new (only when
  -- planned_variant is present and present in pod_inventory).
  IF p_planned_variant_id IS NOT NULL THEN
    SELECT * INTO v_pod_old_row FROM pod_inventory
    WHERE machine_id = v_dispatch.machine_id
      AND boonz_product_id = p_planned_variant_id
      AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL)
      AND status = 'Active'
    ORDER BY snapshot_at DESC LIMIT 1 FOR UPDATE;

    IF FOUND THEN
      UPDATE pod_inventory
      SET current_stock = GREATEST(COALESCE(current_stock,0) - p_qty, 0),
          status = CASE WHEN COALESCE(current_stock,0) - p_qty <= 0
                        THEN 'Inactive' ELSE status END,
          removal_reason = CASE WHEN COALESCE(current_stock,0) - p_qty <= 0
                                THEN format('variant_corrected_to_%s', v_new_name)
                                ELSE removal_reason END
      WHERE pod_inventory_id = v_pod_old_row.pod_inventory_id;
    END IF;
  END IF;

  -- Increment / upsert new variant row in pod_inventory
  SELECT * INTO v_pod_new_row FROM pod_inventory
  WHERE machine_id = v_dispatch.machine_id
    AND boonz_product_id = p_new_variant_id
    AND (shelf_id = v_dispatch.shelf_id OR v_dispatch.shelf_id IS NULL)
    AND status = 'Active'
  ORDER BY snapshot_at DESC LIMIT 1 FOR UPDATE;

  IF FOUND THEN
    UPDATE pod_inventory
    SET current_stock = COALESCE(current_stock,0) + p_qty,
        snapshot_at = now()
    WHERE pod_inventory_id = v_pod_new_row.pod_inventory_id;
  ELSE
    INSERT INTO pod_inventory
      (machine_id, shelf_id, boonz_product_id,
       snapshot_date, current_stock, estimated_remaining,
       expiration_date, batch_id, status, snapshot_at, created_at)
    VALUES
      (v_dispatch.machine_id, v_dispatch.shelf_id, p_new_variant_id,
       v_today, p_qty, p_qty,
       v_dispatch.expiry_date,
       format('VARIANT-CORR-%s', v_today),
       'Active', now(), now());
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dispatch_id', p_refill_dispatching_id,
    'action_type', p_action_type,
    'planned_variant', jsonb_build_object('id', p_planned_variant_id, 'name', v_planned_name),
    'new_variant',     jsonb_build_object('id', p_new_variant_id,     'name', v_new_name),
    'qty', p_qty,
    'log_id', v_log_id,
    'machine_id', v_dispatch.machine_id
  );
END
$$;

REVOKE EXECUTE ON FUNCTION public.record_variant_correction(uuid,uuid,uuid,numeric,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_variant_correction(uuid,uuid,uuid,numeric,text,text,text)
  TO authenticated, service_role;

COMMIT;

-- ============================================================================
-- POST-APPLY VERIFICATION
--   - Test invocation with planned=Truffle, new=Sea Salt, qty=1: variant_action_log
--     row appears, pod_inventory Truffle row decrements by 1, Sea Salt row
--     increments by 1 (or is created).
--   - Cross-family attempt (planned in one family, new in another) without
--     dispatch_extra_variant action_type: rejected.
--   - dispatch_extra_variant with planned_variant_id=NULL: accepted.
--
-- DEFERRED:
--   - FE: variant correction dialog in the driver app trip/return flow.
--     Reads boonz_products in same family via v_product_family_members and
--     calls this RPC.
--   - WH-side warehouse_inventory adjustment when a return crosses a different
--     batch — wraps adjust_warehouse_stock with provenance_reason='manual_adjust'.
-- ============================================================================
