-- ============================================================================
-- PRD-009 — feedback-weight view + scorer for engine consumption
--
-- Source PRD: docs/prds/refill-pipeline/PRD-009-driver-feedback-ingest.md
--
-- DEPENDS ON: 20260521232618_prd009_driver_feedback_notes.sql
--
-- Adds the engine-facing computation layer over driver_feedback_notes:
--
--   1. v_driver_feedback_weight — for every (machine_id, boonz_product_id)
--      pair with any active feedback in the last 30 days, aggregates the
--      weighted scores with three decay windows (7d, 14d, 30d). Weight
--      formula per PRD-009 Decision:
--        signal_source weight: customer_request 3x, sale_anomaly 2x,
--                              observation 1x
--        confidence weight: 1, 2, 3 (driver self-rating)
--        direction sign: more=+1, fewer=-1, replace=0, NULL=+1
--        decay: linear within window, 0 outside
--
--   2. get_driver_feedback_weight(p_machine_id, p_boonz_product_id) —
--      SECURITY INVOKER STABLE scorer that returns the 14-day decayed
--      weight for a single (machine, product) pair. Engine v3 calls this
--      in propose_add_plan to nudge candidate scores.
--
--   3. Convenience read-only function get_machine_feedback_summary(
--      p_machine_id, p_window_days) returning a jsonb summary of the
--      machine's recent feedback — useful for the admin feedback inbox
--      and for the conductor-session pre-visit briefing.
--
-- Cody Articles: 4 (helpers are SECURITY INVOKER per the Article 4
-- default — they have no need for DEFINER privilege).
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_driver_feedback_weight
WITH (security_invoker = true) AS
WITH active_notes AS (
  SELECT
    dfn.machine_id,
    dfn.boonz_product_id,
    dfn.confidence,
    dfn.signal_source,
    dfn.direction,
    dfn.created_at,
    EXTRACT(EPOCH FROM (now() - dfn.created_at)) / 86400.0 AS age_days,
    CASE dfn.signal_source
      WHEN 'customer_request' THEN 3
      WHEN 'sale_anomaly'     THEN 2
      ELSE 1
    END AS source_weight,
    CASE dfn.direction
      WHEN 'fewer'   THEN -1
      WHEN 'replace' THEN 0
      ELSE 1
    END AS direction_sign
  FROM public.driver_feedback_notes dfn
  WHERE dfn.superseded_at IS NULL
    AND dfn.boonz_product_id IS NOT NULL  -- machine-level NULL notes don't weight a specific product
    AND dfn.created_at >= now() - INTERVAL '30 days'
)
SELECT
  machine_id,
  boonz_product_id,
  count(*) AS active_note_count,
  -- 7-day window: linear decay from 1 at age=0 to 0 at age=7
  SUM(
    CASE WHEN age_days <= 7
         THEN direction_sign * source_weight * confidence * GREATEST((7 - age_days) / 7.0, 0)
         ELSE 0 END
  )::numeric AS weight_7d,
  -- 14-day window (PRD-009 default decay horizon)
  SUM(
    CASE WHEN age_days <= 14
         THEN direction_sign * source_weight * confidence * GREATEST((14 - age_days) / 14.0, 0)
         ELSE 0 END
  )::numeric AS weight_14d,
  -- 30-day window (looser, for trend display)
  SUM(
    CASE WHEN age_days <= 30
         THEN direction_sign * source_weight * confidence * GREATEST((30 - age_days) / 30.0, 0)
         ELSE 0 END
  )::numeric AS weight_30d
FROM active_notes
GROUP BY machine_id, boonz_product_id;

COMMENT ON VIEW public.v_driver_feedback_weight IS
  'PRD-009: per-(machine, product) decay-weighted feedback signal. Direction sign '
  '(more=+1, fewer=-1, replace=0), source weight (3x customer_request, 2x '
  'sale_anomaly, 1x observation), confidence (1..3), linear decay within window. '
  'Engine v3 reads weight_14d to nudge ADD/SWAP candidate scoring.';

-- Scorer for a single (machine, product) pair
CREATE OR REPLACE FUNCTION public.get_driver_feedback_weight(
  p_machine_id uuid,
  p_boonz_product_id uuid
)
RETURNS numeric
LANGUAGE sql
SECURITY INVOKER
STABLE
AS $$
  SELECT COALESCE(
    (SELECT weight_14d FROM public.v_driver_feedback_weight
      WHERE machine_id = p_machine_id
        AND boonz_product_id = p_boonz_product_id),
    0
  );
$$;

COMMENT ON FUNCTION public.get_driver_feedback_weight(uuid, uuid) IS
  'PRD-009: 14-day decayed feedback score for a (machine, product) pair. '
  'Returns 0 when no active notes. SECURITY INVOKER STABLE per Article 4 default.';

-- Per-machine summary for admin inbox + conductor briefing
CREATE OR REPLACE FUNCTION public.get_machine_feedback_summary(
  p_machine_id uuid,
  p_window_days int DEFAULT 14
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
STABLE
AS $$
  WITH window_notes AS (
    SELECT *
    FROM public.driver_feedback_notes
    WHERE machine_id = p_machine_id
      AND superseded_at IS NULL
      AND created_at >= now() - make_interval(days => p_window_days)
  ),
  by_direction AS (
    SELECT direction, count(*) AS n
    FROM window_notes
    GROUP BY direction
  ),
  by_source AS (
    SELECT signal_source, count(*) AS n
    FROM window_notes
    GROUP BY signal_source
  )
  SELECT jsonb_build_object(
    'machine_id', p_machine_id,
    'window_days', p_window_days,
    'total_notes', (SELECT count(*) FROM window_notes),
    'by_direction', (SELECT jsonb_object_agg(COALESCE(direction, 'unspecified'), n) FROM by_direction),
    'by_source',    (SELECT jsonb_object_agg(signal_source, n) FROM by_source),
    'top_products', (
      SELECT jsonb_agg(jsonb_build_object(
        'boonz_product_id', boonz_product_id,
        'weight_14d', ROUND(weight_14d, 2),
        'note_count', active_note_count
      ) ORDER BY abs(weight_14d) DESC)
      FROM (
        SELECT boonz_product_id, weight_14d, active_note_count
        FROM public.v_driver_feedback_weight
        WHERE machine_id = p_machine_id
        ORDER BY abs(weight_14d) DESC
        LIMIT 5
      ) t
    )
  );
$$;

COMMENT ON FUNCTION public.get_machine_feedback_summary(uuid, int) IS
  'PRD-009: jsonb summary of recent (default 14d) feedback at a machine. '
  'Used by the admin feedback inbox per-machine drill-down and the upstream '
  'conductor-session briefing.';

GRANT EXECUTE ON FUNCTION public.get_driver_feedback_weight(uuid, uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_machine_feedback_summary(uuid, int) TO authenticated, service_role;

COMMIT;

-- ============================================================================
-- POST-APPLY USAGE
--   SELECT * FROM v_driver_feedback_weight
--   ORDER BY abs(weight_14d) DESC LIMIT 20;
--
--   SELECT get_machine_feedback_summary('<machine_uuid>', 14);
--
-- DEFERRED:
--   - Engine v3 patch in propose_add_plan: JOIN get_driver_feedback_weight
--     and add a feedback-weight nudge to the candidate ranking. Engine
--     team owns the calibration of how much weight to give vs sales velocity.
--   - reconcile_intent_progress credit-back: when a "more X" note translates
--     into a fill that sells well, attribute the velocity credit to the
--     feedback signal (jsonb append to strategic_intents.progress.events).
--   - Google Doc backfill ingest: one-off script, accepts CSV of historical
--     notes and INSERTs into driver_feedback_notes with created_by=NULL.
-- ============================================================================
