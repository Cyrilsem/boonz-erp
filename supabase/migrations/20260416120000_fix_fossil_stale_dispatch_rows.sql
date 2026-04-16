-- Purpose:
--   1. Revive fossil refill_dispatching rows where a prior manual SQL
--      cleanup set include=false with comment "[STALE DUPLICATE - superseded]".
--      These rows represent real packed stock and belong in the dispatch UI.
--   2. Install a guard trigger preventing future duplicate UNSTARTED plan
--      rows on the same (machine, shelf, product, action, date). Slice rows
--      (filled_quantity > 0) remain allowed — that is the app's intentional
--      multi-batch expiry model.
-- Scope: DB only. No app code changes.

-- 1. Repair today's fossil rows
UPDATE refill_dispatching
SET include = true,
    comment = trim(
      regexp_replace(
        COALESCE(comment, ''),
        E'\\s*\\[STALE DUPLICATE[\\s\\u2013\\u2014\\-]+superseded\\]\\s*',
        '',
        'g'
      )
    )
WHERE dispatch_date = CURRENT_DATE
  AND comment LIKE '%STALE DUPLICATE%';

-- 2. Fleet-wide sweep: revive packed fossil rows from any date
UPDATE refill_dispatching
SET include = true,
    comment = trim(
      regexp_replace(
        COALESCE(comment, ''),
        E'\\s*\\[STALE DUPLICATE[\\s\\u2013\\u2014\\-]+superseded\\]\\s*',
        '',
        'g'
      )
    )
WHERE comment LIKE '%STALE DUPLICATE%'
  AND include = false
  AND packed = true;

-- 3. Guard trigger
CREATE OR REPLACE FUNCTION prevent_duplicate_unstarted_dispatch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.include = true
     AND COALESCE(NEW.filled_quantity, 0) = 0
     AND NEW.action IN ('Refill', 'Add New') THEN
    IF EXISTS (
      SELECT 1
      FROM refill_dispatching
      WHERE machine_id       = NEW.machine_id
        AND shelf_id         = NEW.shelf_id
        AND boonz_product_id = NEW.boonz_product_id
        AND dispatch_date    = NEW.dispatch_date
        AND action           = NEW.action
        AND include          = true
        AND COALESCE(filled_quantity, 0) = 0
        AND dispatch_id     != COALESCE(NEW.dispatch_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) THEN
      RAISE EXCEPTION
        'Duplicate unstarted dispatch row for (machine=%, shelf=%, product=%, action=%, date=%). Use slice rows (filled_quantity > 0) for multi-batch packs.',
        NEW.machine_id, NEW.shelf_id, NEW.boonz_product_id, NEW.action, NEW.dispatch_date;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_duplicate_unstarted_dispatch ON refill_dispatching;
CREATE TRIGGER trg_prevent_duplicate_unstarted_dispatch
  BEFORE INSERT OR UPDATE ON refill_dispatching
  FOR EACH ROW
  EXECUTE FUNCTION prevent_duplicate_unstarted_dispatch();
