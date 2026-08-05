-- PRD-110 · P2.1 · leg 34 · engine_add_pod_v3 sizes on the shelf-grain IN-STOCK velocity
--
-- Proven red first by 20260731013500 (fixture 14 seq 40-48). Captured baseline, pre-change:
--   seq 40 = 32 · 41 = 32 · 42 = 32 · 43 = 32 · 46 = 32 · 47 = 32 · 48 = false   (7 expected-red)
--   seq 44 = 0 · 45 = 0  -- VACUOUSLY green (empty populations); seq 48 is what catches that.
--
-- WHAT CHANGES. The skeleton sized on `ceil(v_shelf_state.velocity_raw x days_cover)`.
-- It now sizes on `velocity_instock_shelf` from `v_shelf_instock_velocity_split_v3` — the
-- canonical, censoring-corrected, shelf-grain daily rate — and records WHERE the number came from.
--
-- THE RESIDUAL BRANCH IS D-10'S ANSWER, NOT A NEW DECISION (LAW 5 + LAW 6):
--   1. `instock_split`      velocity_instock_shelf IS NOT NULL  -> use it verbatim
--   2. `weimi_raw_fallback` else v_shelf_state.velocity_raw IS NOT NULL -> use it verbatim
--   3. `none_no_signal`     else 0.0, EXPLICITLY LABELLED
--   Never a silent 0, never an invented number, never an archetype guess at this phase.
--   Today branch 2 is exactly the AMZ-1046 cohort (D-13) plus any below-floor cold-start shelf;
--   branch 3 has no population but exists so that "no signal" can never masquerade as "zero demand".
--
-- ⚠️ S-13 DIES HERE. `velocity_instock` is a DAILY rate BY CONSTRUCTION. There is no /30 and no
--    *30 anywhere in this function. v19 reads `velocity_30d` three mutually incompatible ways;
--    fixture 14 seq 46 is the assertion that stops v3 ever acquiring the same defect.
--
-- ⚠️ S-26 / RISK 88 — THE PERFORMANCE CONTRACT, and it is load-bearing:
--    `v_shelf_instock_velocity_split_v3` costs ~20 s per evaluation and machine-scoping does NOT
--    reduce it (measured leg 34: one machine 19.77 s, fleet-wide 19.8 s — its inner `vel` CTE is
--    MATERIALIZED so no predicate pushes down). It is therefore read EXACTLY ONCE per run, as an
--    explicitly MATERIALIZED CTE joined by shelf_id. Anything that turns this into a per-machine
--    read makes STEP 7's S1 (full fleet < 10 min) unreachable from this object alone.
--
-- ⚠️ WHY `v_shelf_state.velocity_instock` IS STILL NULL, DELIBERATELY. BUILD SPEC P1.2 designs that
--    column to carry this metric. It is NOT populated here, and fixture 3 seq 15 (which asserts it
--    IS NULL) is therefore left untouched and still valid. Reason, measured this leg: v_shelf_state
--    costs 113 ms and is read FOUR times by this engine and on every FE machine-page load; folding
--    a ~20 s object into it would multiply that cost across every consumer. Populating it needs the
--    S-26(b) materialised-history escalation first. Parked as S-39 with this measurement attached.
--
-- ⚠️ RISK 77: this is CREATE OR REPLACE, never DROP+CREATE, so the ACL is preserved. The REVOKE is
--    re-asserted at the tail anyway and verified after apply — anon must stay absent.
--
-- Art 12 forward-only: same signature, same target table, additive reasoning keys only. No
-- protected entity, no RLS, no live plan table. LAW 4: still writes ONLY pod_refills_shadow.

BEGIN;

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
           v.velocity_raw_shelf,
           v.velocity_status,
           v.split_method,
           v.pod_shelf_count
      FROM public.v_shelf_instock_velocity_split_v3 v
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
      vv.velocity_raw_shelf,
      vv.velocity_status,
      vv.split_method,
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
  ),
  sized AS (
    SELECT c.*,
      GREATEST(c.max_stock - c.stock_clamped, 0)  AS fill_to_cap,
      -- S-13: vel_eff is units per CALENDAR DAY. No /30. No *30. Ever.
      CEIL(c.vel_eff * p_days_cover)::int         AS cover_units,
      CASE WHEN c.stock_clamped = 0 AND c.basis <> 'partner' AND c.max_stock > 0
           THEN GREATEST(1, LEAST(v_min_facing, c.max_stock))
           ELSE 0 END                             AS floor_units
    FROM cand c
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
        'velocity_raw_shelf',        r.velocity_raw_shelf,
        'velocity_split_status',     r.velocity_status,
        'velocity_split_method',     r.split_method,
        'velocity_raw_daily',        r.vel_raw_state,
        'days_cover',           p_days_cover,
        'min_facing_floor',     v_min_facing,
        'candidate_source',     'v_shelf_state + v_shelf_availability_v3 + v_shelf_instock_velocity_split_v3',
        'engine_calibration',   'v3_p21_velocity_instock',
        'sizing_mode',          'cover_days_x_velocity_effective_daily_with_min_facing_floor',
        'run_id',               v_run_id)
    FROM reasoned r
    RETURNING qty, clamp_reason, availability_basis, (reasoning->>'velocity_source') AS vsrc
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
         count(*) FILTER (WHERE vsrc = 'none_no_signal')
    INTO v_lines, v_qty0, v_units, v_blocked, v_partial, v_over_cap, v_unknown,
         v_v_instock, v_v_fallback, v_v_none
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

  RETURN jsonb_build_object(
    'run_id',                   v_run_id,
    'engine_tag',               v_tag,
    'engine_version',           'v3_p21_velocity_instock',
    'plan_date',                p_plan_date,
    'days_cover',               p_days_cover,
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
    'target_table',             'public.pod_refills_shadow',
    'wrote_live_pod_refills',   false,
    'duration_ms',              (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END
$function$;

-- RISK 77 belt-and-braces. CREATE OR REPLACE preserves the ACL, but assert it anyway.
REVOKE ALL ON FUNCTION public.engine_add_pod_v3(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.engine_add_pod_v3(date, integer) FROM anon;

COMMIT;
