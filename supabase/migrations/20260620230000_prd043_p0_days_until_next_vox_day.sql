-- PRD-043 P0: days_until_next_vox_day(date) helper for the picker v11 VOX calendar gate (Option B).
-- IMMUTABLE, no table access: returns the day count from p_plan_date to the next Wed (DOW 3) or
-- Fri (DOW 5). 0 if p_plan_date is itself Wed/Fri (the normal-day branch is not reached then, so the
-- override never uses 0). Never NULL: every 7-day window contains a Wed and a Fri.
-- Forward-only. No protected entity touched.
CREATE OR REPLACE FUNCTION public.days_until_next_vox_day(p_plan_date date)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT MIN(d)::int
    FROM generate_series(0, 6) AS d
   WHERE EXTRACT(DOW FROM p_plan_date + d) IN (3, 5);
$function$;

REVOKE ALL ON FUNCTION public.days_until_next_vox_day(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.days_until_next_vox_day(date) TO authenticated, service_role;
