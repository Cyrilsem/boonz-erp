-- PRD-110 · P2.3 · engine_add_pod_v3 gains the EXPIRY CEILING.
--
-- BUILD SPEC P2.3: Ceiling = min(S, capacity, days_to_expiry_available x sell_rate x safety),
-- expiry taken from the FEFO WH batch at PLAN TIME.
--
-- Method (leg-26): exact NAMED SUBSTITUTIONS over the live pg_get_functiondef text, each asserted
-- to match EXACTLY ONCE, plus a reverse substitution asserted to reproduce the original
-- byte-for-byte BEFORE any DDL runs. The 449-line body is never retyped.
--
-- Cody rev 2 (LAW 5): the ceiling caps the COVER term only. The min-facing floor SURVIVES it.
-- Cody rev 3: post-DDL, assert pg_proc still holds exactly ONE engine_add_pod_v3 AND its oid is
--             still 235798 - a substitution that perturbs the signature would ADD AN OVERLOAD
--             instead of replacing, and only the oid proves identity.
-- LAW 7: sizing is READ-ONLY over inventory. Nothing here consumes, writes off or moves stock.
-- METRICS_REGISTRY Article 16: v_product_shelf_life is the canonical shelf-life object and the
--             pod->WH predicate below is COPIED VERBATIM from v_shelf_availability_v3's `wh` CTE,
--             so v3 keeps exactly ONE pod->WH resolution. remaining_shelf_life_days is FORBIDDEN
--             (CURRENT_DATE-anchored; it answers a different question for any future plan_date).
DO $mig$
DECLARE
  v_oid   oid;
  v_def   text;
  v_new   text;
  v_back  text;
  v_n     int;
  i       int;
  v_from  text[];
  v_to    text[];
BEGIN
  SELECT p.oid, pg_get_functiondef(p.oid) INTO v_oid, v_def
    FROM pg_proc p
   WHERE p.proname = 'engine_add_pod_v3' AND p.pronamespace = 'public'::regnamespace;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'P2.3: engine_add_pod_v3 not found';
  END IF;
  IF v_oid <> 235798::oid THEN
    RAISE EXCEPTION 'P2.3 PRE-GUARD: engine_add_pod_v3 oid is % (expected 235798). Identity is '
                    'unproven - refusing to substitute over an unknown body.', v_oid;
  END IF;
  SELECT count(*) INTO v_n FROM pg_proc
   WHERE proname = 'engine_add_pod_v3' AND pronamespace = 'public'::regnamespace;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'P2.3 PRE-GUARD: % overloads of engine_add_pod_v3 (expected exactly 1)', v_n;
  END IF;

  -- ============================================================================================
  -- 1. DECLARE the safety factor + the P2.3 telemetry counters.
  -- ============================================================================================
  v_from := ARRAY[
$s$  v_min_facing   integer     := COALESCE((SELECT min_facing_floor FROM public.refill_policy_params WHERE id = 1), 2);$s$
  ];
  v_to := ARRAY[
$s$  v_min_facing   integer     := COALESCE((SELECT min_facing_floor FROM public.refill_policy_params WHERE id = 1), 2);
  -- P2.3. Read from refill_policy_params, NEVER a hardcoded 0.8 - otherwise tuning the param
  -- is a silent no-op (fixture 8 seq 23).
  v_expiry_factor numeric    := COALESCE((SELECT base_stock_expiry_safety_factor FROM public.refill_policy_params WHERE id = 1), 0.80);
  v_xp_fefo      integer     := 0;
  v_xp_nobatch   integer     := 0;
  v_xp_notwh     integer     := 0;
  v_xp_unknown   integer     := 0;
  v_exp_lines    integer     := 0;
  v_exp_removed  integer     := 0;$s$
  ];

  -- ============================================================================================
  -- 2. The pod-grain FEFO shelf-life map, beside `disp`.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$  disp AS MATERIALIZED (
    SELECT d.machine_id, d.pod_product_id, d.phi, d.phi_source
      FROM public.v_pod_demand_dispersion_v3 d
  ),$s$
  ];
  v_to := v_to || ARRAY[
$s$  disp AS MATERIALIZED (
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
  ),$s$
  ];

  -- ============================================================================================
  -- 3. `cand` carries the date + joins the map.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$      dd.phi,
      dd.phi_source,
      COALESCE(s.velocity_raw, 0)::numeric                      AS vel_raw_state,$s$
  ];
  v_to := v_to || ARRAY[
$s$      dd.phi,
      dd.phi_source,
      xx.earliest_expiry,
      COALESCE(s.velocity_raw, 0)::numeric                      AS vel_raw_state,$s$
  ];

  v_from := v_from || ARRAY[
$s$    LEFT JOIN disp dd
      ON dd.machine_id = s.machine_id AND dd.pod_product_id = s.pod_product_id
  ),$s$
  ];
  v_to := v_to || ARRAY[
$s$    LEFT JOIN disp dd
      ON dd.machine_id = s.machine_id AND dd.pod_product_id = s.pod_product_id
    LEFT JOIN xp xx
      ON xx.machine_id = s.machine_id AND xx.pod_product_id = s.pod_product_id
  ),$s$
  ];

  -- ============================================================================================
  -- 4. `sized` resolves the ceiling and NAMES its basis (LAW 5).
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$      CASE WHEN pl.stock_clamped = 0 AND pl.basis <> 'partner' AND pl.max_stock > 0
           THEN GREATEST(1, LEAST(v_min_facing, pl.max_stock))
           ELSE 0 END                             AS floor_units
    FROM polled pl
  ),$s$
  ];
  v_to := v_to || ARRAY[
$s$      CASE WHEN pl.stock_clamped = 0 AND pl.basis <> 'partner' AND pl.max_stock > 0
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
  ),$s$
  ];

  -- ============================================================================================
  -- 5. `needed`: the ceiling caps the COVER term. The floor survives it (Cody rev 2 / LAW 5).
  --    need_raw_no_expiry is computed too, so `expiry_binds` is EXACT rather than inferred.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$  needed AS (
    SELECT z.*, LEAST(GREATEST(z.cover_units, z.floor_units), z.fill_to_cap) AS need_raw
    FROM sized z
  ),$s$
  ];
  v_to := v_to || ARRAY[
$s$  needed AS (
    SELECT z.*,
      LEAST(GREATEST(LEAST(z.cover_units,
                           COALESCE(z.expiry_ceiling_units, z.cover_units)),
                     z.floor_units), z.fill_to_cap)                     AS need_raw,
      LEAST(GREATEST(z.cover_units, z.floor_units), z.fill_to_cap)      AS need_raw_no_expiry
    FROM sized z
  ),$s$
  ];

  -- ============================================================================================
  -- 6. clamp_reason ladder. ORDER MATTERS: a line the ceiling drives to 0 would otherwise be
  --    labelled 'skipped_full' - a lie that hides the entire clamp class from procurement
  --    (fixture 8 seq 27). The `need_raw > 0` guard on blocked_no_wh keeps that branch's
  --    existing outcome unchanged and makes its precondition explicit.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$        WHEN f.need_raw = 0                                      THEN 'skipped_full'
        WHEN f.avail_for_me IS NOT NULL AND f.avail_for_me = 0   THEN 'blocked_no_wh'$s$
  ];
  v_to := v_to || ARRAY[
$s$        WHEN f.need_raw < f.need_raw_no_expiry                   THEN 'expiry_ceiling'
        WHEN f.need_raw = 0                                      THEN 'skipped_full'
        WHEN f.avail_for_me IS NOT NULL AND f.avail_for_me = 0
             AND f.need_raw > 0                                  THEN 'blocked_no_wh'$s$
  ];

  -- ============================================================================================
  -- 7. Provenance. Every term that moved a quantity is named.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$        'min_facing_floor',     v_min_facing,
        'candidate_source',     'v_shelf_state + v_shelf_availability_v3 + v_shelf_instock_velocity_split_v3 + v_machine_base_stock_policy_v3 + v_pod_demand_dispersion_v3',
        'engine_calibration',   'v3_p22c_base_stock',
        'sizing_mode',          'base_stock_mu_x_horizon_plus_z_x_sigma_x_sqrt_horizon_with_min_facing_floor',$s$
  ];
  v_to := v_to || ARRAY[
$s$        'min_facing_floor',     v_min_facing,
        -- P2.3 expiry-ceiling provenance (fixture 8 seq 21-27).
        'earliest_expiry',      r.earliest_expiry,
        'expiry_days',          r.expiry_days,
        'expiry_ceiling_units', r.expiry_ceiling_units,
        'expiry_source',        r.expiry_source,
        'expiry_safety_factor', v_expiry_factor,
        'need_raw_no_expiry',   r.need_raw_no_expiry,
        'candidate_source',     'v_shelf_state + v_shelf_availability_v3 + v_shelf_instock_velocity_split_v3 + v_machine_base_stock_policy_v3 + v_pod_demand_dispersion_v3 + v_product_shelf_life',
        'engine_calibration',   'v3_p23_expiry_ceiling',
        'sizing_mode',          'base_stock_mu_x_horizon_plus_z_x_sigma_x_sqrt_horizon_with_min_facing_floor_capped_by_expiry_ceiling',$s$
  ];

  -- ============================================================================================
  -- 8. Telemetry, so the clamp class is VISIBLE in every run's own return value.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$    RETURNING qty, clamp_reason, availability_basis,
              (reasoning->>'velocity_source') AS vsrc,
              (reasoning->>'horizon_source')  AS hsrc,
              (reasoning->>'sigma_source')    AS ssrc$s$
  ];
  v_to := v_to || ARRAY[
$s$    RETURNING qty, clamp_reason, availability_basis,
              (reasoning->>'velocity_source') AS vsrc,
              (reasoning->>'horizon_source')  AS hsrc,
              (reasoning->>'sigma_source')    AS ssrc,
              (reasoning->>'expiry_source')            AS xsrc,
              (reasoning->>'need_raw')::int            AS nr,
              (reasoning->>'need_raw_no_expiry')::int  AS nrne$s$
  ];

  v_from := v_from || ARRAY[
$s$         count(*) FILTER (WHERE ssrc = 'no_instock_split'),
         count(*) FILTER (WHERE clamp_reason = 'fill_to_cap')
    INTO v_lines, v_qty0, v_units, v_blocked, v_partial, v_over_cap, v_unknown,
         v_v_instock, v_v_fallback, v_v_none,
         v_h_policy, v_h_fallback, v_sig_meas, v_sig_nodisp, v_sig_nosplit, v_fill_cap
  FROM ins;$s$
  ];
  v_to := v_to || ARRAY[
$s$         count(*) FILTER (WHERE ssrc = 'no_instock_split'),
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
  FROM ins;$s$
  ];

  -- ============================================================================================
  -- 9. LAW-5 guard, cloned from the horizon/sigma guards.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$  IF (v_sig_meas + v_sig_nodisp + v_sig_nosplit) <> v_lines THEN
    RAISE EXCEPTION 'engine_add_pod_v3: % of % lines carry no recognised sigma_source '
      '(run_id %). LAW 5 - a sized line must name its dispersion basis.',
      v_lines - (v_sig_meas + v_sig_nodisp + v_sig_nosplit), v_lines, v_run_id;
  END IF;$s$
  ];
  v_to := v_to || ARRAY[
$s$  IF (v_sig_meas + v_sig_nodisp + v_sig_nosplit) <> v_lines THEN
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
  END IF;$s$
  ];

  -- ============================================================================================
  -- 10. Version stamp + returned telemetry.
  -- ============================================================================================
  v_from := v_from || ARRAY[
$s$    'engine_version',           'v3_p22c_base_stock',$s$
  ];
  v_to := v_to || ARRAY[
$s$    'engine_version',           'v3_p23_expiry_ceiling',$s$
  ];

  v_from := v_from || ARRAY[
$s$    'fill_to_cap_lines',        v_fill_cap,
    'fill_to_cap_share',        CASE WHEN v_lines = 0 THEN 0
                                     ELSE round((v_fill_cap::numeric / v_lines), 4) END,$s$
  ];
  v_to := v_to || ARRAY[
$s$    'fill_to_cap_lines',        v_fill_cap,
    'fill_to_cap_share',        CASE WHEN v_lines = 0 THEN 0
                                     ELSE round((v_fill_cap::numeric / v_lines), 4) END,
    -- P2.3 expiry telemetry. The clamp class is visible in the run's own return value.
    'expiry_ceiling_lines',     v_exp_lines,
    'expiry_units_removed',     v_exp_removed,
    'expiry_fefo_lines',        v_xp_fefo,
    'expiry_no_batch_lines',    v_xp_nobatch,
    'expiry_not_wh_lines',      v_xp_notwh,
    'expiry_unknown_src_lines', v_xp_unknown,$s$
  ];

  -- ============================================================================================
  -- APPLY: every substitution must match EXACTLY ONCE.
  -- ============================================================================================
  v_new := v_def;
  FOR i IN 1 .. array_length(v_from, 1) LOOP
    v_n := (length(v_new) - length(replace(v_new, v_from[i], ''))) / length(v_from[i]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'P2.3 substitution % matched % time(s), expected exactly 1. Anchor drifted '
                      '- refusing to guess.', i, v_n;
    END IF;
    v_new := replace(v_new, v_from[i], v_to[i]);
  END LOOP;

  -- REVERSE PROOF, before any DDL: undo every substitution in reverse order and require the
  -- result to be byte-identical to the live definition. If this holds, the ONLY differences
  -- between v_def and v_new are the ones enumerated above.
  v_back := v_new;
  FOR i IN REVERSE array_length(v_from, 1) .. 1 LOOP
    v_back := replace(v_back, v_to[i], v_from[i]);
  END LOOP;
  IF v_back IS DISTINCT FROM v_def THEN
    RAISE EXCEPTION 'P2.3: reverse substitution did NOT reproduce the original (% vs % chars). '
                    'Refusing to ship an unbounded diff.', length(v_back), length(v_def);
  END IF;

  EXECUTE v_new;

  -- ============================================================================================
  -- POST-DDL GUARDS (Cody rev 3).
  -- ============================================================================================
  SELECT count(*) INTO v_n FROM pg_proc
   WHERE proname = 'engine_add_pod_v3' AND pronamespace = 'public'::regnamespace;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'P2.3 POST-GUARD: % overloads of engine_add_pod_v3 - the substitution '
                    'perturbed the signature and ADDED an overload instead of replacing.', v_n;
  END IF;

  SELECT p.oid INTO v_oid FROM pg_proc p
   WHERE p.proname = 'engine_add_pod_v3' AND p.pronamespace = 'public'::regnamespace;
  IF v_oid <> 235798::oid THEN
    RAISE EXCEPTION 'P2.3 POST-GUARD: oid is now % (expected 235798) - this is a NEW function, '
                    'not a replacement.', v_oid;
  END IF;

  IF (SELECT proacl::text FROM pg_proc WHERE oid = 235798)
     <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'P2.3 POST-GUARD: proacl drifted to %. anon must stay absent.',
      (SELECT proacl::text FROM pg_proc WHERE oid = 235798);
  END IF;

  IF (SELECT prosrc FROM pg_proc WHERE oid = 235798) NOT LIKE '%expiry_ceiling%' THEN
    RAISE EXCEPTION 'P2.3 POST-GUARD: the replaced body does not contain the ceiling.';
  END IF;

  RAISE NOTICE 'P2.3 applied: % substitutions, reverse-proof exact, oid 235798 preserved.',
    array_length(v_from, 1);
END
$mig$;

COMMENT ON FUNCTION public.engine_add_pod_v3(date, integer) IS
'PRD-110 v3 ADD engine (SHADOW: writes pod_refills_shadow only). P2.1 in-stock velocity, P2.2c base stock S = mu*H + z*sigma*sqrt(H), P2.3 expiry ceiling = floor(days_to_expiry * sell_rate * base_stock_expiry_safety_factor) applied to the COVER term only - the min-facing floor survives it. Expiry is pod-grain FEFO from v_product_shelf_life over the machine''s [primary, secondary] warehouses, re-anchored on p_plan_date. clamp_reason ''expiry_ceiling'' is emitted BEFORE ''skipped_full''.';
