-- CC-09c: Partial unique index on machines.official_name for active (non-repurposed) rows.
-- Enforces at DB level that no two active machines share a name.
-- Repurposed rows (repurposed_at IS NOT NULL) are excluded so a repurposed machine's
-- old name can coexist with the new row created by repurpose_machine().
-- Runs AFTER merge_voxmcc_1009_duplicate_rows and retroactive_alhq_to_jet1016_split
-- have resolved all pre-existing duplicate pairs.
CREATE UNIQUE INDEX IF NOT EXISTS machines_official_name_unique_active
  ON public.machines (official_name)
  WHERE repurposed_at IS NULL;
