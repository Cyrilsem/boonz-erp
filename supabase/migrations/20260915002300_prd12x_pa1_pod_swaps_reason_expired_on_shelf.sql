-- ONE-LOOP-2 Block A step 1a follow-up: pod_swaps_reason_check did not allow
-- 'expired_on_shelf', the reason the new engine_add_pod expired-on-shelf
-- substitution pass writes. Caught live: the synthetic proof of that branch
-- (AMZ-1038 A10 Zigi backdated to force expiry) raised
-- 23514 pod_swaps_reason_check on its first attempt.
ALTER TABLE public.pod_swaps DROP CONSTRAINT pod_swaps_reason_check;
ALTER TABLE public.pod_swaps ADD CONSTRAINT pod_swaps_reason_check
  CHECK (reason = ANY (ARRAY['rotate_out'::text, 'dead'::text, 'wind_down'::text, 'm2w'::text, 'intent_driven'::text, 'expired_on_shelf'::text]));
