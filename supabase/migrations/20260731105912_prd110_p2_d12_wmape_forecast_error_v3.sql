-- PRD-110 · P2 · D-12 remainder (WMAPE half). Authorised by ADR-shadow-plan-tables §10.
-- Cody: Article 14 blocked the snapshot until the ADR was amended (§2 assigned WMAPE to a view
-- by name); §10 records the measured 13.5s floor on the actuals source and the measurement-
-- provenance argument. Article 4 revisions (role gate + app.via_rpc/app.rpc_name) applied below.
-- Proven RED first by golden fixture 36 (11 pass / 20 fail, 0 errors).

BEGIN;

CREATE TABLE public.engine_forecast_error_v3 (
  plan_date       date        NOT NULL,
  engine_tag      text        NOT NULL,
  machine_id      uuid        NOT NULL,
  pod_product_id  uuid        NOT NULL,
  horizon_days    integer     NOT NULL,
  horizon_end     date        NOT NULL,
  n_shelves       integer     NOT NULL,
  dc_variants     integer     NOT NULL,
  forecast_units  numeric     NOT NULL,
  actual_units    numeric     NOT NULL,
  abs_error       numeric GENERATED ALWAYS AS (abs(forecast_units - actual_units)) STORED,
  signed_error    numeric GENERATED ALWAYS AS (forecast_units - actual_units) STORED,
  actuals_settled boolean     NOT NULL,
  velocity_basis  text        NOT NULL,
  run_id          uuid,
  measured_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT engine_forecast_error_v3_pkey PRIMARY KEY (plan_date, engine_tag, machine_id, pod_product_id),
  CONSTRAINT engine_forecast_error_v3_engine_chk  CHECK (engine_tag IN ('v19','v3')),
  CONSTRAINT engine_forecast_error_v3_basis_chk   CHECK (velocity_basis IN ('velocity_30d','velocity_instock')),
  CONSTRAINT engine_forecast_error_v3_horizon_chk CHECK (horizon_days > 0),
  CONSTRAINT engine_forecast_error_v3_nonneg_chk  CHECK (forecast_units >= 0 AND actual_units >= 0),
  CONSTRAINT engine_forecast_error_v3_shelves_chk CHECK (n_shelves >= 1)
);

COMMENT ON TABLE public.engine_forecast_error_v3 IS
'PRD-110 D-12. Per-(plan_date, engine, machine, pod) forecast-vs-actual MEASUREMENT SNAPSHOT. '
'Authorised by ADR-shadow-plan-tables §10 (Article 14 needs ADR signoff for a performance '
'materialization). GRAIN IS machine x pod, NOT shelf: actuals only resolve at machine x pod and 139 '
'real (plan_date,machine,pod) groups span >1 shelf, so a shelf grain double-counts their sales — the '
'PK makes that impossible. actuals_settled=false means the horizon had not elapsed when measured; '
'such rows are PROVISIONAL and are excluded from WMAPE by v_engine_wmape_v3. Refresh is per plan_date '
'and idempotent via refresh_engine_forecast_error_v3(date).';

COMMENT ON COLUMN public.engine_forecast_error_v3.forecast_units IS
'velocity x horizon, summed across the shelves carrying this pod on this machine. v19 uses '
'velocity_30d, v3 uses velocity_instock (both are units per CALENDAR day — S-13). Lines whose engine '
'produced no velocity are EXCLUDED from the snapshot entirely rather than scored as a zero forecast; '
'the excluded count is returned by the refresh writer so the omission is never invisible.';

COMMENT ON COLUMN public.engine_forecast_error_v3.actuals_settled IS
'TRUE iff horizon_end <= the Dubai date at measurement time. FALSE = nothing to score yet.';

ALTER TABLE public.engine_forecast_error_v3 ENABLE ROW LEVEL SECURITY;

CREATE POLICY engine_forecast_error_v3_select ON public.engine_forecast_error_v3
  FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.engine_forecast_error_v3 FROM anon;
GRANT SELECT ON public.engine_forecast_error_v3 TO authenticated;

-- ---------------------------------------------------------------------------
-- The refresh writer. Reads only (outside its own snapshot table).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_engine_forecast_error_v3(p_plan_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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

  SELECT sh.run_id INTO v_run
    FROM public.pod_refills_shadow sh
   WHERE sh.plan_date = p_plan_date
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
$fn$;

COMMENT ON FUNCTION public.refresh_engine_forecast_error_v3(date) IS
'PRD-110 D-12. Re-measures forecast-vs-actual for one plan_date across BOTH engines (v19 from '
'pod_refills, v3 from the LATEST pod_refills_shadow run). Idempotent: DELETE+INSERT scoped to the '
'date. Returns skipped_no_velocity so lines the engine never forecast are visibly omitted rather '
'than scored as a zero forecast.';

REVOKE ALL ON FUNCTION public.refresh_engine_forecast_error_v3(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_engine_forecast_error_v3(date) TO authenticated, service_role;

COMMIT;
