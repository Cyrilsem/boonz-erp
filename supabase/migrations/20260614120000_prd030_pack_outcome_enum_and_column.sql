-- PRD-030 step 1 DDL: the not_filled marker.
-- Forward-only: CREATE TYPE + ADD COLUMN nullable (NULL = pending/unpacked).
-- Set ONLY by pack_dispatch_line. Distinct from driver_outcome (driver's
-- machine-side report) and skipped (operator drop). Cody class (a) OK.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pack_outcome_enum') THEN
    CREATE TYPE public.pack_outcome_enum AS ENUM ('packed','partial','not_filled');
  END IF;
END $$;

ALTER TABLE public.refill_dispatching
  ADD COLUMN IF NOT EXISTS pack_outcome public.pack_outcome_enum;

COMMENT ON COLUMN public.refill_dispatching.pack_outcome IS
  'PRD-030 warehouse pack result, set only by pack_dispatch_line: packed (filled=quantity), partial (0<filled<planned), not_filled (planned, attempted, no WH stock; filled=0, packed stays false). NULL = not yet packed. Planned qty preserved in original_quantity (conserve_split_dispatch_quantity owns quantity). Distinct from driver_outcome.';
