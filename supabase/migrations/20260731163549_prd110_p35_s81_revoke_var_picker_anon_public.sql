-- PRD-110 P3.5 / S-81. The value-at-risk picker was EXECUTable by `anon` AND by PUBLIC.
-- It is STABLE + SECURITY INVOKER so it writes nothing, but it returns per-machine value at
-- risk in AED, velocity coverage and visit cadence for the ENTIRE fleet. Same loose-grant class
-- migration 20260731121100 swept under S-57; it regrew on the leg-58 object because fixture 42
-- seq 51 pins VOLATILITY, not GRANTS. Fixture 42 seq 66 (this leg) pins the grants, mirroring
-- fixture 43 seq 15, so it cannot regrow a third time silently.
-- No consumer holds this function: nothing breaks.
REVOKE EXECUTE ON FUNCTION public.rank_machines_by_value_at_risk_v3(date, integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.rank_machines_by_value_at_risk_v3(date, integer) FROM PUBLIC;
