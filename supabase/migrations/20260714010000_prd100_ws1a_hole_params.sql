-- PRD-100 WS1a (DDL): 8+1 hole-signal tuner columns on pick_urgency_params (additive).
-- Defaults are the CS-locked values (spec 2026-07-14). Reseed of existing weights is WS1b (data, applied LAST).
ALTER TABLE public.pick_urgency_params
  ADD COLUMN IF NOT EXISTS hole_frac     numeric NOT NULL DEFAULT 0.15,
  ADD COLUMN IF NOT EXISTS hole_wt_a     numeric NOT NULL DEFAULT 1.0,
  ADD COLUMN IF NOT EXISTS hole_wt_b     numeric NOT NULL DEFAULT 0.8,
  ADD COLUMN IF NOT EXISTS hole_wt_c     numeric NOT NULL DEFAULT 0.6,
  ADD COLUMN IF NOT EXISTS hole_wt_d     numeric NOT NULL DEFAULT 0.4,
  ADD COLUMN IF NOT EXISTS holes_norm    numeric NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS w_holes       numeric NOT NULL DEFAULT 0.30,
  ADD COLUMN IF NOT EXISTS p1_holes_min  integer NOT NULL DEFAULT 2,
  ADD COLUMN IF NOT EXISTS p2_holes_min  integer NOT NULL DEFAULT 1;
