-- PRD-122 Phase 2, Guard G-A: controlled vocabulary on warehouse_inventory.batch_id.
-- Rejects any batch_id that isn't NULL or one of the known legit prefixes, closing off
-- the scratch/one-off prefixes (S5-, TEST-, TRANSFER-, STAGING-, RECON-, RETURN-, MCC-,
-- E2E-, NOOK-, RB330-) an external process has been using to write inventory rows that
-- bypass every canonical writer. ADHOC- is allowed but requires a non-null
-- provenance_reason on the same row, since it has no other audit trail.
--
-- Cody: Approve. Articles 2 (RLS already enabled on warehouse_inventory, untouched here),
-- 12 (forward-only, new migration). Guard only rejects writes; adds no new alerts/tables.
--
-- Backtested in a rolled-back transaction against production: 14 rows rejected
-- (12 S5-*, 2 TEST-*), 1464 PO-*/REMOVE-* rows passed unchanged.

CREATE OR REPLACE FUNCTION public.enforce_warehouse_batch_id_vocabulary()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.batch_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.batch_id ~ '^(PO|REMOVE|RETURNED|RETURN|WM|VOXSOURCE|TRANSFER|RECOUNT|ADHOC)-' THEN
    IF NEW.batch_id ~ '^ADHOC-' AND (NEW.provenance_reason IS NULL OR length(trim(NEW.provenance_reason)) = 0) THEN
      RAISE EXCEPTION 'warehouse_inventory.batch_id: ADHOC- batch_id requires a non-null provenance_reason on the same row (got batch_id=%)', NEW.batch_id;
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'warehouse_inventory.batch_id: "%" does not match an allowed prefix (PO-, REMOVE-, RETURNED-, RETURN-, WM-, VOXSOURCE-, TRANSFER-, RECOUNT-, ADHOC-)', NEW.batch_id;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_warehouse_batch_id_vocabulary ON public.warehouse_inventory;

CREATE TRIGGER trg_enforce_warehouse_batch_id_vocabulary
BEFORE INSERT OR UPDATE OF batch_id ON public.warehouse_inventory
FOR EACH ROW EXECUTE FUNCTION public.enforce_warehouse_batch_id_vocabulary();
