-- PRD-022 DF1 — po_number allocation fix + cross-po_id uniqueness guard.
-- Migration name: prd022_df1_po_number_allocation
-- Articles: 1 (canonical writer stays sole insert path), 4 (DEFINER validates), 12 (forward-only).
--
-- Root cause: po_number_seq.last_value (9143) drifted BELOW max(po_number) (9144) because the
-- retired FE path inserted MAX+1 po_numbers directly while the RPC advanced the sequence
-- independently. nextval would therefore re-issue an existing number. Fix is three parts, all
-- go-forward only. The 23 historical po_numbers that already span >1 po_id are left UNTOUCHED
-- (CS directive); the guard only constrains new inserts.

-- ── 0. Index on po_number — backs the trigger's lookup + the allocation skip-guard. ─────────────
CREATE INDEX IF NOT EXISTS idx_po_number ON public.purchase_orders (po_number);

-- ── 1. Resync the sequence above the true max so nextval resumes at max+1. ───────────────────────
-- COALESCE guard (Dara): safe even if the table were empty / max were NULL.
SELECT setval('public.po_number_seq',
              COALESCE((SELECT MAX(po_number) FROM public.purchase_orders),
                       (SELECT last_value FROM public.po_number_seq)));

-- ── 2. Backstop trigger: a po_number may never be claimed by a SECOND po_id. ─────────────────────
-- Fires only when a brand-new po_id (no existing rows) tries to take a po_number already owned by a
-- different po_id. Appends to an EXISTING po_id (multi-line POs, PRD-022 D3b add-lines) skip the
-- check, and historical duplicates are never re-validated (trigger is INSERT-only).
CREATE OR REPLACE FUNCTION public.trg_po_number_one_po_id_fn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.po_number IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_id = NEW.po_id)
     AND EXISTS (SELECT 1 FROM public.purchase_orders
                  WHERE po_number = NEW.po_number AND po_id <> NEW.po_id)
  THEN
    RAISE EXCEPTION 'po_number % already belongs to a different po_id - a po_number cannot span two po_ids', NEW.po_number;
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.trg_po_number_one_po_id_fn() IS
  'PRD-022 DF1. BEFORE INSERT guard on purchase_orders: blocks a brand-new po_id from claiming a po_number already owned by a different po_id. Skips appends to an existing po_id; never re-checks historical duplicates.';

DROP TRIGGER IF EXISTS trg_po_number_one_po_id ON public.purchase_orders;
CREATE TRIGGER trg_po_number_one_po_id
  BEFORE INSERT ON public.purchase_orders
  FOR EACH ROW EXECUTE FUNCTION public.trg_po_number_one_po_id_fn();

-- ── 3. Harden create_purchase_order allocation: skip any already-used number (self-heal). ────────
-- Verbatim re-create of the live body (PRD-1) with ONLY the skip-guard loop added after nextval.
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

  IF EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_id = p_po_id LIMIT 1) THEN
    RETURN jsonb_build_object(
      'po_id',     p_po_id,
      'po_number', (SELECT po_number FROM public.purchase_orders WHERE po_id = p_po_id LIMIT 1),
      'duplicate', true
    );
  END IF;

  SELECT procurement_type INTO v_procurement_type
  FROM public.suppliers WHERE supplier_id = p_supplier_id;

  v_needs_task := (v_procurement_type = 'walk_in') OR (p_force_driver_task = true);

  -- DF1: allocate the next po_number, skipping any value already present (self-heals sequence drift).
  v_next_num := nextval('public.po_number_seq');
  WHILE EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_number = v_next_num) LOOP
    v_next_num := nextval('public.po_number_seq');
  END LOOP;

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

  INSERT INTO public.po_notifications (
    po_id, po_number, notification_type, recipient, status, sent_by
  ) VALUES (
    p_po_id, v_next_num,
    CASE WHEN v_needs_task THEN 'driver_task' ELSE 'email' END,
    CASE WHEN v_needs_task THEN 'driver' ELSE 'supplier' END,
    'sent', v_caller_id
  );

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
