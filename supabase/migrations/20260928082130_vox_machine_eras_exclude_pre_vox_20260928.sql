-- Pre-cutover era whose previous identity is not a VOX site (e.g. LLFP event on the 2006 cabinet)
-- is labelled 'Pre-VOX' so it never lands in a VOX site bucket. previous_location NULL keeps legacy behaviour.
CREATE OR REPLACE FUNCTION public.vox_machine_eras(p_machine_id uuid)
RETURNS TABLE(era_name text, site text, era_from date, era_to date)
LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT m.official_name, vox_site_label(m.pod_location),
         COALESCE(m.repurposed_at, '-infinity'::date), 'infinity'::date
  FROM machines m WHERE m.machine_id = p_machine_id
  UNION ALL
  SELECT CASE WHEN m.previous_location IS NOT NULL
                   AND COALESCE(ps.s, 'Pre-VOX') <> vox_site_label(m.pod_location)
              THEN m.previous_location ELSE m.official_name END,
         CASE WHEN ps.s IS NOT NULL THEN ps.s
              WHEN m.previous_location IS NULL THEN vox_site_label(m.pod_location)
              ELSE 'Pre-VOX' END,
         '-infinity'::date, m.repurposed_at
  FROM machines m CROSS JOIN LATERAL (SELECT vox_site_from_name(m.previous_location) AS s) ps
  WHERE m.machine_id = p_machine_id AND m.repurposed_at IS NOT NULL
$$;