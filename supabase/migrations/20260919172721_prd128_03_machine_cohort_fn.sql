-- PRD-128 step 03: the cohort classifier. partner_filled must win over co_managed -- a
-- co_managed machine serviced by a partner is a partner machine for this purpose, not a
-- VOX one. Order matters and is exactly as specified: partner check first (either input can
-- trigger it), then co_managed, then fully_managed, else unclassified.

CREATE OR REPLACE FUNCTION public.machine_cohort(p_operating_model text, p_service_model text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_operating_model = 'partner_managed' OR p_service_model = 'partner_filled' THEN 'partner'
    WHEN p_operating_model = 'co_managed' THEN 'vox'
    WHEN p_operating_model = 'fully_managed' THEN 'boonz'
    ELSE 'unclassified'
  END;
$function$;

REVOKE ALL ON FUNCTION public.machine_cohort(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.machine_cohort(text, text) TO authenticated;
