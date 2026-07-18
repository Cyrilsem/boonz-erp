-- PRD-103 — Post-receipt EXPIRY correction on edit_purchase_order_line.
--
-- Context: PRD-002 made received lines (received_qty > 0 OR purchase_outcome =
-- 'received') fully superadmin-only on edit_purchase_order_line. Operationally,
-- warehouse staff frequently need to fix an expiry date they mis-keyed at
-- receiving, and forcing every correction through a superadmin is friction.
--
-- Change (surgical, forward-only CREATE OR REPLACE — same 5-arg signature):
--   * A received line may now have its EXPIRY DATE corrected by the standard
--     edit roles (warehouse, operator_admin, manager). ordered_qty and price on
--     a received line REMAIN superadmin-only.
--   * Every change is still audited (procurement_events + write_audit_log) with
--     lock_level='received' and a new post_receipt_expiry_edit flag so the audit
--     history can single these out.
--   * This corrects the PURCHASE-ORDER RECORD ONLY. It does NOT move or re-date
--     any already-received warehouse_inventory batch (those are written at
--     receive time and remain the FEFO source of truth). Intentional per CS.
--
-- Preserved verbatim from the LIVE definition (checked via pg_get_functiondef,
-- NOT the repo file — the live body carries the PRD-1 boonz_product_block_reason
-- guardrail that the repo migration lacked):
--   * role gate, reason >= 10 chars, FOR UPDATE lock, blocked-product guardrail,
--     no-op guard, GUC attribution, dual audit write, return shape.
--
-- Refinement: the "ordered_qty < received_qty" coherence guard now only fires
-- when the caller is actually changing ordered_qty (p_new_ordered_qty IS NOT
-- NULL). Previously an already over-received line (received > ordered) would
-- reject even an expiry-only edit. No behavior change for qty edits.

CREATE OR REPLACE FUNCTION public.edit_purchase_order_line(
  p_po_line_id uuid,
  p_new_ordered_qty numeric DEFAULT NULL::numeric,
  p_new_price_per_unit_aed numeric DEFAULT NULL::numeric,
  p_new_expiry_date date DEFAULT NULL::date,
  p_reason text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_role         text;
  v_user_id             uuid;
  v_line                public.purchase_orders%ROWTYPE;
  v_new_ordered_qty     numeric;
  v_new_price           numeric;
  v_new_expiry          date;
  v_new_total           numeric;
  v_before              jsonb;
  v_after               jsonb;
  v_lock_level          text;
  v_block_reason        text;    -- PRD-1
  v_post_receipt_expiry boolean; -- PRD-103
BEGIN
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

  -- PRD-1 guardrail: refuse to re-touch a line for a blocked product. Superadmin carve-out.
  v_block_reason := public.boonz_product_block_reason(v_line.boonz_product_id);
  IF v_block_reason IS NOT NULL AND v_caller_role <> 'superadmin' THEN
    RAISE EXCEPTION 'edit_purchase_order_line: this line is a BLOCKED product (rule: %). Edits are refused for role %. Use cancel_po_line to remove it, or escalate to superadmin.',
      v_block_reason, v_caller_role;
  END IF;

  -- PRD-002: classify the lock level. Received lines are qty/price superadmin-only.
  v_lock_level := CASE
    WHEN COALESCE(v_line.received_qty, 0) > 0
         OR v_line.purchase_outcome = 'received'
      THEN 'received'
    ELSE 'unreceived'
  END;

  v_post_receipt_expiry := (v_lock_level = 'received' AND v_caller_role <> 'superadmin');

  -- PRD-103: on a received line, non-superadmin edit roles may correct the
  -- EXPIRY DATE only. Reject any attempt to change ordered_qty or price.
  IF v_post_receipt_expiry THEN
    IF p_new_ordered_qty IS NOT NULL
       AND p_new_ordered_qty IS DISTINCT FROM v_line.ordered_qty THEN
      RAISE EXCEPTION 'edit_purchase_order_line: line is already received; ordered_qty is superadmin-only. Only the expiry date can be corrected post-receipt (received_qty=%, outcome=%).',
        v_line.received_qty, COALESCE(v_line.purchase_outcome, '(null)');
    END IF;
    IF p_new_price_per_unit_aed IS NOT NULL
       AND p_new_price_per_unit_aed IS DISTINCT FROM v_line.price_per_unit_aed THEN
      RAISE EXCEPTION 'edit_purchase_order_line: line is already received; price is superadmin-only. Only the expiry date can be corrected post-receipt (received_qty=%, outcome=%).',
        v_line.received_qty, COALESCE(v_line.purchase_outcome, '(null)');
    END IF;
    -- expiry-only edit permitted; fall through to the shared write path.
  END IF;

  v_new_ordered_qty := COALESCE(p_new_ordered_qty,         v_line.ordered_qty);
  v_new_price       := COALESCE(p_new_price_per_unit_aed,  v_line.price_per_unit_aed);
  v_new_expiry      := COALESCE(p_new_expiry_date,         v_line.expiry_date);
  v_new_total       := CASE
                         WHEN v_new_ordered_qty IS NOT NULL AND v_new_price IS NOT NULL
                           THEN v_new_ordered_qty * v_new_price
                         ELSE NULL
                       END;

  IF v_new_ordered_qty IS NOT DISTINCT FROM v_line.ordered_qty
     AND v_new_price   IS NOT DISTINCT FROM v_line.price_per_unit_aed
     AND v_new_expiry  IS NOT DISTINCT FROM v_line.expiry_date
  THEN
    RAISE EXCEPTION 'edit_purchase_order_line: no changes detected (all three fields already match the submitted values)';
  END IF;

  -- Coherence: ordered_qty cannot drop below received_qty. Only relevant when
  -- ordered_qty is actually being changed (PRD-103: never block an expiry-only edit).
  IF p_new_ordered_qty IS NOT NULL
     AND v_line.received_qty IS NOT NULL
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

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (
    v_line.po_id,
    'po_line_edited',
    v_user_id,
    jsonb_build_object(
      'po_line_id',                p_po_line_id,
      'before',                    v_before,
      'after',                     v_after,
      'reason',                    p_reason,
      'actor_role',                v_caller_role,
      'lock_level',                v_lock_level,
      'post_receipt_expiry_edit',  v_post_receipt_expiry
    )
  );

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'UPDATE', p_po_line_id::text, v_user_id, v_caller_role,
    true, 'edit_purchase_order_line',
    jsonb_build_object('po_id', v_line.po_id, 'before', v_before, 'after', v_after, 'reason', p_reason, 'lock_level', v_lock_level, 'post_receipt_expiry_edit', v_post_receipt_expiry)
  );

  RETURN jsonb_build_object(
    'po_line_id',               p_po_line_id,
    'po_id',                    v_line.po_id,
    'before',                   v_before,
    'after',                    v_after,
    'reason',                   p_reason,
    'lock_level',               v_lock_level,
    'post_receipt_expiry_edit', v_post_receipt_expiry,
    'edited_at',                v_line.last_edited_at,
    'edited_by',                v_user_id
  );
END;
$function$;
