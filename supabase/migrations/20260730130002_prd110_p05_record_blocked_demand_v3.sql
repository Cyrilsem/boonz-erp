-- PRD-110 P0.5 - the canonical blocked_demand writer + its read-only gap derivation helper.
-- Applied via Supabase MCP as `prd110_p05_record_blocked_demand_v3` 2026-07-30.
--
-- ============================================================================================
-- WHY THIS IS NOT AN ENGINE-TAIL EDIT (deviation from BUILD SPEC P0.5, deliberate + evidenced)
-- ============================================================================================
-- BUILD SPEC P0.5 says: "Writers: engine_add_pod (from its procurement_gaps array - modify
-- function tail to INSERT)". Two live facts make that the WRONG construction:
--
--   1. ENGINE FREEZE. WAVE1-2-UNBLOCK holds Family-A engine bodies ("concurrent sessions are
--      editing engines"), and PRD-110 LAW 3 permits versioned additions only. Editing
--      engine_add_pod's tail is exactly the mutation both forbid.
--   2. THE JSON IS NAME-KEYED AND EPHEMERAL. procurement_gaps is built as
--      jsonb_build_object('machine', official_name, 'shelf', shelf_code, 'product',
--      pod_product_name, ...) and is only ever RETURNED, never persisted. Writing the ledger
--      from it would mean resolving machine/shelf/product NAMES back to uuids -- the exact
--      fan-out class of bug the DATA-SOURCE LAW exists to prevent.
--
-- Instead the ledger derives from pod_refills, which is uuid-keyed and already persisted. This
-- is provably the SAME row set, not an approximation. From the live engine body:
--
--     gap_rows AS (... FROM final f
--       WHERE NOT f.is_dead AND NOT f.is_drain AND f.blocking_intent_id IS NULL
--         AND f.need_raw > f.final_qty)
--
--   * is_dead rows are never inserted into pod_refills at all (the `inserted` CTE requires
--     `NOT f.is_dead`), so they are excluded here automatically.
--   * is_drain is hardcoded `false AS is_drain` in the live engine -- dead code, no rows.
--   * blocking_intent_id IS NOT NULL is stamped `clamp_reason='skipped_strategic_intent'` by
--     the very same CASE that produces every other clamp_reason, so excluding that reason IS
--     excluding that predicate. (Those units are a deliberate CS intent block, not a supply
--     gap -- procurement must NOT buy stock for them.)
--   * f.need_raw and f.final_qty are persisted as reasoning->>'need_raw' and qty.
--
-- Verified against all 3,737 live pod_refills rows across 58 plan_dates: gap rows occur under
-- exactly three clamp_reasons -- blocked_no_wh (788), partial_wh_limited (101),
-- skipped_strategic_intent (21, correctly excluded). Every other clamp_reason yields zero gap
-- rows, because final_qty = LEAST(need_raw, wh_avail - prior_need) can only fall short of
-- need_raw when warehouse stock is the binding constraint. The reason enum therefore covers
-- the engine's whole gap universe with no silent fallthrough (and `other_reason` is counted
-- and returned anyway, so a future clamp_reason cannot slip through unnoticed).
--
-- The in-engine-tail INSERT is parked in DECISIONS-READY as a post-freeze simplification. It is
-- NOT needed for correctness: cron 43 calls this RPC right after the nightly build.
--
-- Cody: helper = class (c) read-only -> SECURITY INVOKER (DEFINER not justified for a SELECT).
--       writer = class (b) DEFINER; target table blocked_demand is NOT in Appendix A, but the
--       Article 4 discipline is applied in full anyway: role check, input validation,
--       app.via_rpc + app.rpc_name, and Article 8 audit via the table's trigger.
-- ============================================================================================

CREATE OR REPLACE FUNCTION public._blocked_demand_gaps_v3(p_plan_date date)
RETURNS TABLE (
  machine_id     uuid,
  shelf_id       uuid,
  pod_product_id uuid,
  qty_blocked    integer,
  reason         text,
  reasoning      jsonb
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $$
  SELECT pr.machine_id,
         pr.shelf_id,
         pr.pod_product_id,
         CEIL(SUM((pr.reasoning->>'need_raw')::numeric - pr.qty))::int AS qty_blocked,
         CASE
           WHEN bool_or(pr.clamp_reason = 'blocked_no_wh')      THEN 'blocked_no_wh'
           WHEN bool_or(pr.clamp_reason = 'partial_wh_limited') THEN 'partial_wh_limited'
           ELSE 'routing_gap'
         END AS reason,
         jsonb_build_object(
           'shelf_code',     min(pr.reasoning->>'shelf_code'),
           'machine_name',   min(pr.reasoning->>'official_name'),
           'signal',         min(pr.signal),
           'velocity_30d',   max(pr.velocity_30d),
           'current_stock',  max(pr.current_stock),
           'max_stock',      max(pr.max_stock),
           'need_raw',       max((pr.reasoning->>'need_raw')::numeric),
           'qty_planned',    max(pr.qty),
           'wh_available',   max(pr.wh_available_pod),
           'clamp_reason',   min(pr.clamp_reason),
           'engine_version', min(pr.reasoning->>'engine_calibration'),
           'derived_by',     'record_blocked_demand_v3 from pod_refills'
         ) AS reasoning
    FROM public.pod_refills pr
   WHERE pr.plan_date = p_plan_date
     AND pr.reasoning->>'need_raw' IS NOT NULL
     AND (pr.reasoning->>'need_raw')::numeric > pr.qty
     AND COALESCE(pr.clamp_reason,'') NOT IN
         ('skipped_strategic_intent','dead_tagged_for_swap','drain_no_refill')
   GROUP BY pr.machine_id, pr.shelf_id, pr.pod_product_id
$$;

COMMENT ON FUNCTION public._blocked_demand_gaps_v3(date) IS
  'PRD-110 P0.5 read-only derivation of the engine gap set from pod_refills, uuid-keyed. '
  'Mirrors engine_add_pod gap_rows exactly (see migration header for the proof). GROUP BY the '
  'plan grain so a duplicated pod_refills row can never produce two ledger rows for one shelf/pod. '
  'Rows older than the need_raw-persisting engine version are skipped (need_raw IS NULL) and '
  'counted separately by the writer as legacy_skipped.';

CREATE OR REPLACE FUNCTION public.record_blocked_demand_v3(
  p_plan_date date,
  p_source    text DEFAULT 'engine_add'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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

  -- Article 4: role validation. auth.uid() IS NULL means service_role / cron, which is how the
  -- nightly job calls this; identical carve-out to engine_add_pod's own guard.
  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'record_blocked_demand_v3: caller % lacks operator_admin role', v_user_id;
  END IF;

  -- Article 4: input validation.
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

  -- Upsert the current gap set. Arbiter is the partial unique index on open rows, so a row
  -- already resolved (spot-buy, PO) is NEVER silently reopened or double-counted.
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
    RETURNING (xmax = 0) AS was_insert
  )
  SELECT count(*) FILTER (WHERE was_insert)::int,
         count(*) FILTER (WHERE NOT was_insert)::int
    INTO v_ins, v_upd
    FROM ins;

  -- Close rows that are no longer a gap for this plan_date (a re-run satisfied them, e.g. a
  -- spot buy landed in the WH). Mirrors engine_add_pod's own idempotency, which opens with
  -- DELETE FROM pod_refills WHERE plan_date = p_plan_date. Only OPEN rows of THIS source and
  -- plan_date are touched; resolved history is immutable here. Every delete is audited by
  -- tg_audit_blocked_demand, so this is a traceable close, not a silent disappearance.
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
END $$;

COMMENT ON FUNCTION public.record_blocked_demand_v3(date, text) IS
  'PRD-110 P0.5 canonical writer for blocked_demand. Derives the engine gap set from pod_refills '
  '(uuid-keyed) rather than the name-keyed ephemeral procurement_gaps JSON. Idempotent: re-runs '
  'upsert open rows and close rows that are no longer gaps; resolved rows are never touched. '
  'LAW 5 enforcement point -- every clamped unit the plan could not place becomes a visible row.';

REVOKE ALL ON FUNCTION public.record_blocked_demand_v3(date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._blocked_demand_gaps_v3(date)        FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_blocked_demand_v3(date, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._blocked_demand_gaps_v3(date)        TO authenticated, service_role;

-- Overload guard. This loop has already been bitten twice by accidental overloads
-- (golden.run_fixture 42725; and the Wave-2 13-day driver-confirm outage). Assert one signature.
DO $assert$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'record_blocked_demand_v3';
  IF n <> 1 THEN
    RAISE EXCEPTION 'record_blocked_demand_v3 must have exactly 1 signature, found %', n;
  END IF;
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = '_blocked_demand_gaps_v3';
  IF n <> 1 THEN
    RAISE EXCEPTION '_blocked_demand_gaps_v3 must have exactly 1 signature, found %', n;
  END IF;
END $assert$;
