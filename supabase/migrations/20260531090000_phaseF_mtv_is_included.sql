-- PRD-015 Phase A / AC#10 — machine include/exclude toggle data model.
-- Adds machines_to_visit.is_included (default true). Forward-only, additive.
-- NOT YET APPLIED to prod (PRD-015 ships migration files for per-phase sign-off).

ALTER TABLE public.machines_to_visit
  ADD COLUMN IF NOT EXISTS is_included boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.machines_to_visit.is_included IS
  'PRD-015 AC#10: operator include/exclude toggle for the day route. Default true; '
  'reset to true on every fresh pick (pick_machines_for_refill ON CONFLICT). The engine '
  'build + commit chain process only is_included=true rows (AC#12). Excluded machines '
  'stay in the table (not deleted).';
