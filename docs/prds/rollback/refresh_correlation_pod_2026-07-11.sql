-- Rollback for PRD-CLEAN-02: original refresh_correlation_pod as of 2026-07-11
-- (UTC day-bucketing version, tables last computed 2026-05-11).
CREATE OR REPLACE FUNCTION public.refresh_correlation_pod(p_window_days integer DEFAULT 60, p_min_n_days integer DEFAULT 14, p_min_sales_per_side integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id      uuid;
  v_t0           timestamptz := clock_timestamp();
  v_per_machine  integer;
  v_per_loc_type integer;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'refresh_correlation_pod', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = 'operator_admin'
  ) THEN
    RAISE EXCEPTION 'refresh_correlation_pod: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_window_days <= 0 OR p_min_n_days <= 0 OR p_min_sales_per_side <= 0 THEN
    RAISE EXCEPTION 'invalid params';
  END IF;

  TRUNCATE TABLE public.correlation_pod_per_machine;
  TRUNCATE TABLE public.correlation_pod_per_loc_type;

  -- ── PER-MACHINE ──
  WITH daily_sales AS (
    SELECT machine_id, pod_product_id,
           transaction_date::date AS day,
           SUM(qty)::integer AS qty
      FROM public.v_sales_history_resolved
     WHERE delivery_status = 'Successful'
       AND pod_product_id IS NOT NULL
       AND transaction_date >= now() - (p_window_days || ' days')::interval
     GROUP BY machine_id, pod_product_id, day
  ),
  days AS (
    SELECT (now()::date - g)::date AS day
      FROM generate_series(0, p_window_days - 1) AS g
  ),
  machine_pods AS (
    -- Pods that EVER sold on this machine in the window
    SELECT DISTINCT machine_id, pod_product_id FROM daily_sales
  ),
  pivot AS (
    SELECT mp.machine_id, mp.pod_product_id, d.day,
           COALESCE(ds.qty, 0) AS qty
      FROM machine_pods mp
      CROSS JOIN days d
      LEFT JOIN daily_sales ds
        ON ds.machine_id = mp.machine_id
       AND ds.pod_product_id = mp.pod_product_id
       AND ds.day = d.day
  ),
  pairs AS (
    SELECT a.machine_id,
           LEAST(a.pod_product_id, b.pod_product_id) AS pod_a,
           GREATEST(a.pod_product_id, b.pod_product_id) AS pod_b,
           a.qty AS qty_a, b.qty AS qty_b
      FROM pivot a
      JOIN pivot b
        ON a.machine_id = b.machine_id
       AND a.day = b.day
       AND a.pod_product_id < b.pod_product_id
  ),
  agg AS (
    SELECT machine_id, pod_a, pod_b,
           corr(qty_a::double precision, qty_b::double precision) AS pearson_raw,
           COUNT(*)::int AS n_days,
           SUM(qty_a)::int AS total_a,
           SUM(qty_b)::int AS total_b
      FROM pairs
     GROUP BY machine_id, pod_a, pod_b
  )
  INSERT INTO public.correlation_pod_per_machine(
    machine_id, pod_product_a, pod_product_b, pearson,
    n_days, total_a, total_b, computed_at
  )
  SELECT machine_id, pod_a, pod_b,
         ROUND(pearson_raw::numeric, 3),
         n_days, total_a, total_b, now()
    FROM agg
   WHERE pearson_raw IS NOT NULL
     AND n_days >= p_min_n_days
     AND total_a >= p_min_sales_per_side
     AND total_b >= p_min_sales_per_side;

  GET DIAGNOSTICS v_per_machine = ROW_COUNT;

  -- ── PER LOC TYPE ──
  -- Aggregate daily series across machines of same location_type, then pair.
  WITH daily_sales AS (
    SELECT m.location_type, vshr.pod_product_id,
           vshr.transaction_date::date AS day,
           SUM(vshr.qty)::integer AS qty,
           COUNT(DISTINCT vshr.machine_id) AS mc
      FROM public.v_sales_history_resolved vshr
      JOIN public.machines m ON m.machine_id = vshr.machine_id
     WHERE vshr.delivery_status = 'Successful'
       AND vshr.pod_product_id IS NOT NULL
       AND m.location_type IS NOT NULL
       AND vshr.transaction_date >= now() - (p_window_days || ' days')::interval
     GROUP BY m.location_type, vshr.pod_product_id, day
  ),
  days AS (
    SELECT (now()::date - g)::date AS day FROM generate_series(0, p_window_days - 1) AS g
  ),
  loc_pods AS (
    SELECT DISTINCT location_type, pod_product_id FROM daily_sales
  ),
  pivot AS (
    SELECT lp.location_type, lp.pod_product_id, d.day,
           COALESCE(ds.qty, 0) AS qty
      FROM loc_pods lp
      CROSS JOIN days d
      LEFT JOIN daily_sales ds
        ON ds.location_type = lp.location_type
       AND ds.pod_product_id = lp.pod_product_id
       AND ds.day = d.day
  ),
  pairs AS (
    SELECT a.location_type,
           LEAST(a.pod_product_id, b.pod_product_id) AS pod_a,
           GREATEST(a.pod_product_id, b.pod_product_id) AS pod_b,
           a.qty AS qty_a, b.qty AS qty_b
      FROM pivot a
      JOIN pivot b
        ON a.location_type = b.location_type
       AND a.day = b.day
       AND a.pod_product_id < b.pod_product_id
  ),
  machine_counts AS (
    SELECT m.location_type, COUNT(DISTINCT m.machine_id) AS n_machines
      FROM public.machines m
     WHERE m.location_type IS NOT NULL
       AND m.include_in_refill = true
       AND m.status = 'Active'
     GROUP BY m.location_type
  ),
  agg AS (
    SELECT location_type, pod_a, pod_b,
           corr(qty_a::double precision, qty_b::double precision) AS pearson_raw,
           COUNT(*)::int AS n_days,
           SUM(qty_a)::int AS total_a,
           SUM(qty_b)::int AS total_b
      FROM pairs
     GROUP BY location_type, pod_a, pod_b
  )
  INSERT INTO public.correlation_pod_per_loc_type(
    location_type, pod_product_a, pod_product_b, pearson,
    n_days, machine_count, total_a, total_b, computed_at
  )
  SELECT a.location_type, a.pod_a, a.pod_b,
         ROUND(a.pearson_raw::numeric, 3),
         a.n_days,
         COALESCE(mc.n_machines, 0),
         a.total_a, a.total_b, now()
    FROM agg a
    LEFT JOIN machine_counts mc ON mc.location_type = a.location_type
   WHERE a.pearson_raw IS NOT NULL
     AND a.n_days >= p_min_n_days
     AND a.total_a >= p_min_sales_per_side
     AND a.total_b >= p_min_sales_per_side;

  GET DIAGNOSTICS v_per_loc_type = ROW_COUNT;

  RETURN jsonb_build_object(
    'window_days', p_window_days,
    'min_n_days', p_min_n_days,
    'min_sales_per_side', p_min_sales_per_side,
    'per_machine_rows', v_per_machine,
    'per_loc_type_rows', v_per_loc_type,
    'duration_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END;
$function$;

-- Cron rollback: SELECT cron.unschedule('refresh_correlation_weekly');
