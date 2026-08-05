-- PRD-110 P4.3b (WS-H4 pick-learning) — schema half.
--
-- WHAT THIS EXISTS TO DO: mine machines_to_visit history for CS's revealed machine-selection
-- judgment and PROPOSE picker-weight moves. ⛔ APPLICATION IS PARKED per the goal command:
-- nothing in this design writes public.pick_urgency_params, and that is structural, not incidental.
--
-- ⭐ CALIBRATION MEASURED LIVE BEFORE A LINE WAS WRITTEN (leg 86):
--   1218 live picker rows / 70 plan_dates / 241 CS drops / 2 live CS adds.
--   Drop reasons are ROUTE-SCOPE, not per-machine judgment ("cancel entire 5-Jun plan" x25,
--   "focus on 6-machine route" x22, "AMZ-only route today"). Cohorts: mixed_capacity 24 days /
--   188 drops / 241 kept (LEARNABLE) · cluster_scope 7 days / 53 drops (a route decision, carries
--   no rank signal) · no_drops 39 days.
--   Within the 24 learnable days, 1653 same-day (kept,dropped) pairs:
--   ⛔ priority_score concordance with CS = 50.0% — THE PICKER'S OWN COMPOSITE CARRIES ZERO
--   INFORMATION about what CS keeps. Per-feature: empty_shelves_count 68.6 · empty_shelf_pct 67.3
--   · active_intent_count 38.2 · fill_pct 40.4 · expired_skus_now 56.0 · days_since_visit 51.0
--   · runway_days 49.0 · units_last_7d 49.5 · dead_slot_pct 47.7 · hero_slot_count all-ties.
--
-- ⛔ THE TWO POLARITY TRAPS, both caught by live probe, both structural in this schema:
--   (1) SIGN. Weights multiply normalised s_* terms in v_machine_priority
--       (score = w_runout*s_runout + ... + w_empty*s_empty + ...). A feature whose concordance is
--       BELOW 50 means CS keeps machines with LOW values of it — which for a dial that already
--       rewards low values is evidence to RAISE, not lower. Encoded as param_rewards, in a TABLE
--       so a one-row UPDATE can falsify it. An inline CASE could not be mutated that way.
--   (2) MONOTONICITY. A dial may simply not control the feature being mined. Measured
--       corr(s_term, feature) over v_machine_priority:
--         s_empty  vs empty_shelves_count  = +1.000   ACTIVE
--         s_empty  vs empty_shelf_pct      = +1.000   ACTIVE
--         s_expiry vs expired_skus_now     = +1.000   ACTIVE
--         s_stale  vs days_since_visit     = +0.943   ACTIVE
--         s_capacity vs fill_pct           = -0.458   REFUSED (below the 0.70 bar)
--         s_lowfill  vs fill_pct           = -0.042   REFUSED — ⛔ the naive fill_pct->w_lowfill
--                                                     mapping is WRONG: that dial does not control
--                                                     fill_pct at all. fill_pct's nearest dial is
--                                                     w_capacity, and even that fails the bar.
--         s_runout vs runway_days          = -0.160   REFUSED (weak)
--         s_holes  vs dead_slot_pct        = +0.038   REFUSED (near-zero)
--
-- ⭐ EXPECTED LIVE YIELD, stated before the miner exists so its first run is verified against a
-- prediction and not against itself: among ACTIVE features only empty_shelves_count (excess 18.6)
-- and empty_shelf_pct (excess 17.3) clear pl_concordance_band = 8.0; both target w_empty and
-- aggregate to EXACTLY ONE proposal — raise w_empty 0.900 -> 0.945 (+5.05%), lead feature
-- empty_shelves_count, 1318 pairs, 24 days. expired_skus_now (excess 6.0) and days_since_visit
-- (excess 1.0) fall below the band. ⛔ Do NOT benchmark this miner against the edit miner's
-- ">= 5 proposals" bar: there are only seven dials in total and one honest proposal is the answer.
--
-- Article 14: NO ADR, matching rotation_proposals_v3 / facing_proposals_v3 /
-- reallocation_proposals_v3 — a review queue holds state no view can derive, and the corrected
-- Article 14 test is silent staleness, not table count (S-03).

-- ---------------------------------------------------------------------------------------------
-- (1) THE FEATURE -> DIAL MAP. Each row is a CLAIM about picker semantics.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.picker_feature_param_map_v3 (
  feature        text PRIMARY KEY,
  target_param   text,
  param_rewards  text CHECK (param_rewards IN ('high','low')),
  s_term         text,
  monotonicity   numeric(5,3),
  is_active      boolean NOT NULL DEFAULT false,
  note           text NOT NULL DEFAULT '',
  -- ⛔ S-126: a CHECK evaluating to NULL PASSES. Both operands below are NULL-safe —
  -- is_active is NOT NULL and `IS NOT NULL` never yields NULL — so this bites as written.
  CONSTRAINT pfpm_active_needs_dial CHECK (
    NOT is_active OR (target_param IS NOT NULL AND param_rewards IS NOT NULL))
);

COMMENT ON TABLE  public.picker_feature_param_map_v3 IS
  'PRD-110 P4.3b. Which pick_urgency_params dial each mined machines_to_visit feature moves, and in which direction. param_rewards=high means raising target_param favours machines with HIGH feature values. Rows with is_active=false are NAMED REFUSALS and are mined for telemetry only.';
COMMENT ON COLUMN public.picker_feature_param_map_v3.monotonicity IS
  'corr(s_term, feature) measured over v_machine_priority at map time. |corr| >= 0.70 is the activation bar: below it the dial does not control the feature.';

-- ---------------------------------------------------------------------------------------------
-- (2) THE PROPOSAL QUEUE. One row per TARGET_PARAM per mining run — never one per feature:
--     empty_shelves_count and empty_shelf_pct both move w_empty, and two rows fighting over one
--     dial is a defect CS experiences, not one the schema absorbs.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.picker_weight_proposals_v3 (
  proposal_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mined_at         timestamptz NOT NULL DEFAULT now(),
  window_start     date NOT NULL,
  window_end       date NOT NULL,
  target_param     text NOT NULL,
  current_weight   numeric(6,3) NOT NULL,
  proposed_weight  numeric(6,3) NOT NULL,
  direction        text NOT NULL CHECK (direction IN ('raise','lower')),
  lead_feature     text NOT NULL REFERENCES public.picker_feature_param_map_v3(feature)
                     ON DELETE RESTRICT,
  concordance_pct  numeric(5,2) NOT NULL CHECK (concordance_pct BETWEEN 0 AND 100),
  pairs            integer NOT NULL CHECK (pairs > 0),
  concordant       integer NOT NULL CHECK (concordant >= 0),
  discordant       integer NOT NULL CHECK (discordant >= 0),
  days_covered     integer NOT NULL CHECK (days_covered > 0),
  evidence         jsonb   NOT NULL DEFAULT '{}'::jsonb,
  status           text    NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','approved','rejected','applied','superseded')),
  reviewed_by      uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  reviewed_at      timestamptz,
  review_note      text,
  applied_at       timestamptz,
  applied_weight   numeric(6,3),
  CONSTRAINT pwp_window_ordered CHECK (window_end >= window_start),
  -- ⛔ CODY (leg 86): this is a correct INVARIANT but it is also a CRASH PATH. delta scales from
  -- the band edge, so a candidate landing exactly ON the band computes proposed = current and
  -- this CHECK aborts the WHOLE mining run. Rounding widens the window: w_expiry at 0.120 needs
  -- ~0.42% before numeric(6,3) moves it at all. The miner must gate on |conc-50| > band STRICTLY
  -- and SKIP any candidate whose rounded proposed_weight equals current_weight. The CHECK stays;
  -- the function must never hand it a violation.
  CONSTRAINT pwp_moved          CHECK (proposed_weight <> current_weight),
  CONSTRAINT pwp_pairs_coherent CHECK (concordant + discordant <= pairs),
  CONSTRAINT pwp_applied_shape  CHECK (
    (status = 'applied') = (applied_at IS NOT NULL AND applied_weight IS NOT NULL)),
  -- 'superseded' is a SYSTEM action with no human, so it is exempt from the reviewer check —
  -- the same carve-out rotation/facing/feedback proposals carry.
  CONSTRAINT pwp_reviewed_shape CHECK (
    (status IN ('approved','rejected')) <= (reviewed_at IS NOT NULL))
);

COMMENT ON TABLE public.picker_weight_proposals_v3 IS
  'PRD-110 P4.3b advisory queue. mine_pick_history_v3 is the only writer. ⛔ APPLICATION IS PARKED: no object anywhere writes pick_urgency_params from this queue.';

-- Enforces "at most one live proposal per dial".
CREATE UNIQUE INDEX IF NOT EXISTS ux_pwp_one_pending_per_param
  ON public.picker_weight_proposals_v3 (target_param) WHERE status = 'pending';
-- Serves the review queue and the G12 acceptance-rate telemetry: both read by status, newest first.
CREATE INDEX IF NOT EXISTS idx_pwp_status_mined
  ON public.picker_weight_proposals_v3 (status, mined_at DESC);

-- ---------------------------------------------------------------------------------------------
-- (3) RLS + ACL — byte-for-byte the rotation_proposals_v3 / facing_proposals_v3 convention
--     (S-104): authenticated=r only, NO anon, no write policy at all. The SECURITY DEFINER miner
--     is the only writer; absence of a policy is the denial.
-- ⛔ ADR §11.2 / S-104: REVOKE first, then GRANT — a GRANT is additive and cannot narrow.
-- ---------------------------------------------------------------------------------------------
ALTER TABLE public.picker_feature_param_map_v3 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.picker_weight_proposals_v3  ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.picker_feature_param_map_v3 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.picker_weight_proposals_v3  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.picker_feature_param_map_v3 TO authenticated;
GRANT SELECT ON public.picker_weight_proposals_v3  TO authenticated;

DROP POLICY IF EXISTS pfpm_select ON public.picker_feature_param_map_v3;
CREATE POLICY pfpm_select ON public.picker_feature_param_map_v3
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS pwp_select ON public.picker_weight_proposals_v3;
CREATE POLICY pwp_select ON public.picker_weight_proposals_v3
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------------------------
-- (4) SEED THE MAP. Four ACTIVE, seven NAMED REFUSALS. Monotonicity figures are the live
--     measurements above, recorded so a later leg can re-measure and detect drift.
-- ---------------------------------------------------------------------------------------------
INSERT INTO public.picker_feature_param_map_v3
  (feature, target_param, param_rewards, s_term, monotonicity, is_active, note)
VALUES
  ('empty_shelves_count','w_empty','high','s_empty',   1.000, true,
   'corr +1.000. Strongest CS signal: 68.6% concordance over 1318 pairs.'),
  ('empty_shelf_pct',    'w_empty','high','s_empty',   1.000, true,
   'corr +1.000. 67.3% concordance; same dial as empty_shelves_count, aggregated.'),
  ('expired_skus_now',   'w_expiry','high','s_expiry', 1.000, true,
   'corr +1.000. 56.0% concordance — below the band, mined but not proposing.'),
  ('days_since_visit',   'w_stale','high','s_stale',   0.943, true,
   'corr +0.943. 51.0% concordance — noise; CS does not select on recency.'),
  ('fill_pct',        'w_capacity','low','s_capacity',-0.458, false,
   'REFUSED: nearest dial is w_capacity at corr -0.458, below the 0.70 bar. ⛔ The intuitive fill_pct->w_lowfill mapping is WRONG — corr(s_lowfill, fill_pct) = -0.042, that dial does not control fill at all.'),
  ('runway_days',     'w_runout','low','s_runout',    -0.160, false,
   'REFUSED: corr -0.160. Direction is right but the link is too weak to move a dial on.'),
  ('dead_slot_pct',   'w_holes','high','s_holes',      0.038, false,
   'REFUSED: corr +0.038. w_holes counts holes, not dead slots — near-zero link.'),
  ('active_intent_count', NULL, NULL, NULL, NULL, false,
   '⛔ REFUSED FOR WANT OF A DIAL, and this one matters: 38.2% concordance is the SECOND-STRONGEST signal CS gives us (61.8% in the inverse direction — CS drops machines with more open intents) and no picker weight targets intent volume. Raised as a CS decision.'),
  ('units_last_7d',       NULL, NULL, NULL, NULL, false,
   'REFUSED for want of a dial. 49.5% — noise anyway.'),
  ('hero_slot_count',     NULL, NULL, NULL, NULL, false,
   'REFUSED: ZERO VARIANCE across the live fleet — every pair ties, concordance is NULL. ⛔ Never propose on a NULL concordance.'),
  ('priority_score',      NULL, NULL, NULL, NULL, false,
   '⛔ REFUSED BY CONSTRUCTION: the composite itself, an OUTPUT not an input. Diagnostic only — and its 50.0% concordance is the headline finding, not a proposal.')
ON CONFLICT (feature) DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- (5) PARAMS — pl_* columns on the one-row wide refill_policy_params, matching rot_*/fac_*/var_*.
-- ---------------------------------------------------------------------------------------------
ALTER TABLE public.refill_policy_params
  ADD COLUMN IF NOT EXISTS pl_window_days          integer      NOT NULL DEFAULT 90,
  ADD COLUMN IF NOT EXISTS pl_min_pairs            integer      NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS pl_min_days             integer      NOT NULL DEFAULT 8,
  ADD COLUMN IF NOT EXISTS pl_concordance_band     numeric(5,2) NOT NULL DEFAULT 8.0,
  ADD COLUMN IF NOT EXISTS pl_max_weight_delta_pct numeric(5,2) NOT NULL DEFAULT 20.0,
  ADD COLUMN IF NOT EXISTS pl_max_proposals        integer      NOT NULL DEFAULT 5,
  ADD COLUMN IF NOT EXISTS pl_monotonicity_bar     numeric(5,3) NOT NULL DEFAULT 0.700;
