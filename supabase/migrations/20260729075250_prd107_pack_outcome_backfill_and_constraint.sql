-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-107 Pack-stage truth, step 2/5. Source: docs/prds/PRD-107-EXECUTION-LOG.md Phase 0.4/3
-- (Finding 1) and docs/architecture/MIGRATIONS_REGISTRY.md:684.
--
-- Backfill classes (documented, 4,143 candidate rows fleet-wide, 4,137 actually fixed):
--   A (3,672, legacy pre-PRD-070/071 WH picks)        -> pack_outcome = 'packed'
--   B (439, live Remove/M2W leak) + D1 (10, M2M src)  -> pack_outcome = 'no_pack_needed'
--   D2 (18, M2M dest legs)                            -> pack_outcome = 'packed_transferred'
--   C (4, action IS NULL, CS-approved)                -> pack_outcome = 'packed'
--   6 legacy May-2026 rows blocked by pre-existing NOT VALID m2m_consistency /
--   refill_dispatching_source_consistency_chk constraints are left untouched (documented,
--   unrecoverable without inventing source-machine identity on protected rows).
-- The exact per-row class assignment (date windows / action values) is approximated here from
-- the execution log; prod data is already in its final backfilled state, so this UPDATE is
-- idempotent (WHERE pack_outcome IS NULL) and a no-op on replay against current prod.

UPDATE public.refill_dispatching
   SET pack_outcome = CASE
         WHEN action = 'Remove' OR upper(trim(COALESCE(action,''))) IN ('MACHINE TO WAREHOUSE','M2W')
           THEN 'no_pack_needed'::public.pack_outcome_enum
         WHEN is_m2m = true AND source_kind = 'm2m' AND action IN ('Refill','Add New','Add')
           THEN 'packed_transferred'::public.pack_outcome_enum
         ELSE 'packed'::public.pack_outcome_enum
       END
 WHERE packed = true
   AND pack_outcome IS NULL
   -- skip the 6 legacy rows blocked by pre-existing NOT VALID constraints (documented, unfixable)
   AND NOT (is_m2m = true AND source_machine_id IS NULL)
   AND NOT (is_m2m = false AND source_kind = 'm2m');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chk_packed_requires_outcome'
  ) THEN
    ALTER TABLE public.refill_dispatching
      ADD CONSTRAINT chk_packed_requires_outcome
      CHECK ((packed = false) OR (pack_outcome IS NOT NULL)) NOT VALID;
  END IF;
END $$;

-- Deliberately NOT VALIDATEd: 6 legacy May-2026 M2M rows fail the check and cannot be repaired
-- without inventing M2M identity data (execution log Finding 1). NOT VALID still enforces the
-- constraint on every new/updated row (probe-proven live). Carry-forward: repair the 6 rows,
-- then VALIDATE CONSTRAINT chk_packed_requires_outcome.
