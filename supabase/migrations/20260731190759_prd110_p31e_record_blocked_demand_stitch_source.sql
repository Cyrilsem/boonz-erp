-- PRD-110 · P3.1e · migration B — record_blocked_demand_v3 learns source='stitch'
--
-- ⭐ SPLICED from the live definition (pg_get_functiondef), so the header - 2 args, 1
--    default, SECURITY DEFINER, search_path, return type - is preserved BY CONSTRUCTION
--    rather than by re-typing it correctly (RISK 101). Verified byte-identical before apply.
--
-- ⛔ THE engine_add PATH IS BEHAVIOURALLY UNCHANGED, and that matters: cron 43
--    (prd110_p05_blocked_demand_2015_dubai, 15 16 * * *, ACTIVE) calls this function every
--    night with the default source. It now routes through _blocked_demand_gaps_for_source_v3,
--    which for 'engine_add' returns _blocked_demand_gaps_v3 verbatim. Proven by a
--    before/after diff of the live call in the same transaction, not by inspection.
--
-- Exactly three edits: the source guard, the three gap-source call sites, and scoping the
-- pod_refills 'legacy' diagnostic to engine_add. Nothing else in the body moves.

CREATE OR REPLACE FUNCTION public.record_blocked_demand_v3(p_plan_date date, p_source text DEFAULT 'engine_add'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- P3.1e. 'stitch' joins 'engine_add' as a supported source. ⛔ 'pack' still raises: it is
  -- a valid blocked_demand.source but has no gap source until P4.4b, and a writer that
  -- silently recorded nothing would be indistinguishable from a clean run.
  IF p_source IS NULL OR p_source NOT IN ('engine_add','stitch') THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: source % not implemented (engine_add since P0.5, stitch since P3.1e; pack lands with P4.4b)', p_source;
  END IF;

  SELECT count(*)::int, COALESCE(sum(g.qty_blocked),0)::int,
         count(*) FILTER (WHERE g.reason = 'routing_gap')::int
    INTO v_gaps, v_units, v_other
    FROM public._blocked_demand_gaps_for_source_v3(p_plan_date, p_source) g;

  -- 'legacy' counts v19 pod_refills rows that predate the need_raw field, so it is an
  -- engine_add diagnostic only. Reporting it for a stitch run would attribute an unrelated
  -- table's shape to this call.
  IF p_source = 'engine_add' THEN
    SELECT count(*)::int INTO v_legacy
      FROM public.pod_refills pr
     WHERE pr.plan_date = p_plan_date AND pr.reasoning->>'need_raw' IS NULL;
  END IF;

  WITH ins AS (
    INSERT INTO public.blocked_demand AS bd
      (plan_date, machine_id, shelf_id, pod_product_id, qty_blocked, reason, source,
       detected_by, reasoning)
    SELECT p_plan_date, g.machine_id, g.shelf_id, g.pod_product_id, g.qty_blocked, g.reason,
           p_source, 'record_blocked_demand_v3', g.reasoning
      FROM public._blocked_demand_gaps_for_source_v3(p_plan_date, p_source) g
    ON CONFLICT (plan_date, machine_id, shelf_id, pod_product_id, source)
      WHERE resolved_at IS NULL
    DO UPDATE SET qty_blocked = EXCLUDED.qty_blocked,
                  reason      = EXCLUDED.reason,
                  reasoning   = EXCLUDED.reasoning
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
         SELECT 1 FROM public._blocked_demand_gaps_for_source_v3(p_plan_date, p_source) g
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
END $function$
;

-- ⭐ CODY, BINDING REVISION AT THE P3.1e REVIEW. RPC_REGISTRY cites this very function as the
--    exemplar of the house pattern "EXECUTE granted to authenticated, REVOKEd from PUBLIC and
--    anon; a NULL actor is permitted so cron can call it" - and the live ACL did not follow it
--    (anon=X/postgres). ⛔ With the NULL-actor allowance, that let an UNAUTHENTICATED caller
--    insert, update and delete ledger rows through a SECURITY DEFINER: S-88, the GRANT is the
--    write guard, not RLS. Fixed here because this unit WIDENS what the function may write.
--    Verified safe: zero FE references, cron 43 runs as postgres, the relay as service_role.
REVOKE EXECUTE ON FUNCTION public.record_blocked_demand_v3(date, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_blocked_demand_v3(date, text) TO authenticated, service_role;
