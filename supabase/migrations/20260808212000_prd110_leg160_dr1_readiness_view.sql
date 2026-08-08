-- PRD-110 DR-1 (leg 160) — v_cutover_readiness_v3, the per-cluster evidence gate.
-- Article 16: this becomes THE canonical object for "is a cluster ready for cutover".
-- Registered in METRICS_REGISTRY.md in the same commit.
--
-- ⭐ WHY THIS DOES NOT NEED THE S-175 SCOREBOARD PASS. The parking lot records that per-cluster
--    comparison "cannot be made" because scoreboard_daily_v3.scope_kind is 'fleet' only. That is
--    true OF THE SCOREBOARD and irrelevant here: engine_forecast_error_v3 carries machine_id and
--    joins to machines with ZERO unjoined rows, so the gate aggregates the error table directly.
--
-- ⛔⛔ S-307 — THE FILTER THAT IS THE WHOLE POINT OF THE `real` CTE. engine_forecast_error_v3 holds
--    529 rows on SYNTHETIC 2030 plan_dates, written by golden fixtures, spanning ALL 10 clusters
--    (VOX 119, INDEPENDENT 137, WPP 47, ADDMIND 32, VML 30, GRIT 7...). Six of those clusters have
--    never had a single REAL v3 series. Without `plan_date < '2027-01-01'` (S-244) this gate would
--    report v3 evidence for the largest cluster in the fleet, sourced entirely from fixture residue,
--    and would refuse it as "wait for the horizon" instead of "v3 has never planned this cluster".
--
-- ⛔ S-176: WMAPE is NULL where it cannot be computed. It is NEVER coerced to 0 — a fabricated zero
--    reads as a perfect forecast and would sign off a cutover on no evidence whatsoever.

CREATE OR REPLACE VIEW public.v_cutover_readiness_v3 AS
WITH live AS (
  SELECT m.venue_group AS cluster_key, count(*)::int AS n_machines_active
    FROM public.machines m
   WHERE m.status = 'Active' AND m.venue_group IS NOT NULL
   GROUP BY m.venue_group
),
real AS (
  -- S-244 / S-307: real planning window only. Synthetic fixture dates are not evidence.
  SELECT m.venue_group AS cluster_key, e.engine_tag,
         count(*)::int                                              AS n_series,
         count(*) FILTER (WHERE e.actuals_settled)::int             AS n_settled,
         max(e.plan_date)                                           AS last_plan_date,
         count(DISTINCT e.plan_date)::int                           AS n_dates,
         sum(e.abs_error)    FILTER (WHERE e.actuals_settled)       AS sum_abs_error,
         sum(e.signed_error) FILTER (WHERE e.actuals_settled)       AS sum_signed_error,
         sum(e.actual_units) FILTER (WHERE e.actuals_settled)       AS sum_actual
    FROM public.engine_forecast_error_v3 e
    JOIN public.machines m ON m.machine_id = e.machine_id
   WHERE e.plan_date < DATE '2027-01-01'
   GROUP BY m.venue_group, e.engine_tag
),
v3 AS (SELECT * FROM real WHERE engine_tag = 'v3'),
v19 AS (SELECT * FROM real WHERE engine_tag = 'v19'),
calc AS (
  SELECT
    l.cluster_key,
    l.n_machines_active,
    a.cluster_key IS NOT NULL                       AS is_registered,
    a.authoritative_engine,
    COALESCE(v3.n_series, 0)                        AS n_series_v3,
    COALESCE(v3.n_settled, 0)                       AS n_settled_v3,
    COALESCE(v19.n_series, 0)                       AS n_series_v19,
    COALESCE(v19.n_settled, 0)                      AS n_settled_v19,
    v3.last_plan_date                               AS last_v3_plan_date,
    v19.last_plan_date                              AS last_v19_plan_date,
    COALESCE(v3.n_dates, 0)                         AS n_v3_dates,
    v3.sum_actual                                   AS actual_units_v3,
    v19.sum_actual                                  AS actual_units_v19,
    CASE WHEN COALESCE(v3.n_settled,0) = 0 OR COALESCE(v3.sum_actual,0) = 0 THEN NULL
         ELSE round(v3.sum_abs_error / v3.sum_actual, 4) END        AS wmape_v3,
    CASE WHEN COALESCE(v19.n_settled,0) = 0 OR COALESCE(v19.sum_actual,0) = 0 THEN NULL
         ELSE round(v19.sum_abs_error / v19.sum_actual, 4) END      AS wmape_v19,
    CASE WHEN COALESCE(v3.n_settled,0) = 0 OR COALESCE(v3.sum_actual,0) = 0 THEN NULL
         ELSE round(v3.sum_signed_error / v3.sum_actual, 4) END     AS bias_v3,
    CASE WHEN COALESCE(v19.n_settled,0) = 0 OR COALESCE(v19.sum_actual,0) = 0 THEN NULL
         ELSE round(v19.sum_signed_error / v19.sum_actual, 4) END   AS bias_v19
  FROM live l
  LEFT JOIN public.engine_cutover_authority_v3 a ON a.cluster_key = l.cluster_key
  LEFT JOIN v3  ON v3.cluster_key  = l.cluster_key
  LEFT JOIN v19 ON v19.cluster_key = l.cluster_key
)
SELECT
  c.*,
  CASE WHEN c.wmape_v3 IS NULL OR c.wmape_v19 IS NULL THEN NULL
       ELSE round(c.wmape_v3 - c.wmape_v19, 4) END AS wmape_delta,
  (c.wmape_v3 IS NULL OR c.wmape_v19 IS NULL)      AS is_vacuous,
  -- ── THE REFUSAL TAXONOMY. First match wins; `ready` is the only accepting value. ──
  CASE
    WHEN NOT c.is_registered                    THEN 'cluster_not_registered'
    WHEN c.authoritative_engine = 'v3'          THEN 'already_v3'
    WHEN c.n_series_v3  = 0                     THEN 'no_v3_measurement'
    WHEN c.n_series_v19 = 0                     THEN 'no_v19_baseline'
    WHEN c.n_settled_v3  = 0                    THEN 'v3_horizon_not_elapsed'
    WHEN COALESCE(c.actual_units_v3,0)  = 0     THEN 'v3_zero_actuals'
    WHEN c.n_settled_v19 = 0                    THEN 'v19_horizon_not_elapsed'
    WHEN COALESCE(c.actual_units_v19,0) = 0     THEN 'v19_zero_actuals'
    WHEN c.wmape_v3 > c.wmape_v19               THEN 'v3_worse_than_v19'
    ELSE 'ready'
  END AS refusal_code
FROM calc c;

COMMENT ON VIEW public.v_cutover_readiness_v3 IS
 'PRD-110 DR-1. CANONICAL object (Article 16) for "is a cluster ready for v3 cutover". One row per '
 'ACTIVE cluster. Reads engine_forecast_error_v3 at machine grain over the REAL window only '
 '(plan_date < 2027-01-01, S-244/S-307) — synthetic fixture dates are not evidence. WMAPE is NULL '
 'when uncomputable and is never coerced to 0 (S-176). refusal_code=''ready'' is the only accept.';

REVOKE ALL ON public.v_cutover_readiness_v3 FROM anon;
REVOKE ALL ON public.v_cutover_readiness_v3 FROM PUBLIC;
GRANT SELECT ON public.v_cutover_readiness_v3 TO authenticated;

-- ── POST-IMAGE PROOFS (S-298) ────────────────────────────────────────────────
DO $post$
DECLARE
  v_rows int; v_ready int; v_no_v3 int; v_horizon int; v_vox text; v_vox_n int; v_fake numeric;
BEGIN
  SELECT count(*) INTO v_rows    FROM public.v_cutover_readiness_v3;
  SELECT count(*) INTO v_ready   FROM public.v_cutover_readiness_v3 WHERE refusal_code='ready';
  SELECT count(*) INTO v_no_v3   FROM public.v_cutover_readiness_v3 WHERE refusal_code='no_v3_measurement';
  SELECT count(*) INTO v_horizon FROM public.v_cutover_readiness_v3 WHERE refusal_code='v3_horizon_not_elapsed';
  SELECT refusal_code, n_series_v3 INTO v_vox, v_vox_n FROM public.v_cutover_readiness_v3 WHERE cluster_key='VOX';
  SELECT count(*) INTO v_fake FROM public.v_cutover_readiness_v3 WHERE is_vacuous AND wmape_v3 IS NOT NULL;

  IF v_rows <> 10 THEN RAISE EXCEPTION 'DR-1 gate: expected 10 cluster rows, got %', v_rows; END IF;
  IF v_ready <> 0 THEN RAISE EXCEPTION 'DR-1 gate: % cluster(s) read READY — v3 has zero settled series anywhere; this cannot be right', v_ready; END IF;
  IF v_vox <> 'no_v3_measurement' THEN
    RAISE EXCEPTION 'S-307 REGRESSION: VOX reads % (n_series_v3=%) — the synthetic 2030 fixture rows are leaking into the gate', v_vox, v_vox_n;
  END IF;
  IF v_vox_n <> 0 THEN RAISE EXCEPTION 'S-307 REGRESSION: VOX shows % real v3 series; expected 0', v_vox_n; END IF;
  IF v_fake <> 0 THEN RAISE EXCEPTION 'S-176 REGRESSION: % vacuous row(s) carry a non-NULL wmape_v3', v_fake; END IF;
  RAISE NOTICE 'DR-1 gate OK: 10 clusters, 0 ready, % no_v3_measurement, % horizon-pending, VOX clean', v_no_v3, v_horizon;
END
$post$;
