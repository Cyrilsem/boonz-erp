-- PRD-110 DR-1 (leg 160) — fixture 74's planted series hit a GENERATED column.
--
-- ⛔ engine_forecast_error_v3.abs_error and .signed_error are GENERATED ALWAYS from
--    abs(forecast_units - actual_units) and (forecast_units - actual_units). The red run failed
--    with "cannot insert a non-DEFAULT value into column abs_error" — the same class as PRD-098's
--    `quarantined` trap. The error MAGNITUDES cannot be supplied; they must be ENGINEERED through
--    the forecast, which is strictly better anyway: the planted rows now exercise the real
--    derivation instead of asserting a number the column would never have produced.
--
--    v3  forecasts 110 against 100 actual → abs_error 10  → wmape_v3  = 0.10
--    v19 forecasts 140 against 100 actual → abs_error 40  → wmape_v19 = 0.40
--    v3 <= v19, so the cluster reads `ready` and the accept path is genuinely reachable.
--
-- Article 12: forward-only. The past migration is not edited; the fixture row is UPDATEd here.

DO $mig$
DECLARE
  v_old text;
  v_new text;
  v_from text;
  v_to   text;
  v_n    int;
BEGIN
  SELECT scenario_sql INTO v_old FROM golden.fixtures WHERE fixture_id = 74;
  IF v_old IS NULL THEN RAISE EXCEPTION 'fixture 74 not found'; END IF;

  v_from :=
'      (plan_date, engine_tag, machine_id, pod_product_id, horizon_days, horizon_end, n_shelves,' || E'\n' ||
'       dc_variants, forecast_units, actual_units, abs_error, signed_error, actuals_settled,' || E'\n' ||
'       velocity_basis, measured_at)' || E'\n' ||
'    VALUES' || E'\n' ||
'      (DATE ''2026-07-01'',''v3'',  v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 100, 100, 10, 10, true, ''fixture74'', now()),' || E'\n' ||
'      (DATE ''2026-07-01'',''v19'', v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 100, 100, 40, 40, true, ''fixture74'', now());';

  v_to :=
'      (plan_date, engine_tag, machine_id, pod_product_id, horizon_days, horizon_end, n_shelves,' || E'\n' ||
'       dc_variants, forecast_units, actual_units, actuals_settled,' || E'\n' ||
'       velocity_basis, measured_at)' || E'\n' ||
'    VALUES' || E'\n' ||
'      -- The two error columns are GENERATED ALWAYS and cannot be supplied. The miss is' || E'\n' ||
'      -- engineered through the forecast: v3 off by 10 on 100 (wmape 0.10), v19 off by 40 (0.40).' || E'\n' ||
'      (DATE ''2026-07-01'',''v3'',  v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 110, 100, true, ''fixture74'', now()),' || E'\n' ||
'      (DATE ''2026-07-01'',''v19'', v_novo, v_pod, 7, DATE ''2026-07-08'', 1, 1, 140, 100, true, ''fixture74'', now());';

  v_n := (length(v_old) - length(replace(v_old, v_from, ''))) / length(v_from);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'fixture 74 patch: anchor found % times, expected exactly 1', v_n;
  END IF;

  v_new := replace(v_old, v_from, v_to);

  IF position('abs_error' in v_new) > 0 THEN
    RAISE EXCEPTION 'fixture 74 patch: post-image still supplies abs_error';
  END IF;
  IF position('110, 100, true' in v_new) = 0 OR position('140, 100, true' in v_new) = 0 THEN
    RAISE EXCEPTION 'fixture 74 patch: post-image lost the engineered forecasts';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 74;
END
$mig$;
