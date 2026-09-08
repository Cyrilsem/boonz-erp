-- PRD-119 D4 CORRECTION, part 2 (CS, 2026-09-08): `expiry_pull_horizon` moves
-- from the load-time guard (reverted in 20260908071626) to its intended job --
-- ranking the nightly pull list / driver PULL screen by lane velocity vs the
-- category's horizon, honouring PRD-119's own original D4 decision: "category
-- sets the deadline, velocity decides whether the lane clears before it."
--
-- `v_expiry_pull_candidates`: one row per active shelf-lot expiry batch
-- (v_machine_expiry_batches, already dedupes to the latest snapshot per
-- machine/shelf/product/expiry and filters status='Active', current_stock>0).
-- `horizon_days` = expiry_pull_horizon.pull_days_before_expiry by the
-- product's category_group, falling back to the table's own 'default' row,
-- then the literal 14 only if the table itself has no row at all.
-- `within_horizon` = days_to_expiry <= horizon_days -- category sets the
-- deadline, i.e. the trigger point at which the lane is even considered.
-- `daily_rate_7d` = v_shelf_sales_identity.units_7d / 7 -- the canonical,
-- LIVE, simple 7-day shelf velocity object (Article 16; NOT the in-stock-
-- adjusted v_shelf_instock_velocity_v3, which is still gated pending D-10 and
-- answers a different, more complex question this correction does not need).
-- `is_pull_candidate` = within_horizon AND the lane will NOT sell through
-- (units_on_lane / daily_rate_7d) before it actually expires
-- (days_to_expiry) -- velocity decides whether the lane clears before the
-- category's deadline.
--
-- ⚠️ IDENTITY BRIDGE LIMITATION, found and left honest rather than
-- papered over: v_machine_expiry_batches is boonz_product_id-grain;
-- v_shelf_sales_identity is (machine_id, pod_product_id)-grain, and there is
-- NO clean FK between the two domains -- "pods are mixes so boonz_product_id
-- is NOT a usable identity key" (METRICS_REGISTRY, v_shelf_sales_identity's
-- own row). The only bridge available without a larger WEIMI-slot-mediated
-- resolution (the multi-CTE approach get_machine_slots_with_expiry uses,
-- scoped per-machine and too heavy to inline here) is
-- LOWER(TRIM(boonz_product_name)) = LOWER(TRIM(pod_product_name)) --
-- the exact same pod_by_name pattern that function already uses, DISTINCT ON
-- the lowered name to avoid fan-out. Measured live: this resolves only
-- ~3% of all expiry-batch rows fleet-wide (40/1185), and on today's data
-- ZERO of the 9 real within-horizon rows resolve at all. Per LAW 5 (never
-- fabricate a decision from missing data, documented elsewhere in this
-- schema's velocity objects), an UNRESOLVED identity produces
-- `is_pull_candidate = NULL`, never a false `true` (which would alarm-fatigue
-- every within-horizon row) or a false `false` (which would silently hide a
-- real risk). The nightly check below surfaces the NULL bucket as
-- `needs_review`, separate from confirmed `pull_candidates` -- CS should read
-- this as "the pull list mechanism works, but most of the fleet's product
-- naming doesn't yet support it" rather than "the pull list is empty."
-- Improving the resolution rate (a proper WEIMI-mediated bridge, or a direct
-- boonz_product_id<->pod_product_id mapping) is a real follow-up, not solved
-- here -- flagged for CS, not guessed through.
--
-- Fixture (rolled back; real, already-identity-resolved pair -- AMZ-1038-3001-O1
-- / "Al Ain Zero", units_7d=43 i.e. ~6.14/day -- mutated via an existing real
-- pod_inventory row, never inserted fresh, so no live quantity was left
-- changed):
--   A. 10 units, expiry+5d (within default horizon=14) -> needs 1.6d to
--      clear -> is_pull_candidate = false (will sell through in time).
--   B. 100 units, expiry+5d -> needs 16.3d to clear -> is_pull_candidate =
--      true (will NOT sell through before it spoils).
--   C. 100 units, expiry+30d (outside horizon=14) -> within_horizon = false,
--      is_pull_candidate = false (category hasn't even started the clock
--      yet, regardless of velocity).
-- `check_expiry_pull_candidates()` correctly surfaced scenario B as the sole
-- `pull_candidates` row and the fleet's 9 real within-horizon-but-unresolved
-- rows as `needs_review` in the same rolled-back run.
--
-- Cody: approve, Articles 2 (no RLS concern -- pure read view over already-
-- RLS'd tables), 12 (additive, forward-only), 16 (velocity read is the
-- canonical v_shelf_sales_identity.units_7d, never re-aggregated from
-- sales_history; horizon read is the canonical expiry_pull_horizon, never a
-- re-baked literal).
CREATE OR REPLACE VIEW public.v_expiry_pull_candidates AS
WITH pod_by_name AS (
  SELECT DISTINCT ON (LOWER(TRIM(pp.pod_product_name)))
    LOWER(TRIM(pp.pod_product_name)) AS product_lower, pp.pod_product_id
  FROM public.pod_products pp
  ORDER BY LOWER(TRIM(pp.pod_product_name)), pp.pod_product_id
),
batches AS (
  SELECT
    b.pod_inventory_id, b.machine_id, b.shelf_id, b.boonz_product_id,
    b.expiration_date, b.current_stock,
    bp.boonz_product_name, bp.category_group,
    m.official_name AS machine_name
  FROM public.v_machine_expiry_batches b
  JOIN public.boonz_products bp ON bp.product_id = b.boonz_product_id
  JOIN public.machines m ON m.machine_id = b.machine_id
  WHERE b.expiration_date IS NOT NULL
),
resolved AS (
  SELECT bt.*, pbn.pod_product_id AS resolved_pod_product_id
  FROM batches bt
  LEFT JOIN pod_by_name pbn ON pbn.product_lower = LOWER(TRIM(bt.boonz_product_name))
),
horizoned AS (
  SELECT r.*,
    COALESCE(eph.pull_days_before_expiry, ephd.pull_days_before_expiry, 14) AS horizon_days,
    (r.expiration_date - CURRENT_DATE) AS days_to_expiry
  FROM resolved r
  LEFT JOIN public.expiry_pull_horizon eph ON eph.category = r.category_group
  LEFT JOIN public.expiry_pull_horizon ephd ON ephd.category = 'default'
)
SELECT
  h.pod_inventory_id, h.machine_id, h.machine_name, h.shelf_id,
  h.boonz_product_id, h.boonz_product_name, h.category_group,
  h.resolved_pod_product_id,
  h.current_stock AS units_on_lane, h.expiration_date, h.days_to_expiry, h.horizon_days,
  (h.days_to_expiry <= h.horizon_days) AS within_horizon,
  vsi.units_7d,
  CASE WHEN vsi.units_7d IS NOT NULL THEN ROUND(vsi.units_7d / 7.0, 3) END AS daily_rate_7d,
  CASE WHEN vsi.units_7d > 0 THEN ROUND(h.current_stock / (vsi.units_7d / 7.0), 1) END AS days_needed_to_clear,
  CASE
    WHEN h.days_to_expiry > h.horizon_days THEN false
    WHEN vsi.units_7d IS NULL THEN NULL
    WHEN vsi.units_7d = 0 THEN true
    WHEN (h.current_stock / (vsi.units_7d / 7.0)) > h.days_to_expiry THEN true
    ELSE false
  END AS is_pull_candidate
FROM horizoned h
LEFT JOIN public.v_shelf_sales_identity vsi
  ON vsi.machine_id = h.machine_id AND vsi.pod_product_id = h.resolved_pod_product_id;

COMMENT ON VIEW public.v_expiry_pull_candidates IS
  'PRD-119 D4 correction: category (expiry_pull_horizon) sets the deadline, velocity (v_shelf_sales_identity.units_7d) decides whether the lane clears before it. is_pull_candidate is NULL (not false-true or false-false) when product identity cannot be bridged to a velocity row -- see the migration header for the ~3% resolution-rate limitation. Sole intended consumers: the nightly check_expiry_pull_candidates() and a future driver PULL screen (not yet built) -- NOT a load-time gate.';

-- Nightly check, same family as check_expiry_unvalidated / assert_sales_names_resolved.
CREATE OR REPLACE FUNCTION public.check_expiry_pull_candidates()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_pull_rows    jsonb;
  v_pull_n       int;
  v_review_rows  jsonb;
  v_review_n     int;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'pod_inventory_id', v.pod_inventory_id, 'machine_name', v.machine_name,
           'shelf_id', v.shelf_id, 'boonz_product_name', v.boonz_product_name,
           'category_group', v.category_group, 'units_on_lane', v.units_on_lane,
           'expiration_date', v.expiration_date, 'days_to_expiry', v.days_to_expiry,
           'horizon_days', v.horizon_days, 'daily_rate_7d', v.daily_rate_7d,
           'days_needed_to_clear', v.days_needed_to_clear)), '[]'::jsonb),
         COUNT(*)
    INTO v_pull_rows, v_pull_n
  FROM public.v_expiry_pull_candidates v
  WHERE v.is_pull_candidate = true;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'pod_inventory_id', v.pod_inventory_id, 'machine_name', v.machine_name,
           'boonz_product_name', v.boonz_product_name, 'category_group', v.category_group,
           'days_to_expiry', v.days_to_expiry, 'horizon_days', v.horizon_days)), '[]'::jsonb),
         COUNT(*)
    INTO v_review_rows, v_review_n
  FROM public.v_expiry_pull_candidates v
  WHERE v.within_horizon AND v.is_pull_candidate IS NULL;

  IF v_pull_n > 0 THEN
    PERFORM public.safe_monitoring_alert('expiry_pull_candidates', 'warning',
      jsonb_build_object('checked_at', now(), 'count', v_pull_n, 'rows', v_pull_rows));
  END IF;

  RETURN jsonb_build_object('checked_at', now(),
                             'pull_candidate_count', v_pull_n, 'pull_candidates', v_pull_rows,
                             'needs_review_count', v_review_n, 'needs_review', v_review_rows);
END;
$function$;

SELECT cron.schedule(
  'check_expiry_pull_candidates_nightly',
  '10 20 * * *',
  $$ SELECT public.check_expiry_pull_candidates(); $$
);
