-- PRD-119 P4: wire the 3 named alerts into a WM-actionable queue instead of
-- raw monitoring_alerts rows nobody ever resolves.
--
-- Found live before writing this: monitoring_alerts.acknowledged has NO
-- writer anywhere in the schema -- 1,010 open bug010_wh_approval_stuck rows
-- (2026-05-13 through today, one row per dispatch PER DAY it stays stuck --
-- 1,010 is dispatch-days, not 1,010 distinct dispatches) and 337 open
-- prd016_guardrail2_return_variant_uncorrected rows, both accumulating
-- forever. Also found: check_expiry_unvalidated (PRD-118 K2) was written but
-- never actually scheduled in cron.job -- the alert has literally never
-- fired. This migration fixes both: a dedup'd queue view + an ack writer,
-- and the missing nightly schedule.
--
-- v_wm_alert_queue: one row per DISTINCT underlying condition (dedup_key),
-- not one row per raw alert -- bug010 dedupes by dispatch_id (1,010 raw rows
-- -> 228 actionable lines, verified live), prd016 by dispatch_id+
-- pod_product_id, expiry_unvalidated is a single daily batch alert so
-- dedupes to at most one line. `occurrences` on each row tells the WM how
-- many days a condition has been open.
--
-- acknowledge_wm_alert: the only writer for monitoring_alerts.acknowledged.
-- Acks by (source, dedup_key) so ALL raw rows sharing that key clear in one
-- call -- acking only the latest row's alert_id would leave older duplicate
-- rows open and the queue line would immediately reappear at a stale date.
-- p_note >=10 chars (matches the existing pod_inventory_edit reject/approve
-- precedent) so there's an audit trail of why a WM dismissed it, since
-- acknowledging does NOT itself fix the underlying stuck dispatch or
-- uncorrected variant -- that still requires the normal approval/correction
-- screen; this just clears it from the queue once handled.
--
-- Verified live in a rolled-back transaction: dry-run correctly counted 2
-- raw rows for a real 2-day-open dispatch, the real (rolled-back) call
-- acked both, and the queue line for that key disappeared afterward.
--
-- Cody: approve, Articles 1 (sole writer of monitoring_alerts.acknowledged),
-- 4, 11 (cron calls the RPC only), 16 (queue view is the canonical object,
-- not raw table reads).
ALTER TABLE public.monitoring_alerts
  ADD COLUMN IF NOT EXISTS acknowledged_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS acknowledged_at timestamptz,
  ADD COLUMN IF NOT EXISTS acknowledged_note text;

CREATE OR REPLACE VIEW public.v_wm_alert_queue AS
SELECT
  'bug010_wh_approval_stuck'::text AS source,
  (payload->>'dispatch_id') AS dedup_key,
  (payload->>'dispatch_id') AS dispatch_id,
  NULL::text AS pod_product_id,
  (array_agg(severity ORDER BY created_at DESC))[1] AS severity,
  max(created_at) AS latest_at,
  count(*) AS occurrences,
  (array_agg(payload ORDER BY created_at DESC))[1] AS payload
FROM public.monitoring_alerts
WHERE source = 'bug010_wh_approval_stuck' AND NOT acknowledged
GROUP BY payload->>'dispatch_id'
UNION ALL
SELECT
  'prd016_guardrail2_return_variant_uncorrected',
  (payload->>'dispatch_id') || '|' || (payload->>'pod_product_id'),
  payload->>'dispatch_id', payload->>'pod_product_id',
  (array_agg(severity ORDER BY created_at DESC))[1],
  max(created_at), count(*), (array_agg(payload ORDER BY created_at DESC))[1]
FROM public.monitoring_alerts
WHERE source = 'prd016_guardrail2_return_variant_uncorrected' AND NOT acknowledged
GROUP BY payload->>'dispatch_id', payload->>'pod_product_id'
UNION ALL
SELECT
  'expiry_unvalidated', 'all', NULL, NULL,
  (array_agg(severity ORDER BY created_at DESC))[1],
  max(created_at), count(*), (array_agg(payload ORDER BY created_at DESC))[1]
FROM public.monitoring_alerts
WHERE source = 'expiry_unvalidated' AND NOT acknowledged
GROUP BY source;

CREATE OR REPLACE FUNCTION public.acknowledge_wm_alert(
  p_source text,
  p_dedup_key text,
  p_note text,
  p_caller uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := COALESCE(p_caller, auth.uid());
  v_n int;
BEGIN
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles WHERE id = v_user_id
      AND role = ANY(ARRAY['warehouse','operator_admin','superadmin','manager'])
  ) THEN RAISE EXCEPTION 'forbidden: acknowledge_wm_alert requires warehouse, operator_admin, superadmin, or manager'; END IF;

  IF p_source NOT IN ('bug010_wh_approval_stuck','prd016_guardrail2_return_variant_uncorrected','expiry_unvalidated') THEN
    RAISE EXCEPTION 'acknowledge_wm_alert: unsupported source %', p_source; END IF;
  IF length(COALESCE(p_note,'')) < 10 THEN
    RAISE EXCEPTION 'acknowledge_wm_alert: p_note must be at least 10 characters'; END IF;

  IF p_dry_run THEN
    SELECT count(*) INTO v_n FROM public.monitoring_alerts
     WHERE source = p_source AND NOT acknowledged
       AND (
         (p_source = 'bug010_wh_approval_stuck' AND (payload->>'dispatch_id') = p_dedup_key) OR
         (p_source = 'prd016_guardrail2_return_variant_uncorrected' AND ((payload->>'dispatch_id') || '|' || (payload->>'pod_product_id')) = p_dedup_key) OR
         (p_source = 'expiry_unvalidated')
       );
    RETURN jsonb_build_object('status','dry_run_ok','source',p_source,'dedup_key',p_dedup_key,'rows_would_ack', v_n);
  END IF;

  UPDATE public.monitoring_alerts
     SET acknowledged = true, acknowledged_by = v_user_id, acknowledged_at = now(), acknowledged_note = p_note
   WHERE source = p_source AND NOT acknowledged
     AND (
       (p_source = 'bug010_wh_approval_stuck' AND (payload->>'dispatch_id') = p_dedup_key) OR
       (p_source = 'prd016_guardrail2_return_variant_uncorrected' AND ((payload->>'dispatch_id') || '|' || (payload->>'pod_product_id')) = p_dedup_key) OR
       (p_source = 'expiry_unvalidated')
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'acknowledge_wm_alert: no open % rows matched dedup_key %', p_source, p_dedup_key; END IF;

  PERFORM public.set_write_context('acknowledge_wm_alert',
    format('acknowledge_wm_alert source=%s key=%s rows=%s by=%s: %s', p_source, p_dedup_key, v_n, COALESCE(v_user_id::text,'system'), p_note),
    'monitoring_alert_ack', p_dedup_key);

  RETURN jsonb_build_object('status','acknowledged','source',p_source,'dedup_key',p_dedup_key,'rows_acked', v_n);
END $function$;

SELECT cron.schedule(
  'check_expiry_unvalidated_nightly',
  '0 20 * * *',
  $$ SELECT public.check_expiry_unvalidated(); $$
);
