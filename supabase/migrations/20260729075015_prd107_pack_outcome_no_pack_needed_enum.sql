-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-107 Pack-stage truth, step 1/5. Adds the no_pack_needed terminal state to pack_outcome_enum.
-- Source: docs/prds/PRD-107-EXECUTION-LOG.md Phase 1/2; docs/architecture/MIGRATIONS_REGISTRY.md:683.
-- PG 17.6 forbids using a value added by ALTER TYPE...ADD VALUE inside the same transaction that
-- adds it, so this is deliberately its own migration, ahead of the backfill+constraint step.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = 'pack_outcome_enum' AND e.enumlabel = 'no_pack_needed'
  ) THEN
    ALTER TYPE public.pack_outcome_enum ADD VALUE 'no_pack_needed';
  END IF;
END $$;
