-- PRD-110 P3.4 — the facing rightsizing proposal queue.
--
-- WHAT THIS IS: an ADVISORY queue, exactly like rotation_proposals_v3 (P3.3). A row says
-- "this product family holds N lanes on this machine and the evidence says it should hold
-- N±1". Nothing here moves a lane, edits a planogram, or touches shelf_configurations --
-- all of which are PROTECTED entities this unit does not write. The CS gate is `status`.
--
-- ⛔ ARTICLE 14: this is NOT a snapshot table. It does not cache what
-- v_facing_performance_v3 computes -- that view is recomputed live and is where the numbers
-- come from. What is stored is the thing a view cannot derive: that a proposal was MADE on a
-- date, and what a human then DECIDED about it. Same shape and same justification as
-- rotation_proposals_v3, which carried this reasoning past Cody at leg 57.
--
-- ⛔ The numeric columns are a DECISION RECORD, not a cache: they freeze what the evidence
-- said AT PROPOSAL TIME. The underlying view moves every day (30-day rolling windows, a
-- moving WEIMI anchor), so a proposal reviewed a week later must be judged against what was
-- true when it was made. Article 14's failure mode is a table that goes SILENTLY stale while
-- pretending to be current; these columns are explicitly historical and proposed_at dates them.

CREATE TABLE IF NOT EXISTS public.facing_proposals_v3 (
  proposal_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date          date        NOT NULL,
  proposed_at        timestamptz NOT NULL DEFAULT now(),

  machine_id         uuid    NOT NULL REFERENCES public.machines(machine_id)         ON DELETE CASCADE,
  pod_product_id     uuid    NOT NULL REFERENCES public.pod_products(pod_product_id) ON DELETE RESTRICT,

  direction          text    NOT NULL CHECK (direction IN ('shrink','expand')),
  facings_current    integer NOT NULL CHECK (facings_current  >= 1),
  facings_proposed   integer NOT NULL CHECK (facings_proposed >= 1),

  -- The evidence, frozen. rev_per_facing_day_potential is the IN-STOCK-rate metric: a lane
  -- is judged on what it earns WHILE STOCKED, never on a realized rate that would blame the
  -- assortment for a refill failure.
  rev_per_facing_day_potential numeric(12,4) NOT NULL,
  rev_per_facing_day_realized  numeric(12,4),
  machine_peer_median          numeric(12,4) NOT NULL,
  peer_families                integer       NOT NULL CHECK (peer_families >= 2),
  ratio_to_median              numeric(12,4) NOT NULL,
  -- NULL for shrink (not consulted) and NULL when calendar velocity is 0 (UNMEASURABLE, not
  -- "not starved" -- S-71). A NOT NULL here would force a lie in both cases.
  starvation_ratio             numeric(12,4),
  unit_price                   numeric(12,4) NOT NULL,
  price_basis                  text          NOT NULL,
  velocity_basis               text          NOT NULL,
  stock_units                  integer,
  capacity_units               integer,

  score              numeric(12,4) NOT NULL,
  scoring_breakdown  jsonb         NOT NULL,

  -- THE CS GATE. Same vocabulary-not-transition-graph note as rotation_proposals_v3: a CHECK
  -- sees only the NEW row, so nothing here prevents 'rejected' -> 'pending'. Moot while no
  -- UPDATE path exists (SELECT-only grant, no UPDATE policy); the day an approve/reject RPC
  -- is written, THAT RPC owns the graph and is its own Cody review.
  status             text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','approved','rejected','applied','expired')),
  reviewed_by        uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reviewed_at        timestamptz,
  review_note        text,
  applied_to_plan_date date,

  -- ⛔ A shrink must leave a lane behind: this engine may never take a family to zero.
  -- Removing a product entirely is a delist decision, not a rightsizing one.
  CONSTRAINT fp_v3_keeps_a_lane   CHECK (facings_proposed >= 1),
  -- Direction and arithmetic must agree, and each step moves exactly ONE lane. A proposal
  -- that jumped 3 -> 1 would be two decisions wearing one row.
  CONSTRAINT fp_v3_direction_math CHECK (
       (direction = 'shrink' AND facings_proposed = facings_current - 1 AND facings_current >= 2)
    OR (direction = 'expand' AND facings_proposed = facings_current + 1)),
  CONSTRAINT fp_v3_review_named   CHECK (status NOT IN ('approved','rejected','applied')
                                         OR reviewed_by IS NOT NULL),
  CONSTRAINT fp_v3_applied_dated  CHECK (applied_to_plan_date IS NULL OR status = 'applied'),
  -- IDEMPOTENCY (STEP 7 S4). One open proposal per family per batch; a re-run is a no-op.
  -- ⛔ Keyed WITHOUT direction: a family must never hold a shrink AND an expand at once.
  CONSTRAINT fp_v3_unique_batch   UNIQUE (plan_date, machine_id, pod_product_id)
);

COMMENT ON TABLE public.facing_proposals_v3 IS
'PRD-110 P3.4 facing rightsizing queue. ADVISORY ONLY - a row proposes that a product family holds one lane too many or one too few on a machine. Nothing here moves a lane or touches shelf_configurations/planogram (protected). status is the CS gate. Written only by propose_facing_changes_v3(). Evidence columns are frozen AT PROPOSAL TIME by design (the source view rolls 30-day windows off a moving WEIMI anchor), which is why this is a decision record and not an Article-14 snapshot. Metric source: v_facing_performance_v3.';
COMMENT ON COLUMN public.facing_proposals_v3.rev_per_facing_day_potential IS
'AED/lane/day at the IN-STOCK rate, frozen at proposal time. NOT the realized rate: judging a lane on realized revenue punishes the assortment for a refill failure.';
COMMENT ON COLUMN public.facing_proposals_v3.starvation_ratio IS
'in-stock rate / calendar rate. Required evidence for EXPAND; NULL for shrink and NULL when calendar velocity is 0 (unmeasurable, not "not starved" - S-71).';
COMMENT ON COLUMN public.facing_proposals_v3.score IS
'Dimensionless |ratio_to_median - 1|. Ranks proposals against each other ONLY. NOT comparable to rotation_proposals_v3.fit_score or to rank_machines_by_value_at_risk_v3 AED.';

CREATE INDEX IF NOT EXISTS idx_fp_v3_pending_queue
  ON public.facing_proposals_v3 (plan_date DESC, score DESC) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_fp_v3_machine ON public.facing_proposals_v3 (machine_id, plan_date DESC);

ALTER TABLE public.facing_proposals_v3 ENABLE ROW LEVEL SECURITY;

-- READ for authenticated; writes only through the SECURITY DEFINER proposer (owned by
-- postgres, bypasses RLS). No direct-write policy exists, so a logged-in client cannot
-- INSERT/UPDATE/DELETE. Shadow-table least-privilege shape (cf. 20260731173609, S-57/S-88).
DROP POLICY IF EXISTS fp_v3_select ON public.facing_proposals_v3;
CREATE POLICY fp_v3_select ON public.facing_proposals_v3
  FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.facing_proposals_v3 FROM anon;
REVOKE ALL ON public.facing_proposals_v3 FROM authenticated;
GRANT SELECT ON public.facing_proposals_v3 TO authenticated;
