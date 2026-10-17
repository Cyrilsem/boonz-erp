-- Rollback for 20261017171239_prd140_1_access_catalog.sql
DROP VIEW IF EXISTS public.v_my_access;
DROP FUNCTION IF EXISTS public.clear_user_area_override(uuid, text);
DROP FUNCTION IF EXISTS public.set_user_area_override(uuid, text, text);
DROP FUNCTION IF EXISTS public.has_area(uuid, text);
DROP FUNCTION IF EXISTS public.resolve_user_access(uuid);
DROP TABLE IF EXISTS public.access_audit_log;
DROP TABLE IF EXISTS public.user_area_overrides;
DROP TABLE IF EXISTS public.role_area_defaults;
DROP TABLE IF EXISTS public.access_internal_functions;
DROP TABLE IF EXISTS public.access_areas;
