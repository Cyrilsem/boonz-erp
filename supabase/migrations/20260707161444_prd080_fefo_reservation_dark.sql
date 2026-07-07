-- PRD-080 (Cody PASS, revisions applied): FEFO soft-reservation infra, shipped DARK.
-- wh_reservation + bind/release DEFINER writers (set app.via_rpc/rpc_name). bind no-ops when
-- fefo_reserve_v1<>'on'. Does NOT touch warehouse_inventory (soft hold only). Family A untouched.
-- PARKED: enabling fefo_reserve_v1 (Ops TTL + reservation-shape ruling + dual-mechanism
-- resolution vs warehouse_inventory.reserved_for_machine_id, Article 14 + release-hook wiring).
CREATE TABLE IF NOT EXISTS public.wh_reservation (
  reservation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), wh_inventory_id uuid NOT NULL, machine_id uuid NOT NULL,
  dispatch_id uuid, qty numeric NOT NULL CHECK (qty > 0),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','released','consumed','expired')),
  reserved_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz, created_by uuid);
ALTER TABLE public.wh_reservation ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS whr_select ON public.wh_reservation;
CREATE POLICY whr_select ON public.wh_reservation FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.wh_reservation TO authenticated, service_role;
CREATE INDEX IF NOT EXISTS idx_whr_dispatch_active ON public.wh_reservation (dispatch_id) WHERE status='active';
CREATE INDEX IF NOT EXISTS idx_whr_batch_active ON public.wh_reservation (wh_inventory_id) WHERE status='active';
CREATE OR REPLACE FUNCTION public.bind_fefo_reserved(p_dispatch_id uuid, p_ttl_minutes int DEFAULT 240)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE v_res uuid; v_disp refill_dispatching%ROWTYPE; v_wi uuid;
BEGIN
  IF refill_qa.flag('fefo_reserve_v1') <> 'on' THEN RETURN NULL; END IF;
  PERFORM set_config('app.via_rpc','true',true); PERFORM set_config('app.rpc_name','bind_fefo_reserved',true);
  SELECT * INTO v_disp FROM refill_dispatching WHERE dispatch_id = p_dispatch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'bind_fefo_reserved: dispatch % not found', p_dispatch_id; END IF;
  SELECT p.wh_inventory_id INTO v_wi FROM v_wh_pickable p
   WHERE p.boonz_product_id = v_disp.boonz_product_id AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = v_disp.machine_id)
     AND COALESCE(p.warehouse_stock,0) >= v_disp.quantity ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC LIMIT 1;
  IF v_wi IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.wh_reservation(wh_inventory_id, machine_id, dispatch_id, qty, expires_at)
  VALUES (v_wi, v_disp.machine_id, p_dispatch_id, v_disp.quantity, now() + make_interval(mins => p_ttl_minutes)) RETURNING reservation_id INTO v_res;
  RETURN v_res;
END $fn$;
GRANT EXECUTE ON FUNCTION public.bind_fefo_reserved(uuid,int) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.release_fefo_reservation(p_dispatch_id uuid, p_reason text DEFAULT 'released')
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $fn$
DECLARE n int; BEGIN
  PERFORM set_config('app.via_rpc','true',true); PERFORM set_config('app.rpc_name','release_fefo_reservation',true);
  UPDATE public.wh_reservation SET status = CASE WHEN p_reason='consumed' THEN 'consumed' ELSE 'released' END WHERE dispatch_id = p_dispatch_id AND status='active';
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n; END $fn$;
GRANT EXECUTE ON FUNCTION public.release_fefo_reservation(uuid,text) TO authenticated, service_role;
INSERT INTO refill_qa.feature_flag(flag,value) VALUES ('fefo_reserve_v1','off') ON CONFLICT (flag) DO NOTHING;
