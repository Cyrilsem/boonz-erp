-- PRD-110 P4.5 follow-up. S-140 read-back found the grant layer and the RLS layer
-- disagreeing on public.scoreboard_daily_v3: Supabase's ALTER DEFAULT PRIVILEGES had
-- already granted `authenticated` the full arwdDxtm set at CREATE time, and the
-- GRANT SELECT in 20260803205310 did not reduce it. RLS denies those writes today
-- (only a SELECT policy exists), so this is defense-in-depth rather than an open hole
-- -- but a future policy addition would silently arm them. Make the two layers agree.
-- Forward-only (Article 12); anon/PUBLIC were already correctly revoked.
REVOKE ALL ON public.scoreboard_daily_v3 FROM authenticated;
GRANT SELECT ON public.scoreboard_daily_v3 TO authenticated;
