-- Refill reliability fix (2026-06-07) — two bugs, scoped, CS-approved.
--
-- BUG 1 (deadlock): cron 14 (6am) picks machines but leaves them unconfirmed; cron 13 (8pm)
--   calls build_draft_for_confirmed, which hits Gate 0 (_assert_gate_zero), finds 0 confirmed,
--   returns 'awaiting_confirmation' and writes nothing — every night. Nothing confirms the pick
--   between 6am and 8pm, so the nightly draft can never self-generate.
--   FIX: auto-confirm the pick via the canonical writer confirm_machines_to_visit at the top of
--   build. A draft is non-committal; the real human gates are Gate 1 (approve) + Gate 2 (stitch).
--   CS amended the "keep human confirm in cron" rule for DRAFT generation on 2026-06-07.
--
-- BUG 2 (timeout): a full-fleet build runs engine_add_pod + engine_swap_pod over all included
--   machines in one transaction. Under the 120s db-default statement_timeout (manual/SQL path)
--   it times out and rolls back atomically → zero draft, forcing a manual shortlist.
--   FIX: give this one DEFINER orchestrator a raised, bounded statement_timeout (20 min) so the
--   full-fleet build completes. The nightly cron runs as postgres (already unbounded); this also
--   covers the manual/on-demand path.
--
-- BUG 3 (no finalize): build ran stage 2a (engine_add_pod → pod_refills) + 2b (engine_swap_pod →
--   pod_swaps) and returned 'draft_ready', but never called stage 2c (engine_finalize_pod), which
--   materializes pod_refill_plan — the table the FE "Load draft" reads. So a "successful" build left
--   pod_refill_plan empty and the FE showed nothing.
--   FIX: chain engine_finalize_pod(p_plan_date) after swap so the build yields a loadable draft.
--
-- Diff vs live build_draft_for_confirmed(date): (1) new function SET statement_timeout, (2) the
-- auto-confirm PERFORM + its var, (3) the engine_finalize_pod chain + its var, (4) auto_confirmed and
-- stage_2c in the return jsonb. Everything else identical.
--
-- CODY verdict: ⚠️ Approve with revisions (bound the timeout; record the policy amendment).
--   Articles 1 (write via canonical confirm_machines_to_visit, no raw UPDATE), 4 (via_rpc/rpc_name +
--   role gate intact; nested confirm sets its own), 5 (confirmed_at still transitions via the explicit
--   RPC), 8 (audit via the writers), 11 (cron still calls an RPC, command unchanged), 12 (forward-only;
--   CREATE OR REPLACE in a new migration, no table drop, no edit-in-place), 14 (no parallel table).
--   No Article 6 concern. Hard Rule 10 (conductor): in-session core-writer change — CS green light required.

CREATE OR REPLACE FUNCTION public.build_draft_for_confirmed(p_plan_date date DEFAULT (CURRENT_DATE + 1))
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '1200000'
AS $function$
DECLARE
  v_user_id   uuid;
  v_picked    int;
  v_confirmed int;
  v_included  int;
  v_auto_conf jsonb;
  v_add       jsonb;
  v_swap      jsonb;
  v_final     jsonb;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'build_draft_for_confirmed', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role IN ('operator_admin', 'superadmin')
  ) THEN
    RETURN jsonb_build_object('status', 'error',
      'message', 'unauthorized: requires operator_admin or superadmin');
  END IF;
  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;

  -- AUTO-CONFIRM (refill fix 2026-06-07): drafts are non-committal; real gates are approve + stitch.
  -- Canonical writer, idempotent, service-role bypass for the cron. Kills the Gate-0 deadlock.
  v_auto_conf := public.confirm_machines_to_visit(p_plan_date);

  SELECT
    COUNT(*) FILTER (WHERE status = 'picked'),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL),
    COUNT(*) FILTER (WHERE status IN ('picked','cs_added') AND confirmed_at IS NOT NULL AND COALESCE(is_included, true) = true)
  INTO v_picked, v_confirmed, v_included
  FROM public.machines_to_visit
  WHERE plan_date = p_plan_date;

  BEGIN
    PERFORM public._assert_gate_zero(p_plan_date);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('status', 'awaiting_confirmation',
      'plan_date', p_plan_date, 'confirmed', v_confirmed, 'picked', v_picked);
  END;

  IF v_included = 0 THEN
    RETURN jsonb_build_object('status', 'no_included_machines',
      'plan_date', p_plan_date, 'confirmed', v_confirmed);
  END IF;

  v_add   := engine_add_pod(p_plan_date, 14);
  v_swap  := engine_swap_pod(p_plan_date, 2, 0.30, 14);
  -- STAGE 2c (refill fix 2026-06-07): materialize pod_refill_plan so the FE "Load draft" has rows.
  v_final := engine_finalize_pod(p_plan_date);

  RETURN jsonb_build_object(
    'status', 'draft_ready',
    'plan_date', p_plan_date,
    'machines_picked', v_picked,
    'machines_confirmed', v_confirmed,
    'machines_included', v_included,
    'auto_confirmed', v_auto_conf,
    'stage_2a', v_add,
    'stage_2b', v_swap,
    'stage_2c', v_final
  );
END;
$function$;
