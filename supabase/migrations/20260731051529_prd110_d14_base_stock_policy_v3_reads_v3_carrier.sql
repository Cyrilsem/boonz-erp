-- PRD-110 leg 42 · L42-U1 migration B of D
-- The canonical base-stock resolver (METRICS_REGISTRY line 369) now honours the D-14 v3 carrier.
--   z                       = COALESCE(z_v3, z_default, z_mid)
--   policy tier interval    = COALESCE(trip_interval_days_v3, trip_interval_days)
-- policy_trip_interval_days keeps its ORIGINAL meaning - a faithful passthrough of the RAW v19
-- seed - so fixture 28 seq 11 remains exactly true; the override is exposed separately in the
-- three appended columns. Article 12: CREATE OR REPLACE, existing columns unchanged in name,
-- type and order, new columns appended at the end only.
BEGIN;

-- PRE-GUARD: migration A must have landed.
DO $g$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='machine_service_policy'
     AND column_name IN ('trip_interval_days_v3','z_v3','v3_source');
  IF n <> 3 THEN RAISE EXCEPTION 'B: migration A has not landed (carrier columns = %)', n; END IF;
END
$g$;

CREATE OR REPLACE VIEW public.v_machine_base_stock_policy_v3 AS
 WITH p AS (
         SELECT refill_policy_params.base_stock_lead_days AS lead_d,
            refill_policy_params.base_stock_default_interval_days AS def_iv,
            refill_policy_params.base_stock_min_gaps AS min_g,
            refill_policy_params.base_stock_cadence_lookback_days AS look,
            refill_policy_params.base_stock_max_horizon_days AS max_h,
            refill_policy_params.base_stock_interval_precedence AS prec,
            refill_policy_params.z_mid
           FROM refill_policy_params
         LIMIT 1
        ), scope AS (
         SELECT DISTINCT ss.machine_id,
            ss.machine_name
           FROM v_shelf_state ss
          WHERE ss.pod_product_id IS NOT NULL
        ), dispatch_visits AS (
         SELECT DISTINCT rd.machine_id,
            rd.dispatch_date AS visit_date
           FROM refill_dispatching rd
             JOIN scope s ON s.machine_id = rd.machine_id
             CROSS JOIN p
          WHERE rd.cancelled = false AND rd.skipped = false AND (rd.picked_up = true OR rd.returned = true OR rd.dispatched = true OR rd.packed = true) AND rd.dispatch_date >= (CURRENT_DATE - p.look) AND rd.dispatch_date <= CURRENT_DATE
        ), manual_visits AS (
         SELECT DISTINCT pal.machine_id,
            pal.created_at::date AS visit_date
           FROM pod_inventory_audit_log pal
             JOIN scope s ON s.machine_id = pal.machine_id
             CROSS JOIN p
          WHERE (pal.reference_id ~~ 'manual-refill-%'::text OR pal.reference_id ~~ 'adjust-%'::text) AND pal.created_at::date >= (CURRENT_DATE - p.look)
        ), all_visits AS (
         SELECT dispatch_visits.machine_id,
            dispatch_visits.visit_date
           FROM dispatch_visits
        UNION
         SELECT manual_visits.machine_id,
            manual_visits.visit_date
           FROM manual_visits
        ), gaps AS (
         SELECT all_visits.machine_id,
            (all_visits.visit_date - lag(all_visits.visit_date) OVER (PARTITION BY all_visits.machine_id ORDER BY all_visits.visit_date))::numeric AS gap_days
           FROM all_visits
        ), observed AS (
         SELECT gaps.machine_id,
            count(gaps.gap_days)::integer AS n_gaps,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (gaps.gap_days::double precision))::numeric AS median_gap
           FROM gaps
          WHERE gaps.gap_days IS NOT NULL
          GROUP BY gaps.machine_id
        ), resolved AS (
         SELECT s.machine_id,
            s.machine_name,
            msp.machine_class,
            o.median_gap AS observed_median_gap_days,
            COALESCE(o.n_gaps, 0) AS observed_n_gaps,
            msp.trip_interval_days::numeric AS policy_trip_interval_days,
            msp.trip_interval_days_v3::numeric AS policy_trip_interval_days_v3,
            -- D-14 carrier: the v3 resolver sizes on the override when present, the raw seed otherwise.
            COALESCE(msp.trip_interval_days_v3, msp.trip_interval_days)::numeric AS eff_policy_iv,
            msp.z_v3,
            msp.v3_source,
            p.lead_d AS lead_days,
            COALESCE(msp.z_v3, msp.z_default, p.z_mid) AS z,
                CASE
                    WHEN msp.z_v3 IS NOT NULL THEN 'machine_service_policy_v3'::text
                    WHEN msp.z_default IS NOT NULL THEN 'machine_service_policy'::text
                    ELSE 'param_z_mid'::text
                END AS z_source,
            p.def_iv,
            p.max_h,
                CASE
                    WHEN p.prec = 'policy_first'::text THEN
                    CASE
                        WHEN COALESCE(msp.trip_interval_days_v3, msp.trip_interval_days) IS NOT NULL THEN 'policy_seed'::text
                        WHEN COALESCE(o.n_gaps, 0) >= p.min_g THEN 'observed'::text
                        ELSE 'param_default'::text
                    END
                    ELSE
                    CASE
                        WHEN COALESCE(o.n_gaps, 0) >= p.min_g THEN 'observed'::text
                        WHEN COALESCE(msp.trip_interval_days_v3, msp.trip_interval_days) IS NOT NULL THEN 'policy_seed'::text
                        ELSE 'param_default'::text
                    END
                END AS interval_source
           FROM scope s
             CROSS JOIN p
             LEFT JOIN machine_service_policy msp ON msp.machine_id = s.machine_id
             LEFT JOIN observed o ON o.machine_id = s.machine_id
        ), sized AS (
         SELECT r.machine_id,
            r.machine_name,
            r.machine_class,
            r.observed_median_gap_days,
            r.observed_n_gaps,
            r.policy_trip_interval_days,
            r.policy_trip_interval_days_v3,
            r.z_v3,
            r.v3_source,
            r.lead_days,
            r.z,
            r.z_source,
            r.def_iv,
            r.max_h,
            r.interval_source,
                CASE r.interval_source
                    WHEN 'observed'::text THEN r.observed_median_gap_days
                    WHEN 'policy_seed'::text THEN r.eff_policy_iv
                    ELSE r.def_iv
                END AS visit_interval_days
           FROM resolved r
        )
 SELECT machine_id,
    machine_name,
    machine_class,
    visit_interval_days,
    interval_source,
    observed_median_gap_days,
    observed_n_gaps,
    policy_trip_interval_days,
    lead_days,
    z,
    z_source,
    LEAST(GREATEST(visit_interval_days + lead_days, 1::numeric), max_h) AS horizon_days,
    policy_trip_interval_days_v3,
    z_v3,
    v3_source
   FROM sized;

-- POST-GUARD: shape preserved, nothing moved, nothing lost, behaviour identical while the
-- carrier is still empty (migration D has not run yet).
DO $g$
DECLARE n int; v_txt text;
BEGIN
  SELECT count(*) INTO n FROM public.v_machine_base_stock_policy_v3;
  IF n <> 31 THEN RAISE EXCEPTION 'B: expected 31 resolver rows, got %', n; END IF;

  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_machine_base_stock_policy_v3'
     AND column_name IN ('policy_trip_interval_days_v3','z_v3','v3_source');
  IF n <> 3 THEN RAISE EXCEPTION 'B: expected 3 appended columns, got %', n; END IF;

  -- the 12 original columns must still be at ordinal positions 1..12
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO v_txt
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_machine_base_stock_policy_v3' AND ordinal_position <= 12;
  IF v_txt <> 'machine_id,machine_name,machine_class,visit_interval_days,interval_source,observed_median_gap_days,observed_n_gaps,policy_trip_interval_days,lead_days,z,z_source,horizon_days'
    THEN RAISE EXCEPTION 'B: original column order changed: %', v_txt; END IF;

  -- carrier empty => byte-identical resolution to the pre-B view
  SELECT count(*) INTO n FROM public.v_machine_base_stock_policy_v3
   WHERE z_source <> 'machine_service_policy' AND machine_name <> 'AMZ-1046-2406-O1';
  IF n <> 0 THEN RAISE EXCEPTION 'B: z_source drifted on % machines while carrier is empty', n; END IF;

  SELECT count(*) INTO n FROM public.v_machine_base_stock_policy_v3
   WHERE interval_source NOT IN ('observed','policy_seed','param_default');
  IF n <> 0 THEN RAISE EXCEPTION 'B: unnamed interval_source on % rows', n; END IF;

  SELECT count(*) INTO n FROM public.v_machine_base_stock_policy_v3
   WHERE policy_trip_interval_days_v3 IS NOT NULL OR z_v3 IS NOT NULL OR v3_source IS NOT NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'B: carrier must still be empty here, % rows populated', n; END IF;
END
$g$;

COMMIT;
