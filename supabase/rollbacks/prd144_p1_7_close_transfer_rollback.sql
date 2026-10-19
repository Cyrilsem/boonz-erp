-- Rollback for PRD-144 P1-7 part 2: drops the Pending tab's transfer list and close action. Transfers closed while it
-- was live stay closed (approve_m2m_transfer stamps).
DROP FUNCTION public.close_m2m_transfer(uuid, text);
DROP FUNCTION public.get_open_m2m_transfers(integer);
