-- procurement_proposals outbox table for the weekly procurement automation.
-- GENERATED FROM LIVE PROD for git parity (PRD-ALL overnight run, 2026-06-30).
-- Already applied as supabase_migrations version 20260628141016. Idempotent (IF NOT EXISTS). Do not re-run.

-- Outbox table for the weekly procurement automation. The Wednesday forecast task
-- writes the proposal here; n8n reads pending rows (service role) and sends the email.
CREATE TABLE IF NOT EXISTS public.procurement_proposals (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cycle_date     date NOT NULL DEFAULT CURRENT_DATE,
  kind           text NOT NULL DEFAULT 'proposal' CHECK (kind IN ('proposal','revised','confirmation')),
  status         text NOT NULL DEFAULT 'pending_send' CHECK (status IN ('pending_send','sent','committed','cancelled')),
  email_subject  text NOT NULL,
  email_to       text[] NOT NULL DEFAULT ARRAY['boonzops@gmail.com'],
  reply_to       text NOT NULL DEFAULT 'cyrilsem@gmail.com',
  email_html     text NOT NULL,
  proposal_payload jsonb,          -- structured per-supplier SKU plan (for the approval checker)
  season_factor  numeric,
  created_at     timestamptz NOT NULL DEFAULT now(),
  sent_at        timestamptz,
  committed_at   timestamptz
);
CREATE INDEX IF NOT EXISTS idx_procurement_proposals_pending ON public.procurement_proposals (status, cycle_date) WHERE status='pending_send';

ALTER TABLE public.procurement_proposals ENABLE ROW LEVEL SECURITY;
-- service role (n8n) bypasses RLS. No anon/public policies = locked to service role + definer fns.
COMMENT ON TABLE public.procurement_proposals IS 'Outbox for weekly procurement automation: forecast task writes proposal/confirmation rows; n8n sends pending_send rows then marks sent.';
