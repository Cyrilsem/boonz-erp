-- PRD-067 data integrity: phantom JET/WH2 machine cleanup + (skipped) duplicate "Sour Cream" name.
-- Pre-authorized (PRD-ALL overnight manifest, 2026-06-30). Cody ✅. Idempotent. Applied 2026-06-30.
-- CONSERVATION: phantom write-offs credit NO warehouse_inventory; final assert enforces WH unchanged.
--
-- APPLIED: WH2-2001-3000-O1 phantom (57 pod write-offs via canonical backfill_archive, 226 mappings
-- deleted, status Warehouse->Inactive) + JET-2001-3000-O1 (76 orphan mappings deleted).
--
-- SKIPPED (logged to PRD-065/068 INCOMPLETE list, never forced): the "Sour Cream" rename+shell-delete.
-- The shell boonz_products 285479a7 ("Hunter Ridge - Sour Cream & Onion") is NOT zero-reference as the
-- doc assumed - it is still referenced by 1 daily_reconciliation_log row. Deleting it would orphan that
-- row; renaming 4edc4fbb to the same name while the shell survives would re-create a duplicate name.
-- Needs a CS decision on that single recon row (repoint to 4edc4fbb vs delete) before delete + rename.

CREATE TEMP TABLE _prd067_wh_pre ON COMMIT DROP AS
SELECT COALESCE(SUM(warehouse_stock),0)::numeric AS wh_total FROM warehouse_inventory;

-- 3. WH2-2001-3000-O1 phantom warehouse machine: write off 57 active pod rows (canonical, no WH credit)
DO $$
DECLARE r record; v_caller uuid := '38c282e3-7468-4071-99d0-0473e3a4818f';
BEGIN
  FOR r IN
    SELECT pi.pod_inventory_id
    FROM public.pod_inventory pi JOIN public.machines m ON m.machine_id = pi.machine_id
    WHERE m.official_name = 'WH2-2001-3000-O1' AND pi.status = 'Active'
  LOOP
    PERFORM public.backfill_archive_pod_inventory_row(
      r.pod_inventory_id,
      'PRD-067 phantom WH2-2001-3000-O1 write-off (phantom/expired stock, no WH credit)',
      NULL, v_caller);
  END LOOP;
END $$;

DELETE FROM public.product_mapping pm USING public.machines m
WHERE pm.machine_id = m.machine_id AND m.official_name = 'WH2-2001-3000-O1';

UPDATE public.machines SET status = 'Inactive'
WHERE official_name = 'WH2-2001-3000-O1' AND status = 'Warehouse';

-- 2. JET-2001-3000-O1 phantom (already Inactive): delete its 76 orphan product_mapping rows.
DELETE FROM public.product_mapping pm USING public.machines m
WHERE pm.machine_id = m.machine_id AND m.official_name = 'JET-2001-3000-O1';

-- 1. Sour Cream rename+delete: SKIPPED (see header). Held block for when the recon row is resolved:
--   (a) zero-ref scan of 285479a7, (b) DELETE shell, (c) rename 4edc4fbb -> 'Hunter Ridge - Sour Cream & Onion'.

DO $$
DECLARE v_pre numeric; v_post numeric;
BEGIN
  SELECT wh_total INTO v_pre FROM _prd067_wh_pre;
  SELECT COALESCE(SUM(warehouse_stock),0) INTO v_post FROM public.warehouse_inventory;
  IF v_post <> v_pre THEN
    RAISE EXCEPTION 'PRD-067 CONSERVATION VIOLATED: WH total changed pre=% post=%', v_pre, v_post;
  END IF;
  RAISE NOTICE 'PRD-067 OK: WH total unchanged (=%)', v_post;
END $$;
