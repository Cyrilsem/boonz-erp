-- ONE-LOOP-2 Block E: migration window alert. supabase_migrations.schema_
-- migrations has no applied-at timestamp column -- version IS the
-- timestamp (the migration's own YYYYMMDDHHMMSS identifier, assigned at
-- apply time by the migration tool, not by the filename chosen when
-- writing it -- see DECISIONS-2026-09-15.md D-024 for what this session
-- found out about that). Parsed as a UTC timestamp and converted to Dubai
-- local time, this is what "when did a migration land" means here.
--
-- State table remembers the highest version already checked, so each
-- 5-minute run only looks at genuinely new rows. Every new row whose
-- Dubai-local time of day falls in 06:00-22:00 raises one
-- monitoring_alerts row (migration_in_window). Rows outside that window
-- (the legitimate 22:00-06:00 deploy window) raise nothing.
CREATE TABLE IF NOT EXISTS public.migration_window_alert_state (
  id                    int PRIMARY KEY DEFAULT 1,
  last_checked_version  text NOT NULL DEFAULT '00000000000000',
  CONSTRAINT migration_window_alert_state_singleton CHECK (id = 1)
);
INSERT INTO public.migration_window_alert_state (id, last_checked_version)
VALUES (1, (SELECT COALESCE(MAX(version), '00000000000000') FROM supabase_migrations.schema_migrations))
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.migration_window_alert_state ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.migration_window_alert_state FROM authenticated;
GRANT SELECT ON public.migration_window_alert_state TO authenticated;
DROP POLICY IF EXISTS migration_window_alert_state_select ON public.migration_window_alert_state;
CREATE POLICY migration_window_alert_state_select ON public.migration_window_alert_state
  FOR SELECT TO authenticated USING (true);

CREATE OR REPLACE FUNCTION public.cron_migration_window_alert()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_last text;
  v_new_max text;
  v_alerted int := 0;
  v_checked int := 0;
  r record;
  v_applied_at timestamptz;
  v_dubai_time time;
BEGIN
  SELECT last_checked_version INTO v_last FROM public.migration_window_alert_state WHERE id = 1;

  FOR r IN
    SELECT version, name FROM supabase_migrations.schema_migrations
     WHERE version > v_last ORDER BY version
  LOOP
    v_checked := v_checked + 1;
    BEGIN
      v_applied_at := to_timestamp(r.version, 'YYYYMMDDHH24MISS') AT TIME ZONE 'UTC';
    EXCEPTION WHEN OTHERS THEN
      CONTINUE;
    END;
    v_dubai_time := (v_applied_at AT TIME ZONE 'Asia/Dubai')::time;
    IF v_dubai_time >= '06:00'::time AND v_dubai_time < '22:00'::time THEN
      INSERT INTO public.monitoring_alerts(source, severity, payload)
      VALUES ('migration_in_window', 'warning', jsonb_build_object(
        'title', format('Migration %s (%s) landed inside the 06:00-22:00 Dubai window', r.version, r.name),
        'version', r.version, 'name', r.name,
        'applied_at_utc', v_applied_at, 'dubai_local_time', v_dubai_time,
        'detected_at', now()));
      v_alerted := v_alerted + 1;
    END IF;
  END LOOP;

  SELECT COALESCE(MAX(version), v_last) INTO v_new_max FROM supabase_migrations.schema_migrations;
  UPDATE public.migration_window_alert_state SET last_checked_version = v_new_max WHERE id = 1;

  RETURN jsonb_build_object('checked', v_checked, 'alerted', v_alerted, 'last_checked_version', v_new_max);
END;
$function$;

SELECT cron.schedule('migration_window_alert', '*/5 * * * *',
  $cron$SELECT public.cron_migration_window_alert();$cron$);
