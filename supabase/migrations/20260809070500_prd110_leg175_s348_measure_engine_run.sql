-- PRD-110 leg 175 · S-348 FIX · the measurement subject is NAMED, not inferred from a UUID
--
-- ONE PREDICATE ADDED: AND sh.engine_tag = 'engine_add_pod_v3'. Nothing else in this
-- function moves. Full body re-stated because CREATE OR REPLACE takes no patch.
--
-- WHY (see 20260809070000_prd110_leg175_s348_fixture37_pins.sql for the fixture side):
--   • produced_at is the TRANSACTION clock. D-34 pointed run_nightly_shadow_v3 at
--     run_pipeline_v3, which banks an engine run AND a composed run per call, tied to
--     the microsecond. "the most recent run" stopped identifying one run that night.
--   • The old tail tie-break, ORDER BY ... , sh.run_id, then handed the choice to an
--     arbitrary uuid. Leg 174 caught it as a coin flip: fixture 37 seq 20 went
--     43/0 · 43/0 · 42/1 across one triple, then 42/1 · 43/0 · 43/0 on re-fire.
--   • It is worse than a tie: a composed run banked AFTER the engine run wins outright.
--     Proven by forced-rollback probe -- 2030-02-07 re-measured at 4 series instead of 8.
--     2030-02-11 is already measured on a compose_v3 run today.
--
-- BLAST RADIUS, PROBED (S-336) — callers: run_nightly_shadow_v3 (steps 2 and 3).
-- Readers of engine_forecast_error_v3: _build_draft_core_v3, v_engine_wmape_v3,
-- v_shadow_runner_health_v3, v_cutover_readiness_v3. Golden: fixture 36 (seq 13..30) and
-- fixture 37 (seq 9, 10, 16, 20, 21, 24, 29, 30, and the new 44..47).
--
-- ⭐ NO CS-FACING NUMBER MOVES, verified row by row before applying:
--     2026-08-04  measured run 8e3fe430  engine_add_pod_v3  -> same run selected
--     2026-08-09  measured run 58d6ab1c  engine_add_pod_v3  -> same run selected
--     2030-02-06 / 2030-02-07 / 2030-11-01 (synthetic)      -> same run selected
--     2030-02-11 (synthetic) 4 series on a compose run      -> 8, the engine run.
--                No assertion reads that date's measurement; the 4 was the bug.
--   All ten clusters remain authoritative_engine='v19' and DR-1 still refuses every one
--   as horizon_not_elapsed. LAW 4 untouched: this flips nothing.
--
-- ⛔ NOT A CS RULING, and the reason is specific: pinning the engine tag REPRODUCES the
--    subject every historical date was already measured on. Changing the subject to the
--    composed plan would re-base WMAPE, and that question is parked as S-349.

CREATE OR REPLACE FUNCTION public.refresh_engine_forecast_error_v3(p_plan_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid      uuid := (SELECT auth.uid());
  v_role     text;
  v_today    date := (now() AT TIME ZONE 'Asia/Dubai')::date;
  v_max_dc   integer;
  v_run      uuid;
  v_v19      integer := 0;
  v_v3       integer := 0;
  v_skip_v19 integer := 0;
  v_skip_v3  integer := 0;
BEGIN
  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'refresh_engine_forecast_error_v3: p_plan_date is required';
  END IF;

  -- Article 4 role gate. NULL uid = trusted server-side caller (cron), per the
  -- reweight_pod_splits precedent.
  IF v_uid IS NOT NULL THEN
    SELECT up.role INTO v_role FROM public.user_profiles up WHERE up.id = v_uid;
    IF v_role IS NULL OR v_role NOT IN ('operator_admin','superadmin','manager','warehouse') THEN
      RAISE EXCEPTION 'refresh_engine_forecast_error_v3: role % may not refresh telemetry',
                      COALESCE(v_role,'<none>');
    END IF;
  END IF;

  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','refresh_engine_forecast_error_v3',true);

  SELECT max(dc) INTO v_max_dc FROM (
    SELECT days_cover AS dc FROM public.pod_refills        WHERE plan_date = p_plan_date
    UNION ALL
    SELECT days_cover      FROM public.pod_refills_shadow  WHERE plan_date = p_plan_date
  ) d;

  -- Re-measurement is idempotent: this date's rows are rebuilt wholesale. Scoped to one
  -- plan_date on a non-protected measurement table (Cody, leg 52).
  DELETE FROM public.engine_forecast_error_v3 WHERE plan_date = p_plan_date;

  IF v_max_dc IS NULL THEN
    RETURN jsonb_build_object(
      'plan_date', p_plan_date, 'v19_series', 0, 'v3_series', 0,
      'measured_at', now(), 'note', 'no plan rows on either engine for this date');
  END IF;

  -- ⛔ S-348. The measurement subject is the ENGINE run, named rather than inferred.
  --    produced_at is the TRANSACTION clock, and since D-34 the nightly runner calls
  --    run_pipeline_v3, which banks TWO runs per night into this table -- the engine
  --    run and the composed run -- tied to the microsecond. "ORDER BY produced_at DESC"
  --    therefore no longer identifies ONE run, and the old tail tie-break on run_id
  --    handed the choice to an arbitrary UUID: the same date scored 8 series or 4
  --    depending on which uuid happened to sort first. A composed run landing after the
  --    engine run took the subject outright, with no tie at all (2030-02-11 today).
  --    ⭐ Every historical date was measured on the engine run, and v19's side of this
  --      table reads pod_refills. Pinning the engine tag REPRODUCES that subject exactly
  --      -- it changes no live measurement (2026-08-04 and 2026-08-09 select the same
  --      run_id before and after) -- so it re-bases nothing CS reads at cutover.
  --    ⭐ Whether the v3 subject SHOULD become the composed plan now that D-34 made one
  --      is a real question about what WMAPE compares. It re-bases the cutover
  --      instrument, so it is CS's (S-349, parked), not this function's to decide.
  SELECT sh.run_id INTO v_run
    FROM public.pod_refills_shadow sh
   WHERE sh.plan_date = p_plan_date
     AND sh.engine_tag = 'engine_add_pod_v3'
   ORDER BY sh.produced_at DESC, sh.run_id
   LIMIT 1;

  SELECT count(*) INTO v_skip_v19 FROM public.pod_refills
   WHERE plan_date = p_plan_date AND pod_product_id IS NOT NULL AND velocity_30d IS NULL;
  SELECT count(*) INTO v_skip_v3 FROM public.pod_refills_shadow
   WHERE plan_date = p_plan_date AND run_id = v_run
     AND pod_product_id IS NOT NULL AND velocity_instock IS NULL;

  WITH sd AS (
    -- Actuals, bounded to this plan_date's own horizon window (ADR §10.1: the unbounded
    -- scan of this source costs ~13.5s because pod_product_id resolves by NAME).
    SELECT t.machine_id, t.pod_product_id, t.d, sum(t.qty)::numeric AS qty
      FROM (SELECT s.machine_id, s.pod_product_id, s.qty,
                   (s.transaction_date AT TIME ZONE 'Asia/Dubai')::date AS d
              FROM public.v_sales_history_resolved s
             WHERE s.delivery_status = 'Successful'
               AND s.transaction_date >= (p_plan_date::timestamp AT TIME ZONE 'Asia/Dubai')
               AND s.transaction_date <  ((p_plan_date + v_max_dc)::timestamp AT TIME ZONE 'Asia/Dubai')
           ) t
     WHERE t.pod_product_id IS NOT NULL
     GROUP BY 1,2,3
  ), pl AS (
    SELECT 'v19'::text AS engine_tag, p.machine_id, p.pod_product_id,
           count(DISTINCT p.shelf_id)::int          AS ns,
           count(DISTINCT p.days_cover)::int        AS dcv,
           max(p.days_cover)::int                   AS dc,
           sum(p.velocity_30d * p.days_cover)::numeric AS fc,
           NULL::uuid AS run_id, 'velocity_30d'::text AS basis
      FROM public.pod_refills p
     WHERE p.plan_date = p_plan_date AND p.pod_product_id IS NOT NULL
       AND p.velocity_30d IS NOT NULL AND p.days_cover IS NOT NULL
     GROUP BY 1,2,3
    UNION ALL
    SELECT 'v3', sh.machine_id, sh.pod_product_id,
           count(DISTINCT sh.shelf_id)::int,
           count(DISTINCT sh.days_cover)::int,
           max(sh.days_cover)::int,
           sum(sh.velocity_instock * sh.days_cover)::numeric,
           v_run, 'velocity_instock'
      FROM public.pod_refills_shadow sh
     WHERE sh.plan_date = p_plan_date AND sh.run_id = v_run AND sh.pod_product_id IS NOT NULL
       AND sh.velocity_instock IS NOT NULL AND sh.days_cover IS NOT NULL
     GROUP BY 1,2,3
  )
  INSERT INTO public.engine_forecast_error_v3
    (plan_date, engine_tag, machine_id, pod_product_id, horizon_days, horizon_end,
     n_shelves, dc_variants, forecast_units, actual_units, actuals_settled, velocity_basis, run_id)
  SELECT p_plan_date, pl.engine_tag, pl.machine_id, pl.pod_product_id,
         pl.dc, p_plan_date + pl.dc, pl.ns, pl.dcv,
         round(COALESCE(pl.fc,0), 4),
         COALESCE((SELECT sum(sd.qty) FROM sd
                    WHERE sd.machine_id     = pl.machine_id
                      AND sd.pod_product_id = pl.pod_product_id
                      AND sd.d >= p_plan_date
                      AND sd.d <  p_plan_date + pl.dc), 0),
         (p_plan_date + pl.dc) <= v_today,
         pl.basis, pl.run_id
    FROM pl;

  SELECT count(*) FILTER (WHERE engine_tag='v19'), count(*) FILTER (WHERE engine_tag='v3')
    INTO v_v19, v_v3
    FROM public.engine_forecast_error_v3 WHERE plan_date = p_plan_date;

  RETURN jsonb_build_object(
    'plan_date',   p_plan_date,
    'v19_series',  v_v19,
    'v3_series',   v_v3,
    'v3_run_id',   v_run,
    'horizon_max', v_max_dc,
    'settled',     (p_plan_date + v_max_dc) <= v_today,
    'skipped_no_velocity', jsonb_build_object('v19', v_skip_v19, 'v3', v_skip_v3),
    'measured_at', now());
END
$function$
