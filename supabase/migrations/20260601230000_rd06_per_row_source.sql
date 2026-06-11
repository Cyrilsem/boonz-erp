-- RD-06: per-row source selection. NOT YET APPLIED. The ONE canonical source writer (retires the
-- raw-UPDATE source_origin anti-pattern, conductor Hard Rule 9). Keys off the pod_refill_plan 5-tuple
-- (not the v_live_shelf_stock aisle), so FIX-1 is irrelevant here. Cody: Articles 1,4,5,8,12,14.

ALTER TABLE public.pod_refill_plan
  ADD COLUMN IF NOT EXISTS source_warehouse_id uuid
    REFERENCES public.warehouses(warehouse_id) ON DELETE SET NULL;
COMMENT ON COLUMN public.pod_refill_plan.source_warehouse_id IS
  'RD-06: operator-pinned source warehouse for a warehouse-sourced row; NULL = default WH resolution.';

-- E7: a WH id is only valid when the row is warehouse-sourced. NOT VALID so existing rows aren''t scanned.
ALTER TABLE public.pod_refill_plan
  DROP CONSTRAINT IF EXISTS pod_refill_plan_source_wh_chk;
ALTER TABLE public.pod_refill_plan
  ADD CONSTRAINT pod_refill_plan_source_wh_chk
  CHECK (source_warehouse_id IS NULL OR source_origin::text = 'warehouse') NOT VALID;

CREATE OR REPLACE FUNCTION public.set_refill_row_source(
  p_plan_date date, p_machine_id uuid, p_shelf_id uuid, p_pod_product_id uuid, p_action text,
  p_source text, p_from_machine_id uuid DEFAULT NULL, p_source_warehouse_id uuid DEFAULT NULL,
  p_qty int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid; v_row public.pod_refill_plan; v_dest_name text; v_src_name text; v_transfer jsonb;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','set_refill_row_source',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id=v_user_id
      AND role=ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN RAISE EXCEPTION 'forbidden: set_refill_row_source requires operator_admin/superadmin/warehouse'; END IF;

  IF p_source NOT IN ('warehouse','internal_transfer','vox_at_venue') THEN
    RAISE EXCEPTION 'invalid source: %', p_source; END IF;
  -- E7: non-warehouse source must not carry a WH id.
  IF p_source <> 'warehouse' AND p_source_warehouse_id IS NOT NULL THEN
    RAISE EXCEPTION 'set_refill_row_source: source_warehouse_id only valid for warehouse source'; END IF;
  IF p_source = 'warehouse' AND p_source_warehouse_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.warehouses WHERE warehouse_id=p_source_warehouse_id) THEN
    RAISE EXCEPTION 'set_refill_row_source: warehouse % not found', p_source_warehouse_id; END IF;

  SELECT * INTO v_row FROM public.pod_refill_plan
   WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
     AND pod_product_id=p_pod_product_id AND action=p_action;
  IF NOT FOUND THEN RAISE EXCEPTION 'set_refill_row_source: row not found for the 5-tuple'; END IF;

  -- E4: source change only on a draft (mirrors mark_internal_transfer's locked-row posture).
  IF v_row.status <> 'draft' THEN
    RAISE EXCEPTION 'set_refill_row_source: row status % — source change only on draft', v_row.status; END IF;

  IF p_source = 'internal_transfer' THEN
    IF p_from_machine_id IS NULL THEN RAISE EXCEPTION 'internal_transfer requires p_from_machine_id'; END IF;
    IF p_from_machine_id = p_machine_id THEN RAISE EXCEPTION 'cannot transfer from self (E5)'; END IF;
    SELECT official_name INTO v_dest_name FROM public.machines WHERE machine_id=p_machine_id;
    SELECT official_name INTO v_src_name  FROM public.machines WHERE machine_id=p_from_machine_id;
    IF v_src_name IS NULL THEN RAISE EXCEPTION 'source machine % not found', p_from_machine_id; END IF;
    -- Delegate to the canonical writer (creates the paired REMOVE at the source machine).
    v_transfer := public.mark_internal_transfer(p_plan_date, v_src_name, v_dest_name, p_pod_product_id, COALESCE(p_qty, v_row.qty));
    RETURN jsonb_build_object('status','ok','source','internal_transfer','from_machine',v_src_name,'transfer',v_transfer);
  END IF;

  -- warehouse | vox_at_venue: the canonical source set on the plan row.
  UPDATE public.pod_refill_plan
     SET source_origin       = p_source::public.source_origin_enum,
         source_warehouse_id = CASE WHEN p_source='warehouse' THEN p_source_warehouse_id ELSE NULL END,
         from_machine_id     = NULL,
         updated_at          = now()
   WHERE plan_date=p_plan_date AND machine_id=p_machine_id AND shelf_id=p_shelf_id
     AND pod_product_id=p_pod_product_id AND action=p_action;

  RETURN jsonb_build_object('status','ok','source',p_source,
    'source_warehouse_id', CASE WHEN p_source='warehouse' THEN p_source_warehouse_id ELSE NULL END);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.set_refill_row_source(date,uuid,uuid,uuid,text,text,uuid,uuid,int) TO authenticated;

-- NOTE (flagged for Cody/CS): E8 (flip internal_transfer -> warehouse cleans up the prior paired
-- REMOVE at the source) needs the transfer's REMOVE row id tracked to delete the orphan. Deferred:
-- requires mark_internal_transfer to return/expose the paired swap id. The warehouse/vox path above
-- already clears from_machine_id; the orphan-REMOVE sweep is the one open refinement.
