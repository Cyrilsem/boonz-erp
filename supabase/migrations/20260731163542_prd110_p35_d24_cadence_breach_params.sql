-- PRD-110 P3.5 / CS DECISION D-24 (CLOSED 2026-07-31 ~18:05 Dubai)
-- MONEY FIRST: the service-policy cadence stops being the primary sort key and becomes a
-- CONSTRAINT - a max-days-between-visits floor that forces inclusion only when BREACHED.
-- These two params define "breached". Both are POLICY: CS can retune either with one UPDATE
-- and no migration, exactly like the rot_* family (D-26).
--
-- Additive only: two new columns on the single-row policy table, one NEW check constraint
-- (the existing chk_var_capacity_params_sane is left byte-untouched - no DROP, Article 12).

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS var_cadence_floor_multiple numeric NOT NULL DEFAULT 2.0,
  ADD COLUMN IF NOT EXISTS var_cadence_hard_max_days  integer NOT NULL DEFAULT 14;

ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_var_cadence_floor_params_sane
  CHECK (var_cadence_floor_multiple >= 1.0 AND var_cadence_hard_max_days > 0);

COMMENT ON COLUMN public.refill_policy_params.var_cadence_floor_multiple IS
  'PRD-110 P3.5. POLICY, not measured (CS decision D-24, 2026-07-31). A machine BREACHES its '
  'visit cadence at days_since_visit >= gap_days * this multiple. 1.0 restores the old '
  'behaviour where merely reaching the service target forced inclusion.';

COMMENT ON COLUMN public.refill_policy_params.var_cadence_hard_max_days IS
  'PRD-110 P3.5. POLICY, not measured (CS decision D-24, 2026-07-31). Absolute ceiling on '
  'days between visits: no machine may go longer than this regardless of its own gap_days. '
  'The breach threshold is LEAST(gap_days * var_cadence_floor_multiple, this).';
