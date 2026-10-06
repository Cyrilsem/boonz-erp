-- PRD-139 Item 1: role self-promotion fix
-- Problem (verified live via pg_policy/information_schema/pg_trigger before writing this):
--   user_profiles RLS has only the two CLAUDE.md-permitted policies (own_profile_select,
--   own_profile_update, both id = (SELECT auth.uid())) -- those are NOT touched by this migration.
--   But `authenticated` held full table-wide UPDATE/INSERT with zero column restriction and no
--   guard trigger existed, so any authenticated user could run
--   update user_profiles set role='superadmin' where id=auth.uid() and succeed.
--
-- Fix: column-level GRANT replacing table-wide UPDATE (role/id excluded), full REVOKE of INSERT
-- (no FE code inserts into user_profiles directly -- the only writer is handle_new_user(), a
-- SECURITY DEFINER trigger on auth.users owned by a privileged role, unaffected by revoking
-- `authenticated`'s grant), plus a BEFORE UPDATE/INSERT guard trigger using a new is_admin() helper.
--
-- RLS policies on user_profiles are NOT modified by this migration (CLAUDE.md constraint).
--
-- Client-writable columns confirmed via grep of src/ for .update("user_profiles") call sites:
--   preferred_language (field/page.tsx, field/profile), onboarding_complete (field/page.tsx),
--   pages_toured (use-page-tour.ts). role and id are excluded.
--
-- NOTE: see the immediately-following migration (20261006043408) for a same-window correction
-- to this trigger's UPDATE branch.

CREATE OR REPLACE FUNCTION public.is_admin(p_uid uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = p_uid AND role IN ('operator_admin', 'superadmin')
  );
$$;

REVOKE EXECUTE ON FUNCTION public.is_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_admin(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.user_profiles_role_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      IF current_user = 'service_role' OR public.is_admin(auth.uid()) THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'role change not allowed';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF current_user = 'service_role' OR public.is_admin(auth.uid()) THEN
      RETURN NEW;
    END IF;
    IF auth.uid() IS NULL THEN
      RETURN NEW;
    END IF;
    IF NEW.role IS DISTINCT FROM 'field_staff' THEN
      RAISE EXCEPTION 'role change not allowed';
    END IF;
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_profiles_role_guard ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_role_guard
  BEFORE INSERT OR UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.user_profiles_role_guard();

REVOKE UPDATE, INSERT ON public.user_profiles FROM authenticated;
GRANT UPDATE (preferred_language, onboarding_complete, pages_toured) ON public.user_profiles TO authenticated;
