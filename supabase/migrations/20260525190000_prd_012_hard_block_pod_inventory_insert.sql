-- PRD-012 P3.B (A.6): hard-block trigger on direct INSERT to pod_inventory.
-- Refuses any INSERT not gated by app.via_rpc='true'. Mirrors the Phase A
-- trg_detect_silent_warehouse_write family.
-- Cody verdict: ✅ Approve. Pre-deploy check confirmed all 6 INSERT-doing
-- functions on pod_inventory set app.via_rpc=true (adjust_pod_inventory,
-- approve_pod_inventory_add, bulk_upsert_pod_inventory_from_log,
-- log_manual_refill, receive_dispatch_line, remove_pod_inventory_batch).

CREATE OR REPLACE FUNCTION public.block_direct_pod_inventory_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF current_setting('app.via_rpc', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'pod_inventory direct INSERT blocked: route through a canonical RPC (e.g. remove_pod_inventory_batch, approve_pod_inventory_add, log_manual_refill, receive_dispatch_line, adjust_pod_inventory, bulk_upsert_pod_inventory_from_log). Set app.via_rpc=''true'' inside a SECURITY DEFINER wrapper.'
      USING ERRCODE = '42501',
            HINT  = 'See Constitution Article 3 + PRD-012 P3.B for the canonical writers list.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_block_direct_pod_inventory_insert ON public.pod_inventory;

CREATE TRIGGER trg_block_direct_pod_inventory_insert
  BEFORE INSERT ON public.pod_inventory
  FOR EACH ROW
  EXECUTE FUNCTION public.block_direct_pod_inventory_insert();

COMMENT ON FUNCTION public.block_direct_pod_inventory_insert() IS
  'PRD-012 P3.B (A.6) hard-block. Refuses INSERTs not gated by app.via_rpc=true. Mirrors the trg_detect_silent_warehouse_write family. Caller audit cleared 2026-05-25.';
