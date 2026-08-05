-- PRD-110 P4.2 — THE CONSUMER: engine_add_pod_v3 reads planning pins as constraints.
--
-- Fixtures 16 and 17 landed RED in leg 81 (20 pass/11 fail and 19 pass/6 fail) against an engine
-- that did not know what a pin was. This is the other half. LAW 1 is satisfied not by writing the
-- fixture first but by having WATCHED it fail first, and golden.runs holds that evidence under
-- note='leg81 unit1 RED baseline'.
--
-- ============================ WHAT A PIN MEANS, PRECISELY ============================
--
--   protect_depth (value V)  -> floor of GREATEST(V - current_stock, 0) units. A DEPTH target.
--   min_facing    (value V)  -> floor of V units. A QTY floor: facings placed THIS visit.
--   always_stock  (value NULL) -> floor of 1 unit. A PRESENCE guarantee.
--   never_stock              -> NOT consumed. It is a ceiling, not a floor; LAW 1 says it waits
--                               for the fixture that proves it. Parked as S-128.
--
-- ⛔ always_stock is a floor on UNITS, not on DEPTH, and the difference is the whole point. As a
--    depth rule ("ensure at least 1 on the shelf") it would be a no-op on every shelf already
--    holding stock -- and therefore exactly redundant with the P2.5 unconditional floor, which
--    already fires at stock=0. As a units rule it does real work: on fixture 16's A07 (stock 5,
--    cover 0, warehouse dry) it converts a line the engine would have passed over in SILENCE into
--    a NAMED blocked_no_wh row. That is LAW 5 -- and it is what routes the unit into
--    blocked_demand instead of losing it.
--
-- ============================ THREE THINGS THAT SHAPED THIS ============================
--
-- 1. ⛔ THE BASE `jsonb_build_object` IS AT 49 PAIRS = 98 ARGUMENTS, one pair short of the
--    100-argument ceiling. The four pin keys therefore go in a THIRD object merged with `||`.
--    A previous leg already killed every engine run with SQLSTATE 54023 this exact way, and left
--    the warning in the source; this migration is the first change to test whether that warning
--    gets read. It did.
--
-- 2. ⭐ AVAILABILITY OUTRANKS THE PIN IN THE CLAMP LADDER, AND THE PIN OUTRANKS THE EXPIRY
--    CEILING. Both orderings are load-bearing and both are asserted: fixture 16 seq 16 demands
--    blocked_no_wh (not pin_floor) on the dry shelf, and seq 8 demands pin_floor (not
--    expiry_ceiling) on the served one. A pin raises DEMAND; it never conjures STOCK.
--
-- 3. ⭐ `pin_binds` IS COMPUTED ONCE, in `final`, rather than re-derived in the ladder and again
--    in the reasoning blob. Two copies of a predicate this subtle drift on the first edit, and
--    the symptom would be a line whose clamp_reason and provenance disagree about why it exists.
--
-- ⭐ REGRESSION SAFETY IS STRUCTURAL, NOT TESTED-IN: pin_floor_units is 0 on every line with no
--    pin, so pin_binds is false, so the new ladder branch never fires and the expiry branch keeps
--    its original condition. An unpinned fleet plans byte-identically to before this migration.
--
-- Scoped by machine + SHELF (never pod identity): A01 and A03 are both Coca Cola Zero on
-- VML-1003-0400-O1, so a pod-resolved pin would move a shelf nobody named. Fixture 17 seq 12/13.

SET LOCAL statement_timeout = '120s';

CREATE OR REPLACE FUNCTION public.engine_add_pod_v3(p_plan_date date, p_days_cover integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run_id       uuid        := gen_random_uuid();
  v_tag          text        := 'engine_add_pod_v3';
  v_t0           timestamptz := clock_timestamp();
  v_user_id      uuid;
  v_min_facing   integer     := COALESCE((SELECT min_facing_floor FROM public.refill_policy_params WHERE id = 1), 2);
  -- P2.3. Read from refill_policy_params, NEVER a hardcoded 0.8 - otherwise tuning the param
  -- is a silent no-op (fixture 8 seq 23).
  v_expiry_factor numeric    := COALESCE((SELECT base_stock_expiry_safety_factor FROM public.refill_policy_params WHERE id = 1), 0.80);
  v_xp_fefo      integer     := 0;
  v_xp_nobatch   integer     := 0;
  v_xp_notwh     integer     := 0;
  v_xp_unknown   integer     := 0;
  v_exp_lines    integer     := 0;
  v_exp_removed  integer     := 0;
  v_scope        integer     := 0;
  v_machines     integer     := 0;
  v_empty_mach   integer     := 0;
  v_lines        integer     := 0;
  v_qty0         integer     := 0;
  v_units        integer     := 0;
  v_blocked      integer     := 0;
  v_partial      integer     := 0;
  v_over_cap     integer     := 0;
  v_unknown      integer     := 0;
  v_uncovered    integer     := 0;
  v_v_instock    integer     := 0;
  v_v_fallback   integer     := 0;
  v_v_none       integer     := 0;
  -- P2.2c base-stock provenance + S-43 degeneracy telemetry
  v_h_policy     integer     := 0;
  v_h_fallback   integer     := 0;
  v_sig_meas     integer     := 0;
  v_sig_nodisp   integer     := 0;
  v_sig_nosplit  integer     := 0;
  v_fill_cap     integer     := 0;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',               true);
  PERFORM set_config('app.rpc_name', 'engine_add_pod_v3',  true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.user_profiles up
        WHERE up.id = v_user_id AND up.role = 'operator_admin')
  THEN
    RAISE EXCEPTION 'engine_add_pod_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  -- P2.2c: p_days_cover is NOT orphaned. It stays required and validated, it is still echoed
  -- into pod_refills_shadow.days_cover, and it retains a live sizing role as the TIER-3
  -- horizon fallback for any machine with no base-stock policy row. It is no longer the
  -- primary horizon - v_machine_base_stock_policy_v3.horizon_days is.
  IF p_plan_date IS NULL OR p_days_cover IS NULL OR p_days_cover <= 0 THEN
    RAISE EXCEPTION 'engine_add_pod_v3: p_plan_date required, p_days_cover > 0';
  END IF;

  -- ONE arg, exactly as v19 calls it (the function is two-arg with a default; passing
  -- p_machine_ids would change its behaviour - the pronargdefaults trap).
  PERFORM public._assert_refill_plan_writable(p_plan_date);

  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_add_pod_v3: no picked/cs_added machines for %; run Stage 1 first',
      p_plan_date;
  END IF;

  -- LAW 11: the shadow engine honours manual Gate 0 too, or a shadow run could plan
  -- machines CS never confirmed.
  PERFORM public._assert_gate_zero(p_plan_date);

  -- Scope, measured BEFORE the write so the coverage guard is independent of the write's
  -- own row count (RISK 75: prove the mechanism, not the intent).
  SELECT count(DISTINCT p.machine_id),
         count(*) FILTER (WHERE s.shelf_id IS NOT NULL)
    INTO v_machines, v_scope
    FROM (
      SELECT DISTINCT mtv.machine_id, mtv.official_name
        FROM public.machines_to_visit mtv
       WHERE mtv.plan_date = p_plan_date
         AND mtv.status IN ('picked','cs_added')
         AND NOT EXISTS (
               SELECT 1 FROM public.refill_plan_output rpo
                WHERE rpo.plan_date       = p_plan_date
                  AND rpo.machine_name    = mtv.official_name
                  AND rpo.operator_status = 'approved')
    ) p
    LEFT JOIN public.v_shelf_state s
      ON s.machine_id = p.machine_id AND s.pod_product_id IS NOT NULL;

  SELECT count(*) INTO v_empty_mach FROM (
    SELECT p.machine_id
      FROM (
        SELECT DISTINCT mtv.machine_id, mtv.official_name
          FROM public.machines_to_visit mtv
         WHERE mtv.plan_date = p_plan_date
           AND mtv.status IN ('picked','cs_added')
           AND NOT EXISTS (
                 SELECT 1 FROM public.refill_plan_output rpo
                  WHERE rpo.plan_date       = p_plan_date
                    AND rpo.machine_name    = mtv.official_name
                    AND rpo.operator_status = 'approved')
      ) p
     WHERE NOT EXISTS (SELECT 1 FROM public.v_shelf_state s
                        WHERE s.machine_id = p.machine_id AND s.pod_product_id IS NOT NULL)
  ) q;

  WITH picked AS (
    SELECT DISTINCT mtv.machine_id, mtv.official_name
      FROM public.machines_to_visit mtv
     WHERE mtv.plan_date = p_plan_date
       AND mtv.status IN ('picked','cs_added')
       AND NOT EXISTS (
             SELECT 1 FROM public.refill_plan_output rpo
              WHERE rpo.plan_date       = p_plan_date
                AND rpo.machine_name    = mtv.official_name
                AND rpo.operator_status = 'approved')
  ),
  -- P2.4 (fixture 7). ONE resolver evaluation per PICKED MACHINE, never per shelf: the
  -- answer is machine-grain, and shelf-grain evaluation would re-run it ~16x per machine for an
  -- identical result. Article 16: this READS the canonical demand-multiplier object. It must
  -- never re-implement the most-specific-within-source / multiply-across-sources / clamp rule -
  -- that rule lives in resolve_demand_multiplier_v3 and is pinned by fixture 31 seq 3.
  -- LEFT JOIN LATERAL + COALESCE is deliberate: a resolver returning zero rows would otherwise
  -- DROP that machine's shelves from the plan entirely, which is exactly the silent-qty-0 class
  -- LAW 5 forbids. Fixture 31 seq 2/4 pin that the resolver is total and never returns NULL.
  dmf AS (
    SELECT p.machine_id,
           COALESCE(r.factor, 1)                AS demand_factor,
           COALESCE(r.factor_raw, 1)            AS demand_factor_raw,
           COALESCE(r.clamped, false)           AS demand_factor_clamped,
           COALESCE(r.provenance, '[]'::jsonb)  AS demand_factor_sources
      FROM picked p
      LEFT JOIN LATERAL public.resolve_demand_multiplier_v3(p.machine_id, p_plan_date) r ON true
  ),
  -- S-26: ONE fleet-wide evaluation of the velocity object per run. MATERIALIZED is not a hint
  -- here, it is the contract - inlining would expose it to per-machine re-evaluation.
  vel AS MATERIALIZED (
    SELECT v.shelf_id,
           v.velocity_instock_shelf,
           v.velocity_instock_pod,
           v.velocity_raw_shelf,
           v.velocity_status,
           v.split_method,
           v.pod_shelf_count
      FROM public.v_shelf_instock_velocity_split_v3 v
  ),
  -- P2.2c. Same S-26 contract: one fleet-wide evaluation each, never per-machine.
  -- LAW: read z and horizon_days from the v3 policy VIEW, never from machine_service_policy
  -- directly - the base columns are v19's and are deliberately stale (D-14 / D-16).
  pol AS MATERIALIZED (
    SELECT b.machine_id, b.visit_interval_days, b.interval_source, b.lead_days,
           b.horizon_days, b.z, b.z_source
      FROM public.v_machine_base_stock_policy_v3 b
  ),
  disp AS MATERIALIZED (
    SELECT d.machine_id, d.pod_product_id, d.phi, d.phi_source
      FROM public.v_pod_demand_dispersion_v3 d
  ),
  -- P2.3. Pod-grain FEFO shelf life, ONE row per (machine_id, pod_product_id). The MIN() collapse
  -- across the pod's Active product_mapping members is the earliest date any unit the pod could
  -- be filled from would expire - the binding constraint, per METRICS_REGISTRY Article 16.
  -- The predicate below is COPIED VERBATIM from v_shelf_availability_v3's `wh` CTE. v3 must have
  -- exactly ONE pod->WH resolution, not two that can drift apart (fixture 8 seq 4 catches a
  -- fan-out; seq 3 catches a predicate that resolves nothing).
  pods AS (
    SELECT DISTINCT ss.machine_id, ss.pod_product_id,
           m.primary_warehouse_id, m.secondary_warehouse_id
      FROM picked pk
      JOIN public.v_shelf_state ss ON ss.machine_id = pk.machine_id
      JOIN public.machines m       ON m.machine_id  = ss.machine_id
     WHERE ss.pod_product_id IS NOT NULL
  ),
  xp AS MATERIALIZED (
    SELECT p.machine_id, p.pod_product_id, MIN(sl.earliest_expiry) AS earliest_expiry
      FROM pods p
      JOIN public.product_mapping pm
        ON pm.pod_product_id = p.pod_product_id
       AND pm.status = 'Active'
       AND (pm.machine_id IS NULL OR pm.machine_id = p.machine_id)
      JOIN public.v_product_shelf_life sl
        ON sl.boonz_product_id = pm.boonz_product_id
       AND sl.warehouse_id = ANY (ARRAY[p.primary_warehouse_id, p.secondary_warehouse_id])
     GROUP BY 1, 2
  ),
  cand AS (
    SELECT
      p.machine_id,
      p.official_name,
      s.shelf_id,
      s.shelf_code,
      s.pod_product_id,
      s.pod_name,
      s.signal,
      s.operating_model,
      vv.velocity_instock_shelf,
      vv.velocity_instock_pod,
      vv.velocity_raw_shelf,
      vv.velocity_status,
      vv.split_method,
      bb.visit_interval_days,
      bb.interval_source,
      bb.lead_days,
      bb.horizon_days,
      bb.z,
      bb.z_source,
      dd.phi,
      dd.phi_source,
      xx.earliest_expiry,
      COALESCE(s.velocity_raw, 0)::numeric                      AS vel_raw_state,
      -- LAW 5 + LAW 6: name the source, never invent the number.
      CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN 'instock_split'
           WHEN s.velocity_raw            IS NOT NULL THEN 'weimi_raw_fallback'
           ELSE 'none_no_signal' END                            AS velocity_source,
      CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN vv.velocity_instock_shelf
           WHEN s.velocity_raw            IS NOT NULL THEN s.velocity_raw::numeric
           ELSE 0::numeric END                                  AS vel_base,
      -- P2.4. The multiplier is applied HERE and nowhere else. vel_eff feeds mu_term,
      -- cover_units AND expiry_ceiling_units, so this one multiplication carries the factor into
      -- every sizing term downstream. vel_base is kept UNSCALED beside it so shadow-vs-v19
      -- diffing can always separate "demand moved" from "we multiplied it" (fixture 7 seq 18/19).
      -- ⛔ sigma_daily_shelf is NOT scaled here - see the migration header.
      (CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN vv.velocity_instock_shelf
            WHEN s.velocity_raw            IS NOT NULL THEN s.velocity_raw::numeric
            ELSE 0::numeric END) * COALESCE(mf.demand_factor, 1)  AS vel_eff,
      COALESCE(mf.demand_factor, 1)                               AS demand_factor,
      COALESCE(mf.demand_factor_raw, 1)                           AS demand_factor_raw,
      COALESCE(mf.demand_factor_clamped, false)                   AS demand_factor_clamped,
      COALESCE(mf.demand_factor_sources, '[]'::jsonb)             AS demand_factor_sources,
      COALESCE(s.current_stock, 0)                              AS raw_stock,
      GREATEST(COALESCE(s.max_stock, 0), 0)                     AS max_stock,
      LEAST(GREATEST(COALESCE(s.current_stock, 0), 0),
            GREATEST(COALESCE(s.max_stock, 0), 0))              AS stock_clamped,
      (COALESCE(s.current_stock, 0) > COALESCE(s.max_stock, 0)) AS over_capacity,
      (a.shelf_id IS NULL)                                      AS avail_missing,
      CASE WHEN a.shelf_id IS NULL                                     THEN 'unknown'
           WHEN a.sourcing IN ('boonz_wh','venue','partner','mixed')   THEN a.sourcing
           ELSE 'unknown' END                                   AS basis,
      CASE WHEN a.shelf_id IS NULL      THEN 0
           WHEN a.is_constrained        THEN COALESCE(a.available_units, 0)
           ELSE NULL END                                        AS avail_units
    FROM picked p
    LEFT JOIN dmf mf
      ON mf.machine_id = p.machine_id
    JOIN public.v_shelf_state s
      ON s.machine_id = p.machine_id AND s.pod_product_id IS NOT NULL
    LEFT JOIN public.v_shelf_availability_v3 a
      ON a.shelf_id = s.shelf_id
    LEFT JOIN vel vv
      ON vv.shelf_id = s.shelf_id
    LEFT JOIN pol bb
      ON bb.machine_id = s.machine_id
    LEFT JOIN disp dd
      ON dd.machine_id = s.machine_id AND dd.pod_product_id = s.pod_product_id
    LEFT JOIN xp xx
      ON xx.machine_id = s.machine_id AND xx.pod_product_id = s.pod_product_id
  ),
  -- P2.2c. Resolve the base-stock terms and NAME every one of them (LAW 5). Sigma is not
  -- published at shelf grain by design: it is derived here from the pod-grain phi and split
  -- with the canonical shelf share.
  polled AS (
    SELECT c.*,
      COALESCE(c.horizon_days, p_days_cover::numeric)                AS horizon_eff,
      CASE WHEN c.horizon_days IS NOT NULL THEN 'base_stock_policy_v3'
           ELSE 'days_cover_arg_fallback' END                        AS horizon_source,
      COALESCE(c.z, 0::numeric)                                      AS z_eff,
      CASE WHEN c.z IS NOT NULL THEN COALESCE(c.z_source, 'base_stock_policy_v3')
           ELSE 'none_no_policy_row' END                             AS z_source_eff,
      CASE WHEN c.phi IS NULL                          THEN 0::numeric
           WHEN c.velocity_instock_shelf IS NULL       THEN 0::numeric
           WHEN COALESCE(c.velocity_instock_pod, 0) = 0 THEN 0::numeric
           ELSE c.phi * sqrt(c.velocity_instock_pod)
                     * (c.velocity_instock_shelf / c.velocity_instock_pod)
      END                                                            AS sigma_daily_shelf,
      CASE WHEN c.phi IS NULL                          THEN 'no_dispersion_row'
           WHEN c.velocity_instock_shelf IS NULL       THEN 'no_instock_split'
           WHEN COALESCE(c.velocity_instock_pod, 0) = 0 THEN 'no_instock_split'
           ELSE 'phi_x_sqrt_velocity_instock_pod_split_by_shelf_share'
      END                                                            AS sigma_source
    FROM cand c
  ),
  -- Cody (leg 44): the alias here is deliberately NOT `z` - `polled` now carries a column
  -- literally named `z`, so `z.z_eff` would be legal and a foot-gun for the next leg.
  sized AS (
    SELECT pl.*,
      GREATEST(pl.max_stock - pl.stock_clamped, 0)  AS fill_to_cap,
      -- S-13: vel_eff and sigma_daily_shelf are units per CALENDAR DAY. No /30. No *30. Ever.
      -- P2.2c base-stock target: S = mu*H + z*sigma*sqrt(H).
      (pl.vel_eff * pl.horizon_eff)                                        AS mu_term,
      (pl.z_eff * pl.sigma_daily_shelf * sqrt(pl.horizon_eff))             AS safety_term,
      CEIL(pl.vel_eff * pl.horizon_eff
           + pl.z_eff * pl.sigma_daily_shelf * sqrt(pl.horizon_eff))::int  AS cover_units,
      CASE WHEN pl.stock_clamped = 0 AND pl.basis <> 'partner' AND pl.max_stock > 0
           THEN GREATEST(1, LEAST(v_min_facing, pl.max_stock))
           ELSE 0 END                             AS floor_units,
      -- P2.3. Re-anchored on the PLAN date, never CURRENT_DATE. Floored at zero: a negative
      -- would flip the ceiling's sign and hand a short-dated shelf MORE stock (fixture 8 seq 5).
      -- expiry_days is 0 rather than NULL where no FEFO candidate resolves, so every line carries
      -- the COMPLETE expiry block (seq 22); expiry_source names WHY it is 0 and
      -- expiry_ceiling_units stays NULL there, so nothing binds off a non-measurement.
      GREATEST(COALESCE(pl.earliest_expiry - p_plan_date, 0), 0)          AS expiry_days,
      CASE WHEN pl.basis IN ('boonz_wh','mixed') AND pl.earliest_expiry IS NOT NULL
           THEN FLOOR(GREATEST(COALESCE(pl.earliest_expiry - p_plan_date, 0), 0)
                      * pl.vel_eff * v_expiry_factor)::int
           ELSE NULL END                                                  AS expiry_ceiling_units,
      CASE WHEN pl.basis IN ('boonz_wh','mixed') AND pl.earliest_expiry IS NOT NULL
                                                            THEN 'wh_fefo_batch'
           WHEN pl.basis IN ('boonz_wh','mixed')            THEN 'no_wh_batch'
           WHEN pl.basis IN ('venue','partner')             THEN 'not_wh_sourced'
           ELSE 'unknown_sourcing' END                                    AS expiry_source
    FROM polled pl
  ),
  -- ===================== P4.2 - PLANNING PINS ARE READ AS CONSTRAINTS =====================
  -- The L0 constraint read (BUILD SPEC P4.2). A pin is a FLOOR on the units this visit plans,
  -- never a licence to fill the shelf: it is capped by fill_to_cap here and by availability
  -- downstream, which is exactly how a pin raises DEMAND on a dry shelf without ever conjuring
  -- warehouse stock.
  --
  -- Read from the CANONICAL view, which hides revoked AND expired pins. The base table keeps
  -- both forever, so a consumer reading it would honour instructions CS has already withdrawn.
  --
  -- Scoped by machine + SHELF, and additionally by the product still being mapped to that
  -- shelf's pod. Shelf scope is what keeps a pin surgical: shelves on this fleet routinely carry
  -- the identical pod (A01 and A03 are both Coca Cola Zero on VML-1003-0400-O1), and a pin
  -- resolved through pod identity would move both. The EXISTS check retires a pin by itself once
  -- its shelf is repurposed to a different product.
  --
  -- never_stock is deliberately NOT consumed here: it is a ceiling, not a floor, and LAW 1 says
  -- it does not get built before the fixture that proves it.
  pinned AS (
    SELECT z.*,
      COALESCE(pf.pin_count, 0)                             AS pin_count,
      LEAST(COALESCE(pf.pin_floor_raw, 0), z.fill_to_cap)   AS pin_floor_units
    FROM sized z
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS pin_count,
             COALESCE(max(
               CASE pp.kind
                 -- a DEPTH target: top the shelf up to the level the driver protected
                 WHEN 'protect_depth' THEN GREATEST(COALESCE(pp.value, 0) - z.stock_clamped, 0)
                 -- a QTY floor: the facings the client asked to see placed on this visit
                 WHEN 'min_facing'    THEN GREATEST(COALESCE(pp.value, 0), 0)
                 -- a PRESENCE guarantee: at least one unit is always planned, so a shelf the
                 -- engine would otherwise pass over in silence yields a NAMED line (LAW 5).
                 -- Note this is a floor on UNITS, not on depth - as a depth rule it would be
                 -- a no-op on every shelf that already holds stock, and therefore redundant
                 -- with the P2.5 unconditional floor.
                 WHEN 'always_stock'  THEN 1
                 ELSE 0
               END), 0)::int AS pin_floor_raw
        FROM public.v_planning_pins_active_v3 pp
       WHERE pp.machine_id = z.machine_id
         AND pp.shelf_id   = z.shelf_id
         AND pp.kind IN ('protect_depth', 'min_facing', 'always_stock')
         AND EXISTS (SELECT 1 FROM public.product_mapping pm
                      WHERE pm.boonz_product_id = pp.boonz_product_id
                        AND pm.pod_product_id   = z.pod_product_id
                        AND pm.status = 'Active'
                        AND (pm.machine_id IS NULL OR pm.machine_id = z.machine_id))
    ) pf ON true
  ),
  needed AS (
    SELECT z.*,
      -- need_raw_no_pin is this ladder EXACTLY as it stood before pins existed. Keeping it makes
      -- "the pin is what set this number" DECIDABLE below instead of inferred.
      LEAST(GREATEST(LEAST(z.cover_units,
                           COALESCE(z.expiry_ceiling_units, z.cover_units)),
                     z.floor_units), z.fill_to_cap)                     AS need_raw_no_pin,
      LEAST(GREATEST(LEAST(z.cover_units,
                           COALESCE(z.expiry_ceiling_units, z.cover_units)),
                     z.floor_units, z.pin_floor_units), z.fill_to_cap)  AS need_raw,
      LEAST(GREATEST(z.cover_units, z.floor_units, z.pin_floor_units),
            z.fill_to_cap)                                              AS need_raw_no_expiry
    FROM pinned z
  ),
  alloc AS (
    SELECT n.*,
      COALESCE(SUM(n.need_raw) OVER (
        PARTITION BY n.machine_id, n.pod_product_id
        ORDER BY n.vel_eff DESC, n.shelf_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)::int AS prior_need
    FROM needed n
  ),
  final AS (
    SELECT a.*,
      CASE WHEN a.avail_units IS NULL THEN NULL
           ELSE GREATEST(a.avail_units - a.prior_need, 0) END AS avail_for_me,
      CASE
        WHEN a.avail_missing            THEN 0
        WHEN a.avail_units IS NULL      THEN a.need_raw
        ELSE LEAST(a.need_raw, GREATEST(a.avail_units - a.prior_need, 0))
      END::int                                                AS qty,
      -- A pin BINDS only when it is the term that actually decided need_raw. Computed once,
      -- here, so the clamp ladder and the reasoning blob can never disagree about it.
      (a.pin_floor_units > 0
       AND a.need_raw = a.pin_floor_units
       AND a.pin_floor_units > a.need_raw_no_pin)             AS pin_binds
    FROM alloc a
  ),
  reasoned AS (
    SELECT f.*,
      CASE
        WHEN f.avail_missing                                     THEN 'availability_row_missing'
        WHEN f.over_capacity                                     THEN 'sensor_over_capacity'
        WHEN f.max_stock = 0                                     THEN 'no_capacity_configured'
        -- A binding pin OVERRIDES the expiry ceiling by construction (it sits inside the
        -- GREATEST above), so naming the ceiling here would name a constraint that did not
        -- decide anything. Unpinned lines are bit-for-bit unaffected: pin_binds is false
        -- whenever pin_floor_units is 0.
        WHEN f.need_raw < f.need_raw_no_expiry
             AND NOT f.pin_binds                                 THEN 'expiry_ceiling'
        WHEN f.need_raw = 0                                      THEN 'skipped_full'
        -- AVAILABILITY OUTRANKS THE PIN, DELIBERATELY. A pin raises demand; it never conjures
        -- warehouse stock. On a dry shelf the honest name is blocked_no_wh - which is also the
        -- name that routes the unit into blocked_demand instead of losing it (LAW 5).
        WHEN f.avail_for_me IS NOT NULL AND f.avail_for_me = 0
             AND f.need_raw > 0                                  THEN 'blocked_no_wh'
        WHEN f.avail_for_me IS NOT NULL AND f.qty < f.need_raw   THEN 'partial_wh_limited'
        WHEN f.pin_binds                                         THEN 'pin_floor'
        WHEN f.need_raw >= f.fill_to_cap                         THEN 'fill_to_cap'
        ELSE 'cover_capped'
      END AS clamp_reason
    FROM final f
  ),
  ins AS (
    INSERT INTO public.pod_refills_shadow (
      run_id, engine_tag, plan_date, machine_id, shelf_id, pod_product_id,
      qty, current_stock, max_stock, days_cover, signal,
      wh_available_pod, clamp_reason, velocity_instock, availability_basis, reasoning)
    SELECT
      v_run_id, v_tag, p_plan_date, r.machine_id, r.shelf_id, r.pod_product_id,
      r.qty,
      r.stock_clamped,
      r.max_stock,
      -- Unchanged on purpose: this column keeps meaning "the p_days_cover this run was
      -- invoked with", so shadow-vs-v19 diffing stays comparable. The horizon that actually
      -- sized the line is reasoning->>'horizon_days'.
      p_days_cover,
      r.signal,
      CASE WHEN r.basis = 'boonz_wh' THEN COALESCE(r.avail_units, 0) ELSE r.avail_units END,
      r.clamp_reason,
      -- Canonical from P2.1 on: non-null on EXACTLY the instock_split lines (fixture 14 seq 47).
      r.velocity_instock_shelf,
      r.basis,
      jsonb_build_object(
        'shelf_code',           r.shelf_code,
        'official_name',        r.official_name,
        'pod_name',             r.pod_name,
        'operating_model',      r.operating_model,
        'need_raw',             r.need_raw,
        'cover_units',          r.cover_units,
        'floor_units',          r.floor_units,
        'fill_to_cap',          r.fill_to_cap,
        'prior_need_pool',      r.prior_need,
        'avail_for_me',         r.avail_for_me,
        'available_units',      r.avail_units,
        'raw_current_stock',    r.raw_stock,
        'sensor_over_capacity', r.over_capacity,
        'sourcing',             r.basis,
        -- P2.1 velocity provenance (fixture 14 seq 40-48).
        'velocity_source',           r.velocity_source,
        'velocity_effective_daily',  r.vel_eff,
        -- P2.4 demand-multiplier provenance (fixture 7 seq 14-19). LAW 5: an UNFACTORED line
        -- records 1.0 and an empty source list EXPLICITLY, so silence is never ambiguous.

        'velocity_instock_shelf',    r.velocity_instock_shelf,
        'velocity_instock_pod',      r.velocity_instock_pod,
        'velocity_raw_shelf',        r.velocity_raw_shelf,
        'velocity_split_status',     r.velocity_status,
        'velocity_split_method',     r.split_method,
        'velocity_raw_daily',        r.vel_raw_state,
        -- P2.2c base-stock provenance. Every term that moved a quantity is named.
        'horizon_days',         r.horizon_eff,
        'horizon_source',       r.horizon_source,
        'visit_interval_days',  r.visit_interval_days,
        'interval_source',      r.interval_source,
        'lead_days',            r.lead_days,
        'z',                    r.z_eff,
        'z_source',             r.z_source_eff,
        'phi',                  r.phi,
        'phi_source',           r.phi_source,
        'sigma_daily_shelf',    r.sigma_daily_shelf,
        'sigma_source',         r.sigma_source,
        'mu_term',              r.mu_term,
        'safety_term',          r.safety_term,
        'days_cover',           p_days_cover,
        'days_cover_arg',       p_days_cover,
        'days_cover_role',      'advisory_echo_and_tier3_horizon_fallback_since_p22c',
        'min_facing_floor',     v_min_facing,
        -- P2.3 expiry-ceiling provenance (fixture 8 seq 21-27).
        'earliest_expiry',      r.earliest_expiry,
        'expiry_days',          r.expiry_days,
        'expiry_ceiling_units', r.expiry_ceiling_units,
        'expiry_source',        r.expiry_source,
        'expiry_safety_factor', v_expiry_factor,
        'need_raw_no_expiry',   r.need_raw_no_expiry,
        'candidate_source',     'v_shelf_state + v_shelf_availability_v3 + v_shelf_instock_velocity_split_v3 + v_machine_base_stock_policy_v3 + v_pod_demand_dispersion_v3 + v_product_shelf_life + demand_calendar',
        'engine_calibration',   'v3_p24_demand_multiplier',
        'sizing_mode',          'base_stock_mu_x_horizon_plus_z_x_sigma_x_sqrt_horizon_with_min_facing_floor_capped_by_expiry_ceiling',
        'run_id',               v_run_id)
      -- P2.4 demand-multiplier provenance, fixture 7 seq 14-19. ⛔ These live in a SECOND
      -- jsonb_build_object merged with ||, NOT in the base object above: jsonb_build_object is
      -- capped at 100 arguments = 50 pairs, and the base object is AT that ceiling. Adding one
      -- key there kills every engine run with SQLSTATE 54023.
      -- LAW 5: an UNFACTORED line records 1.0 and an empty source list EXPLICITLY, so silence is
      -- never ambiguous.
      || jsonb_build_object(
        'velocity_base_daily',       r.vel_base,
        'demand_factor',             r.demand_factor,
        'demand_factor_raw',         r.demand_factor_raw,
        'demand_factor_clamped',     r.demand_factor_clamped,
        'demand_factor_sources',     r.demand_factor_sources)
      -- P4.2 pin provenance. A THIRD object on purpose: the base object above is at 49 pairs,
      -- one pair short of jsonb_build_object's 100-argument ceiling, and adding a key there
      -- kills every engine run with SQLSTATE 54023.
      -- LAW 5: EVERY line carries these, pinned or not. An unpinned line records 0 / 0 / false
      -- EXPLICITLY, so "no pin applied" is never indistinguishable from "nobody looked".
      || jsonb_build_object(
        'pin_floor_units',           r.pin_floor_units,
        'pin_count',                 r.pin_count,
        'pin_binds',                 r.pin_binds,
        'need_raw_no_pin',           r.need_raw_no_pin)
    FROM reasoned r
    RETURNING qty, clamp_reason, availability_basis,
              (reasoning->>'velocity_source') AS vsrc,
              (reasoning->>'horizon_source')  AS hsrc,
              (reasoning->>'sigma_source')    AS ssrc,
              (reasoning->>'expiry_source')            AS xsrc,
              (reasoning->>'need_raw')::int            AS nr,
              (reasoning->>'need_raw_no_expiry')::int  AS nrne
  )
  SELECT count(*),
         count(*) FILTER (WHERE qty = 0),
         COALESCE(sum(qty), 0),
         count(*) FILTER (WHERE clamp_reason = 'blocked_no_wh'),
         count(*) FILTER (WHERE clamp_reason = 'partial_wh_limited'),
         count(*) FILTER (WHERE clamp_reason = 'sensor_over_capacity'),
         count(*) FILTER (WHERE availability_basis = 'unknown'),
         count(*) FILTER (WHERE vsrc = 'instock_split'),
         count(*) FILTER (WHERE vsrc = 'weimi_raw_fallback'),
         count(*) FILTER (WHERE vsrc = 'none_no_signal'),
         count(*) FILTER (WHERE hsrc = 'base_stock_policy_v3'),
         count(*) FILTER (WHERE hsrc = 'days_cover_arg_fallback'),
         count(*) FILTER (WHERE ssrc = 'phi_x_sqrt_velocity_instock_pod_split_by_shelf_share'),
         count(*) FILTER (WHERE ssrc = 'no_dispersion_row'),
         count(*) FILTER (WHERE ssrc = 'no_instock_split'),
         count(*) FILTER (WHERE clamp_reason = 'fill_to_cap'),
         count(*) FILTER (WHERE xsrc = 'wh_fefo_batch'),
         count(*) FILTER (WHERE xsrc = 'no_wh_batch'),
         count(*) FILTER (WHERE xsrc = 'not_wh_sourced'),
         count(*) FILTER (WHERE xsrc = 'unknown_sourcing'),
         count(*) FILTER (WHERE clamp_reason = 'expiry_ceiling'),
         COALESCE(sum(GREATEST(nrne - nr, 0)), 0)
    INTO v_lines, v_qty0, v_units, v_blocked, v_partial, v_over_cap, v_unknown,
         v_v_instock, v_v_fallback, v_v_none,
         v_h_policy, v_h_fallback, v_sig_meas, v_sig_nodisp, v_sig_nosplit, v_fill_cap,
         v_xp_fefo, v_xp_nobatch, v_xp_notwh, v_xp_unknown, v_exp_lines, v_exp_removed
  FROM ins;

  -- SELF-PROVING COVERAGE GUARD (RISK 75). The whole point of v3 is that nothing is dropped
  -- silently, so it proves that about its own output before returning.
  SELECT count(*) INTO v_uncovered
    FROM (
      SELECT DISTINCT mtv.machine_id, mtv.official_name
        FROM public.machines_to_visit mtv
       WHERE mtv.plan_date = p_plan_date
         AND mtv.status IN ('picked','cs_added')
         AND NOT EXISTS (
               SELECT 1 FROM public.refill_plan_output rpo
                WHERE rpo.plan_date       = p_plan_date
                  AND rpo.machine_name    = mtv.official_name
                  AND rpo.operator_status = 'approved')
    ) p
    JOIN public.v_shelf_state s
      ON s.machine_id = p.machine_id AND s.pod_product_id IS NOT NULL
   WHERE NOT EXISTS (
           SELECT 1 FROM public.pod_refills_shadow prs
            WHERE prs.run_id = v_run_id AND prs.shelf_id = s.shelf_id);

  IF v_uncovered <> 0 THEN
    RAISE EXCEPTION 'engine_add_pod_v3: % in-scope pod-bound shelf/shelves received no line '
      '(LAW 5 - silent drop). run_id %, plan_date %', v_uncovered, v_run_id, p_plan_date;
  END IF;

  IF v_lines <> v_scope THEN
    RAISE EXCEPTION 'engine_add_pod_v3: wrote % lines for a scope of % pod-bound shelves '
      '(run_id %). A mismatch means the candidate join fanned out or lost rows.',
      v_lines, v_scope, v_run_id;
  END IF;

  -- LAW 5, proved by the engine about its own output: every line named its velocity source.
  -- The velocity join is a LEFT JOIN, so a shelf missing from the velocity object still gets a
  -- line - but it may never get one with an unnamed rate.
  IF (v_v_instock + v_v_fallback + v_v_none) <> v_lines THEN
    RAISE EXCEPTION 'engine_add_pod_v3: % of % lines carry no recognised velocity_source '
      '(run_id %). LAW 5 - a sized line must name where its rate came from.',
      v_lines - (v_v_instock + v_v_fallback + v_v_none), v_lines, v_run_id;
  END IF;

  -- P2.2c, same LAW-5 shape for the two new sizing inputs. A quantity may never move on an
  -- unnamed horizon or an unnamed sigma.
  IF (v_h_policy + v_h_fallback) <> v_lines THEN
    RAISE EXCEPTION 'engine_add_pod_v3: % of % lines carry no recognised horizon_source '
      '(run_id %). LAW 5 - a sized line must name its planning horizon.',
      v_lines - (v_h_policy + v_h_fallback), v_lines, v_run_id;
  END IF;

  IF (v_sig_meas + v_sig_nodisp + v_sig_nosplit) <> v_lines THEN
    RAISE EXCEPTION 'engine_add_pod_v3: % of % lines carry no recognised sigma_source '
      '(run_id %). LAW 5 - a sized line must name its dispersion basis.',
      v_lines - (v_sig_meas + v_sig_nodisp + v_sig_nosplit), v_lines, v_run_id;
  END IF;

  -- P2.3, same LAW-5 shape. A quantity may never be capped - or left uncapped - on an expiry
  -- basis nobody can name.
  IF (v_xp_fefo + v_xp_nobatch + v_xp_notwh + v_xp_unknown) <> v_lines THEN
    RAISE EXCEPTION 'engine_add_pod_v3: % of % lines carry no recognised expiry_source '
      '(run_id %). LAW 5 - a sized line must name its expiry basis.',
      v_lines - (v_xp_fefo + v_xp_nobatch + v_xp_notwh + v_xp_unknown), v_lines, v_run_id;
  END IF;

  RETURN jsonb_build_object(
    'run_id',                   v_run_id,
    'engine_tag',               v_tag,
    'engine_version',           'v3_p23_expiry_ceiling',
    'plan_date',                p_plan_date,
    'days_cover',               p_days_cover,
    'days_cover_role',          'advisory_echo_and_tier3_horizon_fallback_since_p22c',
    'machines_in_scope',        v_machines,
    'machines_without_shelves', v_empty_mach,
    'shelves_in_scope',         v_scope,
    'lines_written',            v_lines,
    'units_planned',            v_units,
    'qty0_lines',               v_qty0,
    'blocked_no_wh',            v_blocked,
    'partial_wh_limited',       v_partial,
    'sensor_over_capacity',     v_over_cap,
    'availability_unknown',     v_unknown,
    'velocity_instock_lines',   v_v_instock,
    'velocity_fallback_lines',  v_v_fallback,
    'velocity_none_lines',      v_v_none,
    -- P2.2c base-stock telemetry. S-43's failure mode (sizing silently degenerating into
    -- "fill everything to capacity" with no error and no anomalous clamp_reason) is now
    -- VISIBLE in every run's own return value instead of having to be inferred.
    'horizon_policy_lines',     v_h_policy,
    'horizon_fallback_lines',   v_h_fallback,
    'sigma_measured_lines',     v_sig_meas,
    'sigma_no_dispersion_lines',v_sig_nodisp,
    'sigma_no_split_lines',     v_sig_nosplit,
    'fill_to_cap_lines',        v_fill_cap,
    'fill_to_cap_share',        CASE WHEN v_lines = 0 THEN 0
                                     ELSE round((v_fill_cap::numeric / v_lines), 4) END,
    -- P2.3 expiry telemetry. The clamp class is visible in the run's own return value.
    'expiry_ceiling_lines',     v_exp_lines,
    'expiry_units_removed',     v_exp_removed,
    'expiry_fefo_lines',        v_xp_fefo,
    'expiry_no_batch_lines',    v_xp_nobatch,
    'expiry_not_wh_lines',      v_xp_notwh,
    'expiry_unknown_src_lines', v_xp_unknown,
    'target_table',             'public.pod_refills_shadow',
    'wrote_live_pod_refills',   false,
    'duration_ms',              (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END
$function$
;

-- Refuse to record this migration as applied unless the engine really carries the consumer.
DO $guard$
DECLARE v_src text; v_missing text := '';
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'engine_add_pod_v3';
  IF v_src IS NULL THEN RAISE EXCEPTION 'engine_add_pod_v3 is missing entirely'; END IF;
  IF position('v_planning_pins_active_v3' in v_src) = 0 THEN v_missing := v_missing || ' canonical_view'; END IF;
  IF v_src ~ '(FROM|JOIN)\s+(public\.)?planning_pins_v3' THEN v_missing := v_missing || ' READS_BASE_TABLE'; END IF;
  IF position('pin_floor_units' in v_src) = 0 THEN v_missing := v_missing || ' pin_floor_units'; END IF;
  IF position('pin_binds' in v_src) = 0 THEN v_missing := v_missing || ' pin_binds'; END IF;
  IF position('need_raw_no_pin' in v_src) = 0 THEN v_missing := v_missing || ' need_raw_no_pin'; END IF;
  IF position('''pin_floor''' in v_src) = 0 THEN v_missing := v_missing || ' pin_floor_clamp'; END IF;
  IF v_missing <> '' THEN
    RAISE EXCEPTION 'P4.2 consumer did not land, missing//wrong:%', v_missing;
  END IF;
END $guard$;
