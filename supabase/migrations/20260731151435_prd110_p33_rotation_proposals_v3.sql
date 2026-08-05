-- PRD-110 P3.3 — Rotation heartbeat: the proposal queue.
--
-- WHY A NEW TABLE AND NOT A REPAIR:
--   `public.rotation_proposals` DOES NOT EXIST. The prior implementation of this
--   feature was retired to `graveyard.rotation_proposals` (22 rows, kept as history).
--   Three SECURITY DEFINER functions -- propose_rotation_plan, apply_rotation_proposal,
--   reject_rotation_proposal -- still reference `public.rotation_proposals` and therefore
--   throw on every call. They are NOT repaired here: repairing them would resurrect a
--   retired design without CS sanction. See PRD-110-PARKING-LOT S-74.
--   LAW 3 (versioned additions only, no destructive change): this is `_v3`, additive,
--   and the graveyard rows are left untouched.
--
-- WHAT THIS IS: an ADVISORY queue. Rows are proposals, never actions. Nothing in this
--   table moves stock. The CS gate is `status`, and the hop from an approved proposal to
--   real M2M dispatch legs is BLOCKED on `stitch_v3` (S-62) and deliberately not built.
--   LAW 4 (shadow, don't switch) holds: no consumer, no flag, no cron writes plan rows.

CREATE TABLE IF NOT EXISTS public.rotation_proposals_v3 (
  proposal_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_date              date        NOT NULL,
  proposed_at            timestamptz NOT NULL DEFAULT now(),

  -- SOURCE: the stranded stock.
  source_machine_id      uuid    NOT NULL REFERENCES public.machines(machine_id)                ON DELETE CASCADE,
  source_shelf_id        uuid    NOT NULL REFERENCES public.shelf_configurations(shelf_id)      ON DELETE CASCADE,
  source_pod_product_id  uuid    NOT NULL REFERENCES public.pod_products(pod_product_id)        ON DELETE RESTRICT,
  source_qty_on_shelf    integer NOT NULL CHECK (source_qty_on_shelf >= 0),
  -- NULL velocity means UNMEASURABLE, never "zero demand". S-71's lesson, one level up:
  -- an absence must not read as a verdict. Callers read coverage_gaps in scoring_breakdown.
  source_velocity        numeric(10,4),
  source_days_to_sell    numeric(10,2),

  -- TARGET: where it is expected to actually sell.
  target_machine_id      uuid    NOT NULL REFERENCES public.machines(machine_id)           ON DELETE CASCADE,
  target_shelf_id        uuid    NOT NULL REFERENCES public.shelf_configurations(shelf_id) ON DELETE CASCADE,
  target_velocity        numeric(10,4) NOT NULL CHECK (target_velocity > 0),
  target_headroom        integer       NOT NULL CHECK (target_headroom >= 0),

  -- THE PROPOSAL.
  proposed_qty           integer NOT NULL CHECK (proposed_qty > 0),
  trigger_reason         text    NOT NULL CHECK (trigger_reason IN
                                   ('stranded_slow_mover','dead_stock','overstock_donor')),
  fit_score              numeric(10,4) NOT NULL,
  projected_days_to_sell numeric(10,2) NOT NULL CHECK (projected_days_to_sell >= 0),
  scoring_breakdown      jsonb   NOT NULL,

  -- THE CS GATE.
  -- CODY (Article 5): a CHECK sees only the NEW row, so this constrains the VOCABULARY,
  -- never the TRANSITION GRAPH -- nothing here would stop 'rejected' -> 'pending'. That is
  -- moot while no UPDATE path exists (SELECT-only grant, no UPDATE policy), and it becomes
  -- binding the moment an approve/reject RPC is written: that RPC OWNS the graph and is a
  -- new class (b) Cody review.
  -- ⛔ 'expired' is RESERVED AND CURRENTLY UNWRITTEN. No writer produces it. It is the
  -- intended bound on Article-14 staleness (fit_score/projected_days_to_sell decay as
  -- velocity moves); until an expiry sweeper exists, staleness is bounded only by a
  -- consumer reading proposed_at. Declared here so the gap is stated, not implied.
  status                 text    NOT NULL DEFAULT 'pending' CHECK (status IN
                                   ('pending','approved','rejected','applied','expired')),
  reviewed_by            uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reviewed_at            timestamptz,
  review_note            text,
  applied_to_plan_date   date,

  -- A proposal may never move stock to the machine it came from.
  CONSTRAINT rp_v3_no_self_move     CHECK (source_machine_id <> target_machine_id),
  -- Conservation at proposal time: cannot send more than is on the shelf, and cannot
  -- send more than the destination can physically hold.
  CONSTRAINT rp_v3_qty_le_onshelf   CHECK (proposed_qty <= source_qty_on_shelf),
  CONSTRAINT rp_v3_qty_le_headroom  CHECK (proposed_qty <= target_headroom),
  -- Every human-gated state must NAME its human. This is the CS gate as a constraint,
  -- not as a convention.
  CONSTRAINT rp_v3_review_named     CHECK (status NOT IN ('approved','rejected','applied')
                                           OR reviewed_by IS NOT NULL),
  CONSTRAINT rp_v3_applied_dated    CHECK (applied_to_plan_date IS NULL OR status = 'applied'),
  -- IDEMPOTENCY. The heartbeat is a weekly cron and STEP 7 S4 requires re-runs to be
  -- idempotent. S-58: an absolute count on an append-only table is not idempotent, so the
  -- table carries the key that makes re-proposing a no-op.
  CONSTRAINT rp_v3_unique_heartbeat UNIQUE (plan_date, source_shelf_id, target_shelf_id)
);

COMMENT ON TABLE public.rotation_proposals_v3 IS
'PRD-110 P3.3 rotation heartbeat proposal queue. ADVISORY ONLY - a row is a suggestion that stranded stock on source_shelf_id would sell faster on target_shelf_id. Nothing here moves stock; status is the CS gate and the approved->M2M-dispatch-leg hop is BLOCKED on stitch_v3 (S-62). Written only by propose_rotations_v3(). Supersedes the retired graveyard.rotation_proposals (whose three public.* functions are broken - S-74). Velocity is read from v_shelf_instock_velocity_split_v3, the canonical owner; NEVER from v_shelf_state.velocity_instock, which is still a NULL placeholder post-P2.1 (S-73).';

COMMENT ON COLUMN public.rotation_proposals_v3.source_velocity IS
'units/day at the SOURCE shelf. NULL = unmeasurable, NOT zero demand (S-71).';
COMMENT ON COLUMN public.rotation_proposals_v3.fit_score IS
'Dimensionless. Higher = better rotation. NOT comparable to v_machine_priority.urgency or to rank_machines_by_value_at_risk_v3 AED figures.';
COMMENT ON COLUMN public.rotation_proposals_v3.projected_days_to_sell IS
'proposed_qty / target_velocity. Days for the moved units to clear AT THE TARGET.';
COMMENT ON COLUMN public.rotation_proposals_v3.scoring_breakdown IS
'Every term that produced fit_score, plus coverage_gaps. A consumer reading fit_score without coverage_gaps is making an explicit mistake rather than being misled (S-71 idiom).';

-- Serves the CS review queue: "show me pending proposals, best first".
CREATE INDEX IF NOT EXISTS idx_rp_v3_pending_queue
  ON public.rotation_proposals_v3 (plan_date DESC, fit_score DESC)
  WHERE status = 'pending';
-- Serves "what is proposed to leave / arrive at this machine".
CREATE INDEX IF NOT EXISTS idx_rp_v3_source_machine ON public.rotation_proposals_v3 (source_machine_id, plan_date DESC);
CREATE INDEX IF NOT EXISTS idx_rp_v3_target_machine ON public.rotation_proposals_v3 (target_machine_id, plan_date DESC);

ALTER TABLE public.rotation_proposals_v3 ENABLE ROW LEVEL SECURITY;

-- READ for authenticated. WRITE only through the SECURITY DEFINER proposer, which is
-- owned by postgres and therefore bypasses RLS. No direct-write policy exists, so a
-- logged-in client cannot INSERT/UPDATE/DELETE even though it can read. This is the
-- shadow-table least-privilege shape (cf. 20260730201338, 20260731121100 / S-57).
DROP POLICY IF EXISTS rp_v3_select ON public.rotation_proposals_v3;
CREATE POLICY rp_v3_select ON public.rotation_proposals_v3
  FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.rotation_proposals_v3 FROM anon;
REVOKE ALL ON public.rotation_proposals_v3 FROM authenticated;
GRANT SELECT ON public.rotation_proposals_v3 TO authenticated;
