-- PRD-1 (Procurement Brain v3) — Guardrail: block ordering decommissioned / never-order products.
-- Migration name: phasef_proc_block_decommissioned_po_writes
-- Articles: 1 (canonical writers stay sole write path), 4 (DEFINER validates input), 8 (audit GUCs untouched).
--
-- Rule (data-driven, NOT hardcoded): a boonz_product is BLOCKED for ordering when it has at
-- least one supplier_products row AND every one of its rows is status='Inactive' with notes
-- containing 'never_order_flavor' or 'decommissioned_product'. A product with NO supplier_products
-- rows at all is "Unassigned" (orderable once a supplier is set), NOT blocked.
--
-- This guard has NO service-role / system bypass by design: it is a safety rail, not an auth gate.
-- No path (FE, skill, service role, edge fn) may write a PO line for a blocked product.
-- Backfill-proof: Ritz Cracker - Regular got ordered 2026-06-10 (PO-2026-MQ7MQIHO, cancelled);
-- this migration makes that write impossible at the RPC layer.

-- ---------------------------------------------------------------------------
-- 1. Shared detection helper. Returns the matching block-reason token, or NULL if orderable.
--    DEFINER so it reads the full supplier_products set regardless of caller (RLS-independent),
--    giving create_purchase_order, edit_purchase_order_line and the FE view one identical verdict.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.boonz_product_block_reason(p_boonz_product_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH rows AS (
    SELECT sp.status, sp.notes,
           (sp.status = 'Inactive'
            AND (sp.notes ILIKE '%never_order_flavor%'
              OR sp.notes ILIKE '%decommissioned_product%')) AS is_blocked_row,
           (sp.notes ILIKE '%decommissioned_product%')       AS is_decommissioned
    FROM public.supplier_products sp
    WHERE sp.boonz_product_id = p_boonz_product_id
  )
  SELECT CASE
           WHEN count(*) = 0 THEN NULL                          -- unassigned, not blocked
           WHEN count(*) FILTER (WHERE is_blocked_row) <> count(*) THEN NULL  -- has an orderable row
           WHEN bool_or(is_decommissioned) THEN 'decommissioned_product'
           ELSE 'never_order_flavor'
         END
  FROM rows;
$function$;

GRANT EXECUTE ON FUNCTION public.boonz_product_block_reason(uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public.boonz_product_block_reason(uuid) IS
  'PRD-1 procurement guardrail. Returns the block-reason token (decommissioned_product|never_order_flavor) when a product''s ONLY supplier_products rows are Inactive never-order rows, else NULL. Sole source of the "is this product orderable" verdict for create_purchase_order, edit_purchase_order_line and v_procurement_blocked_products.';

-- ---------------------------------------------------------------------------
-- 2. create_purchase_order — add the block check inside the line loop, BEFORE insert.
--    Verbatim re-create of the live body (2026-06-10) with the guard added; nothing else changed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_purchase_order(
  p_po_id text, p_supplier_id uuid, p_purchase_date date, p_lines jsonb,
  p_force_driver_task boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id        uuid;
  v_role             text;
  v_next_num         integer;
  v_line             jsonb;
  v_notes_arr        text[];
  v_prod_name        text;
  v_procurement_type text;
  v_needs_task       boolean;
  v_block_reason     text;   -- PRD-1
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'create_purchase_order', true);

  v_caller_id := (SELECT auth.uid());

  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller_id;
  IF v_role NOT IN ('field_staff','warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'create_purchase_order: unauthorized role: %', COALESCE(v_role,'none');
  END IF;

  IF p_po_id IS NULL OR trim(p_po_id) = '' THEN
    RAISE EXCEPTION 'create_purchase_order: p_po_id is required';
  END IF;
  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'create_purchase_order: p_supplier_id is required';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) != 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'create_purchase_order: at least one line is required';
  END IF;

  -- Idempotency guard
  IF EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_id = p_po_id LIMIT 1) THEN
    RETURN jsonb_build_object(
      'po_id',     p_po_id,
      'po_number', (SELECT po_number FROM public.purchase_orders WHERE po_id = p_po_id LIMIT 1),
      'duplicate', true
    );
  END IF;

  -- Determine whether a driver task is needed
  SELECT procurement_type INTO v_procurement_type
  FROM public.suppliers WHERE supplier_id = p_supplier_id;

  v_needs_task := (v_procurement_type = 'walk_in') OR (p_force_driver_task = true);

  -- Atomic sequence increment
  v_next_num := nextval('public.po_number_seq');

  -- Insert PO lines
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    IF (v_line->>'boonz_product_id') IS NULL THEN
      RAISE EXCEPTION 'create_purchase_order: boonz_product_id required in every line';
    END IF;
    IF COALESCE((v_line->>'ordered_qty')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'create_purchase_order: ordered_qty must be > 0';
    END IF;

    SELECT boonz_product_name INTO v_prod_name
    FROM public.boonz_products
    WHERE product_id = (v_line->>'boonz_product_id')::uuid;

    -- PRD-1 guardrail: never order a decommissioned / never-order product. No bypass.
    v_block_reason := public.boonz_product_block_reason((v_line->>'boonz_product_id')::uuid);
    IF v_block_reason IS NOT NULL THEN
      RAISE EXCEPTION 'create_purchase_order: product "%" is BLOCKED for ordering (rule: %; all supplier_products rows are Inactive never-order rows). Remove this line. To revive the product, reactivate a supplier_products row first.',
        COALESCE(v_prod_name, (v_line->>'boonz_product_id')), v_block_reason;
    END IF;

    INSERT INTO public.purchase_orders (
      po_id, po_number, supplier_id, boonz_product_id,
      purchase_date, ordered_qty,
      price_per_unit_aed, total_price_aed, expiry_date, received_date
    ) VALUES (
      p_po_id, v_next_num, p_supplier_id,
      (v_line->>'boonz_product_id')::uuid,
      COALESCE(p_purchase_date, CURRENT_DATE),
      (v_line->>'ordered_qty')::numeric,
      CASE WHEN v_line->>'price_per_unit_aed' IS NOT NULL
           THEN (v_line->>'price_per_unit_aed')::numeric ELSE NULL END,
      CASE WHEN v_line->>'price_per_unit_aed' IS NOT NULL
           THEN (v_line->>'ordered_qty')::numeric * (v_line->>'price_per_unit_aed')::numeric
           ELSE NULL END,
      CASE WHEN v_line->>'expiry_date' IS NOT NULL AND v_line->>'expiry_date' != ''
           THEN (v_line->>'expiry_date')::date ELSE NULL END,
      NULL
    );

    v_notes_arr := array_append(v_notes_arr,
      COALESCE(v_prod_name,'Unknown') || ' x' || (v_line->>'ordered_qty'));
  END LOOP;

  -- Create driver task only when needed
  IF v_needs_task THEN
    INSERT INTO public.driver_tasks (
      po_id, po_number, supplier_id, status, created_by, notes, is_forced
    ) VALUES (
      p_po_id, v_next_num, p_supplier_id, 'pending',
      v_caller_id,
      array_to_string(v_notes_arr, ', '),
      (p_force_driver_task AND v_procurement_type != 'walk_in')
    );
  END IF;

  -- Notification record
  INSERT INTO public.po_notifications (
    po_id, po_number, notification_type, recipient, status, sent_by
  ) VALUES (
    p_po_id, v_next_num,
    CASE WHEN v_needs_task THEN 'driver_task' ELSE 'email' END,
    CASE WHEN v_needs_task THEN 'driver' ELSE 'supplier' END,
    'sent', v_caller_id
  );

  -- Audit event
  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (
    p_po_id, 'po_created', v_caller_id,
    jsonb_build_object(
      'po_number',           v_next_num,
      'supplier_id',         p_supplier_id,
      'procurement_type',    v_procurement_type,
      'driver_task_created', v_needs_task,
      'force_driver_task',   p_force_driver_task,
      'line_count',          jsonb_array_length(p_lines)
    )
  );

  RETURN jsonb_build_object(
    'po_id',               p_po_id,
    'po_number',           v_next_num,
    'driver_task_created', v_needs_task,
    'duplicate',           false
  );
EXCEPTION WHEN OTHERS THEN RAISE;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. edit_purchase_order_line — block edits to a line whose product is blocked.
--    Re-create of the live body with the guard added right after the line is locked.
--    Reductions/removals must go through cancel_po_line, which stays unguarded.
-- ---------------------------------------------------------------------------
-- Re-created from the LIVE body (PRD-002 received-lock + lock_level, 2026-05-25) with the
-- PRD-1 guard added. Everything else is byte-for-byte the live function — no behavior reverted.
CREATE OR REPLACE FUNCTION public.edit_purchase_order_line(
  p_po_line_id              uuid,
  p_new_ordered_qty         numeric  DEFAULT NULL,
  p_new_price_per_unit_aed  numeric  DEFAULT NULL,
  p_new_expiry_date         date     DEFAULT NULL,
  p_reason                  text     DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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
  v_lock_level      text;
  v_block_reason    text;   -- PRD-1
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

  -- PRD-1 guardrail: refuse to re-touch a line for a blocked product.
  -- Superadmin carve-out (CS, 2026-06-10) — e.g. historical price corrections.
  -- Removal of a blocked line goes through cancel_po_line (unguarded).
  v_block_reason := public.boonz_product_block_reason(v_line.boonz_product_id);
  IF v_block_reason IS NOT NULL AND v_caller_role <> 'superadmin' THEN
    RAISE EXCEPTION 'edit_purchase_order_line: this line is a BLOCKED product (rule: %). Edits are refused for role %. Use cancel_po_line to remove it, or escalate to superadmin.',
      v_block_reason, v_caller_role;
  END IF;

  -- PRD-002: classify the lock level. Received lines are superadmin-only.
  v_lock_level := CASE
    WHEN COALESCE(v_line.received_qty, 0) > 0
         OR v_line.purchase_outcome = 'received'
      THEN 'received'
    ELSE 'unreceived'
  END;

  IF v_lock_level = 'received' AND v_caller_role <> 'superadmin' THEN
    RAISE EXCEPTION 'edit_purchase_order_line: line is already received; only superadmin can edit (received_qty=%, outcome=%)',
      v_line.received_qty, COALESCE(v_line.purchase_outcome, '(null)');
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
      'po_line_id',  p_po_line_id,
      'before',      v_before,
      'after',       v_after,
      'reason',      p_reason,
      'actor_role',  v_caller_role,
      'lock_level',  v_lock_level
    )
  );

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'UPDATE', p_po_line_id::text, v_user_id, v_caller_role,
    true, 'edit_purchase_order_line',
    jsonb_build_object('po_id', v_line.po_id, 'before', v_before, 'after', v_after, 'reason', p_reason, 'lock_level', v_lock_level)
  );

  RETURN jsonb_build_object(
    'po_line_id', p_po_line_id,
    'po_id',      v_line.po_id,
    'before',     v_before,
    'after',      v_after,
    'reason',     p_reason,
    'lock_level', v_lock_level,
    'edited_at',  v_line.last_edited_at,
    'edited_by',  v_user_id
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4. FE data source for the "Blocked" group (PRD-2 Boonz SKU tab). Read-only, data-driven.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_procurement_blocked_products AS
  SELECT bp.product_id AS boonz_product_id,
         bp.boonz_product_name,
         bp.product_category,
         public.boonz_product_block_reason(bp.product_id) AS block_reason,
         (SELECT string_agg(sp.notes, ' | ')
            FROM public.supplier_products sp
           WHERE sp.boonz_product_id = bp.product_id) AS supplier_notes
  FROM public.boonz_products bp
  WHERE public.boonz_product_block_reason(bp.product_id) IS NOT NULL;

GRANT SELECT ON public.v_procurement_blocked_products TO authenticated, service_role;

COMMENT ON VIEW public.v_procurement_blocked_products IS
  'PRD-1. Data-driven list of products that may never enter a PO basket (every supplier_products row Inactive never-order). Backs the struck-through "Blocked" group on /app/procurement Demand. block_reason = decommissioned_product | never_order_flavor.';
