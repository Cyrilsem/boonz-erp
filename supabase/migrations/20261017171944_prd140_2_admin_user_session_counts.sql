-- PRD-140 Item 2 support: the admin-users edge function's list action needs
-- an open-session count per user. auth.sessions is not exposed via PostgREST
-- (only public is), so this is a small service_role-only helper instead of
-- querying it directly from the edge function.
CREATE OR REPLACE FUNCTION public.admin_user_session_counts()
RETURNS TABLE(user_id uuid, open_sessions int)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT s.user_id, count(*)::int
  FROM auth.sessions s
  WHERE s.not_after IS NULL OR s.not_after > now()
  GROUP BY s.user_id;
$function$;

REVOKE ALL ON FUNCTION public.admin_user_session_counts() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_user_session_counts() TO service_role;
