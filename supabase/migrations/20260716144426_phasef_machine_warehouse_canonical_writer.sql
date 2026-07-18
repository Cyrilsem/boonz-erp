-- backported from prod schema_migrations on 2026-07-18, RC-15 parity
-- version: 20260716144426  name: phasef_machine_warehouse_canonical_writer
-- Close the Article-1 gap on machine warehouse mapping.
-- Adds FK hygiene + the VOX invariant as a CHECK + a canonical DEFINER writer.
-- Table is tiny (39 rows); all rows already satisfy these, so validation is immediate.

-- 1) FK hygiene (Dara D4)
ALTER TABLE public.machines
  ADD CONSTRAINT machines_primary_wh_fk
  FOREIGN KEY (primary_warehouse_id) REFERENCES public.warehouses(warehouse_id) ON DELETE RESTRICT;

ALTER TABLE public.machines
  ADD CONSTRAINT machines_secondary_wh_fk
  FOREIGN KEY (secondary_warehouse_id) REFERENCES public.warehouses(warehouse_id) ON DELETE RESTRICT;

-- 2) VOX invariant: only VOX venues may have a non-Central primary warehouse.
--    WH_CENTRAL = 4bebef68-9e36-4a5c-9c2c-142f8dbdae85
ALTER TABLE public.machines
  ADD CONSTRAINT machines_nonvox_primary_central
  CHECK (
    venue_group = 'VOX'
    OR primary_warehouse_id = '4bebef68-9e36-4a5c-9c2c-142f8dbdae85'::uuid
  );

-- 3) Canonical writer for the warehouse mapping columns.
CREATE OR REPLACE FUNCTION public.set_machine_warehouse(
  p_machine_id             uuid,
  p_primary_warehouse_id   uuid,
  p_secondary_warehouse_id uuid DEFAULT NULL,
  p_reason                 text DEFAULT NULL
) RETURNS public.machines
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role       text;
  v_venue      text;
  v_wh_central uuid := '4bebef68-9e36-4a5c-9c2c-142f8dbdae85';
  v_result     public.machines;
BEGIN
  -- Article 4: role validation (config action -> admin/manager only)
  SELECT role INTO v_role FROM public.user_profiles WHERE id = (SELECT auth.uid());
  IF v_role IS NULL OR v_role <> ALL (ARRAY['operator_admin','superadmin','manager']) THEN
    RAISE EXCEPTION 'set_machine_warehouse: caller role % not permitted', COALESCE(v_role, '<none>');
  END IF;

  -- Article 4: input validation
  IF p_machine_id IS NULL OR p_primary_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'set_machine_warehouse: machine_id and primary_warehouse_id are required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.warehouses WHERE warehouse_id = p_primary_warehouse_id) THEN
    RAISE EXCEPTION 'set_machine_warehouse: primary_warehouse_id % not found', p_primary_warehouse_id;
  END IF;
  IF p_secondary_warehouse_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.warehouses WHERE warehouse_id = p_secondary_warehouse_id) THEN
    RAISE EXCEPTION 'set_machine_warehouse: secondary_warehouse_id % not found', p_secondary_warehouse_id;
  END IF;
  IF p_secondary_warehouse_id IS NOT NULL AND p_secondary_warehouse_id = p_primary_warehouse_id THEN
    RAISE EXCEPTION 'set_machine_warehouse: primary and secondary warehouse must differ';
  END IF;

  SELECT venue_group INTO v_venue FROM public.machines WHERE machine_id = p_machine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'set_machine_warehouse: machine % not found', p_machine_id;
  END IF;

  -- VOX invariant (belt-and-suspenders with the table CHECK)
  IF COALESCE(v_venue, '') <> 'VOX' AND p_primary_warehouse_id <> v_wh_central THEN
    RAISE EXCEPTION 'set_machine_warehouse: non-VOX machine % must have primary = WH_CENTRAL', p_machine_id;
  END IF;

  -- Article 8: audit attribution for the generic trigger
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'set_machine_warehouse', true);

  UPDATE public.machines
     SET primary_warehouse_id   = p_primary_warehouse_id,
         secondary_warehouse_id = p_secondary_warehouse_id,
         updated_at             = now()
   WHERE machine_id = p_machine_id
  RETURNING * INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL   ON FUNCTION public.set_machine_warehouse(uuid,uuid,uuid,text) FROM public;
GRANT  EXECUTE ON FUNCTION public.set_machine_warehouse(uuid,uuid,uuid,text) TO authenticated;

COMMENT ON FUNCTION public.set_machine_warehouse(uuid,uuid,uuid,text) IS
  'Canonical writer for machines.primary/secondary_warehouse_id. Validates role + warehouse existence + VOX invariant (non-VOX => primary WH_CENTRAL). Article 1/4/8. Added phasef_machine_warehouse_canonical_writer 2026-07-16.';
