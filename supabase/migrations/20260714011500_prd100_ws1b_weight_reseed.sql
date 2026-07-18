-- PRD-100 WS1b (DATA, apply LAST): weight rebalance to the CS-locked PRD-100 blend.
-- Guarded on the exact PRD-063 values: re-running is a no-op and it refuses to clobber
-- later tuning. If it updates 0 rows, STOP and inspect the row.
UPDATE public.pick_urgency_params
   SET w_runout = 0.35, w_capacity = 0.10, w_expiry = 0.12, w_stale = 0.13,
       updated_at = now()
 WHERE id = 1
   AND w_runout = 0.50 AND w_capacity = 0.15 AND w_expiry = 0.20 AND w_stale = 0.15;
