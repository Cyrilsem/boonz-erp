-- VOX reports: site attribution becomes time-aware (machine eras split at repurposed_at),
-- and Dubai Festival City is added as a site. Existing machines whose site never changed
-- keep identical output (same name, same site).

CREATE OR REPLACE FUNCTION public.vox_site_label(p_pod_location text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_pod_location ILIKE '%Mercato%'  THEN 'Mercato'
              WHEN p_pod_location ILIKE '%Mirdi%'    THEN 'Mirdif'
              WHEN p_pod_location ILIKE '%Festival%' THEN 'Festival City'
              ELSE 'Other' END
$$;

CREATE OR REPLACE FUNCTION public.vox_site_from_name(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_name ~* 'MCC[-_]' THEN 'Mirdif'
              WHEN p_name ~* 'MM[-_]'  THEN 'Mercato'
              WHEN p_name ~* 'DFC[-_]' THEN 'Festival City'
              ELSE NULL END
$$;

-- One row per identity era of a machine. Pre-cutover era keeps the old name only when the site changed.
CREATE OR REPLACE FUNCTION public.vox_machine_eras(p_machine_id uuid)
RETURNS TABLE(era_name text, site text, era_from date, era_to date)
LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT m.official_name, vox_site_label(m.pod_location),
         COALESCE(m.repurposed_at, '-infinity'::date), 'infinity'::date
  FROM machines m WHERE m.machine_id = p_machine_id
  UNION ALL
  SELECT CASE WHEN ps.s IS NOT NULL AND ps.s <> vox_site_label(m.pod_location)
              THEN m.previous_location ELSE m.official_name END,
         COALESCE(ps.s, vox_site_label(m.pod_location)),
         '-infinity'::date, m.repurposed_at
  FROM machines m CROSS JOIN LATERAL (SELECT vox_site_from_name(m.previous_location) AS s) ps
  WHERE m.machine_id = p_machine_id AND m.repurposed_at IS NOT NULL
$$;

DO $patch$
DECLARE
  fn text; d text; d0 text;
  old_case text := $s$CASE WHEN m.pod_location ILIKE '%Mercato%' THEN 'Mercato'
           WHEN m.pod_location ILIKE '%Mirdi%'   THEN 'Mirdif' ELSE 'Other' END AS site
    FROM machines m WHERE m.venue_group = 'VOX' AND m.status = 'Active'$s$;
  new_case text := $s$e.site, e.era_from, e.era_to
    FROM machines m CROSS JOIN LATERAL vox_machine_eras(m.machine_id) e
    WHERE m.venue_group = 'VOX' AND m.status = 'Active'$s$;
  old_join text := 'JOIN selected_machines sm ON sm.machine_id = sh.machine_id';
  new_join text := 'JOIN selected_machines sm ON sm.machine_id = sh.machine_id AND sh.transaction_date::date >= sm.era_from AND sh.transaction_date::date < sm.era_to';
  old_def text := $s$DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text]$s$;
  new_def text := $s$DEFAULT ARRAY['Mercato'::text, 'Mirdif'::text, 'Festival City'::text]$s$;
BEGIN
  FOREACH fn IN ARRAY ARRAY['get_vox_commercial_report','get_vox_commercial_txn_lines','get_vox_consumer_report'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname=fn;
    d0 := d;
    IF position(old_case in d)=0 OR position(old_join in d)=0 OR position(old_def in d)=0 THEN
      RAISE EXCEPTION 'patch anchor missing in %', fn;
    END IF;
    d := replace(d, old_case, new_case);
    d := replace(d, old_join, new_join);
    d := replace(d, old_def, new_def);
    d := replace(d, 'SELECT m.machine_id, m.official_name AS machine_name,', 'SELECT m.machine_id, e.era_name AS machine_name,');
    d := replace(d, 'SELECT m.machine_id, m.official_name,', 'SELECT m.machine_id, e.era_name AS official_name,');
    IF fn = 'get_vox_consumer_report' THEN
      IF position($s$'Mirdif' AND psp_reference IS NOT NULL), 0))
    ) AS data$s$ in d)=0 THEN RAISE EXCEPTION 'summary anchor missing'; END IF;
      d := replace(d, $s$'Mirdif' AND psp_reference IS NOT NULL), 0))
    ) AS data$s$, $s$'Mirdif' AND psp_reference IS NOT NULL), 0)),
      'festival_city', jsonb_build_object('total', COALESCE(SUM(total_amount) FILTER (WHERE site = 'Festival City'), 0),
        'txns', COUNT(*) FILTER (WHERE site = 'Festival City'), 'units', COALESCE(SUM(qty) FILTER (WHERE site = 'Festival City'), 0),
        'captured', COALESCE(SUM(captured) FILTER (WHERE site = 'Festival City' AND psp_reference IS NOT NULL), 0))
    ) AS data$s$);
    END IF;
    IF d = d0 THEN RAISE EXCEPTION 'no change for %', fn; END IF;
    EXECUTE d;
  END LOOP;
END
$patch$;