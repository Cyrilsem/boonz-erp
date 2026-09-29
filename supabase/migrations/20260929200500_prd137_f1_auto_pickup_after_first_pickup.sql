-- PRD-137 F1, 2026-09-29/30: mark_picked_up only flips picked_up=true for the exact dispatch_ids
-- the FE passes at button-press time. Any line packed AFTER that press for the same machine and
-- date (a later M2M leg confirmation, an operator-added row via add_dispatch_row, a second pack
-- batch) never gets picked_up, and nothing else ever revisits it. Evidence tonight: mark_picked_up
-- pressed once per machine at 08:47, CS had to press it again manually at 09:34 for 35 lines that
-- packed in between.
--
-- Fix: once a machine/date has ANY picked_up=true row, treat pickup as already in progress for
-- that visit -- any row that becomes packed=true afterward (via UPDATE or, for M2M destination
-- legs and add_dispatch_row lines that are inserted already packed, via INSERT) is auto marked
-- picked_up=true too. Invariant target: no row packed=true, picked_up=false for a machine that
-- already has a picked_up=true row that day.
--
-- Rollback: supabase/rollback/20260929200500_prd137_f1_auto_pickup_after_first_pickup_rollback.sql
CREATE OR REPLACE FUNCTION public.tg_auto_pickup_after_first_pickup()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.refill_dispatching d
     WHERE d.machine_id = NEW.machine_id
       AND d.dispatch_date = NEW.dispatch_date
       AND d.dispatch_id <> NEW.dispatch_id
       AND d.picked_up = true
  ) THEN
    PERFORM set_config('app.via_trigger', 'true', true);
    UPDATE public.refill_dispatching
       SET picked_up = true
     WHERE dispatch_id = NEW.dispatch_id;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_auto_pickup_on_insert
  AFTER INSERT ON public.refill_dispatching
  FOR EACH ROW
  WHEN (NEW.packed = true AND COALESCE(NEW.picked_up,false) = false)
  EXECUTE FUNCTION public.tg_auto_pickup_after_first_pickup();

CREATE TRIGGER trg_auto_pickup_on_pack
  AFTER UPDATE OF packed ON public.refill_dispatching
  FOR EACH ROW
  WHEN (NEW.packed = true AND OLD.packed IS DISTINCT FROM true AND COALESCE(NEW.picked_up,false) = false)
  EXECUTE FUNCTION public.tg_auto_pickup_after_first_pickup();

-- One-time backfill: correct historical rows already violating the invariant (packed and
-- delivered in reality, since their machine/date already has other picked_up rows, but never
-- flipped themselves -- all from May-Aug 2026, no rows from tonight since CS already manually
-- re-ran mark_picked_up for tonight's 35 lines at 09:34).
--
-- Excludes rows with pack_outcome IS NULL: a handful of these old rows also violate the
-- separate, pre-existing NOT VALID constraint chk_packed_requires_outcome (packed=true with no
-- pack_outcome). Touching pack_outcome is a different, unrelated data-quality question this
-- migration does not attempt to answer; those rows are left for a dedicated pass and flagged in
-- the run report instead.
DO $backfill$
BEGIN
  PERFORM set_config('app.via_trigger', 'true', true);
  UPDATE public.refill_dispatching rd
     SET picked_up = true
   WHERE rd.packed = true AND COALESCE(rd.picked_up,false) = false
     AND rd.pack_outcome IS NOT NULL
     AND COALESCE(rd.cancelled,false) = false AND COALESCE(rd.skipped,false) = false
     AND EXISTS (
       SELECT 1 FROM public.refill_dispatching d2
        WHERE d2.machine_id = rd.machine_id AND d2.dispatch_date = rd.dispatch_date
          AND d2.dispatch_id <> rd.dispatch_id AND d2.picked_up = true
     );
END;
$backfill$;
