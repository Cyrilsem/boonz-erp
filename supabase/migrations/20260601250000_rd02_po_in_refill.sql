-- RD-02: PO-in-refill (procure + receive inline). NOT YET APPLIED. FLAGGED CORRECTIONS vs PRD:
--   * add_stock() does NOT exist in prod -> the canonical receive writer is receive_purchase_order().
--     receive_po_in_refill delegates to it (Article 1: don't reinvent the receive logic).
--   * purchase_orders keys on supplier_id uuid (PRD said p_supplier text) -> p_supplier_id uuid here.
--   * Art.6: only confirm/reject_warehouse_status_proposal exist; NO proposal-CREATE writer was found.
--     So operator/superadmin receive cannot create a compliant proposal yet -> receive is gated to
--     role 'warehouse' (delegates to receive_purchase_order). Operator-receive is BLOCKED pending a
--     create_warehouse_status_proposal writer (flagged for Cody/CS — Art.6 must not be bypassed).
--   * box-multiple source (procurement_min_order_qty) not located -> p_box_size param (default 1).
-- No warehouse_inventory row is created on PO create (BUG-001 phantom-stock guard). Keys off
-- boonz_product_id, not the aisle join -> FIX-1 irrelevant. Cody: Articles 1,4,6,8,12.

ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'weekly'
    CHECK (origin IN ('weekly','refill_inline')),
  ADD COLUMN IF NOT EXISTS origin_plan_date date,
  ADD COLUMN IF NOT EXISTS origin_boonz_product_id uuid;
CREATE INDEX IF NOT EXISTS idx_po_origin_refill
  ON public.purchase_orders (origin_plan_date) WHERE origin = 'refill_inline';

-- ── request_po_in_refill: box-round + create PO (+ paired driver task) via the canonical writer ──
CREATE OR REPLACE FUNCTION public.request_po_in_refill(
  p_plan_date        date,
  p_boonz_product_id uuid,
  p_qty              int,
  p_supplier_id      uuid,
  p_reason           text,
  p_box_size         int DEFAULT 1
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid; v_rounded int; v_po_id text; v_create jsonb; v_is_vox boolean;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','request_po_in_refill',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id=v_user_id
      AND role=ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN RAISE EXCEPTION 'forbidden: request_po_in_refill requires operator_admin/superadmin/warehouse'; END IF;

  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'p_qty must be > 0'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.boonz_products WHERE product_id=p_boonz_product_id) THEN
    RAISE EXCEPTION 'request_po_in_refill: boonz_product % not found', p_boonz_product_id; END IF;

  -- E6: VOX-sourced products are not Boonz-procured -> block PO, raise with VOX team.
  -- FLAG: VOX detector source unconfirmed; using product_mapping->pod source_origin vox as a proxy.
  SELECT EXISTS (
    SELECT 1 FROM public.product_mapping pm
    JOIN public.pod_refill_plan prp ON prp.pod_product_id = pm.pod_product_id
    WHERE pm.boonz_product_id = p_boonz_product_id AND prp.plan_date = p_plan_date
      AND prp.source_origin::text = 'vox_at_venue'
  ) INTO v_is_vox;
  IF v_is_vox THEN RAISE EXCEPTION 'request_po_in_refill: % is VOX-sourced; raise with the VOX team, not a PO', p_boonz_product_id; END IF;

  -- E1: round up to the box multiple.
  v_rounded := CASE WHEN COALESCE(p_box_size,1) <= 1 THEN p_qty
                    ELSE CEIL(p_qty::numeric / p_box_size) * p_box_size END;

  v_po_id := 'RFL-' || to_char(p_plan_date,'YYYYMMDD') || '-' || substr(p_boonz_product_id::text,1,8);

  -- Delegate to the canonical PO writer (creates the paired driver_task atomically).
  v_create := public.create_purchase_order(
    v_po_id, p_supplier_id, CURRENT_DATE,
    jsonb_build_array(jsonb_build_object('boonz_product_id', p_boonz_product_id, 'ordered_qty', v_rounded)),
    true /* p_force_driver_task */);

  -- Link the new line(s) back to the refill that raised them.
  UPDATE public.purchase_orders
     SET origin='refill_inline', origin_plan_date=p_plan_date, origin_boonz_product_id=p_boonz_product_id
   WHERE po_id = v_po_id AND boonz_product_id = p_boonz_product_id;

  RETURN jsonb_build_object('status','ok','po_id',v_po_id,'ordered_qty',v_rounded,
    'origin','refill_inline','origin_plan_date',p_plan_date,'create_result',v_create,
    'note','warehouse_inventory NOT touched until receive (phantom-stock guard); then run restitch_after_edits');
END;
$function$;
GRANT EXECUTE ON FUNCTION public.request_po_in_refill(date,uuid,int,uuid,text,int) TO authenticated;

-- ── receive_po_in_refill: warehouse-role receive via the canonical receive writer ────────────
CREATE OR REPLACE FUNCTION public.receive_po_in_refill(
  p_po_id           text,
  p_boonz_product_id uuid,
  p_received_qty    int,
  p_expiration_date date,
  p_confirm         boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user_id uuid; v_role text; v_ordered numeric; v_recv jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','receive_po_in_refill',true);

  v_user_id := auth.uid();
  SELECT role INTO v_role FROM public.user_profiles WHERE id=v_user_id;
  IF v_user_id IS NOT NULL AND v_role NOT IN ('operator_admin','superadmin','warehouse') THEN
    RAISE EXCEPTION 'forbidden: receive_po_in_refill'; END IF;

  SELECT ordered_qty INTO v_ordered FROM public.purchase_orders
   WHERE po_id=p_po_id AND boonz_product_id=p_boonz_product_id LIMIT 1;
  IF v_ordered IS NULL THEN RAISE EXCEPTION 'receive_po_in_refill: PO line not found'; END IF;
  IF p_received_qty > v_ordered THEN
    RAISE EXCEPTION 'receive_po_in_refill: over-receipt (% > ordered %) — flag for manager', p_received_qty, v_ordered; END IF;  -- E5

  IF NOT p_confirm THEN
    RETURN jsonb_build_object('status','diff','po_id',p_po_id,'boonz_product_id',p_boonz_product_id,
      'ordered',v_ordered,'to_receive',p_received_qty,'expiry',p_expiration_date);
  END IF;

  -- Art.6: warehouse_inventory.status is manager-only. Only role 'warehouse' may apply (delegates to
  -- the canonical receive_purchase_order). Operator/superadmin must use the Art.6 proposal path —
  -- which has no CREATE writer yet (flagged), so it is refused here rather than silently bypassed.
  IF v_user_id IS NOT NULL AND v_role <> 'warehouse' THEN
    RAISE EXCEPTION 'receive_po_in_refill: Art.6 — only the warehouse manager may apply receive. Operator receive needs create_warehouse_status_proposal (not yet built).';
  END IF;

  v_recv := public.receive_purchase_order(
    p_po_id,
    jsonb_build_array(jsonb_build_object('boonz_product_id', p_boonz_product_id,
      'received_qty', p_received_qty, 'expiry_date', p_expiration_date)),
    '[]'::jsonb /* p_additions */);

  RETURN jsonb_build_object('status','received','po_id',p_po_id,'received_qty',p_received_qty,
    'receive_result',v_recv,'note','now run restitch_after_edits so the blocked row dispatches (E8)');
END;
$function$;
GRANT EXECUTE ON FUNCTION public.receive_po_in_refill(text,uuid,int,date,boolean) TO authenticated;
