-- PRD-121 P0.1a: refill_plan_gate_waivers -- durable record of which merchandising
-- gate codes were waived on a given approve_refill_plan call, and why.
--
-- validate_refill_plan's violations are lane/product-level aggregates (its own detail
-- strings, e.g. "MC-2004-0100-O1 A02: 14+6 of 14"), not tied to a specific
-- refill_plan_output.id -- backmapping each formatted detail string to the exact row(s)
-- that produced it would require re-deriving 9 different gate-specific joins just to
-- attach a waiver. This ledger's grain is the APPROVAL CALL, not the plan row: one row
-- per waived gate per approve_refill_plan invocation, carrying the plan_date and machine
-- set that call covered.
--
-- Ledger table, not a mutable jsonb column on refill_plan_output -- refill_plan_output
-- rows get re-approved/re-pushed across a plan's life, and a plain column would be
-- silently overwritten on the next approval, losing the audit trail of what the FIRST
-- approval waived. Same append-only pattern as refill_dispatching_edit_log.
--
-- Dara: ledger table over mutable column (audit trail survives re-approval).
-- Cody: approve, Articles 1 (single writer: approve_refill_plan), 2 (RLS enabled),
-- 3 (S-308: explicit WITH CHECK(false)/USING(false) on write policies, not omission),
-- 7 (append-only), 12 (new table, forward-only).

CREATE TABLE IF NOT EXISTS public.refill_plan_gate_waivers (
  waiver_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date     date NOT NULL,
  machine_names text[] NOT NULL,
  gate          text NOT NULL,
  reason        text NOT NULL CHECK (length(reason) >= 10),
  waived_by     uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  waived_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_refill_plan_gate_waivers_date
  ON public.refill_plan_gate_waivers (plan_date);
-- serves "show every waiver used to approve plan_date X" for Gate-1/audit display.

ALTER TABLE public.refill_plan_gate_waivers ENABLE ROW LEVEL SECURITY;

CREATE POLICY rpgw_select ON public.refill_plan_gate_waivers
  FOR SELECT TO authenticated USING (true);
CREATE POLICY rpgw_no_direct_insert ON public.refill_plan_gate_waivers
  FOR INSERT TO authenticated WITH CHECK (false);
CREATE POLICY rpgw_no_update ON public.refill_plan_gate_waivers
  FOR UPDATE TO authenticated USING (false);
CREATE POLICY rpgw_no_delete ON public.refill_plan_gate_waivers
  FOR DELETE TO authenticated USING (false);
