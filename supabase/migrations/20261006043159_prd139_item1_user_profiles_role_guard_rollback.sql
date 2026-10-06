-- Rollback for 20261006043159_prd139_item1_user_profiles_role_guard.sql
-- Apply the 20261006043408 rollback first if that migration was also applied (it replaces
-- the same function body), or just run this -- DROP FUNCTION below removes it regardless.
DROP TRIGGER IF EXISTS trg_user_profiles_role_guard ON public.user_profiles;
DROP FUNCTION IF EXISTS public.user_profiles_role_guard();
DROP FUNCTION IF EXISTS public.is_admin(uuid);

REVOKE UPDATE (preferred_language, onboarding_complete, pages_toured) ON public.user_profiles FROM authenticated;
GRANT UPDATE, INSERT ON public.user_profiles TO authenticated;
