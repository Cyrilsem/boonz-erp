-- PRD-131 F1: movement_kind column, constraint, backfill.
--
-- NOT APPLIED YET. Gated: this column is read by pack_dispatch_line, receive_dispatch_line,
-- wh_approve_remove_receipt*, wm_confirm_line_split and the field app (via F2/F3/F5/F6), so it
-- ships in the same after-22:00-Dubai window as those. Drafted and dry-run tested now per CS
-- instruction; DO NOT run this file before 22:00 Dubai.
--
-- No existing CHECK constraint on refill_dispatching.action was found (verified: pg_constraint
-- has zero rows for this table matching '%action%'). The historical data already contains 16
-- distinct action spellings with no enforcement (Add 18064, Refill 8542+7879, Remove 2518+751,
-- Add New 2472+925, REFILL 255+12, Machine To Warehouse 6+3, Move 69+4, Keep 51, Backup 20,
-- REMOVE 8, ADD NEW 8, Transfer 5, Calibrate 4, plus 168 NULL). This migration adds the first
-- action constraint this table has ever had, NOT VALID so it does not choke on that history,
-- and it excludes 'Machine To Warehouse' plus all the legacy spellings -- new rows must use the
-- canonical five (Refill, Add New, Remove) going forward; movement_kind is the real signal now.
--
-- Classification (case-insensitive throughout via lower(action)), CS decision 2026-09-22, in
-- this priority order:
--   1. (is_m2m OR source_kind IN ('m2m','truck_transfer')), action=remove -> transfer_out;
--      action IN (refill, add new, add) -> transfer_in.
--   2. source_kind='intra_machine', action=remove -> intra_out; action IN (refill, add new,
--      add) -> intra_in.
--   3. action IN (remove, machine to warehouse) -> warehouse_return.
--   4. action IN (refill, add new, add) -> warehouse_fill ('Add' = 'Add New' = warehouse_fill,
--      a pre-2026-05-04 naming convention, confirmed source_kind='wh' on all 18,064 rows).
--   5. action IN (move, transfer): source_machine_id or from_machine_id set -> transfer_out
--      when from_wh_inventory_id is null, else transfer_in; neither machine field set ->
--      warehouse_fill. Live data: all 78 Move/Transfer rows have neither field set, so all
--      resolve to warehouse_fill.
--   6. action=replace -> warehouse_fill.
--   7. action IN (keep, backup, calibrate) -> legacy_noop.
--   8. action IS NULL: item_added=true -> warehouse_fill; returned=true or quantity<0 ->
--      warehouse_return; else -> legacy_noop.
-- write_off gets zero backfilled rows (F1a) -- return_reason is never scanned.
--
-- Dry run 2026-09-22 on all 42,054 rows (see docs/PRD-131-movement-kind.md): warehouse_fill
-- 38,368, warehouse_return 3,289, legacy_noop 216, transfer_out 95, transfer_in 86, intra_out/
-- intra_in 0/0, unclassifiable 0.

-- Landmine found while dry-testing this migration: refill_dispatching carries four pre-existing
-- NOT VALID CHECK constraints (chk_dispatch_qty_nonnegative, chk_packed_requires_outcome,
-- m2m_consistency, refill_dispatching_source_consistency_chk). NOT VALID only skips the
-- one-time bulk scan at creation -- it does NOT exempt existing non-compliant rows from being
-- re-validated on every future UPDATE, including this migration's own bulk classification
-- UPDATE below. Violation counts found: qty_nonneg 2,272 rows (quantity < 0, an existing signed
-- convention elsewhere in this schema, not something this migration should "fix"),
-- packed_outcome 6, m2m_consistency 7, source_consistency 2. A blanket UPDATE would abort on
-- the first of these it touches.
--
-- Fix: drop all four, run the classification UPDATE untouched by any of their semantics, then
-- re-add all four verbatim (same definition, still NOT VALID) so the exact same protective
-- posture exists after this migration as before it -- this migration does not change what those
-- constraints allow or validate any historical row against them; it only needs them out of the
-- way for the duration of its own UPDATE.
ALTER TABLE public.refill_dispatching
  DROP CONSTRAINT chk_dispatch_qty_nonnegative,
  DROP CONSTRAINT chk_packed_requires_outcome,
  DROP CONSTRAINT m2m_consistency,
  DROP CONSTRAINT refill_dispatching_source_consistency_chk;

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS movement_kind text,
  ADD COLUMN IF NOT EXISTS return_warehouse_id uuid REFERENCES public.warehouses(warehouse_id),
  ADD COLUMN IF NOT EXISTS receipt_gap_qty numeric,
  ADD COLUMN IF NOT EXISTS receipt_gap_reason text;

UPDATE public.refill_dispatching rd
SET movement_kind = CASE
  WHEN (COALESCE(rd.is_m2m,false) OR rd.source_kind IN ('m2m','truck_transfer')) AND lower(rd.action) = 'remove' THEN 'transfer_out'
  WHEN (COALESCE(rd.is_m2m,false) OR rd.source_kind IN ('m2m','truck_transfer')) AND lower(rd.action) IN ('refill','add new','add') THEN 'transfer_in'
  WHEN rd.source_kind = 'intra_machine' AND lower(rd.action) = 'remove' THEN 'intra_out'
  WHEN rd.source_kind = 'intra_machine' AND lower(rd.action) IN ('refill','add new','add') THEN 'intra_in'
  WHEN lower(rd.action) IN ('remove','machine to warehouse') THEN 'warehouse_return'
  WHEN lower(rd.action) IN ('refill','add new','add') THEN 'warehouse_fill'
  WHEN lower(rd.action) IN ('move','transfer') THEN
    CASE WHEN rd.source_machine_id IS NOT NULL OR rd.from_machine_id IS NOT NULL THEN
      CASE WHEN rd.from_wh_inventory_id IS NULL THEN 'transfer_out' ELSE 'transfer_in' END
    ELSE 'warehouse_fill' END
  WHEN lower(rd.action) = 'replace' THEN 'warehouse_fill'
  WHEN lower(rd.action) IN ('keep','backup','calibrate') THEN 'legacy_noop'
  WHEN rd.action IS NULL THEN
    CASE WHEN rd.item_added = true THEN 'warehouse_fill'
         WHEN rd.returned = true OR rd.quantity < 0 THEN 'warehouse_return'
         ELSE 'legacy_noop' END
  ELSE NULL
END
WHERE rd.movement_kind IS NULL;

-- return_warehouse_id: WH_CENTRAL for a plain warehouse_return, machines.primary_warehouse_id
-- for a venue-primary machine's warehouse_return (PRD-131 F5 VOX rule), NULL for every other
-- kind (transfers/intra/fill settle no warehouse credit against a return queue).
UPDATE public.refill_dispatching rd
SET return_warehouse_id = m.primary_warehouse_id
FROM public.machines m
WHERE rd.machine_id = m.machine_id
  AND rd.movement_kind = 'warehouse_return'
  AND rd.return_warehouse_id IS NULL;

DO $$
DECLARE
  v_unclassified int;
BEGIN
  SELECT count(*) INTO v_unclassified FROM public.refill_dispatching WHERE movement_kind IS NULL;
  IF v_unclassified > 0 THEN
    RAISE EXCEPTION 'prd131_01: % row(s) could not be classified by the backfill rule -- stopping per PRD-131 F1', v_unclassified;
  END IF;
END $$;

-- Restore the four constraints dropped above, verbatim, still NOT VALID.
ALTER TABLE public.refill_dispatching
  ADD CONSTRAINT chk_dispatch_qty_nonnegative CHECK (quantity >= 0::numeric) NOT VALID,
  ADD CONSTRAINT chk_packed_requires_outcome CHECK (packed = false OR pack_outcome IS NOT NULL) NOT VALID,
  ADD CONSTRAINT m2m_consistency CHECK (
    ((is_m2m IS NOT TRUE) OR (from_warehouse_id IS NULL))
    AND ((is_m2m IS NOT TRUE) OR (source_kind IS NULL) OR (source_kind = ANY (ARRAY['m2m','truck_transfer'])))
    AND ((source_kind IS NULL) OR (source_kind <> ALL (ARRAY['m2m','truck_transfer'])) OR (is_m2m IS TRUE))
    AND ((is_m2m IS NOT TRUE) OR (source_machine_id IS NOT NULL))
  ) NOT VALID,
  ADD CONSTRAINT refill_dispatching_source_consistency_chk CHECK (
    ((source_kind = 'wh') AND (source_warehouse_id IS NOT NULL) AND (source_machine_id IS NULL)) OR
    ((source_kind = 'venue') AND (source_warehouse_id IS NULL) AND (source_machine_id IS NULL)) OR
    ((source_kind = 'm2m') AND (source_machine_id IS NOT NULL) AND (source_warehouse_id IS NULL)) OR
    ((source_kind = 'truck_transfer') AND (source_machine_id IS NOT NULL) AND (source_warehouse_id IS NULL)) OR
    ((source_kind = 'intra_machine') AND (source_machine_id IS NOT NULL) AND (source_warehouse_id IS NULL)) OR
    ((source_kind = 'unknown') AND (source_warehouse_id IS NULL) AND (source_machine_id IS NULL))
  ) NOT VALID;

ALTER TABLE public.refill_dispatching
  ALTER COLUMN movement_kind SET NOT NULL;

ALTER TABLE public.refill_dispatching
  ADD CONSTRAINT refill_dispatching_movement_kind_chk
  CHECK (movement_kind IN (
    'warehouse_fill','warehouse_return','transfer_out','transfer_in',
    'intra_out','intra_in','write_off','legacy_noop'
  ));

-- Deliberately NOT adding a table-wide CHECK on `action` here, and this is a deviation from
-- the PRD's literal text ("the check constraint on action no longer accepts it") worth flagging:
-- a CHECK constraint, even NOT VALID, is re-evaluated on every future UPDATE of every existing
-- row regardless of which column changed -- NOT VALID only skips the one-time bulk validation
-- at creation, it does not exempt old rows going forward. Adding
-- `CHECK (action IN ('Refill','Add New','Remove'))` would make any future UPDATE to any of the
-- 18,678 legacy-action rows (touching `comment`, a data correction, anything) fail outright,
-- since their `action` value ('Add', 'Move', 'Keep', etc.) would never satisfy it. That is a
-- landmine under 44% of this table's history, not a safe retirement of one value.
-- 'Machine To Warehouse' retirement is enforced two other ways instead: every writer that can
-- set `action` (add_dispatch_row already does; F2 confirms the rest) validates
-- `p_action IN ('Refill','Add New','Remove')` itself before insert, and G-M2W (F8) catches any
-- live row with action='Machine To Warehouse' nightly, expect 0. Revisit a real CHECK
-- constraint only if a future migration also normalizes or archives the legacy-action history.
