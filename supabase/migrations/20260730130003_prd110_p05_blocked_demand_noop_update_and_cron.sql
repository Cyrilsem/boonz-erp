-- PRD-110 P0.5 (part 3) - make no-change re-runs true no-ops, then schedule the nightly writer.
-- Applied via Supabase MCP as `prd110_p05_blocked_demand_noop_update_and_cron` 2026-07-30.
--
-- FOUND BY VERIFY, NOT BY REVIEW: running record_blocked_demand_v3 three times on 2026-07-30
-- correctly left 20 rows / 107 units (idempotent on the ledger), but wrote 60 rows to
-- write_audit_log - each re-run UPDATEd all 20 rows with byte-identical values. The ledger was
-- right and the audit trail was noise. Article 8 audit is only useful if a logged UPDATE means
-- something actually changed, so the upsert now carries a change predicate.
--
-- This also sharpens stress case S4 ("re-run every engine 3x same date - idempotent, no dup
-- lines"): rows_updated now reads 0 on a genuine no-op instead of 20, which is the honest signal.
--
-- Article 12: forward-only CREATE OR REPLACE, signature unchanged (no new defaulted arg, so no
-- overload). Article 11: the cron calls the RPC, never a raw table write.

CREATE OR REPLACE FUNCTION public.record_blocked_demand_v3(
  p_plan_date date,
  p_source    text DEFAULT 'engine_add'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_user_id  uuid;
  v_gaps     int := 0;
  v_units    int := 0;
  v_ins      int := 0;
  v_upd      int := 0;
  v_closed   int := 0;
  v_other    int := 0;
  v_legacy   int := 0;
  v_t0       timestamptz := clock_timestamp();
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'record_blocked_demand_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: p_plan_date is required';
  END IF;
  IF p_source IS NULL OR p_source <> 'engine_add' THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: source % not implemented in v1 (engine_add only; stitch and pack writers land in Phase 3/4)', p_source;
  END IF;

  SELECT count(*)::int, COALESCE(sum(g.qty_blocked),0)::int,
         count(*) FILTER (WHERE g.reason = 'routing_gap')::int
    INTO v_gaps, v_units, v_other
    FROM public._blocked_demand_gaps_v3(p_plan_date) g;

  SELECT count(*)::int INTO v_legacy
    FROM public.pod_refills pr
   WHERE pr.plan_date = p_plan_date AND pr.reasoning->>'need_raw' IS NULL;

  WITH ins AS (
    INSERT INTO public.blocked_demand AS bd
      (plan_date, machine_id, shelf_id, pod_product_id, qty_blocked, reason, source,
       detected_by, reasoning)
    SELECT p_plan_date, g.machine_id, g.shelf_id, g.pod_product_id, g.qty_blocked, g.reason,
           p_source, 'record_blocked_demand_v3', g.reasoning
      FROM public._blocked_demand_gaps_v3(p_plan_date) g
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id, source)
      WHERE resolved_at IS NULL
    DO UPDATE SET qty_blocked = EXCLUDED.qty_blocked,
                  reason      = EXCLUDED.reason,
                  reasoning   = EXCLUDED.reasoning
    -- Change predicate: a re-run that finds the same gap writes nothing and audits nothing.
    WHERE bd.qty_blocked IS DISTINCT FROM EXCLUDED.qty_blocked
       OR bd.reason      IS DISTINCT FROM EXCLUDED.reason
       OR bd.reasoning   IS DISTINCT FROM EXCLUDED.reasoning
    RETURNING (xmax = 0) AS was_insert
  )
  SELECT count(*) FILTER (WHERE was_insert)::int,
         count(*) FILTER (WHERE NOT was_insert)::int
    INTO v_ins, v_upd
    FROM ins;

  WITH del AS (
    DELETE FROM public.blocked_demand bd
     WHERE bd.plan_date   = p_plan_date
       AND bd.source      = p_source
       AND bd.resolved_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM public._blocked_demand_gaps_v3(p_plan_date) g
          WHERE g.machine_id     = bd.machine_id
            AND g.shelf_id       = bd.shelf_id
            AND g.pod_product_id = bd.pod_product_id)
    RETURNING 1)
  SELECT count(*)::int INTO v_closed FROM del;

  RETURN jsonb_build_object(
    'plan_date',        p_plan_date,
    'source',           p_source,
    'gaps_found',       v_gaps,
    'units_blocked',    v_units,
    'rows_inserted',    v_ins,
    'rows_updated',     v_upd,
    'rows_closed_stale',v_closed,
    'open_rows_now',    (SELECT count(*) FROM public.blocked_demand
                          WHERE plan_date = p_plan_date AND source = p_source
                            AND resolved_at IS NULL),
    'other_reason_rows',v_other,
    'legacy_skipped',   v_legacy,
    'duration_ms',      (EXTRACT(EPOCH FROM (clock_timestamp() - v_t0)) * 1000)::int
  );
END $fn$;

-- Nightly: 16:15 UTC = 20:15 Dubai, 15 minutes AFTER cron 13
-- (phaseF_stage1_prep_8pm_dubai, 16:00 UTC) has built the plan, so the gaps exist to record.
-- Deliberately a SEPARATE job rather than a call inside the build chain: if the ledger writer
-- ever fails it must not be able to take the nightly advisory down with it (LAW 12).
SELECT cron.schedule(
  'prd110_p05_blocked_demand_2015_dubai',
  '15 16 * * *',
  $job$SELECT public.record_blocked_demand_v3(public.resolve_refill_plan_date());$job$
);
