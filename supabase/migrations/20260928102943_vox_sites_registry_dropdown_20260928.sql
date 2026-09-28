-- VOX sites become data: add a row to vox_sites to open a new location. No code change needed.
CREATE TABLE IF NOT EXISTS public.vox_sites (
  site              text PRIMARY KEY,
  pod_location_like text NOT NULL,   -- ILIKE pattern on machines.pod_location
  name_regex        text NOT NULL,   -- regex on official/previous names (e.g. 'DFC[-_]')
  sort_order        int  NOT NULL DEFAULT 100,
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.vox_sites ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vox_sites_read ON public.vox_sites;
CREATE POLICY vox_sites_read ON public.vox_sites FOR SELECT TO authenticated USING (true);

INSERT INTO public.vox_sites (site, pod_location_like, name_regex, sort_order) VALUES
  ('Mercato',       '%Mercato%',  'MM[-_]',  10),
  ('Mirdif',        '%Mirdi%',    'MCC[-_]', 20),
  ('Festival City', '%Festival%', 'DFC[-_]', 30)
ON CONFLICT (site) DO NOTHING;

CREATE OR REPLACE FUNCTION public.vox_site_label(p_pod_location text)
RETURNS text LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT COALESCE((SELECT s.site FROM vox_sites s WHERE p_pod_location ILIKE s.pod_location_like
                   ORDER BY s.sort_order LIMIT 1), 'Other')
$$;

CREATE OR REPLACE FUNCTION public.vox_site_from_name(p_name text)
RETURNS text LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT s.site FROM vox_sites s WHERE p_name ~* s.name_regex ORDER BY s.sort_order LIMIT 1
$$;

-- Dropdown source: active sites that have (or had) at least one VOX machine
CREATE OR REPLACE FUNCTION public.get_vox_sites()
RETURNS TABLE(site text, sort_order int, active_machines int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT s.site, s.sort_order,
    (SELECT COUNT(*)::int FROM machines m WHERE m.venue_group='VOX' AND m.status='Active'
       AND vox_site_label(m.pod_location) = s.site)
  FROM vox_sites s WHERE s.is_active ORDER BY s.sort_order
$$;
GRANT EXECUTE ON FUNCTION public.get_vox_sites() TO authenticated;

-- Reports: p_pods NULL = all sites; consumer summary gains a generic by_site array (legacy keys kept)
DO $patch$
DECLARE fn text; d text; d0 text;
  old_f text := 'selected_machines AS (SELECT * FROM vox_machines WHERE site = ANY(p_pods))';
  new_f text := 'selected_machines AS (SELECT * FROM vox_machines WHERE (p_pods IS NULL OR site = ANY(p_pods)))';
  old_s text := $s$    ) AS data FROM vox_joined
  ),$s$;
  new_s text := $s$,
      'by_site', (SELECT COALESCE(jsonb_agg(jsonb_build_object('site', bs.site, 'total', bs.total, 'txns', bs.txns,
                    'units', bs.units, 'captured', bs.captured) ORDER BY bs.site), '[]'::jsonb)
                  FROM (SELECT site, SUM(total_amount) AS total, COUNT(*) AS txns, COALESCE(SUM(qty),0) AS units,
                          COALESCE(SUM(captured) FILTER (WHERE psp_reference IS NOT NULL),0) AS captured
                        FROM vox_joined GROUP BY site) bs)
    ) AS data FROM vox_joined
  ),$s$;
BEGIN
  FOREACH fn IN ARRAY ARRAY['get_vox_commercial_report','get_vox_commercial_txn_lines','get_vox_consumer_report'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname=fn;
    d0 := d;
    IF position(old_f in d)=0 THEN RAISE EXCEPTION 'filter anchor missing in %', fn; END IF;
    d := replace(d, old_f, new_f);
    IF fn='get_vox_consumer_report' THEN
      IF position(old_s in d)=0 THEN RAISE EXCEPTION 'summary anchor missing'; END IF;
      d := replace(d, old_s, new_s);
    END IF;
    IF d=d0 THEN RAISE EXCEPTION 'no change %', fn; END IF;
    EXECUTE d;
  END LOOP;
END $patch$;