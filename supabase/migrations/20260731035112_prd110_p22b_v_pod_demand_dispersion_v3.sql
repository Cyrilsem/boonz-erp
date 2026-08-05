-- PRD-110 P2.2b - the dispersion (sigma) term of S = mu*L + z*sigma*sqrt(L).
--
-- WHY A RATIO AND NOT A SIGMA (S-44, and S-13 in a new costume):
--   sigma computed over "days with sales" drops zero-demand days and counts stockout days as zero,
--   while the canonical mu (velocity_instock) is already in-stock-corrected. Mixing those two bases
--   is exactly the two-incompatible-units defect S-13 was raised for. The fix is to keep sigma_obs
--   and mu_obs on the SAME (observed) basis and export only the scale-free ratio
--       phi = sigma_obs / sqrt(mu_obs)
--   which the engine then applies to the CANONICAL mu:
--       sigma_daily_pod   = phi * sqrt(velocity_instock_pod)
--       sigma_daily_shelf = sigma_daily_pod * (velocity_instock_shelf / velocity_instock_pod)
--   Numerator and denominator shift together, so phi is robust to the basis difference.
--
-- WHY THIS VIEW IS CHEAP AND DELIBERATELY STOPS AT phi (RISK 88):
--   it reads sales history only. It does NOT join either velocity object. The shelf split is left
--   to engine_add_pod_v3 (P2.2c), which already evaluates v_shelf_instock_velocity_split_v3 once -
--   folding it in here would make every reader pay for that expensive object a second time.
--   ⚠️ There is therefore NO shelf-grain sigma view by design. Do not go looking for one.
--
-- Measured 2026-07-31 (leg 39): 469 in-scope canonical (machine, pod) pairs over 31 machines.
--   own 163 · pod_prior 198 · fleet_prior 108 (a partition - no pair is left without a phi).
--   52 pairs have ZERO sales in the window and are still covered, because scope comes from
--   v_shelf_state and not from the sales table. fleet phi = 0.690066.

-- ---------------------------------------------------------------------------------------------
-- The canonical pod-alias owner (S-38). Both velocity objects carry this mapping as an INLINE
-- VALUES list; this is the first named owner of it. It is ADDITIVE - the existing inline copies
-- are untouched, and golden fixture 29 seq 16/17 is the standing guard that they do not diverge.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_pod_product_canonical_v3 AS
WITH alias(pod_product_id, canonical_pod) AS (
  VALUES ('168aeb7e-fc0c-441b-94df-6d8cc185945d'::uuid, '51e4600f-2c15-428b-92ef-85fdc783c3af'::uuid)
)
SELECT pp.pod_product_id,
       COALESCE(al.canonical_pod, pp.pod_product_id) AS canonical_pod_product_id,
       (al.canonical_pod IS NOT NULL)                AS is_alias
  FROM public.pod_products pp
  LEFT JOIN alias al ON al.pod_product_id = pp.pod_product_id;

COMMENT ON VIEW public.v_pod_product_canonical_v3 IS
  'PRD-110 P2.2b. Canonical owner of the pod-product alias map (Hunter -> Hunter Ridge). Join ANY raw pod_product_id through this to get the key the canonical velocity objects use. Added because the map had three inline copies and no owner (S-38), which is how S-37 (a raw key joined against a canonical one) happened.';

-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_pod_demand_dispersion_v3 AS
WITH p AS (
  SELECT base_stock_sigma_lookback_days        AS look,
         base_stock_sigma_min_days             AS min_d,
         base_stock_sigma_phi_floor            AS phi_floor,
         base_stock_sigma_prior_precedence     AS prec
    FROM public.refill_policy_params
   LIMIT 1
), scope AS (
  SELECT DISTINCT ss.machine_id, ss.machine_name, c.canonical_pod_product_id AS pod_product_id
    FROM public.v_shelf_state ss
    JOIN public.v_pod_product_canonical_v3 c ON c.pod_product_id = ss.pod_product_id
   WHERE ss.pod_product_id IS NOT NULL
), daily AS (
  -- RISK 91: the vocabulary is 'Successful'. The bare 'Success' literal matches ZERO rows and would
  -- make sigma 0 fleet-wide with no error. Both accepted here, exactly as the canonical velocity
  -- object does; fixture 29 seq 14/15 is the tripwire.
  SELECT s.machine_id,
         c.canonical_pod_product_id AS pod_product_id,
         s.transaction_date::date   AS sale_date,
         sum(s.qty)                 AS units
    FROM public.v_sales_history_resolved s
    JOIN public.v_pod_product_canonical_v3 c ON c.pod_product_id = s.pod_product_id
    JOIN (SELECT DISTINCT machine_id FROM scope) m ON m.machine_id = s.machine_id
    CROSS JOIN p
   WHERE s.pod_product_id IS NOT NULL
     AND s.delivery_status = ANY (ARRAY['Success'::text, 'Successful'::text])
     AND s.transaction_date::date >= CURRENT_DATE - p.look
   GROUP BY 1, 2, 3
), obs AS (
  SELECT machine_id, pod_product_id,
         count(*)::integer           AS n_sale_days,
         avg(units)::numeric         AS mu_obs,
         stddev_samp(units)::numeric AS sigma_obs
    FROM daily
   GROUP BY 1, 2
), ownp AS (
  SELECT o.machine_id, o.pod_product_id, o.n_sale_days, o.mu_obs, o.sigma_obs,
         CASE WHEN o.n_sale_days >= p.min_d AND o.mu_obs > 0 AND o.sigma_obs IS NOT NULL
              THEN o.sigma_obs / sqrt(o.mu_obs)
         END AS phi_own
    FROM obs o CROSS JOIN p
), pod_prior AS (
  SELECT pod_product_id,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY phi_own)::numeric AS phi_pod_prior,
         count(*)::integer                                             AS phi_pod_prior_n
    FROM ownp WHERE phi_own IS NOT NULL GROUP BY pod_product_id
), fleet AS (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY phi_own)::numeric AS phi_fleet_prior,
         count(*)::integer                                             AS phi_fleet_prior_n
    FROM ownp WHERE phi_own IS NOT NULL
), r AS (
  SELECT s.machine_id, s.machine_name, s.pod_product_id, pp.pod_product_name AS pod_name,
         o.n_sale_days, o.mu_obs, o.sigma_obs, o.phi_own,
         CASE WHEN p.prec <> 'fleet_only' THEN pr.phi_pod_prior END AS phi_pod_prior,
         pr.phi_pod_prior_n,
         f.phi_fleet_prior, f.phi_fleet_prior_n,
         p.look AS lookback_days, p.min_d AS min_sale_days, p.phi_floor, p.prec AS prior_precedence
    FROM scope s
    CROSS JOIN p
    CROSS JOIN fleet f
    LEFT JOIN ownp o      ON o.machine_id = s.machine_id AND o.pod_product_id = s.pod_product_id
    LEFT JOIN pod_prior pr ON pr.pod_product_id = s.pod_product_id
    LEFT JOIN public.pod_products pp ON pp.pod_product_id = s.pod_product_id
)
SELECT r.machine_id,
       r.machine_name,
       r.pod_product_id,
       r.pod_name,
       r.n_sale_days,
       r.mu_obs,
       r.sigma_obs,
       r.phi_own,
       r.phi_pod_prior,
       r.phi_pod_prior_n,
       r.phi_fleet_prior,
       r.phi_fleet_prior_n,
       -- LAW 5: never NULL. The final COALESCE onto phi_floor is the degenerate-data backstop and
       -- it NAMES itself as 'floor_no_history' rather than passing silently as a real estimate.
       GREATEST(r.phi_floor,
                COALESCE(r.phi_own, r.phi_pod_prior, r.phi_fleet_prior, r.phi_floor)) AS phi,
       CASE WHEN r.phi_own         IS NOT NULL THEN 'own'
            WHEN r.phi_pod_prior   IS NOT NULL THEN 'pod_prior'
            WHEN r.phi_fleet_prior IS NOT NULL THEN 'fleet_prior'
            ELSE 'floor_no_history'
       END AS phi_source,
       r.lookback_days,
       r.min_sale_days,
       r.phi_floor,
       r.prior_precedence
  FROM r;

COMMENT ON VIEW public.v_pod_demand_dispersion_v3 IS
  'PRD-110 P2.2b. Canonical dispersion input to the base-stock target. One row per in-scope canonical (machine, pod) pair, scoped from v_shelf_state so zero-sales pairs are covered. Exports the scale-free ratio phi = sigma_obs/sqrt(mu_obs) with a NAMED three-tier ladder (own -> pod_prior -> fleet_prior, plus a floor_no_history backstop); phi is never NULL. The engine applies it as sigma_daily_pod = phi*sqrt(velocity_instock_pod) and splits to shelf with the already-canonical weight velocity_instock_shelf/velocity_instock_pod. Cheap by design: reads sales history only, joins NEITHER velocity object (RISK 88).';

REVOKE ALL ON public.v_pod_product_canonical_v3  FROM PUBLIC, anon;
REVOKE ALL ON public.v_pod_demand_dispersion_v3  FROM PUBLIC, anon;
GRANT SELECT ON public.v_pod_product_canonical_v3 TO authenticated;
GRANT SELECT ON public.v_pod_demand_dispersion_v3 TO authenticated;
