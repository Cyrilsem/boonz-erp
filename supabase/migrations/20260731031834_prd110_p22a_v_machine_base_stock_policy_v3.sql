-- PRD-110 P2.2a migration 3/3 — v_machine_base_stock_policy_v3.
-- One row per in-scope pod-bound machine: the service inputs to S = mu*H + z*sigma*sqrt(H).
-- Read-only. Nothing consumes it yet; the engine wiring is P2.2c.
--
-- ARTICLE 16 — the visit vocabulary is the CANONICAL one. The registered metric
-- "Days since visit" (v_machine_health_signals.days_since_visit) defines a visit as
--   GREATEST(last dispatch evidence, last manual-refill evidence)
-- where dispatch evidence is (cancelled=false AND skipped=false AND (picked_up OR returned
-- OR dispatched OR packed)) and manual evidence is pod_inventory_audit_log rows whose
-- reference_id matches 'manual-refill-%' or 'adjust-%', joined on pal.machine_id DIRECTLY.
-- That object yields a RECENCY and so cannot yield inter-visit gaps; cadence is therefore a
-- NEW metric, and this view is its canonical object. What it may NOT do is invent a second
-- definition of "a visit" — measured 2026-07-31, a dispatch-only derivation disagrees on 13
-- of 30 machines, ALWAYS overstating the gap (up to 1.60x). An overstated interval inflates
-- the horizon, fill_to_cap absorbs it, and the engine degenerates to always-max-fill with no
-- error at all: S-43's failure mode, reintroduced quietly.
--
-- THREE TIERS ARE MANDATORY, NOT DEFENSIVE. AMZ-1046-2406-O1 (16 pod-bound shelves) has
-- NEITHER a machine_service_policy row NOR any measurable inter-visit gap in the window.
-- Two tiers starve it silently (LAW 5). interval_source NAMES the tier that fired (LAW 6).
--
-- machine_service_policy is CS-owned data and is READ ONLY here (D-14).

CREATE OR REPLACE VIEW public.v_machine_base_stock_policy_v3
WITH (security_invoker = true) AS
WITH p AS (
  SELECT base_stock_lead_days              AS lead_d,
         base_stock_default_interval_days  AS def_iv,
         base_stock_min_gaps               AS min_g,
         base_stock_cadence_lookback_days  AS look,
         base_stock_max_horizon_days       AS max_h,
         base_stock_interval_precedence    AS prec,
         z_mid
    FROM public.refill_policy_params
   LIMIT 1
),
scope AS (
  SELECT DISTINCT ss.machine_id, ss.machine_name
    FROM public.v_shelf_state ss
   WHERE ss.pod_product_id IS NOT NULL
),
dispatch_visits AS (
  SELECT DISTINCT rd.machine_id, rd.dispatch_date AS visit_date
    FROM public.refill_dispatching rd
    JOIN scope s ON s.machine_id = rd.machine_id
   CROSS JOIN p
   WHERE rd.cancelled = false
     AND rd.skipped   = false
     AND (rd.picked_up = true OR rd.returned = true OR rd.dispatched = true OR rd.packed = true)
     AND rd.dispatch_date >= CURRENT_DATE - p.look
     AND rd.dispatch_date <= CURRENT_DATE
),
manual_visits AS (
  SELECT DISTINCT pal.machine_id, pal.created_at::date AS visit_date
    FROM public.pod_inventory_audit_log pal
    JOIN scope s ON s.machine_id = pal.machine_id
   CROSS JOIN p
   WHERE (pal.reference_id LIKE 'manual-refill-%' OR pal.reference_id LIKE 'adjust-%')
     AND pal.created_at::date >= CURRENT_DATE - p.look
),
all_visits AS (
  SELECT machine_id, visit_date FROM dispatch_visits
  UNION
  SELECT machine_id, visit_date FROM manual_visits
),
gaps AS (
  SELECT machine_id,
         (visit_date - LAG(visit_date) OVER (PARTITION BY machine_id ORDER BY visit_date))::numeric AS gap_days
    FROM all_visits
),
observed AS (
  SELECT machine_id,
         count(gap_days)::integer AS n_gaps,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_days)::numeric AS median_gap
    FROM gaps
   WHERE gap_days IS NOT NULL
   GROUP BY machine_id
),
resolved AS (
  SELECT s.machine_id,
         s.machine_name,
         msp.machine_class,
         o.median_gap                        AS observed_median_gap_days,
         COALESCE(o.n_gaps, 0)               AS observed_n_gaps,
         msp.trip_interval_days::numeric     AS policy_trip_interval_days,
         p.lead_d                            AS lead_days,
         COALESCE(msp.z_default, p.z_mid)    AS z,
         CASE WHEN msp.z_default IS NOT NULL THEN 'machine_service_policy'
              ELSE 'param_z_mid' END         AS z_source,
         p.def_iv, p.max_h,
         CASE WHEN p.prec = 'policy_first'
              THEN CASE WHEN msp.trip_interval_days IS NOT NULL     THEN 'policy_seed'
                        WHEN COALESCE(o.n_gaps,0) >= p.min_g        THEN 'observed'
                        ELSE 'param_default' END
              ELSE CASE WHEN COALESCE(o.n_gaps,0) >= p.min_g        THEN 'observed'
                        WHEN msp.trip_interval_days IS NOT NULL     THEN 'policy_seed'
                        ELSE 'param_default' END
         END                                 AS interval_source
    FROM scope s
   CROSS JOIN p
    LEFT JOIN public.machine_service_policy msp ON msp.machine_id = s.machine_id
    LEFT JOIN observed o                        ON o.machine_id   = s.machine_id
),
sized AS (
  SELECT r.*,
         CASE r.interval_source
              WHEN 'observed'    THEN r.observed_median_gap_days
              WHEN 'policy_seed' THEN r.policy_trip_interval_days
              ELSE r.def_iv
         END AS visit_interval_days
    FROM resolved r
)
SELECT sized.machine_id,
       sized.machine_name,
       sized.machine_class,
       sized.visit_interval_days,
       sized.interval_source,
       sized.observed_median_gap_days,
       sized.observed_n_gaps,
       sized.policy_trip_interval_days,
       sized.lead_days,
       sized.z,
       sized.z_source,
       LEAST(GREATEST(sized.visit_interval_days + sized.lead_days, 1), sized.max_h) AS horizon_days
  FROM sized;

COMMENT ON VIEW public.v_machine_base_stock_policy_v3 IS
  'PRD-110 P2.2a. Canonical object for MACHINE VISIT CADENCE and the base-stock horizon. One row per in-scope pod-bound machine. Observed cadence uses the CANONICAL visit vocabulary (Article 16: dispatch evidence UNION manual-refill/adjust, matching v_machine_health_signals.days_since_visit) — never a dispatch-only derivation, which overstates gaps on 13 of 30 machines. Three-tier precedence, observed_first by default (S-43); interval_source names the tier. machine_service_policy is read-only here (D-14). Pinned by golden fixture 28.';

REVOKE ALL ON public.v_machine_base_stock_policy_v3 FROM anon;
REVOKE ALL ON public.v_machine_base_stock_policy_v3 FROM authenticated;
GRANT SELECT ON public.v_machine_base_stock_policy_v3 TO authenticated;
