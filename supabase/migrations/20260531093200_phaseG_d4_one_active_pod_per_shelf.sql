-- PRD-015 Phase D / AC#6 — one-Active-row-per-shelf integrity.
-- MUST run LAST, only AFTER reconcile_pod_inventory_shelf has cleared every multi_active_rows
-- shelf (AC#5/#7). As of 2026-05-31 there are ~279 multi-active shelves, so this index WOULD
-- FAIL today. The pre-check below raises a clear message instead of a cryptic unique violation.
-- NOT YET APPLIED. Apply only when v_pod_inventory_shelf_mismatch shows zero 'multi_active_rows'.

DO $$
DECLARE v_dupes int;
BEGIN
  SELECT COUNT(*) INTO v_dupes FROM (
    SELECT machine_id, shelf_id FROM public.pod_inventory
    WHERE status = 'Active' AND shelf_id IS NOT NULL
    GROUP BY machine_id, shelf_id HAVING COUNT(*) > 1
  ) d;
  IF v_dupes > 0 THEN
    RAISE EXCEPTION 'Cannot add uniq_active_pod_per_shelf: % shelf(es) still have >1 Active pod_inventory row. Reconcile them first via reconcile_pod_inventory_shelf (AC#5/#7).', v_dupes;
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_active_pod_per_shelf
  ON public.pod_inventory (machine_id, shelf_id)
  WHERE status = 'Active';
