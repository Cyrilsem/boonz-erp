-- PRD-063 step 1: pick_urgency_params singleton.
-- All knobs for the shelf-aware urgency model that v_machine_priority (rewritten in step 3) reads.
-- Singleton (id = 1, CHECK id = 1). RLS: SELECT true; writes operator_admin/superadmin/manager.
-- Seeded to the CS-locked defaults. Forward-only; idempotent (IF NOT EXISTS + ON CONFLICT seed).

CREATE TABLE IF NOT EXISTS public.pick_urgency_params (
  id                       integer     PRIMARY KEY DEFAULT 1 CHECK (id = 1),

  -- runout / grading
  horizon_days             numeric     NOT NULL DEFAULT 2,     -- H: days-of-supply horizon
  a_floor                  numeric     NOT NULL DEFAULT 0.5,   -- grade A: dvel >= 0.5/day
  b_floor                  numeric     NOT NULL DEFAULT 0.2,   -- grade B: dvel >= 0.2/day  (C: >0, D: 0)
  grade_wt_a               numeric     NOT NULL DEFAULT 1.0,   -- gradeWeight in s_runout
  grade_wt_b               numeric     NOT NULL DEFAULT 0.6,
  grade_wt_c               numeric     NOT NULL DEFAULT 0.25,
  runout_worst_wt          numeric     NOT NULL DEFAULT 0.75,  -- machine s_runout = worst_wt*worst + breadth_wt*breadth
  runout_breadth_wt        numeric     NOT NULL DEFAULT 0.25,

  -- component weights (sum to 1.0; urgency = 100 * weighted sum of 0..1 components)
  w_runout                 numeric     NOT NULL DEFAULT 0.50,
  w_capacity               numeric     NOT NULL DEFAULT 0.15,
  w_expiry                 numeric     NOT NULL DEFAULT 0.20,
  w_stale                  numeric     NOT NULL DEFAULT 0.15,

  -- expiry component: (expired_wt*expired + exp3d_wt*expiring<=3d) / expiry_norm, capped at 1
  expiry_norm              numeric     NOT NULL DEFAULT 6,
  expiry_weight_expired    numeric     NOT NULL DEFAULT 2,
  expiry_weight_exp3d      numeric     NOT NULL DEFAULT 1,
  p1_expired_min           integer     NOT NULL DEFAULT 1,     -- expired_skus_now >= this forces P1
  p2_exp3d_min             integer     NOT NULL DEFAULT 3,     -- expiring<=3d count >= this forces P2

  -- stale component + override
  stale_grace_days         numeric     NOT NULL DEFAULT 7,     -- s_stale = 0 at/below
  stale_full_days          numeric     NOT NULL DEFAULT 21,    -- s_stale = 100 at/above
  stale_override_days      numeric     NOT NULL DEFAULT 14,    -- days_since_visit > this forces P1
  cooldown_days            numeric     NOT NULL DEFAULT 1,     -- hero override needs days_since_visit > this

  -- tier thresholds
  p1_threshold             numeric     NOT NULL DEFAULT 50,    -- urgency >= this -> P1
  p2_threshold             numeric     NOT NULL DEFAULT 25,    -- urgency >= this -> P2

  -- selection (used by the picker, not the tiering)
  driver_capacity          integer     NOT NULL DEFAULT 8,     -- main-track cap-8 (p_max_total)

  updated_at               timestamptz NOT NULL DEFAULT now(),
  updated_by               uuid
);

-- Seed the singleton with the locked defaults (no-op if it already exists).
INSERT INTO public.pick_urgency_params (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.pick_urgency_params ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pick_urgency_params_select ON public.pick_urgency_params;
CREATE POLICY pick_urgency_params_select ON public.pick_urgency_params
  FOR SELECT USING (true);

DROP POLICY IF EXISTS pick_urgency_params_write ON public.pick_urgency_params;
CREATE POLICY pick_urgency_params_write ON public.pick_urgency_params
  FOR ALL
  USING (EXISTS (SELECT 1 FROM public.user_profiles
                 WHERE user_profiles.id = (SELECT auth.uid())
                   AND user_profiles.role = ANY (ARRAY['operator_admin','superadmin','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles
                 WHERE user_profiles.id = (SELECT auth.uid())
                   AND user_profiles.role = ANY (ARRAY['operator_admin','superadmin','manager'])));

COMMENT ON TABLE public.pick_urgency_params IS
  'PRD-063 singleton knobs for the shelf-aware urgency model in v_machine_priority. One row (id=1). Writes: operator_admin/superadmin/manager.';
