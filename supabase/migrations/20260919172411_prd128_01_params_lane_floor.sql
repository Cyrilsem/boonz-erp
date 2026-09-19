-- PRD-128 step 01: the two lane floors and the delivery-verify tolerance. Every use of
-- these three values reads pick_urgency_params directly (steps 05 and 08); none is
-- hardcoded anywhere. Values confirmed by CS in the PRD text itself (see
-- DECISIONS-2026-09-19.md D-006). Does not touch stale_full_days or any weight column.

ALTER TABLE public.pick_urgency_params
  ADD COLUMN lane_floor_gap_aed        numeric NOT NULL DEFAULT 5,
  ADD COLUMN lane_floor_runout_aed     numeric NOT NULL DEFAULT 0,
  ADD COLUMN delivery_verify_tolerance numeric NOT NULL DEFAULT 0.6;
