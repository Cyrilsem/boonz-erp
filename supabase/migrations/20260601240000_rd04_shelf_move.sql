-- RD-04: shelf-to-shelf layout move. NOT YET APPLIED. Archive-then-seed paired move on
-- pod_inventory (keyed by shelf_id directly — NOT the aisle join — so FIX-1 is irrelevant here).
-- Atomic; same-machine; never 2 Active rows/shelf (respects idx_pod_inv_active_shelf); NO planogram
-- capacity edit (Cody revision c); locked-row guard. Cody: Articles 1,4,5,8,12,14.

CREATE TABLE IF NOT EXISTS public.shelf_layout_changes (
  change_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id     uuid NOT NULL REFERENCES public.machines(machine_id) ON DELETE RESTRICT,
  from_shelf_id  uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  to_shelf_id    uuid NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE RESTRICT,
  pod_product_id uuid,
  boonz_product_id uuid,
  is_swap        boolean NOT NULL DEFAULT false,
  moved_by       uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  moved_at       timestamptz NOT NULL DEFAULT now(),
  reason         text NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_shelf_layout_machine ON public.shelf_layout_changes (machine_id, moved_at DESC);
ALTER TABLE public.shelf_layout_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS shelf_layout_changes_select ON public.shelf_layout_changes;
CREATE POLICY shelf_layout_changes_select ON public.shelf_layout_changes FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles WHERE id=(SELECT auth.uid())
                 AND role=ANY(ARRAY['operator_admin','superadmin','warehouse','manager'])));
-- written only by move_shelf_product (DEFINER owner bypass).

CREATE OR REPLACE FUNCTION public.move_shelf_product(
  p_machine_id   uuid,
  p_from_shelf_id uuid,
  p_to_shelf_id   uuid,
  p_reason        text,
  p_confirm       boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid; v_a public.pod_inventory; v_b public.pod_inventory;
  v_mname text; v_from_code text; v_to_code text; v_from_cap int; v_to_cap int;
  v_locked int; v_is_swap boolean;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','move_shelf_product',true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id=v_user_id
      AND role=ANY(ARRAY['operator_admin','superadmin','warehouse'])
  ) THEN RAISE EXCEPTION 'forbidden: move_shelf_product requires operator_admin/superadmin/warehouse'; END IF;  -- E8

  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN RAISE EXCEPTION 'p_reason required (>=10 chars)'; END IF;
  IF p_from_shelf_id = p_to_shelf_id THEN
    RETURN jsonb_build_object('status','noop','reason','from and to shelf are the same'); END IF;  -- E7

  -- (a) both shelves must belong to p_machine_id (E3 cross-machine -> refuse).
  SELECT sc.shelf_code, sc.max_capacity INTO v_from_code, v_from_cap
    FROM public.shelf_configurations sc WHERE sc.shelf_id=p_from_shelf_id AND sc.machine_id=p_machine_id;
  SELECT sc.shelf_code, sc.max_capacity INTO v_to_code, v_to_cap
    FROM public.shelf_configurations sc WHERE sc.shelf_id=p_to_shelf_id AND sc.machine_id=p_machine_id;
  IF v_from_code IS NULL OR v_to_code IS NULL THEN
    RAISE EXCEPTION 'move_shelf_product: both shelves must belong to machine % (cross-machine -> use mark_internal_transfer)', p_machine_id; END IF;

  SELECT official_name INTO v_mname FROM public.machines WHERE machine_id=p_machine_id;

  -- (d) locked-row guard: refuse if either shelf has a linked refill_plan_output past pending.
  SELECT COUNT(*) INTO v_locked FROM public.refill_plan_output rpo
   WHERE rpo.plan_date >= CURRENT_DATE AND rpo.machine_name=v_mname
     AND rpo.shelf_code IN (v_from_code, v_to_code) AND rpo.operator_status <> 'pending';
  IF v_locked > 0 THEN RAISE EXCEPTION 'move_shelf_product: % locked dispatch line(s) on these shelves; move only on next plan', v_locked; END IF;  -- E4

  SELECT * INTO v_a FROM public.pod_inventory WHERE machine_id=p_machine_id AND shelf_id=p_from_shelf_id AND status='Active' LIMIT 1;
  IF v_a.pod_inventory_id IS NULL THEN RAISE EXCEPTION 'move_shelf_product: no Active product on source shelf %', v_from_code; END IF;
  SELECT * INTO v_b FROM public.pod_inventory WHERE machine_id=p_machine_id AND shelf_id=p_to_shelf_id AND status='Active' LIMIT 1;
  v_is_swap := (v_b.pod_inventory_id IS NOT NULL);  -- E2 occupied -> swap; E1 empty -> simple move

  IF NOT p_confirm THEN
    RETURN jsonb_build_object('status','diff','is_swap',v_is_swap,
      'from', jsonb_build_object('shelf',v_from_code,'boonz_product_id',v_a.boonz_product_id,'stock',v_a.current_stock,'cap',v_from_cap),
      'to',   jsonb_build_object('shelf',v_to_code,'boonz_product_id',v_b.boonz_product_id,'stock',v_b.current_stock,'cap',v_to_cap),
      'capacity_mismatch', (v_to_cap IS NOT NULL AND v_a.current_stock IS NOT NULL AND v_to_cap < v_a.current_stock));  -- E5 note
  END IF;

  -- Archive source (and target if swap) BEFORE seeding -> never 2 Active rows/shelf (idx_pod_inv_active_shelf).
  UPDATE public.pod_inventory SET status='Inactive', removal_reason=format('moved to %s: %s', v_to_code, p_reason),
         last_decremented_at=now() WHERE pod_inventory_id=v_a.pod_inventory_id;
  IF v_is_swap THEN
    UPDATE public.pod_inventory SET status='Inactive', removal_reason=format('swapped to %s: %s', v_from_code, p_reason),
           last_decremented_at=now() WHERE pod_inventory_id=v_b.pod_inventory_id;
  END IF;

  -- Seed A's product on B (carry identity + physical stock/expiry/batch).
  INSERT INTO public.pod_inventory(machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
     expiration_date, batch_id, status, created_at, snapshot_at)
  VALUES (p_machine_id, p_to_shelf_id, v_a.boonz_product_id, CURRENT_DATE, v_a.current_stock,
     v_a.expiration_date, v_a.batch_id, 'Active', now(), now());

  -- Swap: seed B's product back on A.
  IF v_is_swap THEN
    INSERT INTO public.pod_inventory(machine_id, shelf_id, boonz_product_id, snapshot_date, current_stock,
       expiration_date, batch_id, status, created_at, snapshot_at)
    VALUES (p_machine_id, p_from_shelf_id, v_b.boonz_product_id, CURRENT_DATE, v_b.current_stock,
       v_b.expiration_date, v_b.batch_id, 'Active', now(), now());
  END IF;

  INSERT INTO public.shelf_layout_changes(machine_id, from_shelf_id, to_shelf_id, boonz_product_id, is_swap, moved_by, reason)
  VALUES (p_machine_id, p_from_shelf_id, p_to_shelf_id, v_a.boonz_product_id, v_is_swap, v_user_id, p_reason);

  RETURN jsonb_build_object('status','moved','is_swap',v_is_swap,'from',v_from_code,'to',v_to_code,
    'moved_boonz_product_id',v_a.boonz_product_id,
    'capacity_mismatch', (v_to_cap IS NOT NULL AND v_a.current_stock IS NOT NULL AND v_to_cap < v_a.current_stock),
    'note','planogram capacity NOT edited (separate action)');
END;
$function$;
GRANT EXECUTE ON FUNCTION public.move_shelf_product(uuid,uuid,uuid,text,boolean) TO authenticated;
