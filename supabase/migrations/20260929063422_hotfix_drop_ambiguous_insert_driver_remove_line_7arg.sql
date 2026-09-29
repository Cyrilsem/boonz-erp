-- Hotfix 2026-09-29 Dubai, approved by CS: loopv2 R1 added an 8-arg overload (p_dispatch_date DEFAULT CURRENT_DATE)
-- next to the old 7-arg one, so FE named-arg calls became ambiguous. Keep the R1 body; drop the stale 7-arg overload.
DROP FUNCTION IF EXISTS public.insert_driver_remove_line(uuid, uuid, uuid, uuid, numeric, date, text);
REVOKE EXECUTE ON FUNCTION public.insert_driver_remove_line(uuid, uuid, uuid, uuid, numeric, date, text, date) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.insert_driver_remove_line(uuid, uuid, uuid, uuid, numeric, date, text, date) TO authenticated, service_role;