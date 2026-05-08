-- Defensive TZ pin on functions that cast naked timestamps to timestamptz.
-- Mirrors process_weimi_staging (fixed 2026-04-17), extending the same defense
-- to the rest of the timestamp-handling SECURITY DEFINER surface.
--
-- Why these four functions:
--   - upsert_sales_lines:    called by refresh-stage1 edge function. Edge fn
--                            already converts to ISO UTC ("Z" suffix) so this
--                            is currently a no-op, but prevents 4h-shift if a
--                            future caller sends naked Dubai-local strings.
--   - upsert_daily_sales:    called by n8n. Same defense rationale.
--   - process_adyen_staging: Adyen export uses naked Dubai-local timestamps
--                            with TimeZone='GST' as a separate column. The
--                            function casts them ::timestamptz under the
--                            session TZ. With session=UTC, every row was being
--                            tagged 4h forward of reality. Pinning fixes
--                            future inserts.
--   - import_adyen_batch:    sibling of process_adyen_staging, same risk.
--
-- This is DDL on function attributes only — no data backfill, no row movement.

ALTER FUNCTION public.upsert_daily_sales(jsonb)
  SET timezone = 'Asia/Dubai';

ALTER FUNCTION public.upsert_sales_lines(jsonb)
  SET timezone = 'Asia/Dubai';

ALTER FUNCTION public.process_adyen_staging(text, boolean)
  SET timezone = 'Asia/Dubai';

ALTER FUNCTION public.import_adyen_batch(jsonb)
  SET timezone = 'Asia/Dubai';

COMMENT ON FUNCTION public.upsert_daily_sales(jsonb) IS
  'Called by n8n with JSON array of items. Resolves machine IDs, upserts to sales_history, refreshes matview. SECURITY DEFINER = no service key needed by caller. Pinned to Asia/Dubai timezone (defensive: prevents 4h-shift if callers ever send naked timestamps).';

COMMENT ON FUNCTION public.upsert_sales_lines(jsonb) IS
  'Called by refresh-stage1 edge function. Upserts sales_history rows from JSON. Pinned to Asia/Dubai timezone (defensive: edge function currently sends ISO UTC strings so this is a no-op, but prevents 4h-shift if a future caller sends naked Dubai-local strings).';

COMMENT ON FUNCTION public.process_adyen_staging(text, boolean) IS
  'ETL: maps native Adyen export columns from adyen_staging to adyen_transactions. Adyen export naked timestamps are Dubai-local (TimeZone column = ''GST''). Pinned to Asia/Dubai so naked casts interpret correctly. Processes SettledBulk and RefundedBulk only.';
