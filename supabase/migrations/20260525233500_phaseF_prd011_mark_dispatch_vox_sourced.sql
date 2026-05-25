-- ============================================================================
-- PRD-011 follow-up — mark_dispatch_vox_sourced canonical writer.
--
-- Tags a refill_dispatching row with source_origin='vox_at_venue' so the
-- packing FE + repair_unbound_dispatch can skip the WH-debit path for
-- products that are sourced by VOX (cinema partner), not by Boonz, at
-- VOX-venue machines.
--
-- 9 VOX-sourced products (per memory reference_vox_sourced_products):
--   Pepsi, Ice Tea, M&M Bags, Aquafina, Maltesers, Fade Fit,
--   Chocolate Bar, Skittles Bag, Soft Drinks Mix (7up), Mountain Dew
--
-- Applied to prod 2026-05-26 via MCP. Used to retroactively tag 12 skipped
-- dispatch rows from the 19-23 May window (4 ACTIVATE + 8 IFLYMCC + 2 MPMCC +
-- 1 MPMCC + 1 VOXMCC). The remaining 79 skipped rows are real engine
-- over-allocation problems separate to PRD-013.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mark_dispatch_vox_sourced(
  p_dispatch_id uuid,
  p_reason      text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller_id   uuid := (SELECT auth.uid());
  v_caller_role text;
  v_disp        refill_dispatching%ROWTYPE;
  v_old_origin  text;
BEGIN
  SELECT role INTO v_caller_role FROM user_profiles WHERE id = v_caller_id;
  IF v_caller_role IS NULL OR v_caller_role NOT IN
    ('warehouse','operator_admin','superadmin','manager') THEN
    RAISE EXCEPTION 'mark_dispatch_vox_sourced: role % not authorized',
      COALESCE(v_caller_role, 'none');
  END IF;
  IF p_dispatch_id IS NULL THEN RAISE EXCEPTION 'p_dispatch_id required'; END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required (>=10 chars)';
  END IF;

  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'mark_dispatch_vox_sourced', true);
  PERFORM set_config('app.mutation_reason', p_reason, true);

  SELECT * INTO v_disp FROM refill_dispatching WHERE dispatch_id = p_dispatch_id FOR UPDATE;
  IF v_disp.dispatch_id IS NULL THEN RAISE EXCEPTION 'dispatch row % not found', p_dispatch_id; END IF;
  v_old_origin := v_disp.source_origin::text;

  UPDATE refill_dispatching
  SET source_origin = 'vox_at_venue'::source_origin_enum
  WHERE dispatch_id = p_dispatch_id;

  RETURN jsonb_build_object('ok', true, 'dispatch_id', p_dispatch_id,
    'old_source_origin', v_old_origin, 'new_source_origin', 'vox_at_venue',
    'reason', p_reason, 'tagged_by', v_caller_id);
END
$$;

REVOKE EXECUTE ON FUNCTION public.mark_dispatch_vox_sourced(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_dispatch_vox_sourced(uuid,text) TO authenticated, service_role;
