-- PRD-003 part 2 — the three RPCs + the internal additions mirror.
-- Cody conditions C-2 (mirror is definer-only, not a 3rd caller-reachable INSERT writer),
-- C-4 (explicit dual audit), C-5 (GUC + role gate), C-7 (anon/PUBLIC revoke), C-8 (no WH write).

CREATE OR REPLACE FUNCTION public.set_po_document_totals(
  p_po_id                      text,
  p_discount_aed               numeric DEFAULT 0,
  p_discount_label             text    DEFAULT NULL,
  p_vat_aed                    numeric DEFAULT NULL,
  p_vat_rate                   numeric DEFAULT 0.05,
  p_other_adjustment_aed       numeric DEFAULT 0,
  p_other_adjustment_label     text    DEFAULT NULL,
  p_supplier_invoice_number    text    DEFAULT NULL,
  p_supplier_invoice_date      date    DEFAULT NULL,
  p_supplier_invoice_total_aed numeric DEFAULT NULL,
  p_reason                     text    DEFAULT NULL,
  p_source                     text    DEFAULT 'receiving',
  p_line_price_regime          text    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller_id uuid;
  v_role      text;
  v_exists    boolean;
  v_is_edit   boolean;
  v_lines     numeric(12,2);
  v_additions numeric(12,2);
  v_subtotal  numeric(12,2);
  v_discount  numeric(12,2);
  v_other     numeric(12,2);
  v_rate      numeric(6,4);
  v_vat_auto  numeric(12,2);
  v_vat       numeric(12,2);
  v_override  boolean := false;
  v_grand     numeric(12,2);
  v_regime    text;
  v_warnings  jsonb := '[]'::jsonb;
  v_before    jsonb;
  v_after     jsonb;
  v_row       public.purchase_order_totals%ROWTYPE;
BEGIN
  v_caller_id := (SELECT auth.uid());
  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_caller_id;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'set_po_document_totals: forbidden for role %', COALESCE(v_role,'unknown');
  END IF;

  IF p_po_id IS NULL OR btrim(p_po_id) = '' THEN
    RAISE EXCEPTION 'set_po_document_totals: p_po_id is required';
  END IF;
  IF p_source IS NULL OR p_source NOT IN ('receiving','edit','backfill') THEN
    RAISE EXCEPTION 'set_po_document_totals: p_source must be receiving|edit|backfill, got %', COALESCE(p_source,'(null)');
  END IF;
  IF p_line_price_regime IS NOT NULL AND p_line_price_regime NOT IN ('ex_vat','vat_inclusive','unknown') THEN
    RAISE EXCEPTION 'set_po_document_totals: p_line_price_regime must be ex_vat|vat_inclusive|unknown, got %', p_line_price_regime;
  END IF;

  SELECT EXISTS (SELECT 1 FROM public.purchase_orders WHERE po_id = p_po_id) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'set_po_document_totals: po_id % not found', p_po_id;
  END IF;

  v_rate := COALESCE(p_vat_rate, 0.05);
  IF v_rate < 0 OR v_rate > 1 THEN
    RAISE EXCEPTION 'set_po_document_totals: p_vat_rate must be between 0 and 1, got %', v_rate;
  END IF;
  v_discount := ROUND(COALESCE(p_discount_aed, 0), 2);
  v_other    := ROUND(COALESCE(p_other_adjustment_aed, 0), 2);
  IF v_discount < 0 THEN
    RAISE EXCEPTION 'set_po_document_totals: discount cannot be negative (use other_adjustment for a credit note)';
  END IF;
  IF v_discount > 0 AND (p_discount_label IS NULL OR btrim(p_discount_label) = '') THEN
    RAISE EXCEPTION 'set_po_document_totals: discount_label is required when discount > 0';
  END IF;
  IF v_other <> 0 AND (p_other_adjustment_label IS NULL OR btrim(p_other_adjustment_label) = '') THEN
    RAISE EXCEPTION 'set_po_document_totals: other_adjustment_label is required when other_adjustment <> 0';
  END IF;

  SELECT ROUND(COALESCE(SUM(l.total_price_aed)
           FILTER (WHERE COALESCE(l.purchase_outcome,'') <> 'not_purchased'), 0), 2)
    INTO v_lines FROM public.purchase_orders l WHERE l.po_id = p_po_id;

  SELECT ROUND(COALESCE(SUM(a.qty * COALESCE(a.price_per_unit_aed, 0)), 0), 2)
    INTO v_additions FROM public.po_additions a
   WHERE a.po_id = p_po_id AND a.status = 'received'
     AND NOT EXISTS (SELECT 1 FROM public.purchase_orders l2 WHERE l2.source_addition_id = a.addition_id);

  v_subtotal := v_lines + v_additions;
  v_vat_auto := ROUND((v_subtotal - v_discount) * v_rate, 2);
  IF v_vat_auto < 0 THEN v_vat_auto := 0; END IF;
  v_vat := ROUND(COALESCE(p_vat_aed, v_vat_auto), 2);
  IF v_vat < 0 THEN RAISE EXCEPTION 'set_po_document_totals: vat cannot be negative'; END IF;
  v_override := (p_vat_aed IS NOT NULL AND v_vat IS DISTINCT FROM v_vat_auto);

  IF p_vat_aed IS NOT NULL AND abs(v_vat - v_vat_auto) > 1.00 THEN
    v_warnings := v_warnings || jsonb_build_object(
      'code', 'vat_override_warning',
      'message', format('VAT entered as %s but auto @ %s%% on %s would be %s (deviation %s AED)',
                        v_vat, ROUND(v_rate*100, 2), v_subtotal - v_discount, v_vat_auto,
                        ROUND(abs(v_vat - v_vat_auto), 2)),
      'vat_entered', v_vat, 'vat_auto', v_vat_auto);
  END IF;

  v_grand := v_subtotal - v_discount + v_vat + v_other;

  SELECT * INTO v_row FROM public.purchase_order_totals WHERE po_id = p_po_id FOR UPDATE;
  v_is_edit := (v_row.po_id IS NOT NULL);
  IF v_is_edit THEN
    IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
      RAISE EXCEPTION 'set_po_document_totals: reason is required on edit (>= 10 chars)';
    END IF;
    v_before := to_jsonb(v_row);
  END IF;

  v_regime := COALESCE(p_line_price_regime, v_row.line_price_regime, 'unknown');

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'set_po_document_totals', true);

  INSERT INTO public.purchase_order_totals AS t (
    po_id, lines_subtotal_ex_vat_aed, additions_subtotal_ex_vat_aed, subtotal_ex_vat_aed,
    discount_aed, discount_label, vat_rate, vat_aed, vat_auto_aed, vat_is_override,
    other_adjustment_aed, other_adjustment_label, grand_total_aed,
    supplier_invoice_number, supplier_invoice_date, supplier_invoice_total_aed,
    line_price_regime, source, created_by
  ) VALUES (
    p_po_id, v_lines, v_additions, v_subtotal,
    v_discount, NULLIF(btrim(COALESCE(p_discount_label,'')),''), v_rate, v_vat, v_vat_auto, v_override,
    v_other, NULLIF(btrim(COALESCE(p_other_adjustment_label,'')),''), v_grand,
    NULLIF(btrim(COALESCE(p_supplier_invoice_number,'')),''), p_supplier_invoice_date,
    CASE WHEN p_supplier_invoice_total_aed IS NULL THEN NULL ELSE ROUND(p_supplier_invoice_total_aed, 2) END,
    v_regime, p_source, v_caller_id
  )
  ON CONFLICT (po_id) DO UPDATE SET
    lines_subtotal_ex_vat_aed     = EXCLUDED.lines_subtotal_ex_vat_aed,
    additions_subtotal_ex_vat_aed = EXCLUDED.additions_subtotal_ex_vat_aed,
    subtotal_ex_vat_aed           = EXCLUDED.subtotal_ex_vat_aed,
    discount_aed                  = EXCLUDED.discount_aed,
    discount_label                = EXCLUDED.discount_label,
    vat_rate                      = EXCLUDED.vat_rate,
    vat_aed                       = EXCLUDED.vat_aed,
    vat_auto_aed                  = EXCLUDED.vat_auto_aed,
    vat_is_override               = EXCLUDED.vat_is_override,
    other_adjustment_aed          = EXCLUDED.other_adjustment_aed,
    other_adjustment_label        = EXCLUDED.other_adjustment_label,
    grand_total_aed               = EXCLUDED.grand_total_aed,
    supplier_invoice_number       = EXCLUDED.supplier_invoice_number,
    supplier_invoice_date         = EXCLUDED.supplier_invoice_date,
    supplier_invoice_total_aed    = EXCLUDED.supplier_invoice_total_aed,
    line_price_regime             = EXCLUDED.line_price_regime,
    source                        = 'edit',
    last_edited_at                = now(),
    last_edited_by                = v_caller_id
  RETURNING * INTO v_row;

  v_after := to_jsonb(v_row);

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (p_po_id,
    CASE WHEN v_is_edit THEN 'po_totals_edited' ELSE 'po_totals_set' END,
    v_caller_id,
    jsonb_build_object('before', v_before, 'after', v_after, 'reason', p_reason,
                       'actor_role', v_role, 'source', p_source, 'warnings', v_warnings));

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_order_totals', CASE WHEN v_is_edit THEN 'UPDATE' ELSE 'INSERT' END, p_po_id,
    v_caller_id, v_role, true, 'set_po_document_totals',
    jsonb_build_object('before', v_before, 'after', v_after, 'reason', p_reason, 'warnings', v_warnings));

  RETURN jsonb_build_object(
    'ok', true, 'po_id', p_po_id, 'is_edit', v_is_edit,
    'lines_ex_vat_aed', v_lines, 'additions_ex_vat_aed', v_additions,
    'subtotal_ex_vat_aed', v_subtotal, 'discount_aed', v_discount,
    'vat_rate', v_rate, 'vat_aed', v_vat, 'vat_auto_aed', v_vat_auto,
    'vat_is_override', v_override, 'other_adjustment_aed', v_other,
    'grand_total_aed', v_grand, 'line_price_regime', v_regime,
    'invoice_variance_aed', CASE WHEN v_row.supplier_invoice_total_aed IS NULL THEN NULL
                                 ELSE ROUND(v_grand - v_row.supplier_invoice_total_aed, 2) END,
    'warnings', v_warnings);
END;
$function$;

COMMENT ON FUNCTION public.set_po_document_totals(text,numeric,text,numeric,numeric,numeric,text,text,date,numeric,text,text,text) IS
  'PRD-003. Sole canonical writer on purchase_order_totals. NEVER writes purchase_orders - VAT must not reach the ex-VAT cost spine (PRD I-1/I-2). Roles: warehouse, operator_admin, manager, superadmin. Reason >= 10 chars required on edit.';

CREATE OR REPLACE FUNCTION public.get_po_document_totals(p_po_id text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
           (SELECT to_jsonb(v) FROM public.v_po_document_totals v WHERE v.po_id = p_po_id),
           jsonb_build_object('po_id', p_po_id, 'has_totals', false));
$function$;

COMMENT ON FUNCTION public.get_po_document_totals(text) IS
  'PRD-003. Thin read wrapper over the Article 16 canonical object v_po_document_totals so the FE renders the totals block in ONE call instead of re-deriving arithmetic client-side.';

CREATE OR REPLACE FUNCTION public.get_input_vat_report(
  p_date_from date DEFAULT NULL,
  p_date_to   date DEFAULT NULL
)
RETURNS TABLE (
  period_month        date,
  supplier_id         uuid,
  supplier_name       text,
  po_count            bigint,
  subtotal_ex_vat_aed numeric,
  discount_aed        numeric,
  vat_aed             numeric,
  grand_total_aed     numeric,
  overrides           bigint
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH po_supplier AS (
    SELECT DISTINCT ON (l.po_id) l.po_id AS ps_po_id, l.supplier_id AS ps_supplier_id
      FROM public.purchase_orders l
     ORDER BY l.po_id, (l.supplier_id IS NULL), l.purchase_date
  )
  SELECT
    date_trunc('month', COALESCE(t.supplier_invoice_date, t.created_at::date))::date,
    ps.ps_supplier_id,
    s.supplier_name,
    COUNT(*),
    SUM(t.subtotal_ex_vat_aed),
    SUM(t.discount_aed),
    SUM(t.vat_aed),
    SUM(t.grand_total_aed),
    COUNT(*) FILTER (WHERE t.vat_is_override)
  FROM public.purchase_order_totals t
  LEFT JOIN po_supplier ps ON ps.ps_po_id = t.po_id
  LEFT JOIN public.suppliers s ON s.supplier_id = ps.ps_supplier_id
  WHERE (p_date_from IS NULL OR COALESCE(t.supplier_invoice_date, t.created_at::date) >= p_date_from)
    AND (p_date_to   IS NULL OR COALESCE(t.supplier_invoice_date, t.created_at::date) <= p_date_to)
  GROUP BY 1, 2, 3
  ORDER BY 1 DESC, 3;
$function$;

COMMENT ON FUNCTION public.get_input_vat_report(date,date) IS
  'PRD-003 CS ruling Q3. Recoverable input VAT by month by supplier. Reads purchase_order_totals only - this is a RECEIVABLE report, never a cost report (PRD I-2).';

CREATE OR REPLACE FUNCTION public._mirror_po_addition_line_v1(
  p_addition_id uuid,
  p_actor_id    uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_a             public.po_additions%ROWTYPE;
  v_po_number     integer;
  v_supplier_id   uuid;
  v_purchase_date date;
  v_line_id       uuid;
  v_total         numeric;
  v_today         date := CURRENT_DATE;
  v_actor         uuid := COALESCE(p_actor_id, (SELECT auth.uid()));
BEGIN
  IF p_addition_id IS NULL THEN RETURN NULL; END IF;

  SELECT * INTO v_a FROM public.po_additions WHERE addition_id = p_addition_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT po_line_id INTO v_line_id
    FROM public.purchase_orders WHERE source_addition_id = p_addition_id;
  IF v_line_id IS NOT NULL THEN RETURN v_line_id; END IF;

  SELECT po_number, supplier_id, purchase_date
    INTO v_po_number, v_supplier_id, v_purchase_date
    FROM public.purchase_orders WHERE po_id = v_a.po_id
    ORDER BY purchase_date LIMIT 1;

  IF v_po_number IS NULL AND v_supplier_id IS NULL THEN RETURN NULL; END IF;

  v_total := CASE WHEN v_a.price_per_unit_aed IS NOT NULL
                  THEN ROUND(v_a.qty * v_a.price_per_unit_aed, 2) ELSE NULL END;

  INSERT INTO public.purchase_orders (
    po_id, po_number, supplier_id, boonz_product_id, purchase_date,
    ordered_qty, received_qty, price_per_unit_aed, total_price_aed,
    expiry_date, received_date, purchase_outcome, source_addition_id
  ) VALUES (
    v_a.po_id, v_po_number, v_supplier_id, v_a.boonz_product_id,
    COALESCE(v_purchase_date, v_today),
    v_a.qty, v_a.qty, v_a.price_per_unit_aed, v_total,
    v_a.expiry_date, COALESCE(v_a.received_at::date, v_today), 'received', p_addition_id
  )
  ON CONFLICT (source_addition_id) WHERE source_addition_id IS NOT NULL DO NOTHING
  RETURNING po_line_id INTO v_line_id;

  IF v_line_id IS NULL THEN
    SELECT po_line_id INTO v_line_id
      FROM public.purchase_orders WHERE source_addition_id = p_addition_id;
    RETURN v_line_id;
  END IF;

  INSERT INTO public.procurement_events (po_id, event_type, performed_by, payload)
  VALUES (v_a.po_id, 'po_addition_line_mirrored', v_actor,
    jsonb_build_object('addition_id', p_addition_id, 'po_line_id', v_line_id,
      'boonz_product_id', v_a.boonz_product_id, 'qty', v_a.qty,
      'price_per_unit_aed', v_a.price_per_unit_aed, 'total_price_aed', v_total,
      'note', 'financial mirror only - no warehouse batch created by this write'));

  INSERT INTO public.write_audit_log (
    table_name, operation, row_pk, actor, actor_role, via_rpc, rpc_name, payload
  ) VALUES (
    'purchase_orders', 'INSERT', v_line_id::text, v_actor,
    (SELECT role FROM public.user_profiles WHERE id = v_actor),
    true, '_mirror_po_addition_line_v1',
    jsonb_build_object('po_id', v_a.po_id, 'addition_id', p_addition_id,
                       'qty', v_a.qty, 'total_price_aed', v_total));

  RETURN v_line_id;
END;
$function$;

COMMENT ON FUNCTION public._mirror_po_addition_line_v1(uuid,uuid) IS
  'PRD-003 C-2. INTERNAL definer-only helper - ACL {postgres, service_role} only, never anon or authenticated. Mirrors a received po_additions row into a real purchase_orders line so the PO card total and cost reads stop silently excluding additions. Idempotent. FORWARD-ONLY: no backfill, historical addition prices are pack totals not unit prices. Writes purchase_orders ONLY - creates no warehouse batch (Article 6, C-8).';

-- C-7: new functions are BORN anon-executable here; four of five D-42 functions also carried PUBLIC.
REVOKE ALL ON FUNCTION public.set_po_document_totals(text,numeric,text,numeric,numeric,numeric,text,text,date,numeric,text,text,text) FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.get_po_document_totals(text)           FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public.get_input_vat_report(date,date)        FROM anon, PUBLIC;
REVOKE ALL ON FUNCTION public._mirror_po_addition_line_v1(uuid,uuid) FROM anon, PUBLIC, authenticated;

GRANT EXECUTE ON FUNCTION public.set_po_document_totals(text,numeric,text,numeric,numeric,numeric,text,text,date,numeric,text,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_po_document_totals(text)           TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_input_vat_report(date,date)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._mirror_po_addition_line_v1(uuid,uuid) TO service_role;
