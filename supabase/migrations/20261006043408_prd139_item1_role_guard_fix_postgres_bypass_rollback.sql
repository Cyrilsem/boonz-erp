-- Rollback for 20261006043408: restores the pre-fix function body (no auth.uid() IS NULL
-- bypass in the UPDATE branch). Not recommended standalone -- that reintroduces the
-- postgres-SQL-editor-manual-fix block this migration fixed. Prefer rolling back the whole
-- Item 1 feature via 20261006043159's rollback file instead.
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
