-- ONE-LOOP-2 Block A0 (1): horizon_days 3 -> 4.
--
-- pick_urgency_params.horizon_days was set to 3 last night in prd12x_p5
-- (PRD-126 R1-R4). PRD-122's own note assumed it was still 2. Both
-- s_runout_hero (PRD-122) and s_runout_aed (PRD-126) read this single row,
-- so this one change applies to both. Block B's backtest tunes
-- p1_threshold_aed / p2_threshold_aed against horizon 4.
UPDATE public.pick_urgency_params SET horizon_days = 4, updated_at = now()
WHERE id = 1;
