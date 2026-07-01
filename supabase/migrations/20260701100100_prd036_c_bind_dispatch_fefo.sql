-- PRD-036 backend: FEFO-bind from_wh_inventory_id on Refill/Add dispatch lines at pickup.
-- Without a bound source batch, packing/pickup shows qty 0 + no expiry despite real WH stock.
-- Canonical DEFINER writer, role-gated, audited via GUCs. Idempotent (only binds NULL rows).
-- FEFO source = the canonical v_wh_pickable (Active, not quarantined, in-date), earliest expiry first,
-- at the line's from_warehouse_id (default WH_CENTRAL), reserved for this machine or unreserved.
-- Backend bind ONLY - the FE field-capture half of PRD-036 is explicitly excluded.

CREATE OR REPLACE FUNCTION public.bind_dispatch_fefo(
  p_plan_date     date,
  p_machine_names text[] DEFAULT NULL,
  p_caller_id     uuid   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
DECLARE
  v_user_id uuid := COALESCE(p_caller_id, auth.uid());
  v_role    text;
  v_bound   int;
  v_left    int;
BEGIN
  IF v_user_id IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user_id;
    IF v_role IS NULL OR v_role NOT IN ('warehouse','operator_admin','superadmin','manager') THEN
      RAISE EXCEPTION 'bind_dispatch_fefo: forbidden for role %', COALESCE(v_role,'unknown');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc','true', true);
  PERFORM set_config('app.rpc_name','bind_dispatch_fefo', true);
  PERFORM set_config('app.via_trigger','true', true);
  PERFORM set_config('app.mutation_reason', format('FEFO bind plan_date=%s by=%s', p_plan_date, v_user_id), true);

  WITH targets AS (
    SELECT rd.dispatch_id, rd.boonz_product_id, rd.machine_id,
           COALESCE(rd.from_warehouse_id, '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid) AS wh
    FROM public.refill_dispatching rd
    WHERE rd.dispatch_date = p_plan_date
      AND rd.action IN ('Refill','Add','Add New')
      AND rd.from_wh_inventory_id IS NULL
      AND COALESCE(rd.item_added,false) = false
      AND COALESCE(rd.returned,false)   = false
      AND COALESCE(rd.cancelled,false)  = false
      AND COALESCE(rd.packed,false)     = false
      AND COALESCE(rd.is_m2m,false)     = false
      AND (p_machine_names IS NULL
           OR rd.machine_id IN (SELECT machine_id FROM public.machines WHERE official_name = ANY(p_machine_names)))
  ),
  picks AS (
    SELECT t.dispatch_id, t.wh AS warehouse_id,
      ( SELECT p.wh_inventory_id
        FROM public.v_wh_pickable p
        WHERE p.boonz_product_id = t.boonz_product_id
          AND p.warehouse_id = t.wh
          AND (p.reserved_for_machine_id IS NULL OR p.reserved_for_machine_id = t.machine_id)
          AND COALESCE(p.warehouse_stock,0) > 0
        ORDER BY p.expiration_date ASC NULLS LAST, p.warehouse_stock DESC
        LIMIT 1 ) AS wh_inventory_id
    FROM targets t
  ),
  upd AS (
    UPDATE public.refill_dispatching rd
       SET from_wh_inventory_id = picks.wh_inventory_id,
           from_warehouse_id    = COALESCE(rd.from_warehouse_id, picks.warehouse_id)
    FROM picks
    WHERE rd.dispatch_id = picks.dispatch_id
      AND picks.wh_inventory_id IS NOT NULL
    RETURNING 1
  )
  SELECT count(*) INTO v_bound FROM upd;

  SELECT count(*) INTO v_left
  FROM public.refill_dispatching rd
  WHERE rd.dispatch_date = p_plan_date
    AND rd.action IN ('Refill','Add','Add New')
    AND rd.from_wh_inventory_id IS NULL
    AND COALESCE(rd.item_added,false)=false AND COALESCE(rd.returned,false)=false
    AND COALESCE(rd.cancelled,false)=false AND COALESCE(rd.packed,false)=false AND COALESCE(rd.is_m2m,false)=false
    AND (p_machine_names IS NULL
         OR rd.machine_id IN (SELECT machine_id FROM public.machines WHERE official_name = ANY(p_machine_names)));

  RETURN jsonb_build_object('status','ok','plan_date',p_plan_date,'bound',v_bound,
                            'still_unbound_no_wh_stock',v_left);
END;
$$;

REVOKE ALL ON FUNCTION public.bind_dispatch_fefo(date,text[],uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.bind_dispatch_fefo(date,text[],uuid) TO authenticated, service_role;

-- DOWN:
-- DROP FUNCTION IF EXISTS public.bind_dispatch_fefo(date,text[],uuid);
