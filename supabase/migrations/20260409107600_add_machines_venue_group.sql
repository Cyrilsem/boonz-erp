-- CC-01b retry: Add venue_group column to machines.
-- DEFAULT 'INDEPENDENT' ensures all existing rows satisfy NOT NULL before the backfill migration.
ALTER TABLE public.machines
  ADD COLUMN IF NOT EXISTS venue_group text NOT NULL DEFAULT 'INDEPENDENT';

COMMENT ON COLUMN public.machines.venue_group IS 'Family grouping for coexistence and travel-scope guardrails. Values: ADDMIND, VOX, VML, WPP, OHMYDESK, INDEPENDENT. See engines/refill/guardrails/coexistence.md and engines/refill/guardrails/travel-scope.md for rules.';

ALTER TABLE public.machines
  ADD CONSTRAINT machines_venue_group_check
  CHECK (venue_group IN ('ADDMIND', 'VOX', 'VML', 'WPP', 'OHMYDESK', 'INDEPENDENT'));
