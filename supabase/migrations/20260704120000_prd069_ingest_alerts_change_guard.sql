-- PRD-069 fix 1+2: change-guard the last_seen refresh and scope to open findings.
-- APPLIED TO PROD 2026-07-04 via Cowork MCP (migration name: prd069_ingest_alerts_change_guard).
-- A no-change UPDATE previously fired tg_audit_findings_ledger and wrote a no-op
-- row into write_audit_log every hour for every finding ever created (~82k/day).
-- Verified post-apply: a full ingest run writes 0 audit rows (was ~3,400/run).
-- Companion one-time reclaim (executed same day, CS green light, documented in
-- docs/prds/PRD-069-audit-log-noop-alert-ingest-leak.md): 1,400,734 no-op UPDATE
-- rows deleted from write_audit_log (checksum 1827832212716335355980), then
-- VACUUM FULL: 3671 MB -> 1592 MB.
CREATE OR REPLACE FUNCTION public.ingest_alerts_into_ledger()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_inserted int;
  v_signal_updated int;
BEGIN
  PERFORM set_config('app.via_rpc','true',true);
  PERFORM set_config('app.rpc_name','ingest_alerts_into_ledger',true);
  PERFORM set_config('app.mutation_reason','cron_ingest_monitoring_alerts',true);

  WITH new_rows AS (
    INSERT INTO public.findings_ledger (source, source_ref, title, detail, severity, last_seen_signal_at)
    SELECT
      'monitoring_alerts',
      ('00000000-0000-0000-0000-' || lpad(a.alert_id::text, 12, '0'))::uuid,
      coalesce(a.payload->>'title', a.source || ' alert'),
      a.payload || jsonb_build_object('alert_id', a.alert_id),
      a.severity,
      coalesce(a.created_at, now())
    FROM public.monitoring_alerts a
    WHERE NOT coalesce(a.acknowledged, false)
    ON CONFLICT (source, source_ref) DO NOTHING
    RETURNING finding_id
  )
  SELECT count(*) INTO v_inserted FROM new_rows;

  -- PRD-069: only touch rows where the signal genuinely advances (change-guard)
  -- and only findings that are still open (scope guard). No UPDATE row fired
  -- means no audit write from tg_audit_findings_ledger.
  UPDATE public.findings_ledger fl
     SET last_seen_signal_at = greatest(fl.last_seen_signal_at, a.max_created)
    FROM (
      SELECT ('00000000-0000-0000-0000-' || lpad(alert_id::text, 12, '0'))::uuid AS source_ref,
             max(created_at) AS max_created
        FROM public.monitoring_alerts
       WHERE NOT coalesce(acknowledged, false)
       GROUP BY 1
    ) a
   WHERE fl.source = 'monitoring_alerts'
     AND fl.source_ref = a.source_ref
     AND fl.status = 'open'
     AND a.max_created > fl.last_seen_signal_at;
  GET DIAGNOSTICS v_signal_updated = ROW_COUNT;

  RETURN jsonb_build_object('result','success','newly_inserted',v_inserted,'last_seen_refreshed',v_signal_updated,'ran_at',now(),'version','v2_prd069_change_guard');
END $function$;
