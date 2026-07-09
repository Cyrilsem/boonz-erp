-- PRD-087 PERF/FIX: anon statement_timeout is 3s but get_machine_health
-- runs 2-5s → the FE server-cache fetch timed out and the refill heatmap /
-- dashboard ops arrived empty. Fix: a tiny DB-side snapshot table refreshed
-- by pg_cron AS POSTGRES (no API timeout); readers return instantly.
-- Own cache table only — no protected entity touched.
CREATE TABLE IF NOT EXISTS public.app_cache (
  cache_key text PRIMARY KEY,
  payload jsonb NOT NULL,
  refreshed_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.app_cache ENABLE ROW LEVEL SECURITY;
-- no policies: table is reached only through the SECURITY DEFINER readers

CREATE OR REPLACE FUNCTION public.refresh_app_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.app_cache (cache_key, payload, refreshed_at)
  VALUES (
    'machine_health',
    COALESCE((SELECT jsonb_agg(to_jsonb(h)) FROM public.get_machine_health() h), '[]'::jsonb),
    now()
  )
  ON CONFLICT (cache_key)
  DO UPDATE SET payload = EXCLUDED.payload, refreshed_at = EXCLUDED.refreshed_at;

  INSERT INTO public.app_cache (cache_key, payload, refreshed_at)
  VALUES ('dashboard_ops', public.get_dashboard_ops(), now())
  ON CONFLICT (cache_key)
  DO UPDATE SET payload = EXCLUDED.payload, refreshed_at = EXCLUDED.refreshed_at;
END;
$$;

-- instant readers (SECURITY DEFINER so anon/authenticated can use them)
CREATE OR REPLACE FUNCTION public.get_machine_health_cached()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object('refreshed_at', refreshed_at, 'rows', payload)
     FROM public.app_cache WHERE cache_key = 'machine_health'),
    jsonb_build_object('refreshed_at', NULL, 'rows', '[]'::jsonb)
  );
$$;

CREATE OR REPLACE FUNCTION public.get_dashboard_ops_cached()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT payload || jsonb_build_object('cache_refreshed_at', refreshed_at)
     FROM public.app_cache WHERE cache_key = 'dashboard_ops'),
    NULL
  );
$$;

-- refresh every 2 minutes as postgres (no API statement timeout)
SELECT cron.schedule(
  'refresh_app_cache',
  '*/2 * * * *',
  $$SELECT public.refresh_app_cache()$$
);

-- prime it now
SELECT public.refresh_app_cache();

COMMENT ON TABLE public.app_cache IS
'PRD-087: 2-min snapshots of heavy read aggregates (machine_health, dashboard_ops) so API-role timeouts (anon 3s) never blank the FE.';
