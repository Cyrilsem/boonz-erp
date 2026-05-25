-- ============================================================================
-- PRD-014-inventory Phase 2 — block orphan internal_transfer rows
--
-- Prevents the anonymous-flip pattern where refill_dispatching rows land with
-- source_origin='internal_transfer' AND m2m_transfer_id IS NULL — half-pairs
-- of M2M transfers where the destination credit was never written. 28 such
-- rows existed in the 14-day window before this migration.
--
-- Allow-list: swap_between_machines (canonical M2M writer) + future
-- repair_orphan_internal_transfer (slot reserved for Phase 3 repair RPC).
--
-- BEFORE INSERT only. UPDATE is intentionally not gated to allow existing
-- orphan rows to be repaired by Phase 3 without trigger interference.
--
-- Applied to prod 2026-05-26 via MCP. Includes the enum-cast fix shipped
-- as the immediate follow-up migration phaseF_prd014_block_orphan_fix_enum_cast.
--
-- Cody articles: 1, 3, 12, 14.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.block_orphan_internal_transfer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rpc      text := current_setting('app.rpc_name', true);
  v_via_rpc  text := current_setting('app.via_rpc', true);
BEGIN
  IF NEW.source_origin = 'internal_transfer'::source_origin_enum
     AND NEW.m2m_transfer_id IS NULL THEN

    IF v_via_rpc IS DISTINCT FROM 'true'
       OR v_rpc IS NULL
       OR v_rpc NOT IN (
         'swap_between_machines',
         'repair_orphan_internal_transfer'
       )
    THEN
      RAISE EXCEPTION
        'refill_dispatching: source_origin=internal_transfer requires m2m_transfer_id AND must be written by swap_between_machines (got rpc=%, via_rpc=%, transfer_id=%)',
        COALESCE(v_rpc, 'NULL'),
        COALESCE(v_via_rpc, 'NULL'),
        NEW.m2m_transfer_id
        USING HINT = 'Call public.swap_between_machines to create a paired Remove+Add New transfer.';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

COMMENT ON FUNCTION public.block_orphan_internal_transfer() IS
  'PRD-014-inventory: prevents anonymous internal_transfer half-pairs. Allow-list: swap_between_machines + repair_orphan_internal_transfer.';

DROP TRIGGER IF EXISTS trg_block_orphan_internal_transfer ON public.refill_dispatching;
CREATE TRIGGER trg_block_orphan_internal_transfer
  BEFORE INSERT ON public.refill_dispatching
  FOR EACH ROW
  EXECUTE FUNCTION public.block_orphan_internal_transfer();
