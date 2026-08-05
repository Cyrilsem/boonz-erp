-- PRD-110 P3.4 — propose_facing_changes_v3: the rightsizing proposer.
--
-- Reads v_facing_performance_v3 and emits at most one proposal per (machine, family):
--   SHRINK  a family whose lanes each earn far LESS than this machine's median lane.
--   EXPAND  a family whose lanes each earn far MORE than the median AND which is STARVED.
--
-- ⛔ WHY EXPAND REQUIRES STARVATION AND SHRINK DOES NOT. High revenue per lane on its own is
-- an argument for RESTOCKING the lane, not for building a second one. The only evidence that
-- a second lane would sell more is that the first one keeps running dry -- which is exactly
-- what starvation_ratio (in-stock rate / calendar rate) measures. Without this gate the
-- engine would propose extra lanes for every strong seller in the fleet and be right about
-- almost none of them.
--
-- ⛔ TWO GUARDS AGAINST A RATIO FIRING ON NOISE:
--   (1) fac_min_abs_rev_gap_aed -- an absolute AED floor. 0.02 vs 0.05 AED/lane/day is a 2.5x
--       ratio and a 0.03 AED decision. The ratio alone would emit it.
--   (2) fac_min_peer_families -- a machine needs a real peer group before its median means
--       anything. A median over two lanes is not a benchmark.
--
-- ⛔ EXCLUDED, EACH FOR A STATED REASON, EACH COUNTED IN THE RETURN (LAW 5: nothing is
-- silently dropped -- every family the proposer declines to judge is reported):
--   · outside the refill universe        -- not ours to plan
--   · operating_model = 'partner_managed'-- the partner owns that assortment
--   · price_basis = 'none'               -- no AED basis; a revenue metric without a price is
--                                           not a weak signal, it is no signal
--   · velocity_basis <> 'instock_split'  -- 71 live families have no in-stock rate; without it
--                                           there is no potential metric and no starvation test
--   · too few peer families              -- no usable median
--
-- ⛔ S-75: p_plan_date is a BATCH KEY, not a clock. Fixtures use synthetic 2030 dates. Every
-- measurement here comes from the live view (CURRENT_DATE-based windows); p_plan_date only
-- groups and de-duplicates the batch. Nothing in this body compares it to a date.
--
-- ⛔ LAW 4 / SHADOW: writes facing_proposals_v3 and NOTHING else. No plan row, no dispatch
-- leg, no planogram, no shelf_configurations, no machines_to_visit. Not wired to any cron.

CREATE OR REPLACE FUNCTION public.propose_facing_changes_v3(
  p_plan_date date,
  p_limit     integer DEFAULT NULL,
  p_dry_run   boolean DEFAULT false
)
RETURNS TABLE (
  proposals_written    integer,
  shrink_count         integer,
  expand_count         integer,
  families_considered  integer,
  skipped_universe     integer,
  skipped_partner      integer,
  skipped_no_price     integer,
  skipped_no_velocity  integer,
  skipped_thin_peers   integer,
  dry_run              boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_limit        integer;
  v_maxprop      integer;
  v_written      integer := 0;
  v_shrink       integer := 0;
  v_expand       integer := 0;
BEGIN
  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'propose_facing_changes_v3: p_plan_date is required';
  END IF;
  IF p_limit IS NOT NULL AND p_limit <= 0 THEN
    RAISE EXCEPTION 'propose_facing_changes_v3: p_limit must be positive, got %', p_limit;
  END IF;

  PERFORM set_config('app.via_rpc',  'true',                        true);
  PERFORM set_config('app.rpc_name', 'propose_facing_changes_v3',   true);

  SELECT fac_max_proposals INTO v_maxprop FROM public.refill_policy_params LIMIT 1;
  IF v_maxprop IS NULL THEN
    RAISE EXCEPTION 'propose_facing_changes_v3: refill_policy_params holds no row';
  END IF;
  v_limit := LEAST(COALESCE(p_limit, v_maxprop), v_maxprop);

  -- ⛔ READ THE VIEW EXACTLY ONCE. S-26 / RISK 88: v_facing_performance_v3 inherits the
  -- ~20 s cost of v_shelf_instock_velocity_split_v3, and machine-scoping does NOT reduce it
  -- (the inner vel CTE is MATERIALIZED, so no predicate pushes down). The first draft of
  -- this function computed its five skip counters as six separate subqueries over the view
  -- and blew a 2-minute timeout outright. Everything below reads this snapshot.
  -- ⛔ ON COMMIT DROP DROPS AT COMMIT, NOT AT RETURN. A SECOND call inside the SAME
  -- transaction therefore hits `relation "_fac_perf" already exists` -- which is exactly
  -- what the idempotency contract (STEP 7 S4: re-run every engine 3x on the same date)
  -- and golden fixture 48 (three calls in one transaction: dry+limit, real, re-run) both
  -- do. The scratch tables must be rebuilt PER CALL, not per transaction. Caught by
  -- dry-running the BEHAVIOUR rather than the DDL.
  DROP TABLE IF EXISTS pg_temp._fac_perf;
  DROP TABLE IF EXISTS pg_temp._fac_cand;

  CREATE TEMP TABLE _fac_perf ON COMMIT DROP AS
    SELECT * FROM public.v_facing_performance_v3;

  CREATE TEMP TABLE _fac_cand (
    machine_id uuid, pod_product_id uuid, direction text,
    facings_current int, facings_proposed int,
    rev_pot numeric, rev_real numeric, med numeric, peers int,
    ratio numeric, starv numeric, price numeric, price_basis text, velocity_basis text,
    stock_units int, capacity_units int, score numeric, breakdown jsonb
  ) ON COMMIT DROP;

  INSERT INTO _fac_cand
  SELECT f.machine_id, f.pod_product_id, d.direction,
         f.facings,
         CASE WHEN d.direction = 'shrink' THEN f.facings - 1 ELSE f.facings + 1 END,
         f.rev_per_facing_day_potential, f.rev_per_facing_day_realized,
         f.machine_peer_median_potential, f.machine_peer_families,
         d.ratio, f.starvation_ratio, f.unit_price, f.price_basis, f.velocity_basis,
         f.stock_units, f.capacity_units,
         round(abs(d.ratio - 1.0), 4),
         jsonb_build_object(
           'metric',            'rev_per_facing_day_potential (in-stock rate / facings)',
           'velocity_grain',    'POTENTIAL = in-stock-day rate; REALIZED calendar rate carried beside it, never mixed',
           'rev_per_facing_day_potential', f.rev_per_facing_day_potential,
           'rev_per_facing_day_realized',  f.rev_per_facing_day_realized,
           'machine_peer_median',          f.machine_peer_median_potential,
           'peer_families',                f.machine_peer_families,
           'ratio_to_median',              d.ratio,
           'abs_gap_aed',                  round(abs(f.rev_per_facing_day_potential - f.machine_peer_median_potential), 4),
           'starvation_ratio',             f.starvation_ratio,
           'starvation_required',          (d.direction = 'expand'),
           'facings_current',              f.facings,
           'price_basis',                  f.price_basis,
           'velocity_basis',               f.velocity_basis,
           'identity_source',              'v_shelf_sales_identity (canonical alias owner, Article 16)',
           'instock_source',               'v_shelf_instock_velocity_split_v3',
           'plan_date_role',               'batch key only, never a clock (S-75)',
           'thresholds', jsonb_build_object(
              'shrink_ratio', prm.fac_shrink_ratio, 'expand_ratio', prm.fac_expand_ratio,
              'starvation_ratio', prm.fac_starvation_ratio,
              'min_abs_rev_gap_aed', prm.fac_min_abs_rev_gap_aed,
              'min_peer_families', prm.fac_min_peer_families,
              'min_facings_to_shrink', prm.fac_min_facings_to_shrink)
         )
  FROM _fac_perf f
  CROSS JOIN public.refill_policy_params prm
  CROSS JOIN LATERAL (
    SELECT f.rev_per_facing_day_potential / NULLIF(f.machine_peer_median_potential, 0) AS ratio
  ) r
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN f.facings >= prm.fac_min_facings_to_shrink
       AND r.ratio  <  prm.fac_shrink_ratio
       AND (f.machine_peer_median_potential - f.rev_per_facing_day_potential) >= prm.fac_min_abs_rev_gap_aed
        THEN 'shrink'
      WHEN r.ratio > prm.fac_expand_ratio
       AND f.starvation_ratio IS NOT NULL
       AND f.starvation_ratio >= prm.fac_starvation_ratio
       AND (f.rev_per_facing_day_potential - f.machine_peer_median_potential) >= prm.fac_min_abs_rev_gap_aed
        THEN 'expand'
      END AS direction, r.ratio
  ) d
  WHERE d.direction IS NOT NULL
    AND f.in_refill_universe
    AND f.operating_model IS DISTINCT FROM 'partner_managed'
    AND f.price_basis    <> 'none'
    AND f.velocity_basis  = 'instock_split'
    AND f.machine_peer_families >= prm.fac_min_peer_families;

  IF NOT p_dry_run THEN
    WITH ranked AS (
      SELECT * FROM _fac_cand ORDER BY score DESC, machine_id, pod_product_id LIMIT v_limit
    ), ins AS (
      INSERT INTO public.facing_proposals_v3 (
        plan_date, machine_id, pod_product_id, direction, facings_current, facings_proposed,
        rev_per_facing_day_potential, rev_per_facing_day_realized, machine_peer_median,
        peer_families, ratio_to_median, starvation_ratio, unit_price, price_basis,
        velocity_basis, stock_units, capacity_units, score, scoring_breakdown)
      SELECT p_plan_date, machine_id, pod_product_id, direction, facings_current, facings_proposed,
             rev_pot, rev_real, med, peers, ratio, starv, price, price_basis,
             velocity_basis, stock_units, capacity_units, score, breakdown
      FROM ranked
      ON CONFLICT ON CONSTRAINT fp_v3_unique_batch DO NOTHING
      RETURNING direction
    )
    SELECT count(*)::int,
           count(*) FILTER (WHERE direction = 'shrink')::int,
           count(*) FILTER (WHERE direction = 'expand')::int
      INTO v_written, v_shrink, v_expand
    FROM ins;
  ELSE
    SELECT count(*)::int,
           count(*) FILTER (WHERE direction = 'shrink')::int,
           count(*) FILTER (WHERE direction = 'expand')::int
      INTO v_written, v_shrink, v_expand
    FROM (SELECT direction FROM _fac_cand ORDER BY score DESC LIMIT v_limit) z;
  END IF;

  RETURN QUERY
  SELECT v_written, v_shrink, v_expand,
         (SELECT count(*)::int FROM _fac_perf),
         (SELECT count(*)::int FROM _fac_perf WHERE NOT in_refill_universe),
         (SELECT count(*)::int FROM _fac_perf WHERE operating_model = 'partner_managed'),
         (SELECT count(*)::int FROM _fac_perf WHERE price_basis = 'none'),
         (SELECT count(*)::int FROM _fac_perf WHERE velocity_basis <> 'instock_split'),
         (SELECT count(*)::int FROM _fac_perf prm2
            CROSS JOIN public.refill_policy_params p3
            WHERE prm2.machine_peer_families < p3.fac_min_peer_families),
         p_dry_run;
END;
$fn$;

COMMENT ON FUNCTION public.propose_facing_changes_v3(date, integer, boolean) IS
'PRD-110 P3.4 facing rightsizing proposer. ADVISORY: writes facing_proposals_v3 at status pending and nothing else - no plan row, no dispatch leg, no planogram or shelf_configurations touch (all protected). p_dry_run computes the full answer and writes nothing. Idempotent per (plan_date, machine_id, pod_product_id). SHRINK needs only a below-median lane; EXPAND additionally requires starvation_ratio >= threshold, because high revenue per lane alone argues for restocking, not for another lane. Reads v_facing_performance_v3 ONLY. p_plan_date is a batch key, never a clock (S-75). Not wired to any cron. Pinned by golden fixture 48.';

-- ⛔ S-88, which fired for real on this unit''s sibling last leg: RLS is not the write guard,
-- the GRANT is. A SECURITY DEFINER reachable by anon is an unauthenticated write path.
REVOKE ALL ON FUNCTION public.propose_facing_changes_v3(date, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.propose_facing_changes_v3(date, integer, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.propose_facing_changes_v3(date, integer, boolean) TO service_role;
