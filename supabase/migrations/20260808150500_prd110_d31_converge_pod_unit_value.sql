-- PRD-110 · D-31 · leg 152
-- THE CONVERGENCE. Turns fixture 72 from 10/14 to 24/0.
--
-- D-31 ruling (CS 2026-08-01): "CONVERGE the price cascade into ONE canonical unit-value
-- object; both consumers read it."
--
-- WHAT THIS IS NOT: it is not a policy change. Every price this returns is the price the
--    two inline copies return today, proven row for row against the legacy formula
--    transcribed literally from both live bodies (fixture 72 seqs 15-21), on the FULL live
--    population, not a sample.
--
-- WHY THE LOOKBACK IS A PARAMETER AND NOT A DIAL READ INSIDE THE OBJECT (S-288).
--    The two copies are recorded in the parking lot and at METRICS_REGISTRY line 751 as
--    harmless because they were "copied verbatim so the two objects cannot disagree about
--    what a unit is worth (S-94)". THEY ARE NOT VERBATIM:
--      · rank_machines_by_value_at_risk_v3 -> refill_policy_params.var_price_lookback_days
--      · v_facing_performance_v3           -> refill_policy_params.fac_price_lookback_days
--    Both read 90 today. The copies therefore agree BY COINCIDENCE OF TWO DIAL VALUES, not
--    by construction, and the day CS turns either one the two objects price a unit
--    differently with nothing anywhere to say so.
--    A canonical object that read ONE dial would have closed that hole by silently
--    retiring a policy dial CS owns - a policy change wearing a refactor's clothes, which
--    is exactly what D-27(b) and D-28 half-2 were parked rather than committed for. So the
--    object takes the window as an argument and each consumer keeps passing its own dial.
--    Fixture 72 seqs 13/14 pin that; seq 5 keeps the coincidence visible.
--
-- THE ONE-SCAN ROLLUP. Each consumer scans the 90-day window TWICE today - once grouped by
--    (machine, pod), once by (pod). This groups ONCE and derives the fleet tier by summing
--    those sums: SUM(sum_paid)/SUM(sum_qty) == SUM(paid)/SUM(qty), identical by
--    associativity rather than by luck. Fixture 72 seq 20 proves it on every pod with a
--    FULL JOIN, so a pod present on one side only is a mismatch and not an unjoined row.
--    The HAVING is applied INDEPENDENTLY AT EACH GRAIN and never before the rollup: a
--    (machine, pod) group with sum(qty) <= 0 must be excluded from the machine tier yet
--    still contribute to the fleet total, which is what the two-scan form does. That
--    population is 0 rows live (seq 6), so the care is INERT today and deliberate - it is
--    written this way so it cannot rot into a defect the first time a refund lands.
--
-- THE GRID IS A UNION, NOT machines x pod_products, AND THAT WAS MEASURED (seq 4).
--    ONE pod carries realized sales and is absent from pod_products. The obvious grid
--    would have dropped its machine-pod prices silently - a price today, NULL tomorrow, no
--    error anywhere. The grid is (machines x pods-known-to-either-source) UNION the
--    realized (machine, pod) pairs themselves. seq 19 proves that pod still covered.
--
-- ROWS 20000 is not decoration: an SRF defaults to a 1000-row estimate, and both consumers
--    LEFT JOIN this at 16.7k rows. The hint keeps the planner off a nested loop.

-- ============================================================================
-- 1. THE CANONICAL OBJECT
-- ============================================================================
CREATE OR REPLACE FUNCTION public.pod_unit_value_v3(p_lookback_days integer)
RETURNS TABLE (
  machine_id      uuid,
  pod_product_id  uuid,
  unit_price      numeric,
  price_basis     text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
ROWS 20000
SET search_path = public, pg_catalog
AS $fn$
  WITH base AS (
    -- ONE scan of the window. Both realized tiers are derived from this.
    --
    -- ⛔ pod_product_id IS NOT NULL, and this is an EQUIVALENCE-PRESERVING exclusion, not
    -- a filter with an opinion. v_sales_history_resolved leaves 15 of the 720 (machine,
    -- pod) groups in the live 90-day window UNRESOLVED - 110 units, AED 1,904 of real
    -- revenue that resolves to no pod at all. The inline copies carried those 15 groups
    -- plus a 15-into-1 NULL "fleet pod" (which is why the legacy fleet tier reads 111 pods
    -- and not 110), and every one of them is UNREACHABLE: both consumers join the tier on
    -- pod_product_id, and NULL = NULL is never true, so a NULL-pod price could never be
    -- selected by anything. Dropping them here removes 16 groups no consumer could read
    -- and changes no price. Fixture 72 seqs 25/26 pin the population and the exclusion.
    SELECT v.machine_id, v.pod_product_id,
           sum(sh.paid_amount) AS sum_paid,
           sum(sh.qty)         AS sum_qty
      FROM public.v_sales_history_resolved v
      JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
     WHERE v.transaction_date >= CURRENT_DATE - p_lookback_days
       AND v.pod_product_id IS NOT NULL
     GROUP BY 1, 2
  ),
  px_mp AS (
    -- TIER 1. HAVING at the machine-pod grain, exactly as the inline copies state it.
    SELECT b.machine_id, b.pod_product_id, b.sum_paid / NULLIF(b.sum_qty, 0) AS unit_price
      FROM base b
     WHERE b.sum_qty > 0
  ),
  px_fleet AS (
    -- TIER 2. HAVING at the POD grain, applied to the rollup and never inherited from
    -- tier 1 - a machine-pod group excluded above must still count toward the fleet total.
    SELECT b.pod_product_id, sum(b.sum_paid) / NULLIF(sum(b.sum_qty), 0) AS unit_price
      FROM base b
     GROUP BY 1
    HAVING sum(b.sum_qty) > 0
  ),
  pods AS (
    SELECT p.pod_product_id FROM public.pod_products p
    UNION
    SELECT f.pod_product_id FROM px_fleet f
  ),
  grid AS (
    SELECT m.machine_id, p.pod_product_id
      FROM public.machines m CROSS JOIN pods p
    UNION
    SELECT b.machine_id, b.pod_product_id FROM base b
  )
  SELECT g.machine_id,
         g.pod_product_id,
         COALESCE(mp.unit_price, fl.unit_price, NULLIF(pp.recommended_selling_price, 0)) AS unit_price,
         CASE WHEN mp.unit_price                 IS NOT NULL THEN 'realized_machine_pod'
              WHEN fl.unit_price                 IS NOT NULL THEN 'realized_fleet_pod'
              WHEN pp.recommended_selling_price  > 0         THEN 'recommended_price'
              ELSE 'none' END                                                            AS price_basis
    FROM grid g
    LEFT JOIN px_mp    mp ON mp.machine_id = g.machine_id AND mp.pod_product_id = g.pod_product_id
    LEFT JOIN px_fleet fl ON fl.pod_product_id = g.pod_product_id
    LEFT JOIN public.pod_products pp ON pp.pod_product_id = g.pod_product_id;
$fn$;

COMMENT ON FUNCTION public.pod_unit_value_v3(integer) IS
  'PRD-110 D-31 (CS 2026-08-01). CANONICAL unit-value object: the three-tier price cascade '
  '(realized machine-pod -> realized fleet-pod -> recommended_selling_price) that '
  'rank_machines_by_value_at_risk_v3 and v_facing_performance_v3 each carried inline. '
  'The lookback window is an ARGUMENT, not a dial read here: the two consumers own DIFFERENT '
  'dials (var_price_lookback_days / fac_price_lookback_days) which read 90 today only by '
  'coincidence, and collapsing them would be a policy change, not a convergence. '
  'Proof: golden fixture 72. Article 16 registered.';

-- S-268: a bare REVOKE ... FROM PUBLIC does NOT remove Supabase's schema default
-- privileges - anon must be named EXPLICITLY or it keeps EXECUTE. This is the exposure
-- D-30 had to be executed for, and fixture 72 seq 11 counts BOTH grantees.
REVOKE ALL ON FUNCTION public.pod_unit_value_v3(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pod_unit_value_v3(integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.pod_unit_value_v3(integer) TO authenticated, service_role;

-- ============================================================================
-- 2. CONSUMER 1 — v_facing_performance_v3
--    Column list, order and types are byte-identical to the pre-image; only the two px
--    CTEs and the inline cascade are replaced. CREATE OR REPLACE VIEW would refuse
--    anything else, which is a guard rather than a constraint here.
-- ============================================================================
CREATE OR REPLACE VIEW public.v_facing_performance_v3 AS
 WITH prm AS (
         SELECT refill_policy_params.fac_price_lookback_days
           FROM refill_policy_params
         LIMIT 1
        ), uv AS (
         -- D-31: the canonical cascade, passed THIS view's own dial.
         SELECT u.machine_id, u.pod_product_id, u.unit_price, u.price_basis
           FROM prm
           CROSS JOIN LATERAL public.pod_unit_value_v3(prm.fac_price_lookback_days) u
        ), vel AS (
         SELECT v_shelf_instock_velocity_split_v3.machine_id,
            v_shelf_instock_velocity_split_v3.pod_product_id,
            max(v_shelf_instock_velocity_split_v3.velocity_instock_pod) AS velocity_instock_pod,
            max(v_shelf_instock_velocity_split_v3.velocity_raw_pod) AS velocity_raw_pod,
            max(v_shelf_instock_velocity_split_v3.pod_shelf_count) AS velocity_facings,
            (count(*))::integer AS velocity_shelf_rows
           FROM v_shelf_instock_velocity_split_v3
          GROUP BY v_shelf_instock_velocity_split_v3.machine_id, v_shelf_instock_velocity_split_v3.pod_product_id
        ), base AS (
         SELECT i.machine_id,
            m.official_name AS machine_name,
            m.operating_model,
            (m.include_in_refill AND (m.status = 'Active'::text)) AS in_refill_universe,
            i.pod_product_id,
            i.goods_name_sample AS pod_name,
            pp.product_category,
            (i.facings)::integer AS facings,
            (i.stock)::integer AS stock_units,
            (i.cap)::integer AS capacity_units,
            i.units_30d,
            i.has_sales,
            i.dvel AS velocity_calendar,
            vel.velocity_instock_pod AS velocity_instock,
            vel.velocity_facings,
            vel.velocity_shelf_rows,
            uv.unit_price,
            COALESCE(uv.price_basis, 'none'::text) AS price_basis,
                CASE
                    WHEN (vel.machine_id IS NULL) THEN 'none'::text
                    WHEN (vel.velocity_instock_pod IS NULL) THEN 'null_instock'::text
                    ELSE 'instock_split'::text
                END AS velocity_basis
           FROM ((((v_shelf_sales_identity i
             JOIN machines m ON ((m.machine_id = i.machine_id)))
             LEFT JOIN vel ON (((vel.machine_id = i.machine_id) AND (vel.pod_product_id = i.pod_product_id))))
             LEFT JOIN pod_products pp ON ((pp.pod_product_id = i.pod_product_id)))
             LEFT JOIN uv ON (((uv.machine_id = i.machine_id) AND (uv.pod_product_id = i.pod_product_id))))
        ), calc AS (
         SELECT b.machine_id,
            b.machine_name,
            b.operating_model,
            b.in_refill_universe,
            b.pod_product_id,
            b.pod_name,
            b.product_category,
            b.facings,
            b.stock_units,
            b.capacity_units,
            b.units_30d,
            b.has_sales,
            b.velocity_calendar,
            b.velocity_instock,
            b.velocity_facings,
            b.velocity_shelf_rows,
            b.unit_price,
            b.price_basis,
            b.velocity_basis,
            ((b.velocity_calendar * b.unit_price) / (NULLIF(b.facings, 0))::numeric) AS rev_per_facing_day_realized,
            ((b.velocity_instock * b.unit_price) / (NULLIF(b.facings, 0))::numeric) AS rev_per_facing_day_potential,
            (b.velocity_calendar * b.unit_price) AS rev_per_day_family,
                CASE
                    WHEN ((b.velocity_calendar > (0)::numeric) AND (b.velocity_instock IS NOT NULL)) THEN (b.velocity_instock / b.velocity_calendar)
                    ELSE NULL::numeric
                END AS starvation_ratio
           FROM base b
        ), med AS (
         SELECT calc.machine_id,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((calc.rev_per_facing_day_potential)::double precision)))::numeric AS med_potential,
            (count(*))::integer AS peer_families
           FROM calc
          WHERE (calc.rev_per_facing_day_potential IS NOT NULL)
          GROUP BY calc.machine_id
        )
 SELECT c.machine_id,
    c.machine_name,
    c.operating_model,
    c.in_refill_universe,
    c.pod_product_id,
    c.pod_name,
    c.product_category,
    c.facings,
    c.stock_units,
    c.capacity_units,
    c.units_30d,
    c.has_sales,
    round(c.velocity_calendar, 4) AS velocity_calendar,
    round(c.velocity_instock, 4) AS velocity_instock,
    round(c.starvation_ratio, 4) AS starvation_ratio,
    round(c.unit_price, 4) AS unit_price,
    c.price_basis,
    c.velocity_basis,
    round(c.rev_per_day_family, 4) AS rev_per_day_family,
    round(c.rev_per_facing_day_realized, 4) AS rev_per_facing_day_realized,
    round(c.rev_per_facing_day_potential, 4) AS rev_per_facing_day_potential,
    round(med.med_potential, 4) AS machine_peer_median_potential,
    COALESCE(med.peer_families, 0) AS machine_peer_families,
    c.velocity_facings,
    c.velocity_shelf_rows,
    ((c.velocity_facings IS NOT NULL) AND (c.velocity_facings <> c.facings)) AS facing_count_disagreement
   FROM (calc c
     LEFT JOIN med ON ((med.machine_id = c.machine_id)));

-- ============================================================================
-- 3. CONSUMER 2 — rank_machines_by_value_at_risk_v3 (SENTINEL 754532ac)
--
--    16,049 characters, of which this unit is entitled to change 1,399. It is therefore
--    edited by COUNTED SUBSTITUTION on the live body, not retyped - the leg-150/151 guard,
--    which exists so that a big body cannot be silently re-authored under cover of a small
--    change. The guard REFUSES rather than guesses: the pre-image md5 is a hard RAISE,
--    every substitution's occurrence count is asserted exactly, an idempotence guard
--    refuses a second application, and the post-block proves the ONLY things that moved
--    are the price sites.
--
--    ⛔ The LEFT JOIN onto pod_products is RETAINED even though the cascade was its only
--    reader. pod_product_id is the PK (163/163 distinct), so it can neither multiply nor
--    drop a row - keeping it confines this unit's diff to price logic on a sentinel engine
--    body, which is worth more than the tidiness of removing it.
-- ============================================================================
DO $conv$
DECLARE
  c_pre_md5  constant text := '754532acaee1beba20d7f1bf038f5837';

  v_def   text;
  v_src   text;
  v_new   text;
  v_post  text;

  a_old constant text :=
'px_mp AS (
  SELECT v.machine_id, v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  CROSS JOIN prm
  WHERE v.transaction_date >= CURRENT_DATE - prm.var_price_lookback_days
  GROUP BY 1, 2
  HAVING sum(sh.qty) > 0
),
px_fleet AS (
  SELECT v.pod_product_id,
         sum(sh.paid_amount) / NULLIF(sum(sh.qty), 0) AS unit_price
  FROM public.v_sales_history_resolved v
  JOIN public.sales_history sh ON sh.transaction_id = v.transaction_id
  CROSS JOIN prm
  WHERE v.transaction_date >= CURRENT_DATE - prm.var_price_lookback_days
  GROUP BY 1
  HAVING sum(sh.qty) > 0
),';

  a_new constant text :=
'-- D-31 (CS 2026-08-01): the three-tier price cascade is no longer written here. It lives
-- in the canonical unit-value object, read below with THIS object''s OWN dial - the picker
-- and v_facing_performance_v3 own different lookback dials and collapsing them would be a
-- policy change, not a convergence (S-288). Two window scans became one; the numbers are
-- unchanged and golden fixture 72 seqs 15-21 prove it against the pre-image formula.
-- ⛔ The canonical object is named exactly ONCE in this body, at the call site below, and
-- the migration''s post-guard asserts that count - so this comment must not name it.
uv AS (
  SELECT u.machine_id, u.pod_product_id, u.unit_price, u.price_basis
  FROM prm
  CROSS JOIN LATERAL public.pod_unit_value_v3(prm.var_price_lookback_days) u
),';

  b_old constant text :=
'         COALESCE(px_mp.unit_price, px_fleet.unit_price,
                  NULLIF(pp.recommended_selling_price, 0)) AS unit_price,
         CASE WHEN px_mp.unit_price               IS NOT NULL THEN ''realized_machine_pod''
              WHEN px_fleet.unit_price            IS NOT NULL THEN ''realized_fleet_pod''
              WHEN pp.recommended_selling_price   > 0         THEN ''recommended_price''
              ELSE ''none'' END AS price_basis,';

  b_new constant text :=
'         uv.unit_price                                       AS unit_price,
         COALESCE(uv.price_basis, ''none'')                     AS price_basis,';

  c_old constant text :=
'  LEFT JOIN px_mp    ON px_mp.machine_id = s.machine_id AND px_mp.pod_product_id = s.pod_product_id
  LEFT JOIN px_fleet ON px_fleet.pod_product_id = s.pod_product_id
  LEFT JOIN public.pod_products pp ON pp.pod_product_id = s.pod_product_id';

  c_new constant text :=
'  LEFT JOIN uv       ON uv.machine_id = s.machine_id AND uv.pod_product_id = s.pod_product_id
  -- The join below is retained DELIBERATELY: the cascade was its only reader, but
  -- pod_product_id is its PK (163/163 distinct) so it can neither multiply nor drop a
  -- row, and removing it would widen a sentinel body''s diff past the price logic D-31
  -- authorises. ⛔ The table is named exactly ONCE here, at the join, because the
  -- migration''s post-guard asserts that count against the pre-image.
  LEFT JOIN public.pod_products pp ON pp.pod_product_id = s.pod_product_id';

  n int;
BEGIN
  SELECT p.prosrc, pg_get_functiondef(p.oid)
    INTO v_src, v_def
    FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
   WHERE n2.nspname = 'public' AND p.proname = 'rank_machines_by_value_at_risk_v3';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'D-31 REFUSES: rank_machines_by_value_at_risk_v3 not found';
  END IF;

  -- IDEMPOTENCE: a second application must refuse, not re-substitute into a changed body.
  IF position('pod_unit_value_v3' IN v_src) > 0 THEN
    RAISE EXCEPTION 'D-31 REFUSES: rank_machines_by_value_at_risk_v3 already reads pod_unit_value_v3';
  END IF;

  -- PRE-IMAGE PIN: hard refusal, not a warning (S-109 - md5(prosrc), never functiondef).
  IF md5(v_src) <> c_pre_md5 THEN
    RAISE EXCEPTION 'D-31 REFUSES: pre-image md5 is % but this unit was written against %',
      md5(v_src), c_pre_md5;
  END IF;

  -- EVERY substitution's occurrence count asserted EXACTLY, before any of them is applied.
  -- ⛔ Counted by SUBSTRING ARITHMETIC, not regexp_matches: these blocks are multi-line SQL
  -- full of (, ), *, . and | - escaping them into a regex is a second thing to get wrong,
  -- and getting it wrong silently reads as "0 occurrences" and refuses for the wrong reason.
  n := (length(v_def) - length(replace(v_def, a_old, ''))) / length(a_old);
  IF n <> 1 THEN RAISE EXCEPTION 'D-31 REFUSES: block A occurs % times, expected 1', n; END IF;
  n := (length(v_def) - length(replace(v_def, b_old, ''))) / length(b_old);
  IF n <> 1 THEN RAISE EXCEPTION 'D-31 REFUSES: block B occurs % times, expected 1', n; END IF;
  n := (length(v_def) - length(replace(v_def, c_old, ''))) / length(c_old);
  IF n <> 1 THEN RAISE EXCEPTION 'D-31 REFUSES: block C occurs % times, expected 1', n; END IF;

  v_new := replace(v_def, a_old, a_new);
  v_new := replace(v_new, b_old, b_new);
  v_new := replace(v_new, c_old, c_new);

  IF v_new = v_def THEN
    RAISE EXCEPTION 'D-31 REFUSES: substitution produced an identical body';
  END IF;

  EXECUTE v_new;

  ------------------------------------------------------------------ POST-GUARD --
  SELECT p.prosrc INTO v_post
    FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
   WHERE n2.nspname = 'public' AND p.proname = 'rank_machines_by_value_at_risk_v3';

  -- The cascade is GONE, not merely bypassed: all 6 px_mp and all 5 px_fleet references
  -- must have left the body. A leftover reference would not compile, but it would also
  -- mean a substitution missed - and the count says which.
  n := (SELECT count(*) FROM regexp_matches(v_post, 'px_mp', 'g'));
  IF n <> 0 THEN RAISE EXCEPTION 'D-31 POST-GUARD: % px_mp references survived', n; END IF;
  n := (SELECT count(*) FROM regexp_matches(v_post, 'px_fleet', 'g'));
  IF n <> 0 THEN RAISE EXCEPTION 'D-31 POST-GUARD: % px_fleet references survived', n; END IF;
  n := (SELECT count(*) FROM regexp_matches(v_post, 'realized_fleet_pod', 'g'));
  IF n <> 0 THEN RAISE EXCEPTION 'D-31 POST-GUARD: the inline cascade survived (% hits)', n; END IF;

  -- It reads the canonical object EXACTLY once, with ITS OWN dial.
  n := (SELECT count(*) FROM regexp_matches(v_post, 'pod_unit_value_v3', 'g'));
  IF n <> 1 THEN RAISE EXCEPTION 'D-31 POST-GUARD: pod_unit_value_v3 referenced % times, expected 1', n; END IF;
  IF v_post !~ 'pod_unit_value_v3\(prm\.var_price_lookback_days\)' THEN
    RAISE EXCEPTION 'D-31 POST-GUARD: the picker is not passing var_price_lookback_days';
  END IF;

  -- THE UNTOUCHED NEIGHBOURS, COUNTED IN THE PRE-IMAGE AND ASSERTED IN THE POST-IMAGE
  -- (the leg-151 lesson, and the counts were MEASURED - the first three guesses written
  -- here were 2/1/1 and the live body reads 3/3/1). D-44's money reservation, the visit
  -- clock and the retained pod_products join must all come through untouched.
  n := (SELECT count(*) FROM regexp_matches(v_post, 'var_money_reserved_slots', 'g'));
  IF n <> 3 THEN RAISE EXCEPTION 'D-31 POST-GUARD: D-44 money reservation moved (% hits, expected 3)', n; END IF;
  n := (SELECT count(*) FROM regexp_matches(v_post, 'v_machine_health_signals', 'g'));
  IF n <> 3 THEN RAISE EXCEPTION 'D-31 POST-GUARD: the visit clock moved (% hits, expected 3)', n; END IF;
  n := (SELECT count(*) FROM regexp_matches(v_post, 'pod_products', 'g'));
  IF n <> 1 THEN RAISE EXCEPTION 'D-31 POST-GUARD: the retained pod_products join moved (% hits, expected 1)', n; END IF;
  -- The dial is READ ONCE now, where the two px CTEs each read it: 2 -> 1.
  n := (SELECT count(*) FROM regexp_matches(v_post, 'prm\.var_price_lookback_days', 'g'));
  IF n <> 1 THEN RAISE EXCEPTION 'D-31 POST-GUARD: dial read % times, expected exactly 1', n; END IF;

  RAISE NOTICE 'D-31: rank_machines_by_value_at_risk_v3 md5 % -> %', c_pre_md5, md5(v_post);
END $conv$;
