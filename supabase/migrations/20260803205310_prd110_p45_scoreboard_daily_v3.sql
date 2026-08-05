-- PRD-110 P4.5 — Scoreboard: daily materialised metrics (BUILD SPEC line 105)
-- Dara design, leg 101. Consumes CANONICAL objects only (Article 16):
--   v_weimi_shelf_history_v3  (historical shelf state)   -> osa_a_shelves, stockout_rate
--   inventory_events          (P1.4 event ledger)        -> waste_pct, expired_sold_incidents
--   v_engine_wmape_v3         (forecast accuracy)        -> wmape (per engine_tag)
--   v_refill_accuracy         (refill execution accuracy)-> plan_adherence
--   sales_history_aggregated  (net revenue)              -> revenue_per_machine_day
--   blocked_demand            (P0.5 blocked ledger)      -> blocked_aging_days
--   shelf_composition         (P1.4 estimator)           -> composition_confidence_avg
--   v_active_fleet            (machine scope)            -> denominators
--
-- ANTI-VACUITY INVARIANT (the whole point, per S-132 / S-173 / S-174):
-- a metric row is EITHER a real value (is_vacuous=false, metric_value NOT NULL)
-- OR an explicit refusal to report (is_vacuous=true, metric_value NULL,
-- vacuous_reason NOT NULL). A silently-absent or silently-zero metric cannot be
-- represented. Enforced by CHECK ck_scoreboard_vacuity, not by convention.

CREATE TABLE IF NOT EXISTS public.scoreboard_daily_v3 (
  scoreboard_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  metric_date     date NOT NULL,                       -- Dubai calendar day the metric describes
  scope_kind      text NOT NULL DEFAULT 'fleet'        -- wave 1 populates 'fleet' only
                  CHECK (scope_kind IN ('fleet','venue_group','machine')),
  scope_ref       text NOT NULL DEFAULT 'ALL',         -- 'ALL' | venue_group | machine_id::text
  machine_id      uuid NULL REFERENCES public.machines(machine_id) ON DELETE CASCADE,
  metric_key      text NOT NULL CHECK (metric_key IN (
                    'osa_a_shelves','stockout_rate','waste_pct','wmape','plan_adherence',
                    'revenue_per_machine_day','blocked_aging_days','expired_sold_incidents',
                    'composition_confidence_avg')),
  engine_tag      text NULL,                           -- only for wmape ('v3' | 'v19')
  metric_value    numeric NULL,                        -- NULL iff is_vacuous
  numerator       numeric NULL,                        -- the measured thing
  denominator     numeric NULL,                        -- the population it was measured over
  unit            text NOT NULL CHECK (unit IN ('ratio','aed','days','count')),
  is_vacuous      boolean NOT NULL DEFAULT false,
  vacuous_reason  text NULL,                           -- NOT NULL iff is_vacuous
  source_object   text NOT NULL,                       -- Article 16 traceability
  computed_at     timestamptz NOT NULL DEFAULT now(),
  computed_by     text NOT NULL DEFAULT 'compute_scoreboard_day_v3',
  CONSTRAINT ck_scoreboard_vacuity CHECK (
    (is_vacuous AND metric_value IS NULL AND vacuous_reason IS NOT NULL)
    OR (NOT is_vacuous AND metric_value IS NOT NULL AND vacuous_reason IS NULL)),
  CONSTRAINT ck_scoreboard_engine_tag CHECK (
    (metric_key = 'wmape' AND engine_tag IN ('v3','v19'))
    OR (metric_key <> 'wmape' AND engine_tag IS NULL)),
  CONSTRAINT ck_scoreboard_machine_scope CHECK (
    (scope_kind = 'machine' AND machine_id IS NOT NULL)
    OR (scope_kind <> 'machine' AND machine_id IS NULL))
);

COMMENT ON TABLE public.scoreboard_daily_v3 IS
  'PRD-110 P4.5. One row per (metric_date, scope, metric_key[, engine_tag]). Long/narrow so every metric '
  'carries its own numerator, denominator and explicit vacuity. Written ONLY by compute_scoreboard_day_v3.';
COMMENT ON COLUMN public.scoreboard_daily_v3.is_vacuous IS
  'TRUE = we refuse to report this metric for this date and say why. A vacuous green and a silent zero are '
  'the same defect (PRD-110 S-132/S-173/S-174); this column makes the difference queryable.';
COMMENT ON COLUMN public.scoreboard_daily_v3.source_object IS
  'The canonical object consumed (Article 16). Lets a reader audit that no metric was re-derived locally.';

-- Idempotent upsert key. NULLS NOT DISTINCT (PG15+) so engine_tag IS NULL collides
-- correctly for the eight non-wmape metrics. Serves: the RPC's ON CONFLICT, and
-- "give me metric X for date D" reads.
CREATE UNIQUE INDEX IF NOT EXISTS scoreboard_daily_v3_uniq
  ON public.scoreboard_daily_v3 (metric_date, scope_kind, scope_ref, metric_key, engine_tag)
  NULLS NOT DISTINCT;

-- Serves the dashboard's "last N days, all metrics" scan and the 7-consecutive-days gate.
CREATE INDEX IF NOT EXISTS scoreboard_daily_v3_date_idx
  ON public.scoreboard_daily_v3 (metric_date DESC, metric_key);

ALTER TABLE public.scoreboard_daily_v3 ENABLE ROW LEVEL SECURITY;

-- Read-only to the app. NO insert/update/delete policy exists, so every write from
-- authenticated/anon is denied; the SECURITY DEFINER writer below bypasses RLS as owner.
-- Deliberately NOT a GUC writer-gate: PRD-110 S-160/D-36 has an open GUC-leak defect and
-- this table will not add a ninth site to it.
DROP POLICY IF EXISTS scoreboard_daily_v3_select ON public.scoreboard_daily_v3;
CREATE POLICY scoreboard_daily_v3_select ON public.scoreboard_daily_v3
  FOR SELECT TO authenticated USING (true);

-- ---------------------------------------------------------------------------
-- Writer. SECURITY DEFINER, versioned (_v3), additive.
-- NOTE ON THE ROLE GUARD: auth.uid() IS NULL is deliberately allowed. pg_cron runs as
-- postgres with no JWT, so a NULL-refusing guard would strand the nightly job. This is the
-- documented fleet convention (PRD-110 leg 100 premise correction); exposure is handled at
-- the GRANT layer below, which is the only safe lever.
-- ---------------------------------------------------------------------------
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

COMMENT ON FUNCTION public.compute_scoreboard_day_v3(date) IS
  'PRD-110 P4.5. Materialises the ten fleet-scope scoreboard rows (9 metrics; wmape twice, per engine) '
  'for one Dubai calendar day. Idempotent upsert. Wave 1 is fleet scope only; venue_group/machine scope '
  'is forward-declared in the CHECK but deliberately unpopulated (see PARKING-LOT S-175).';

-- D-42 lesson applied pre-emptively: this writer is never anon- or PUBLIC-reachable.
REVOKE ALL ON FUNCTION public.compute_scoreboard_day_v3(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.compute_scoreboard_day_v3(date) FROM anon;
GRANT EXECUTE ON FUNCTION public.compute_scoreboard_day_v3(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.compute_scoreboard_day_v3(date) TO service_role;

-- ---------------------------------------------------------------------------
-- Read surface for the FE dashboard (Stax) and the weekly Remy pack: one wide row
-- per date, with vacuity preserved as NULL + a companion reason map.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_scoreboard_daily_v3 AS
SELECT metric_date,
       max(metric_value) FILTER (WHERE metric_key = 'osa_a_shelves')             AS osa_a_shelves,
       max(metric_value) FILTER (WHERE metric_key = 'stockout_rate')             AS stockout_rate,
       max(metric_value) FILTER (WHERE metric_key = 'waste_pct')                 AS waste_pct,
       max(metric_value) FILTER (WHERE metric_key = 'wmape' AND engine_tag='v3') AS wmape_v3,
       max(metric_value) FILTER (WHERE metric_key = 'wmape' AND engine_tag='v19')AS wmape_v19,
       max(metric_value) FILTER (WHERE metric_key = 'plan_adherence')            AS plan_adherence,
       max(metric_value) FILTER (WHERE metric_key = 'revenue_per_machine_day')   AS revenue_per_machine_day,
       max(metric_value) FILTER (WHERE metric_key = 'blocked_aging_days')        AS blocked_aging_days,
       max(metric_value) FILTER (WHERE metric_key = 'expired_sold_incidents')    AS expired_sold_incidents,
       max(metric_value) FILTER (WHERE metric_key = 'composition_confidence_avg')AS composition_confidence_avg,
       count(*) FILTER (WHERE is_vacuous)                                        AS n_vacuous,
       count(*)                                                                  AS n_metrics,
       jsonb_object_agg(
         metric_key || COALESCE('_' || engine_tag, ''), vacuous_reason
       ) FILTER (WHERE is_vacuous)                                               AS vacuous_reasons,
       max(computed_at)                                                          AS computed_at
FROM public.scoreboard_daily_v3
WHERE scope_kind = 'fleet'
GROUP BY metric_date;

COMMENT ON VIEW public.v_scoreboard_daily_v3 IS
  'PRD-110 P4.5 dashboard surface. A NULL metric here is ALWAYS explained by vacuous_reasons - '
  'read the two together or you will mistake a refusal for a zero.';

REVOKE ALL ON public.v_scoreboard_daily_v3 FROM PUBLIC;
REVOKE ALL ON public.v_scoreboard_daily_v3 FROM anon;
GRANT SELECT ON public.v_scoreboard_daily_v3 TO authenticated;

-- Cody finding (D-42 shape on a brand-new object): Supabase ALTER DEFAULT PRIVILEGES
-- grants new public tables to anon at creation, so the base table ships anon-readable
-- unless explicitly revoked. Revoke anon AND PUBLIC - the two traps compose (leg 99).
REVOKE ALL ON public.scoreboard_daily_v3 FROM PUBLIC;
REVOKE ALL ON public.scoreboard_daily_v3 FROM anon;
GRANT SELECT ON public.scoreboard_daily_v3 TO authenticated;

-- Health/gate view: is the scoreboard actually populated N consecutive days? (P4 GATE)
CREATE OR REPLACE VIEW public.v_scoreboard_health_v3 AS
WITH d AS (
  SELECT DISTINCT metric_date FROM public.scoreboard_daily_v3 WHERE scope_kind = 'fleet'
), g AS (
  SELECT metric_date, metric_date - (row_number() OVER (ORDER BY metric_date))::int AS grp FROM d
)
SELECT max(metric_date)                       AS latest_date,
       count(*)                               AS days_in_latest_streak,
       min(metric_date)                       AS streak_start
FROM g
WHERE grp = (SELECT grp FROM g ORDER BY metric_date DESC LIMIT 1);

COMMENT ON VIEW public.v_scoreboard_health_v3 IS
  'PRD-110 P4.5. days_in_latest_streak is the P4 GATE measurement ("scoreboard populated 7 consecutive days").';

REVOKE ALL ON public.v_scoreboard_health_v3 FROM PUBLIC;
REVOKE ALL ON public.v_scoreboard_health_v3 FROM anon;
GRANT SELECT ON public.v_scoreboard_health_v3 TO authenticated;

-- ---------------------------------------------------------------------------
-- Article 11: cron calls the RPC, never inline SQL.
-- 22:45 UTC = 02:45 Asia/Dubai, i.e. after the Dubai day has fully closed and after
-- the P2.7 nightly shadow runner (cron 45, 21:22 UTC). Computes the day that just ended.
-- Additive: no existing job's schedule or command is touched (LAW 12).
-- ---------------------------------------------------------------------------
DO $cron$
BEGIN
  PERFORM cron.unschedule('prd110_p45_scoreboard_daily_0245_dubai')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'prd110_p45_scoreboard_daily_0245_dubai');

  PERFORM cron.schedule(
    'prd110_p45_scoreboard_daily_0245_dubai',
    '45 22 * * *',
    $job$SELECT public.compute_scoreboard_day_v3(((now() AT TIME ZONE 'Asia/Dubai')::date - 1));$job$);
END
$cron$;
