-- CC-01: Add building_id and source_of_supply columns to machines
-- No backfill in this round (CS-06 / CS-07 handle that separately)
ALTER TABLE public.machines
  ADD COLUMN IF NOT EXISTS building_id text,
  ADD COLUMN IF NOT EXISTS source_of_supply text;

COMMENT ON COLUMN public.machines.building_id IS 'Free-text building identifier for clubbing adjacent machines during refill route planning. Backfilled later per CS-06.';
COMMENT ON COLUMN public.machines.source_of_supply IS 'One of: VOX, BOONZ, LLFP. Determines travel-scope guardrail. Backfilled later per CS-07.';
