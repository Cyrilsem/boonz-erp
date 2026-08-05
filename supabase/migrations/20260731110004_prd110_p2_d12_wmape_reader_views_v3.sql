-- PRD-110 · P2 · D-12. The two READER objects over the WMAPE snapshot. Both stay VIEWS, so
-- ADR §2's "do not materialize the same answer twice" holds for everything cheaply derivable
-- (ADR §10.3). RISK 102 idiom throughout: these objects must be able to say "I measured nothing".

BEGIN;

CREATE VIEW public.v_engine_wmape_v3 WITH (security_invoker = true) AS
SELECT
  e.plan_date,
  e.engine_tag,
  count(*)::bigint                                        AS n_series,
  count(*) FILTER (WHERE e.actuals_settled)::bigint       AS n_series_settled,
  max(e.horizon_end)                                      AS horizon_end_max,
  max(e.measured_at)                                      AS measured_at,
  round(sum(e.forecast_units), 4)                         AS sum_forecast,
  round(sum(e.forecast_units) FILTER (WHERE e.actuals_settled), 4) AS sum_forecast_settled,
  round(sum(e.actual_units)   FILTER (WHERE e.actuals_settled), 4) AS sum_actual,
  round(sum(e.abs_error)      FILTER (WHERE e.actuals_settled), 4) AS sum_abs_error,
  round(sum(e.signed_error)   FILTER (WHERE e.actuals_settled), 4) AS sum_signed_error,
  -- WMAPE over SETTLED rows only. NULL — never 0.0 — when there is nothing to score.
  CASE
    WHEN count(*) FILTER (WHERE e.actuals_settled) = 0 THEN NULL
    WHEN COALESCE(sum(e.actual_units) FILTER (WHERE e.actuals_settled), 0) = 0 THEN NULL
    ELSE round( sum(e.abs_error)    FILTER (WHERE e.actuals_settled)
              / sum(e.actual_units) FILTER (WHERE e.actuals_settled), 4)
  END AS wmape,
  -- Signed bias. Positive = the engine over-forecast. See the COMMENT: v3 is expected to run
  -- positive relative to v19 on stockout-prone shelves, and that is NOT evidence v3 is worse.
  CASE
    WHEN count(*) FILTER (WHERE e.actuals_settled) = 0 THEN NULL
    WHEN COALESCE(sum(e.actual_units) FILTER (WHERE e.actuals_settled), 0) = 0 THEN NULL
    ELSE round( sum(e.signed_error) FILTER (WHERE e.actuals_settled)
              / sum(e.actual_units) FILTER (WHERE e.actuals_settled), 4)
  END AS bias_ratio,
  ( count(*) FILTER (WHERE e.actuals_settled) = 0
    OR COALESCE(sum(e.actual_units) FILTER (WHERE e.actuals_settled), 0) = 0 ) AS is_vacuous,
  CASE
    WHEN count(*) FILTER (WHERE e.actuals_settled) = 0 THEN 'horizon_not_elapsed'
    WHEN COALESCE(sum(e.actual_units) FILTER (WHERE e.actuals_settled), 0) = 0 THEN 'zero_actuals'
  END AS vacuous_reason
FROM public.engine_forecast_error_v3 e
GROUP BY e.plan_date, e.engine_tag;

COMMENT ON VIEW public.v_engine_wmape_v3 IS
'PRD-110 D-12. WMAPE per (plan_date, engine) over engine_forecast_error_v3. ⛔ ALWAYS BRANCH ON '
'is_vacuous BEFORE QUOTING wmape (RISK 102): wmape is NULL, never 0.0, when the horizon has not '
'elapsed or actuals sum to zero, and vacuous_reason names which. ⚠️ INTERPRETING bias_ratio ACROSS '
'ENGINES: v19 forecasts from velocity_30d (calendar sales / 30, already CENSORED by stockouts) while '
'v3 forecasts from velocity_instock (sales per IN-STOCK day, deliberately UNCENSORED). Actuals are '
'censored. So on shelves that stocked out, v3 will over-forecast relative to v19 precisely BECAUSE it '
'corrected the suppression bug — a higher v3 bias_ratio there is expected and is not evidence v3 is '
'worse. Segmenting WMAPE by stockout exposure is parked (see PARKING-LOT, leg 52).';

CREATE VIEW public.v_engine_wmape_v3_gate WITH (security_invoker = true) AS
SELECT
  COALESCE(a.plan_date, b.plan_date)                          AS plan_date,
  a.wmape                                                     AS wmape_v19,
  b.wmape                                                     AS wmape_v3,
  a.n_series_settled                                          AS n_settled_v19,
  b.n_series_settled                                          AS n_settled_v3,
  a.sum_actual                                                AS actual_units_v19,
  b.sum_actual                                                AS actual_units_v3,
  a.bias_ratio                                                AS bias_v19,
  b.bias_ratio                                                AS bias_v3,
  CASE WHEN a.wmape IS NULL OR b.wmape IS NULL THEN NULL
       ELSE round(b.wmape - a.wmape, 4) END                   AS wmape_delta,
  -- The Phase-2 GATE question: WMAPE(v3) <= WMAPE(v19)? NULL means UNKNOWN, never a verdict.
  CASE WHEN a.wmape IS NULL OR b.wmape IS NULL THEN NULL
       ELSE (b.wmape <= a.wmape) END                          AS v3_meets_gate,
  (a.wmape IS NULL OR b.wmape IS NULL)                        AS is_vacuous,
  CASE
    WHEN a.plan_date IS NULL                    THEN 'no_v19_measurement'
    WHEN b.plan_date IS NULL                    THEN 'no_v3_measurement'
    WHEN a.wmape IS NULL AND b.wmape IS NULL    THEN COALESCE(a.vacuous_reason, b.vacuous_reason)
    WHEN a.wmape IS NULL                        THEN 'v19_' || COALESCE(a.vacuous_reason,'vacuous')
    WHEN b.wmape IS NULL                        THEN 'v3_'  || COALESCE(b.vacuous_reason,'vacuous')
  END                                                         AS vacuous_reason
FROM      (SELECT * FROM public.v_engine_wmape_v3 WHERE engine_tag = 'v19') a
FULL JOIN (SELECT * FROM public.v_engine_wmape_v3 WHERE engine_tag = 'v3')  b
       ON b.plan_date = a.plan_date;

COMMENT ON VIEW public.v_engine_wmape_v3_gate IS
'PRD-110 D-12. Head-to-head answer to the Phase-2 GATE clause "WMAPE(v3) <= WMAPE(v19)". '
'⛔ v3_meets_gate is NULL (UNKNOWN) whenever EITHER side is vacuous — a date where only one engine '
'ran, or whose horizon has not elapsed, produces no verdict rather than a flattering one. A FULL JOIN '
'is used deliberately so a date measured for only one engine is visible as no_v19_measurement / '
'no_v3_measurement instead of vanishing (the v19_only lesson from v_engine_diff_v3).';

REVOKE ALL ON public.v_engine_wmape_v3      FROM anon;
REVOKE ALL ON public.v_engine_wmape_v3_gate FROM anon;
GRANT SELECT ON public.v_engine_wmape_v3      TO authenticated;
GRANT SELECT ON public.v_engine_wmape_v3_gate TO authenticated;

COMMIT;
