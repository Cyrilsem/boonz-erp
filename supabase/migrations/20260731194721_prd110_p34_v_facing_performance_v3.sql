-- PRD-110 P3.4 — the revenue/facing/day report.
--
-- BUILD SPEC P3.4: "Facing rightsizing proposals (revenue/facing/day report + proposal
-- queue)". This is the report half. It answers one question per product family per
-- machine: what does each LANE this family occupies earn per day, and is that a lot or a
-- little for this machine?
--
-- ═══ GRAIN, AND WHY IT IS NOT THE OBVIOUS ONE ═══
--
-- ⛔ MEASURED THIS LEG, ON LIVE DATA. The obvious construction -- group
-- v_shelf_instock_velocity_split_v3 by its output pod_product_id -- is WRONG, and wrong in
-- a way that produces contradictory proposals rather than an error. That view canonicalises
-- the Hunter/Hunter Ridge alias INTERNALLY (S-37) but emits the RAW pod key per shelf, while
-- pod_shelf_count and velocity_*_pod are FAMILY-level. Grouping by the emitted key therefore
-- splits one 2-lane family into TWO rows that EACH claim facings = 2 and EACH claim the full
-- family velocity, with only their own shelf's stock. On the 7 dual-Hunter machines that
-- doubles attributed revenue and would emit two "drop a lane" proposals for a family that
-- should lose one. This is the S-37 double-count trap one level up.
--
-- ⭐ THE FIX IS TO READ IDENTITY FROM ITS OWNER (Article 16), not to write another copy of
-- the alias rule. public.v_shelf_sales_identity IS the canonical alias object, it is already
-- collapsed to one row per merged family, and it ALREADY CARRIES facings, stock and cap at
-- that grain. Verified live: 525 rows, (machine_id, pod_product_id) UNIQUE (0 duplicate
-- keys), and its facings agrees with the velocity view's pod_shelf_count on every family
-- where both are present. So this view takes identity + facings + stock + cap + calendar
-- velocity from v_shelf_sales_identity, and ONLY the in-stock rate from the velocity split
-- view. S-38 (converge the alias copies) is untouched and unblocked by this: adding a
-- consumer of the canonical object is the direction S-38 wants.
--
-- ═══ TWO VELOCITIES, NEVER MIXED ═══
--
-- ⛔ THE PRD-108 ppad TRAP, IN A NEW OBJECT. The pointer warns not to build a facings/day
-- metric on rank_slot_suitability.proven because it is units per SELLING day (~23.6x mean
-- overstatement). This view does not touch that column -- but velocity_instock_pod is the
-- SAME CLASS of quantity: sales / in-stock hours, i.e. a per-IN-STOCK-day rate. MEASURED
-- live across 456 families: it is >= the calendar rate on every single one (min ratio
-- 1.006), mean 1.121x, MAX 14.003x, with 20 families overstated by more than 50%. Silently
-- dividing that by facings would inflate a lane's apparent earnings by up to 14x on exactly
-- the shelves that run dry -- the ones most likely to be judged.
--
-- ⭐ So BOTH are exposed and NEITHER is called "the" velocity:
--     REALIZED  (dvel, calendar) = what the lane ACTUALLY earned per day. Arithmetically
--               confirmed as units_30d/30 (5/30 = 0.167, 24/30 = 0.800 on live rows).
--     POTENTIAL (in-stock rate)  = what it earns per day WHILE STOCKED.
--     starvation_ratio = POTENTIAL / REALIZED = how much the lane is held back by being
--               empty. This is not a nuisance to be corrected away; it is the evidence that
--               separates "sells well, keep restocking it" from "needs another lane".
-- A consumer picking one is making an explicit choice; there is no default to be misled by.
--
-- ═══ COVERAGE, STATED NOT IMPLIED ═══
-- 71 of 525 families (13.5%) have NO row in the velocity split view. They are LEFT JOINed
-- and flagged, never inner-joined away: an absence must not read as a verdict (S-71). Same
-- for price -- the 3-tier cascade below is the VAR picker's, verbatim, so the two objects
-- cannot disagree about what a unit is worth (S-94).
--
-- ⛔ peer_median is computed over PRICED AND MEASURED families ONLY, and peer_families
-- counts them. A median taken over families whose revenue is NULL would silently rank a
-- machine's lanes against nothing.
--
-- security_invoker: this view reads only objects the caller may already read.
-- No protected entity, no SECURITY DEFINER, no flag, no live plan table, no engine.

CREATE OR REPLACE VIEW public.v_facing_performance_v3 WITH (security_invoker = true) AS
WITH prm AS (
  SELECT fac_price_lookback_days FROM public.refill_policy_params LIMIT 1
),
-- Price cascade: IDENTICAL in shape and precedence to rank_machines_by_value_at_risk_v3
-- (20260731145040). Realized machine-pod, then realized fleet-pod, then recommended.
px_mp AS (
  SELECT v.machine_id, v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  CROSS JOIN prm
  WHERE v.transaction_date >= CURRENT_DATE - prm.fac_price_lookback_days
  GROUP BY 1, 2
  HAVING sum(sh.qty) > 0
),
px_fleet AS (
  SELECT v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  CROSS JOIN prm
  WHERE v.transaction_date >= CURRENT_DATE - prm.fac_price_lookback_days
  GROUP BY 1
  HAVING sum(sh.qty) > 0
),
-- The in-stock rate, collapsed to family grain. velocity_instock_pod is CONSTANT within a
-- family by construction (S-37 recomputes n over the merged group), so max() reads it
-- without assuming row order; velocity_shelf_rows proves the collapse rather than trusting it.
vel AS (
  SELECT machine_id, pod_product_id,
         max(velocity_instock_pod) AS velocity_instock_pod,
         max(velocity_raw_pod)     AS velocity_raw_pod,
         max(pod_shelf_count)      AS velocity_facings,
         count(*)::int             AS velocity_shelf_rows
  FROM public.v_shelf_instock_velocity_split_v3
  GROUP BY 1, 2
),
base AS (
  SELECT
    i.machine_id,
    -- ⛔ NOT machine_number: it is not unique and not a label (36 identity machines carry
    -- values like 'Batch_1', repeated across distinct machine_ids). official_name is the
    -- human key and is non-NULL on all 36. `machines` has no `name` column.
    m.official_name                                    AS machine_name,
    m.operating_model,
    -- The refill universe, CARRIED not APPLIED. 30 of 36 identity machines qualify. The
    -- report shows every family; the PROPOSER is what refuses to act outside the universe.
    -- Filtering here would make a machine's absence indistinguishable from having no lanes.
    (m.include_in_refill AND m.status = 'Active')      AS in_refill_universe,
    i.pod_product_id,
    i.goods_name_sample                                AS pod_name,
    pp.product_category,
    i.facings::int                                     AS facings,
    i.stock::int                                       AS stock_units,
    i.cap::int                                         AS capacity_units,
    i.units_30d,
    i.has_sales,
    i.dvel                                             AS velocity_calendar,  -- REALIZED
    vel.velocity_instock_pod                             AS velocity_instock,   -- POTENTIAL
    vel.velocity_facings,
    vel.velocity_shelf_rows,
    COALESCE(px_mp.unit_price, px_fleet.unit_price,
             NULLIF(pp.recommended_selling_price, 0))  AS unit_price,
    CASE WHEN px_mp.unit_price             IS NOT NULL THEN 'realized_machine_pod'
         WHEN px_fleet.unit_price          IS NOT NULL THEN 'realized_fleet_pod'
         WHEN pp.recommended_selling_price  > 0        THEN 'recommended_price'
         ELSE 'none' END                               AS price_basis,
    CASE WHEN vel.machine_id           IS NULL THEN 'none'
         WHEN vel.velocity_instock_pod IS NULL THEN 'null_instock'
         ELSE 'instock_split' END                      AS velocity_basis
  FROM public.v_shelf_sales_identity i
  JOIN public.machines m ON m.machine_id = i.machine_id
  LEFT JOIN vel      ON vel.machine_id = i.machine_id AND vel.pod_product_id = i.pod_product_id
  LEFT JOIN public.pod_products pp ON pp.pod_product_id = i.pod_product_id
  LEFT JOIN px_mp    ON px_mp.machine_id = i.machine_id AND px_mp.pod_product_id = i.pod_product_id
  LEFT JOIN px_fleet ON px_fleet.pod_product_id = i.pod_product_id
),
calc AS (
  SELECT b.*,
    -- ⛔ facings is the DENOMINATOR. NULLIF guards a 0/NULL facing count rather than
    -- letting division decide; a family with no lanes is not a rightsizing candidate.
    (b.velocity_calendar * b.unit_price) / NULLIF(b.facings, 0) AS rev_per_facing_day_realized,
    (b.velocity_instock  * b.unit_price) / NULLIF(b.facings, 0) AS rev_per_facing_day_potential,
    b.velocity_calendar  * b.unit_price                         AS rev_per_day_family,
    CASE WHEN b.velocity_calendar > 0 AND b.velocity_instock IS NOT NULL
         THEN b.velocity_instock / b.velocity_calendar END      AS starvation_ratio
  FROM base b
),
-- ⛔ percentile_cont is an ORDERED-SET aggregate: PostgreSQL rejects it with OVER(), so the
-- machine benchmark cannot be a window function. It is its own grouped CTE, restricted to
-- families that HAVE a metric -- a median over NULLs would rank lanes against nothing.
med AS (
  SELECT machine_id,
         -- ⛔ percentile_cont resolves to the float8 overload even on numeric input, so the
         -- cast back to numeric is required before round(x, 4).
         percentile_cont(0.5) WITHIN GROUP (ORDER BY rev_per_facing_day_potential)::numeric AS med_potential,
         count(*)::int AS peer_families
  FROM calc
  WHERE rev_per_facing_day_potential IS NOT NULL
  GROUP BY 1
)
SELECT
  c.machine_id, c.machine_name, c.operating_model, c.in_refill_universe,
  c.pod_product_id, c.pod_name, c.product_category,
  c.facings, c.stock_units, c.capacity_units, c.units_30d, c.has_sales,
  round(c.velocity_calendar, 4)              AS velocity_calendar,
  round(c.velocity_instock,  4)              AS velocity_instock,
  round(c.starvation_ratio,  4)              AS starvation_ratio,
  round(c.unit_price, 4)                     AS unit_price,
  c.price_basis, c.velocity_basis,
  round(c.rev_per_day_family, 4)             AS rev_per_day_family,
  round(c.rev_per_facing_day_realized,  4)   AS rev_per_facing_day_realized,
  round(c.rev_per_facing_day_potential, 4)   AS rev_per_facing_day_potential,
  -- The machine peer benchmark. Computed over PRICED AND MEASURED families only.
  round(med.med_potential, 4)                AS machine_peer_median_potential,
  COALESCE(med.peer_families, 0)             AS machine_peer_families,
  -- The velocity view's own facing count, carried so a consumer can SEE the two identity
  -- sources agree. NULL where the velocity view has no row for this family (71 live).
  c.velocity_facings, c.velocity_shelf_rows,
  (c.velocity_facings IS NOT NULL AND c.velocity_facings <> c.facings) AS facing_count_disagreement
FROM calc c
LEFT JOIN med ON med.machine_id = c.machine_id;

COMMENT ON VIEW public.v_facing_performance_v3 IS
'PRD-110 P3.4 revenue/facing/day report. ONE ROW PER (machine, canonical product family) - identity, facings, stock, cap and CALENDAR velocity read from v_shelf_sales_identity, the canonical alias owner (Article 16); only the in-stock rate comes from v_shelf_instock_velocity_split_v3. ⛔ Do NOT rebuild this by grouping the velocity split view on its emitted pod_product_id: that key is RAW while its pod_shelf_count/velocity_*_pod are FAMILY-level, so one alias-merged family becomes two rows that each claim the full velocity (the S-37 double-count, one level up). ⛔ TWO velocities are exposed and neither is "the" velocity: rev_per_facing_day_realized uses the CALENDAR rate (what the lane earned), rev_per_facing_day_potential uses the IN-STOCK rate (what it earns while stocked, >= calendar always, up to 14.003x live). starvation_ratio is their quotient and is the ONLY admissible evidence for adding a lane. Price cascade is byte-equivalent to rank_machines_by_value_at_risk_v3 so the two objects cannot disagree on unit value. Advisory/read-only: writes nothing, gates nothing.';

COMMENT ON COLUMN public.v_facing_performance_v3.rev_per_facing_day_potential IS
'AED/lane/day at the IN-STOCK rate. THE P3.4 metric for shrink decisions: judging a lane on its realized rate would punish the assortment for a refill failure.';
COMMENT ON COLUMN public.v_facing_performance_v3.starvation_ratio IS
'velocity_instock / velocity_calendar. NULL when calendar velocity is 0 (unmeasurable, NOT "not starved" - S-71). >1 means the family runs dry between visits.';
COMMENT ON COLUMN public.v_facing_performance_v3.machine_peer_median_potential IS
'Median rev_per_facing_day_potential across this machine''s PRICED AND MEASURED families. Machine-relative by design: an AED 0.30/lane/day family is weak in an office tower and strong in a low-traffic site.';
COMMENT ON COLUMN public.v_facing_performance_v3.facing_count_disagreement IS
'TRUE if v_shelf_sales_identity.facings and the velocity view''s pod_shelf_count disagree for this family. Live count at build: 0. A non-zero value means the two identity sources have drifted - pinned by fixture 48.';

REVOKE ALL ON public.v_facing_performance_v3 FROM anon;
GRANT SELECT ON public.v_facing_performance_v3 TO authenticated;
