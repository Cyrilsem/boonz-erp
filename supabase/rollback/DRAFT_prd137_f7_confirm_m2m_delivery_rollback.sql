-- Rollback for PRD-137 F7 (confirm_m2m_delivery). Net-new function, nothing to restore.
DROP FUNCTION IF EXISTS public.confirm_m2m_delivery(uuid, numeric, numeric, uuid, text);
