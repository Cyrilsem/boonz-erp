-- Refill reliability / WS4a - v_driver_feedback_demand view (Dara). STATUS: DRAFT - NOT APPLIED.
--
-- Purpose (PRD WS4 / postmortem RC3): driver_feedback is captured (table + submit/resolve RPCs + a decayed
-- v_driver_feedback_weight) but engine_add_pod never ingests it, so ground-truth asks ("OMDCW +5 Mars") are
-- dropped every cycle. This view maps an UNRESOLVED, in-window driver ask (keyed by boonz_product_id) to the
-- engine's planning grain (machine_id, pod_product_id, via product_mapping) and exposes the requested qty so
-- engine_add_pod can use it as a demand floor. Decay = the 14-day window + the resolved flag (once the engine
-- plans the ask it marks the feedback resolved, so it stops boosting).

CREATE OR REPLACE VIEW public.v_driver_feedback_demand AS
SELECT
  df.machine_id,
  pm.pod_product_id,
  MAX(df.requested_qty)::int            AS requested_qty,   -- strongest active ask for this pod on this machine
  array_agg(DISTINCT df.feedback_id)    AS feedback_ids,    -- the asks rolled into this demand (for resolve)
  MAX(df.created_at)                    AS latest_at
FROM public.driver_feedback df
JOIN public.product_mapping pm
  ON  pm.boonz_product_id = df.boonz_product_id
  AND pm.status = 'Active'
  AND (pm.machine_id = df.machine_id OR pm.machine_id IS NULL)
WHERE df.resolved = false
  AND df.requested_qty IS NOT NULL
  AND df.requested_qty > 0
  AND df.created_at >= (now() - interval '14 days')          -- decay window
GROUP BY df.machine_id, pm.pod_product_id;

COMMENT ON VIEW public.v_driver_feedback_demand IS
  'WS4: per (machine_id, pod_product_id) unresolved driver-feedback demand within a 14-day decay window, mapped boonz->pod. Consumed by engine_add_pod as a refill demand floor; the engine marks feedback_ids resolved once planned.';
