-- Reconstructed from prod 2026-08-20; originally applied via MCP with no migration file committed.
-- Makes the stitch preflight gate param-driven instead of unconditionally blocking (a scope correction applied within minutes of prd109_stitch_preflight_gate). Ships defaulted to 'warn'; flip to 'block' is a manual CS decision after burn-in.

ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS preflight_enforcement text NOT NULL DEFAULT 'warn';

ALTER TABLE public.refill_policy_params
  DROP CONSTRAINT IF EXISTS chk_preflight_enforcement;

ALTER TABLE public.refill_policy_params
  ADD CONSTRAINT chk_preflight_enforcement CHECK (preflight_enforcement = ANY (ARRAY['warn'::text, 'block'::text]));
