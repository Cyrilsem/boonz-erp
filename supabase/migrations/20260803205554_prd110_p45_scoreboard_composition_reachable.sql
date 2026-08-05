-- PRD-110 P4.5 fix: composition_confidence_avg was unreachable (see body comment).
CREATE OR REPLACE FUNCTION public.compute_scoreboard_day_v3(p_metric_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid          uuid := auth.uid();
  v_rows         int  := 0;
  v_num          numeric;
  v_den          numeric;
  v_written      jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.user_profiles
       WHERE id = (SELECT auth.uid())
         AND role = ANY (ARRAY['operator_admin','superadmin','manager'])) THEN
    RAISE EXCEPTION 'compute_scoreboard_day_v3: role not permitted';
  END IF;

  IF p_metric_date IS NULL THEN
    RAISE EXCEPTION 'compute_scoreboard_day_v3: p_metric_date is required';
  END IF;

  -- ===== 1 + 2. osa_a_shelves and stockout_rate, from the canonical historical shelf state
  -- Latest snapshot per physical slot for the day; A-aisle only; enabled, unbroken,
  -- refill-eligible machines. DATA-SOURCE LAW: WEIMI is shelf state.
  -- osa: slot-grain availability
  WITH snap AS (
    SELECT DISTINCT ON (h.machine_id, h.cabinet_index, h.layer_label, h.slot_name)
           h.machine_id, h.current_stock
    FROM public.v_weimi_shelf_history_v3 h
    WHERE h.snapshot_at::date = p_metric_date
      AND h.is_eligible_machine AND h.is_enabled AND NOT h.is_broken
      AND h.aisle_code ~ '-A[0-9]+$'
    ORDER BY h.machine_id, h.cabinet_index, h.layer_label, h.slot_name, h.snapshot_at DESC)
  SELECT count(*) FILTER (WHERE current_stock > 0), count(*) INTO v_num, v_den FROM snap;
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'osa_a_shelves',
     CASE WHEN v_den > 0 THEN round(v_num / v_den, 4) END, v_num, NULLIF(v_den,0), 'ratio',
     v_den = 0, CASE WHEN v_den = 0 THEN 'no_weimi_snapshot_for_date' END,
     'v_weimi_shelf_history_v3')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 1;

  -- stockout_rate: MACHINE-grain incidence (share of observed machines with >=1 empty A slot).
  -- Deliberately a different grain from osa so the pair is not 1-x of itself (S-132 class).
  WITH snap AS (
    SELECT DISTINCT ON (h.machine_id, h.cabinet_index, h.layer_label, h.slot_name)
           h.machine_id, h.current_stock
    FROM public.v_weimi_shelf_history_v3 h
    WHERE h.snapshot_at::date = p_metric_date
      AND h.is_eligible_machine AND h.is_enabled AND NOT h.is_broken
      AND h.aisle_code ~ '-A[0-9]+$'
    ORDER BY h.machine_id, h.cabinet_index, h.layer_label, h.slot_name, h.snapshot_at DESC),
  per_machine AS (
    SELECT machine_id, bool_or(current_stock = 0) AS z FROM snap GROUP BY machine_id)
  SELECT count(*) FILTER (WHERE z), count(*) INTO v_num, v_den FROM per_machine;
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'stockout_rate',
     CASE WHEN v_den > 0 THEN round(v_num / v_den, 4) END, v_num, NULLIF(v_den,0), 'ratio',
     v_den = 0, CASE WHEN v_den = 0 THEN 'no_weimi_snapshot_for_date' END,
     'v_weimi_shelf_history_v3')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 1;

  -- ===== 3. waste_pct: units written off vs all units that left the shelf that day.
  SELECT abs(sum(qty_delta) FILTER (WHERE kind = 'write_off')),
         abs(sum(qty_delta) FILTER (WHERE kind IN ('write_off','derived_decrement','expired_sold_incident')))
    INTO v_num, v_den
  FROM public.inventory_events
  WHERE ts::date = p_metric_date;
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'waste_pct',
     CASE WHEN COALESCE(v_den,0) > 0 THEN round(COALESCE(v_num,0) / v_den, 4) END,
     COALESCE(v_num,0), NULLIF(COALESCE(v_den,0),0), 'ratio',
     COALESCE(v_den,0) = 0, CASE WHEN COALESCE(v_den,0) = 0 THEN 'no_shelf_exit_events_for_date' END,
     'inventory_events')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 1;

  -- ===== 4. wmape, per engine, passing the canonical view's OWN vacuity through unchanged.
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, engine_tag, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  SELECT p_metric_date, 'wmape', t.engine_tag,
         w.wmape, w.sum_abs_error, NULLIF(w.sum_actual,0), 'ratio',
         (w.wmape IS NULL), CASE WHEN w.wmape IS NULL
           THEN COALESCE(w.vacuous_reason, 'no_wmape_row_for_date') END,
         'v_engine_wmape_v3'
  FROM (VALUES ('v3'),('v19')) AS t(engine_tag)
  LEFT JOIN public.v_engine_wmape_v3 w
    ON w.plan_date = p_metric_date AND w.engine_tag = t.engine_tag
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 2;

  -- ===== 5. plan_adherence: dispatched units vs intended units for that plan_date.
  SELECT sum(dispatched_qty), sum(pod_intent) INTO v_num, v_den
  FROM public.v_refill_accuracy WHERE plan_date = p_metric_date;
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'plan_adherence',
     CASE WHEN COALESCE(v_den,0) > 0 THEN round(COALESCE(v_num,0) / v_den, 4) END,
     COALESCE(v_num,0), NULLIF(COALESCE(v_den,0),0), 'ratio',
     COALESCE(v_den,0) = 0, CASE WHEN COALESCE(v_den,0) = 0 THEN 'no_planned_intent_for_date' END,
     'v_refill_accuracy')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 1;

  -- ===== 6. revenue_per_machine_day: net revenue / refill-eligible active machines.
  SELECT (SELECT sum(net_revenue) FROM public.sales_history_aggregated
           WHERE transaction_date::date = p_metric_date),
         (SELECT count(*) FROM public.v_active_fleet WHERE include_in_refill)
    INTO v_num, v_den;
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'revenue_per_machine_day',
     CASE WHEN COALESCE(v_den,0) > 0 AND v_num IS NOT NULL THEN round(v_num / v_den, 2) END,
     v_num, NULLIF(COALESCE(v_den,0),0), 'aed',
     (COALESCE(v_den,0) = 0 OR v_num IS NULL),
     CASE WHEN COALESCE(v_den,0) = 0 THEN 'no_active_fleet'
          WHEN v_num IS NULL THEN 'no_sales_for_date' END,
     'sales_history_aggregated + v_active_fleet')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 1;

  -- ===== 7. blocked_aging_days: mean age of blocked_demand rows OPEN as at that date.
  -- blocked_demand has no status column - open == resolved_at IS NULL (shape reminder).
  SELECT avg(p_metric_date - created_at::date), count(*) INTO v_num, v_den
  FROM public.blocked_demand
  WHERE created_at::date <= p_metric_date
    AND (resolved_at IS NULL OR resolved_at::date > p_metric_date);
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'blocked_aging_days',
     CASE WHEN COALESCE(v_den,0) > 0 THEN round(v_num, 2) END, round(COALESCE(v_num,0),2),
     NULLIF(COALESCE(v_den,0),0), 'days',
     COALESCE(v_den,0) = 0, CASE WHEN COALESCE(v_den,0) = 0 THEN 'no_open_blocked_rows_as_at_date' END,
     'blocked_demand')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 1;

  -- ===== 8. expired_sold_incidents: a COUNT, so 0 is a real answer and never vacuous.
  -- The EXPIRY IRON RULE's KPI (fixture 23). Its positive control lives in the fixture.
  SELECT count(*) INTO v_num
  FROM public.inventory_events
  WHERE ts::date = p_metric_date AND kind = 'expired_sold_incident';
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'expired_sold_incidents', v_num, v_num, NULL, 'count',
     false, NULL, 'inventory_events')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        is_vacuous = EXCLUDED.is_vacuous, vacuous_reason = EXCLUDED.vacuous_reason,
        computed_at = now();
  v_rows := v_rows + 1;

  -- ===== 9. composition_confidence_avg. shelf_composition is PRESENT-TENSE (no history),
  -- so it is only honest for today; past dates report an explicit refusal rather than
  -- back-stamping today's confidence onto a historical day.
  -- The freshest estimator state legitimately describes today AND the day that just ended:
  -- the nightly job runs at 02:45 Dubai for Dubai-yesterday, so restricting this to
  -- "= today" made the metric UNREACHABLE by the only caller that ever runs it. That is the
  -- S-173/S-174 defect class (a value that can never be produced), caught by the vacuity map
  -- on first backfill. Window is now [today-1, today]; anything older is still refused,
  -- because back-stamping today's confidence onto last week would be a lie.
  IF p_metric_date >= (now() AT TIME ZONE 'Asia/Dubai')::date - 1 THEN
    SELECT avg(confidence), count(*) INTO v_num, v_den FROM public.shelf_composition;
  ELSE
    v_num := NULL; v_den := 0;
  END IF;
  INSERT INTO public.scoreboard_daily_v3
    (metric_date, metric_key, metric_value, numerator, denominator, unit,
     is_vacuous, vacuous_reason, source_object)
  VALUES (p_metric_date, 'composition_confidence_avg',
     CASE WHEN COALESCE(v_den,0) > 0 THEN round(v_num, 4) END,
     round(COALESCE(v_num,0),4), NULLIF(COALESCE(v_den,0),0), 'ratio',
     COALESCE(v_den,0) = 0,
     CASE WHEN COALESCE(v_den,0) = 0 THEN
       CASE WHEN p_metric_date >= (now() AT TIME ZONE 'Asia/Dubai')::date - 1
            THEN 'no_composition_rows' ELSE 'composition_is_present_tense_only' END END,
     'shelf_composition (as at compute time)')
  ON CONFLICT (metric_date, scope_kind, scope_ref, metric_key, engine_tag) DO UPDATE
    SET metric_value = EXCLUDED.metric_value, numerator = EXCLUDED.numerator,
        denominator = EXCLUDED.denominator, is_vacuous = EXCLUDED.is_vacuous,
        vacuous_reason = EXCLUDED.vacuous_reason, computed_at = now();
  v_rows := v_rows + 1;

  SELECT jsonb_agg(jsonb_build_object('k', metric_key, 'e', engine_tag,
                                      'v', metric_value, 'vac', is_vacuous)
                   ORDER BY metric_key, engine_tag)
    INTO v_written
  FROM public.scoreboard_daily_v3
  WHERE metric_date = p_metric_date AND scope_kind = 'fleet';

  RETURN jsonb_build_object(
    'ok', true, 'metric_date', p_metric_date, 'scope', 'fleet',
    'metrics_written', v_rows, 'metrics', v_written);
END;
$fn$;
