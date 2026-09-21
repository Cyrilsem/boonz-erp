-- PRD-128 step 02: IRIS-1070-0000-O1 was the one Active machine with a null
-- operating_model (verified before writing this -- see DECISIONS-2026-09-19.md D-004).
-- Backfilled to fully_managed, then a CHECK guards against this happening again silently.

UPDATE public.machines
   SET operating_model = 'fully_managed'
 WHERE official_name = 'IRIS-1070-0000-O1';

ALTER TABLE public.machines
  ADD CONSTRAINT machines_active_requires_operating_model
  CHECK (status <> 'Active' OR operating_model IS NOT NULL);
