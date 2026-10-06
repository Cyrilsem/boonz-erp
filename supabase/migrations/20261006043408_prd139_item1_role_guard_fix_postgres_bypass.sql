-- Correction to 20261006043159_prd139_item1_user_profiles_role_guard.sql, applied in the same
-- window after live testing caught the gap: the UPDATE branch of user_profiles_role_guard()
-- lacked the auth.uid() IS NULL bypass that the INSERT branch already had. Without it, CS's
-- own established SQL-editor manual-fix workflow (runs as `postgres`, not `service_role`, no
-- JWT claims set, so auth.uid() is NULL there) would have been incorrectly blocked with
-- "role change not allowed" on any direct role fix. Caught by a rolled-back-transaction test
-- simulating that exact path before this was reported as done.
--
-- CREATE OR REPLACE of the same trigger function, no signature change, no new overload.
CREATE OR REPLACE FUNCTION public.user_profiles_role_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      IF current_user = 'service_role' OR auth.uid() IS NULL OR public.is_admin(auth.uid()) THEN
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
