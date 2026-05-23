-- PRD-001 — WH manager can edit submitted PO with full audit capture
-- Migration name: phaseF_proc_edit_po_line_audit
-- Articles: 1 (canonical writer), 4 (DEFINER validates), 7 (audit append-only), 8 (universal audit)
-- Dara corrections: numeric not integer; write_audit_log = operation+occurred_at; dual-write procurement_events + write_audit_log.
-- Cody required revisions: dual-write audit; column COMMENTs name edit_purchase_order_line as sole writer; no-op edit guard.

-- 1. Denormalized "last edited" columns on purchase_orders.
ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS last_edited_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_edited_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.purchase_orders.last_edited_at IS
  'Set EXCLUSIVELY by the edit_purchase_order_line RPC (PRD-001). Any other writer creates silent drift — add new canonical writers via an explicit migration that documents the contract.';
COMMENT ON COLUMN public.purchase_orders.last_edited_by IS
  'Set EXCLUSIVELY by the edit_purchase_order_line RPC (PRD-001). Resolves to user_profiles.id of the WH manager who applied the most recent edit.';

-- 2. edit_purchase_order_line — sole canonical writer for the three editable fields.
CREATE OR REPLACE FUNCTION public.edit_purchase_order_line(
  p_po_line_id              uuid,
  p_new_ordered_qty         numeric  DEFAULT NULL,
  p_new_price_per_unit_aed  numeric  DEFAULT NULL,
  p_new_expiry_date         date     DEFAULT NULL,
  p_reason                  text     DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_caller_role     text;
  v_user_id         uuid;
  v_line            public.purchase_orders%ROWTYPE;
  v_new_ordered_qty numeric;
  v_new_price       numeric;
  v_new_expiry      date;
  v_new_total       numeric;
  v_before          jsonb;
  v_after           jsonb;
BEGIN
  -- Article 4: role + input validation
  v_user_id := auth.uid();
  SELECT role INTO v_caller_role
    FROM public.user_profiles WHERE id = v_user_id;

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'edit_purchase_order_line: forbidden for role %', COALESCE(v_caller_role, 'unknown');
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'edit_purchase_order_line: reason is required (>= 10 chars)';
  END IF;

  SELECT * INTO v_line
    FROM public.purchase_orders
   WHERE po_line_id = p_po_line_id
   FOR UPDATE;
  IF v_line.po_line_id IS NULL THEN
    RAISE EXCEPTION 'edit_purchase_order_line: po_line_id % not found', p_po_line_id;
  END IF;

  -- Compute proposed new values (NULL params = no change, per RPC contract)
  v_new_ordered_qty := COALESCE(p_new_ordered_qty,         v_line.ordered_qty);
  v_new_price       := COALESCE(p_new_price_per_unit_aed,  v_line.price_per_unit_aed);
  v_new_expiry      := COALESCE(p_new_expiry_date,         v_line.expiry_date);
  v_new_total       := CASE
                         WHEN v_new_ordered_qty IS NOT NULL AND v_new_price IS NOT NULL
                           THEN v_new_ordered_qty * v_new_price
                         ELSE NULL
                       END;

  -- Cody recommended: no-op guard. Reject before writing audit noise.
  IF v_new_ordered_qty IS NOT DISTINCT FROM v_line.ordered_qty
     AND v_new_price   IS NOT DISTINCT FROM v_line.price_per_unit_aed
     AND v_new_expiry  IS NOT DISTINCT FROM v_line.expiry_date
  THEN
    RAISE EXCEPTION 'edit_purchase_order_line: no changes detected (all three fields already match the submitted values)';
  END IF;

  -- Coherence: ordered_qty cannot drop below received_qty
  IF v_line.received_qty IS NOT NULL
     AND v_new_ordered_qty < v_line.received_qty
  THEN
    RAISE EXCEPTION 'edit_purchase_order_line: new ordered_qty (%) < received_qty (%). Reverse receipt first.',
      v_new_ordered_qty, v_line.received_qty;
  END IF;

  v_before := jsonb_build_object(
    'ordered_qty',        v_line.ordered_qty,
    'price_per_unit_aed', v_line.price_per_unit_aed,
    'total_price_aed',    v_line.total_price_aed,
    'expiry_date',        v_line.expiry_date
  );

  -- Article 8: attribution GUCs for the universal trigger
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'edit_purchase_order_line', true);

  UPDATE public.purchase_orders
     SET ordered_qty        = v_new_ordered_qty,
         price_per_unit_aed = v_new_price,
         expiry_date        = v_new_expiry,
         total_price_aed    = v_new_total,
         last_edited_at     = now(),
         last_edited_by     = v_user_id
   WHERE po_line_id = p_po_line_id
   RETURNING * INTO v_line;

  v_after := jsonb_build_object(
    'ordered_qty',        v_line.ordered_qty,
    'price_per_unit_aed', v_line.price_per_unit_aed,
    'total_price_aed',    v_line.total_price_aed,
    'expiry_date',        v_line.expiry_date
  );

  -- Dual-write per Cody Article 8 finding. Both writes are within the canonical RPC transaction.
  -- 1) Subsystem audit table (procurement_events) — primary access path for get_po_edit_history.
  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (
    v_line.po_id,
    'po_line_edited',
    v_user_id,
    jsonb_build_object(
      'po_line_id',  p_po_line_id,
      'before',      v_before,
      'after',       v_after,
      'reason',      p_reason,
      'actor_role',  v_caller_role
    )
  );

  -- 2) Universal write_audit_log — explicit append for Article 8 compliance.
  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'UPDATE', p_po_line_id::text, v_user_id, v_caller_role,
    true, 'edit_purchase_order_line',
    jsonb_build_object('po_id', v_line.po_id, 'before', v_before, 'after', v_after, 'reason', p_reason)
  );

  RETURN jsonb_build_object(
    'po_line_id', p_po_line_id,
    'po_id',      v_line.po_id,
    'before',     v_before,
    'after',      v_after,
    'reason',     p_reason,
    'edited_at',  v_line.last_edited_at,
    'edited_by',  v_user_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.edit_purchase_order_line(uuid, numeric, numeric, date, text)
  TO authenticated;

-- 3. get_po_edit_history — read RPC powering the Edit-history pill.
-- Reads from procurement_events (Dara's preferred access path; idx_procurement_events_po_id covers it).
CREATE OR REPLACE FUNCTION public.get_po_edit_history(p_po_id text)
RETURNS TABLE (
  event_id     uuid,
  po_line_id   uuid,
  actor_id     uuid,
  actor_name   text,
  actor_role   text,
  changed_at   timestamptz,
  before       jsonb,
  after        jsonb,
  reason       text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $function$
  SELECT
    pe.event_id,
    (pe.payload ->> 'po_line_id')::uuid                 AS po_line_id,
    pe.performed_by                                     AS actor_id,
    up.full_name                                        AS actor_name,
    (pe.payload ->> 'actor_role')                       AS actor_role,
    pe.created_at                                       AS changed_at,
    pe.payload -> 'before'                              AS before,
    pe.payload -> 'after'                               AS after,
    pe.payload ->> 'reason'                             AS reason
  FROM public.procurement_events pe
  LEFT JOIN public.user_profiles up ON up.id = pe.performed_by
  WHERE pe.po_id = p_po_id
    AND pe.event_type = 'po_line_edited'
  ORDER BY pe.created_at DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.get_po_edit_history(text) TO authenticated;
