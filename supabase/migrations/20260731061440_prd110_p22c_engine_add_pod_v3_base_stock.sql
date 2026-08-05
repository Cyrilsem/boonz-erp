-- PRD-110 P2.2c — engine_add_pod_v3 base-stock wiring
-- S = mu * H + z * sigma * sqrt(H), H = horizon_days from v_machine_base_stock_policy_v3
-- sigma_daily_pod = phi * sqrt(velocity_instock_pod); split to shelf by the canonical
-- weight velocity_instock_shelf / velocity_instock_pod.
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
      COALESCE(s.velocity_raw, 0)::numeric                      AS vel_raw_state,
      -- LAW 5 + LAW 6: name the source, never invent the number.
      CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN 'instock_split'
           WHEN s.velocity_raw            IS NOT NULL THEN 'weimi_raw_fallback'
           ELSE 'none_no_signal' END                            AS velocity_source,
      CASE WHEN vv.velocity_instock_shelf IS NOT NULL THEN vv.velocity_instock_shelf
           WHEN s.velocity_raw            IS NOT NULL THEN s.velocity_raw::numeric
           ELSE 0::numeric END                                  AS vel_eff,
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
           ELSE 0 END                             AS floor_units
    FROM polled pl
  ),
  needed AS (
    SELECT z.*, LEAST(GREATEST(z.cover_units, z.floor_units), z.fill_to_cap) AS need_raw
    FROM sized z
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
      END::int                                                AS qty
    FROM alloc a
  ),
  reasoned AS (
    SELECT f.*,
      CASE
        WHEN f.avail_missing                                     THEN 'availability_row_missing'
        WHEN f.over_capacity                                     THEN 'sensor_over_capacity'
        WHEN f.max_stock = 0                                     THEN 'no_capacity_configured'
        WHEN f.need_raw = 0                                      THEN 'skipped_full'
        WHEN f.avail_for_me IS NOT NULL AND f.avail_for_me = 0   THEN 'blocked_no_wh'
        WHEN f.avail_for_me IS NOT NULL AND f.qty < f.need_raw   THEN 'partial_wh_limited'
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
        'candidate_source',     'v_shelf_state + v_shelf_availability_v3 + v_shelf_instock_velocity_split_v3 + v_machine_base_stock_policy_v3 + v_pod_demand_dispersion_v3',
        'engine_calibration',   'v3_p22c_base_stock',
        'sizing_mode',          'base_stock_mu_x_horizon_plus_z_x_sigma_x_sqrt_horizon_with_min_facing_floor',
        'run_id',               v_run_id)
    FROM reasoned r
    RETURNING qty, clamp_reason, availability_basis,
              (reasoning->>'velocity_source') AS vsrc,
              (reasoning->>'horizon_source')  AS hsrc,
              (reasoning->>'sigma_source')    AS ssrc
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
         count(*) FILTER (WHERE clamp_reason = 'fill_to_cap')
    INTO v_lines, v_qty0, v_units, v_blocked, v_partial, v_over_cap, v_unknown,
         v_v_instock, v_v_fallback, v_v_none,
         v_h_policy, v_h_fallback, v_sig_meas, v_sig_nodisp, v_sig_nosplit, v_fill_cap
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

  RETURN jsonb_build_object(
    'run_id',                   v_run_id,
    'engine_tag',               v_tag,
    'engine_version',           'v3_p22c_base_stock',
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
    'target_table',             'public.pod_refills_shadow',
    'wrote_live_pod_refills',   false,
    'duration_ms',              (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END
$function$;
