-- PRD-015-inventory provenance warning trigger (Phase 1: RAISE WARNING window).
-- Cody-approved 2026-05-30 with verb-neutral naming so the function name
-- stays accurate after the 2026-06-06 cutover (WARNING -> EXCEPTION via
-- forward-only CREATE OR REPLACE).
-- Articles satisfied: 2, 6, 8 (n/a), 12, 14.
-- Applied to prod 2026-05-30 via MCP. This file is the repo mirror.

CREATE OR REPLACE FUNCTION public.enforce_provenance_on_warehouse_inventory_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_provenance text := current_setting('app.provenance_reason', true);
  v_rpc        text := current_setting('app.rpc_name', true);
BEGIN
  -- Phase 1 (7-day window starting 2026-05-30): RAISE WARNING only.
  -- Phase 2 cutover (planned 2026-06-06): forward-only migration
  -- phaseG_followup_prd015_warehouse_inventory_provenance_cutover
  -- replaces this body with RAISE EXCEPTION.
  IF v_provenance IS NULL
     OR v_provenance = ''
     OR v_provenance = 'unknown_pre_migration' THEN
    RAISE WARNING 'warehouse_inventory INSERT without explicit provenance_reason. rpc=% provenance=%. This becomes a hard error on 2026-06-06 cutover.',
      COALESCE(v_rpc, 'NULL'), COALESCE(v_provenance, 'NULL');
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_provenance_wh_inventory ON public.warehouse_inventory;
CREATE TRIGGER trg_enforce_provenance_wh_inventory
  BEFORE INSERT ON public.warehouse_inventory
  FOR EACH ROW EXECUTE FUNCTION public.enforce_provenance_on_warehouse_inventory_insert();
