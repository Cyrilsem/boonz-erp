-- Pin session timezone to Asia/Dubai for the VOX report RPCs.
--
-- Bug: get_vox_consumer_report and get_vox_commercial_report format
-- timestamptz values via to_char(), ::date, EXTRACT(HOUR/ISODOW/…),
-- and date_trunc('week', …) without a timezone. In a UTC session
-- (Supabase default) a 20:40 Asia/Dubai transaction renders as 16:40,
-- and near-midnight rows bucket into the wrong Dubai day/week/hour.
--
-- The underlying TIMESTAMPTZ storage is correct (UTC instants). The
-- fix is purely display-side: pin the session TZ for just these two
-- functions so every format helper resolves in Dubai-local time.
--
-- Other candidate functions were reviewed and left alone:
--   * get_operational_signals, get_daily_sales_summary: already pin Dubai
--     explicitly where they format output.
--   * get_machine_health, get_machine_slots_with_expiry,
--     get_sales_by_machine: use rolling NOW() - interval windows that
--     are timezone-agnostic.
--   * process_weimi_staging: already has TimeZone=Asia/Dubai.
--   * import_adyen_batch, process_adyen_staging, upsert_daily_sales,
--     upsert_sales_lines, auto_decrement_pod_inventory: write paths,
--     intentionally untouched.

ALTER FUNCTION public.get_vox_consumer_report(text[], boolean, date, date)
  SET timezone = 'Asia/Dubai';

ALTER FUNCTION public.get_vox_commercial_report(text[], date, date)
  SET timezone = 'Asia/Dubai';
