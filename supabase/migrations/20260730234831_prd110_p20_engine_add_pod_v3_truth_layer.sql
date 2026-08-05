-- PRD-110 · P2 · relay leg 31 · public.engine_add_pod_v3
--
-- THE FIRST v3 ENGINE. Additive: v19 (public.engine_add_pod) is untouched and remains the
-- production engine. This one writes ONLY public.pod_refills_shadow (LAW 4 - shadow, don't
-- switch) and is invoked by nothing except the golden harness until a later leg wires it.
--
-- WHAT IT IS: the P2 SKELETON on the TRUTH LAYER. It owns candidate selection, coverage,
-- clamping, sourcing-aware availability and LAW-5 blocking. It deliberately does NOT own
-- P2.1-P2.4 sizing intelligence yet:
--   * P2.1 velocity_instock is NULL in v_shelf_state and D-10 has not been decided, so the
--     column is written through verbatim (NULL) and is NEVER used for sizing. Reading it as
--     canonical here would pre-empt D-10 (leg-30 pointer) and S-13's ppad/calendar-day trap.
--   * P2.2's S = mu(visit_interval+lead) + z*sigma, P2.3's expiry ceiling and P2.4's demand
--     multipliers are later legs. Sizing here is cover-days x daily velocity, clamped to
--     capacity, with P2.5's unconditional floor - enough to satisfy the eight gated
--     acceptance criteria and nothing more. NO SCOPE DRIFT (LAW 10).
--
-- WHY IT IS BUILT ON v_shelf_state / v_shelf_availability_v3 AND NOT ON slot_lifecycle:
--   v19's candidate set is `JOIN slot_lifecycle sl ... archived=false AND is_current=true`,
--   which is exactly why S-35's nightly rotation gap blinds it ~17h/day. Both truth-layer
--   views contain the S-35 victim shelf and carry the same 544 pod-bound rows, an exact 1:1
--   (R29-D1, measured leg 29 and re-measured leg 31). v3 inherits none of that blindness,
--   for free.
--
-- THE DEFECT IT EXISTS TO CLOSE (LAW 5, and it is one predicate):
--   v19's insert is `WHERE (NOT f.is_dead AND f.need_raw > 0)`. A shelf whose need rounds to
--   zero, an over-capacity shelf, and a dead-tagged shelf get NO ROW AT ALL - the plan simply
--   does not mention them. That single predicate is what fixtures 3:1, 14:30 and 14:33
--   detect. v3 emits a row for EVERY in-scope pod-bound shelf, always, and says WHY the qty
--   is what it is in clamp_reason. Silent qty-0 is a build failure.
--
-- CONTRACT (imposed by 20260730212000_..._reexpressed_on_shadow.sql, applied in the same unit):
--   * signature (p_plan_date date, p_days_cover integer) RETURNS jsonb
--   * the jsonb MUST carry 'run_id' - pod_refills_shadow is append-only, so run_id is the
--     only honest scope for an acceptance assertion
--   * reasoning->>'need_raw' MUST be present on every line or v_blocked_demand_shadow_v3
--     derives nothing and fixture 105 seq 10 can never go green
--   * it MUST NOT write public.pod_refills (fixture seq 87 is the tripwire)
--
-- ADR-shadow-plan-tables §7 Art 4 preamble, called exactly as v19 calls it:
--   _assert_refill_plan_writable(p_plan_date)  -- ONE arg. The function is two-arg with a
--                                                 default; passing p_machine_ids would change
--                                                 its behaviour (pronargdefaults trap).
--   _assert_gate_zero(p_plan_date)             -- LAW 11: manual Gate 0 is honoured by the
--                                                 shadow engine too, or a shadow run could
--                                                 plan machines CS never confirmed.
--   app.via_rpc / app.rpc_name                 -- Article 4 provenance.

BEGIN;

CREATE OR REPLACE FUNCTION public.engine_add_pod_v3(
  p_plan_date  date,
  p_days_cover integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
BEGIN
  -- Article 4 provenance.
  PERFORM set_config('app.via_rpc',  'true',               true);
  PERFORM set_config('app.rpc_name', 'engine_add_pod_v3',  true);

  -- Same role posture as v19: a logged-in caller must be operator_admin; a NULL auth.uid()
  -- (service role / SQL console / cron) is allowed through, exactly as the live engine is.
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

  PERFORM public._assert_refill_plan_writable(p_plan_date);

  IF NOT EXISTS (SELECT 1 FROM public.machines_to_visit
                  WHERE plan_date = p_plan_date AND status IN ('picked','cs_added')) THEN
    RAISE EXCEPTION 'engine_add_pod_v3: no picked/cs_added machines for %; run Stage 1 first',
      p_plan_date;
  END IF;

  PERFORM public._assert_gate_zero(p_plan_date);

  -- ---------------------------------------------------------------------------
  -- Scope, measured BEFORE the write so the coverage guard below is independent
  -- of the write's own row count (RISK 75: prove the mechanism, not the intent).
  -- ---------------------------------------------------------------------------
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

  -- ---------------------------------------------------------------------------
  -- The plan.
  -- ---------------------------------------------------------------------------
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
  -- Candidates come from the truth layer, NOT slot_lifecycle (R29-D1). Availability is
  -- LEFT JOINed on purpose: the two views are 1:1 today (544 / 544), and if that ever stops
  -- being true the shelf must still get a line - saying 'unknown' out loud beats vanishing.
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
      s.velocity_instock,                                        -- NULL until D-10; never used to size
      COALESCE(s.velocity_raw, 0)::numeric                    AS vel_day,
      COALESCE(s.current_stock, 0)                            AS raw_stock,
      GREATEST(COALESCE(s.max_stock, 0), 0)                   AS max_stock,
      LEAST(GREATEST(COALESCE(s.current_stock, 0), 0),
            GREATEST(COALESCE(s.max_stock, 0), 0))            AS stock_clamped,
      (COALESCE(s.current_stock, 0) > COALESCE(s.max_stock, 0)) AS over_capacity,
      (a.shelf_id IS NULL)                                    AS avail_missing,
      CASE WHEN a.shelf_id IS NULL                       THEN 'unknown'
           WHEN a.sourcing IN ('boonz_wh','venue','partner','mixed') THEN a.sourcing
           ELSE 'unknown' END                                 AS basis,
      -- NULL means "not constrained by Boonz WH" (venue / partner supply). 0 means
      -- "constrained and empty". The two are never conflated - that conflation is S-06.
      CASE WHEN a.shelf_id IS NULL      THEN 0
           WHEN a.is_constrained        THEN COALESCE(a.available_units, 0)
           ELSE NULL END                                      AS avail_units
    FROM picked p
    JOIN public.v_shelf_state s
      ON s.machine_id = p.machine_id AND s.pod_product_id IS NOT NULL
    LEFT JOIN public.v_shelf_availability_v3 a
      ON a.shelf_id = s.shelf_id
  ),
  sized AS (
    SELECT c.*,
      GREATEST(c.max_stock - c.stock_clamped, 0)              AS fill_to_cap,
      CEIL(c.vel_day * p_days_cover)::int                     AS cover_units,
      -- P2.5 UNCONDITIONAL FLOOR: an empty shelf that is not partner-supplied gets a line
      -- with qty > 0 whatever its velocity says. This is the rule v19's "need_raw > 0"
      -- predicate cannot express, because a zero-velocity empty shelf never reaches it.
      CASE WHEN c.stock_clamped = 0 AND c.basis <> 'partner' AND c.max_stock > 0
           THEN GREATEST(1, LEAST(v_min_facing, c.max_stock))
           ELSE 0 END                                         AS floor_units
    FROM cand c
  ),
  needed AS (
    SELECT z.*,
      LEAST(GREATEST(z.cover_units, z.floor_units), z.fill_to_cap) AS need_raw
    FROM sized z
  ),
  -- One WH pool per (machine, pod), shared by every shelf carrying that pod. Without this
  -- window two shelves of the same product each claim the whole pool and the plan promises
  -- stock twice. Priority: fastest mover first, shelf_id as the deterministic tiebreak.
  alloc AS (
    SELECT n.*,
      COALESCE(SUM(n.need_raw) OVER (
        PARTITION BY n.machine_id, n.pod_product_id
        ORDER BY n.vel_day DESC, n.shelf_id
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
  -- Every row gets a clamp_reason. There is no ELSE NULL branch anywhere below: that is
  -- LAW 5 expressed as code, and pod_refills_shadow_no_silent_zero enforces it at the table.
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
      r.stock_clamped,        -- THE CLAMPED VALUE, never the raw sensor lie (fixture 14 seq 31)
      r.max_stock,
      p_days_cover,
      r.signal,
      CASE WHEN r.basis = 'boonz_wh' THEN COALESCE(r.avail_units, 0) ELSE r.avail_units END,
      r.clamp_reason,
      r.velocity_instock,
      r.basis,
      jsonb_build_object(
        'shelf_code',          r.shelf_code,
        'official_name',       r.official_name,
        'pod_name',            r.pod_name,
        'operating_model',     r.operating_model,
        'need_raw',            r.need_raw,          -- CONTRACT: v_blocked_demand_shadow_v3 reads this
        'cover_units',         r.cover_units,
        'floor_units',         r.floor_units,
        'fill_to_cap',         r.fill_to_cap,
        'prior_need_pool',     r.prior_need,
        'avail_for_me',        r.avail_for_me,
        'available_units',     r.avail_units,
        'raw_current_stock',   r.raw_stock,
        'sensor_over_capacity',r.over_capacity,
        'sourcing',            r.basis,
        'velocity_raw_daily',  r.vel_day,
        'days_cover',          p_days_cover,
        'min_facing_floor',    v_min_facing,
        'candidate_source',    'v_shelf_state + v_shelf_availability_v3',
        'engine_calibration',  'v3_p2_skeleton_truth_layer',
        'sizing_mode',         'cover_days_x_velocity_raw_with_p25_floor',
        'run_id',              v_run_id)
    FROM reasoned r
    RETURNING qty, clamp_reason, availability_basis
  )
  SELECT count(*),
         count(*) FILTER (WHERE qty = 0),
         COALESCE(sum(qty), 0),
         count(*) FILTER (WHERE clamp_reason = 'blocked_no_wh'),
         count(*) FILTER (WHERE clamp_reason = 'partial_wh_limited'),
         count(*) FILTER (WHERE clamp_reason = 'sensor_over_capacity'),
         count(*) FILTER (WHERE availability_basis = 'unknown')
    INTO v_lines, v_qty0, v_units, v_blocked, v_partial, v_over_cap, v_unknown
  FROM ins;

  -- ---------------------------------------------------------------------------
  -- SELF-PROVING COVERAGE GUARD. The whole point of v3 is that nothing is dropped
  -- silently, so the engine proves it about its own output before returning. A run that
  -- covered less than its scope raises rather than reporting a cheerful number - the
  -- vacuous-success class RISK 75 exists to prevent.
  -- ---------------------------------------------------------------------------
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

  RETURN jsonb_build_object(
    'run_id',                  v_run_id,
    'engine_tag',              v_tag,
    'engine_version',          'v3_p2_skeleton_truth_layer',
    'plan_date',               p_plan_date,
    'days_cover',              p_days_cover,
    'machines_in_scope',       v_machines,
    'machines_without_shelves',v_empty_mach,
    'shelves_in_scope',        v_scope,
    'lines_written',           v_lines,
    'units_planned',           v_units,
    'qty0_lines',              v_qty0,
    'blocked_no_wh',           v_blocked,
    'partial_wh_limited',      v_partial,
    'sensor_over_capacity',    v_over_cap,
    'availability_unknown',    v_unknown,
    'target_table',            'public.pod_refills_shadow',
    'wrote_live_pod_refills',  false,
    'duration_ms',             (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END
$fn$;

COMMENT ON FUNCTION public.engine_add_pod_v3(date, integer) IS
  'PRD-110 P2 (relay leg 31): the first v3 ADD engine. Reads the truth layer '
  '(v_shelf_state + v_shelf_availability_v3), writes ONLY public.pod_refills_shadow under a '
  'fresh run_id, and NEVER writes public.pod_refills (LAW 4 - shadow, don''t switch). Emits a '
  'line for EVERY in-scope pod-bound shelf with a non-null clamp_reason - v19''s '
  '"WHERE need_raw > 0" silent drop is the defect it exists to close (LAW 5). Sizing is the '
  'P2 skeleton: cover-days x velocity_raw, capacity-clamped, with P2.5''s unconditional floor. '
  'P2.1-P2.4 sizing intelligence and velocity_instock are NOT wired - D-10 gates them.';

-- RISK 77: a fresh function inherits EXECUTE from PUBLIC via default privileges. This one is
-- SECURITY DEFINER over a protected write path, so the grant is stated explicitly, never left
-- to the default.
REVOKE ALL ON FUNCTION public.engine_add_pod_v3(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.engine_add_pod_v3(date, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.engine_add_pod_v3(date, integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- END-STATE GUARD. Assert what the migration MEANT, not that a statement fired.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'engine_add_pod_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'END-STATE: expected exactly 1 public.engine_add_pod_v3, found % '
      '(an overload of a planning engine is a foot-gun - see repurpose_machine)', v_n;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'engine_add_pod_v3'
       AND pg_get_function_identity_arguments(p.oid) = 'p_plan_date date, p_days_cover integer'
       AND p.prosecdef
       AND p.pronargdefaults = 0)
  THEN
    RAISE EXCEPTION 'END-STATE: engine_add_pod_v3 signature/secdef/defaults are not as contracted';
  END IF;

  -- anon must not reach a SECURITY DEFINER writer.
  IF has_function_privilege('anon', 'public.engine_add_pod_v3(date, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'END-STATE: anon holds EXECUTE on engine_add_pod_v3';
  END IF;

  -- The live engine must be untouched and still be the only writer of public.pod_refills.
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'engine_add_pod') THEN
    RAISE EXCEPTION 'END-STATE: public.engine_add_pod (v19) is missing - this migration is additive only';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.proname = 'engine_add_pod_v3'
                AND p.prosrc LIKE '%INTO public.pod_refills %')
  THEN
    RAISE EXCEPTION 'END-STATE: engine_add_pod_v3 body references an INSERT INTO public.pod_refills';
  END IF;
END
$guard$;

COMMIT;
