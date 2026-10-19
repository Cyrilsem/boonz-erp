-- Rollback for PRD-144 P1-3: drops the two new RPCs (nothing else changed).
DROP FUNCTION IF EXISTS public.split_pod_lot(uuid, numeric, date, numeric, date, text);
DROP FUNCTION IF EXISTS public.record_sold_since_planning(uuid, numeric, text);
