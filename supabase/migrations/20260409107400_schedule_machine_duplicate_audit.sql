-- CC-09d: Daily audit function + cron for machine duplicate detection.
-- The unique index should prevent new duplicates, but this cron provides
-- belt-and-suspenders alerting via pg_cron warning logs.
CREATE OR REPLACE FUNCTION public.audit_machine_duplicates()
RETURNS TABLE(official_name text, duplicate_count int, machine_ids uuid[])
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    official_name,
    COUNT(*)::int                             AS duplicate_count,
    ARRAY_AGG(machine_id ORDER BY created_at) AS machine_ids
  FROM public.machines
  WHERE repurposed_at IS NULL
  GROUP BY official_name
  HAVING COUNT(*) > 1;
$$;

REVOKE ALL ON FUNCTION public.audit_machine_duplicates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.audit_machine_duplicates() TO service_role, authenticated;

COMMENT ON FUNCTION public.audit_machine_duplicates() IS
'Returns active (non-repurposed) machines with duplicate official_name. Should always return 0 rows given the machines_official_name_unique_active index.';

-- Schedule daily at 06:00 Dubai (02:00 UTC)
SELECT cron.schedule(
  'daily-machine-duplicate-audit',
  '0 2 * * *',
  $$
  DO $inner$
  BEGIN
    IF EXISTS (SELECT 1 FROM public.audit_machine_duplicates()) THEN
      RAISE WARNING 'Machine duplicate audit found duplicates — check pg_cron logs and run SELECT * FROM public.audit_machine_duplicates()';
    END IF;
  END;
  $inner$;
  $$
);
