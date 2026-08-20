-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- PRD-108 Volume-Driven Size-Up, step 1/4. Source: docs/prds/PRD-108-EXECUTION-LOG.md Phase 1
-- GATE (CS threshold sign-off 2026-07-29); docs/architecture/MIGRATIONS_REGISTRY.md:707.
-- Four additive columns on refill_policy_params, CS-approved thresholds from a read-only 90d
-- calibration pass: T1 closes the sole zombie leak (ADDMIND-1007 at 1.20/day) while keeping the
-- star case's 2x headroom; the machine floor is a structural guard T1 cannot enforce alone;
-- T2/T3 unchanged from the PRD's proposed values. Verified against live prod: current row values
-- match these defaults exactly.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS sizeup_min_vel_per_day        numeric NOT NULL DEFAULT 1.25,
  ADD COLUMN IF NOT EXISTS sizeup_overflow_factor        numeric NOT NULL DEFAULT 1.25,
  ADD COLUMN IF NOT EXISTS sizeup_vs_alternative_factor  numeric NOT NULL DEFAULT 1.3,
  ADD COLUMN IF NOT EXISTS sizeup_min_machine_units_wk   numeric NOT NULL DEFAULT 30;

UPDATE public.refill_policy_params
   SET sizeup_min_vel_per_day       = COALESCE(sizeup_min_vel_per_day, 1.25),
       sizeup_overflow_factor       = COALESCE(sizeup_overflow_factor, 1.25),
       sizeup_vs_alternative_factor = COALESCE(sizeup_vs_alternative_factor, 1.3),
       sizeup_min_machine_units_wk  = COALESCE(sizeup_min_machine_units_wk, 30);
