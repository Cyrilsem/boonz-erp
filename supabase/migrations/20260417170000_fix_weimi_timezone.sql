-- Fix Weimi timezone handling.
--
-- Problem:
--   Weimi uploads arrive with wall-clock timestamps in Dubai local time but no
--   timezone offset. `process_weimi_staging` runs under the default session
--   timezone (UTC), so its `::timestamptz` cast was interpreting each raw value
--   as UTC and storing it 4h off from reality. All 2026 rows with
--   `internal_txn_sn IS NOT NULL` are shifted 4 hours forward vs. actual
--   Dubai wall-clock.
--
-- Fix (two parts):
--   1. Pin the function's session timezone to 'Asia/Dubai' so future uploads
--      interpret the raw string correctly.
--   2. Backfill the 2026 rows already in sales_history:
--        corrected = (stored_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Dubai'
--      This strips the (wrong) UTC tag and re-applies Dubai, yielding the
--      correct UTC instant for the Dubai wall-clock the operator actually saw.
--
-- Trigger safety:
--   sales_history has `prevent_duplicate_txn_forms_trigger` BEFORE UPDATE
--   that can either return NULL (silently drop the update) when a suffixed
--   sibling exists, or DELETE the bare sibling when a suffixed row is updated.
--   Both behaviours are destructive during a bulk timestamp-only backfill,
--   so we disable that one trigger for the UPDATE and re-enable after.
--   The other BEFORE trigger (`trg_auto_fill_machine_mapping`) is safe: it
--   only writes machine_mapping when it is NULL, and our UPDATE does not
--   touch that column.

BEGIN;

-- 1. Pin function timezone for future invocations
ALTER FUNCTION public.process_weimi_staging(text, boolean)
  SET timezone = 'Asia/Dubai';

-- 2. Disable the duplicate-prevention trigger for the backfill only
ALTER TABLE public.sales_history
  DISABLE TRIGGER prevent_duplicate_txn_forms_trigger;

-- 3. Backfill 2026 Weimi rows (8,110 rows: 554 bare + 7,556 suffixed)
UPDATE public.sales_history
SET
  delivery_finished_time = (delivery_finished_time AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Dubai',
  transaction_date       = (transaction_date       AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Dubai'
WHERE internal_txn_sn IS NOT NULL
  AND ((delivery_finished_time AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Dubai') >= '2026-01-01'
  AND ((delivery_finished_time AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Dubai') <  '2026-04-16';

-- 4. Re-enable the duplicate-prevention trigger
ALTER TABLE public.sales_history
  ENABLE TRIGGER prevent_duplicate_txn_forms_trigger;

COMMIT;
