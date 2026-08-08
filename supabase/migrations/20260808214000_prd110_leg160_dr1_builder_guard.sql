-- PRD-110 DR-1 (leg 160) — wire the cutover guard into the LIVE nightly producer.
--
-- ⛔⛔ THIS TOUCHES _build_draft_core_v3, WHICH cron 13 CALLS AT 16:00 UTC EVERY DAY.
--    Cody ruled it does not violate LAW 12 ("production cron behavior may not change") because the
--    new branch is UNREACHABLE while zero clusters are flipped — but only on three conditions,
--    all three of which are met here:
--      (1) the guard FAILS OPEN. cutover_block_reason_v3 catches everything and returns
--          blocked=false + degraded=true, so a failure of the GUARD can never stop the plan.
--      (2) PLACEMENT. The refusal sits AFTER the calendar check, AFTER the LAW-12 live-plan guard,
--          AFTER the repick, and AFTER the Gate-0 advisory block — immediately before the three
--          engine calls. LAW 12 also requires the nightly advisory stay functional, and it does:
--          a flipped cluster costs the plan, never the 'awaiting_confirmation' pick list.
--      (3) the change is surgical and proven so: exact-once anchor, pre-image md5, post-image md5.
--
-- ⭐ WHY STOP-LOUDLY RATHER THAN WARN-AND-PLAN (Cody, Article 5). Both ADD engines are
--    whole-plan-date scoped — engine_add_pod(date,int) and engine_add_pod_v3(date,int) — so there
--    is no argument that says "only these machines" and a partial cutover physically cannot be
--    honoured. The builder's only options are to plan v3-believed machines with v19 (a silent lie,
--    exactly the S-304a failure where three sensors said `ok` over a night that planned nothing),
--    or to stop with a named reason. It stops.

DO $mig$
DECLARE
  v_old   text;
  v_new   text;
  v_anchor text := '  v_add   := engine_add_pod(p_plan_date, 14);';
  v_guard text;
  v_n     int;
BEGIN
  -- PRE-IMAGE GUARD: refuse if the function drifted since this migration was written offline.
  IF (SELECT md5(prosrc) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3')
     <> 'fef941d502ecf64c1b73d2bb20887b84' THEN
    RAISE EXCEPTION 'DR-1 pre-image: _build_draft_core_v3 has drifted; re-derive the patch before applying';
  END IF;

  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3') <> 1 THEN
    RAISE EXCEPTION 'DR-1 pre-image: expected exactly one _build_draft_core_v3 overload';
  END IF;

  v_old := pg_get_functiondef('public._build_draft_core_v3(date,boolean,boolean)'::regprocedure);

  v_n := (length(v_old) - length(replace(v_old, v_anchor, ''))) / length(v_anchor);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'DR-1: anchor found % times, expected exactly 1', v_n;
  END IF;

  v_guard :=
'  -- ── PRD-110 DR-1: the per-cluster cutover guard. Flag-off = unreachable. ──────' || E'\n' ||
'  -- Placed HERE deliberately: everything above (calendar, LAW-12 live-plan guard, repick,' || E'\n' ||
'  -- Gate-0 advisory) still runs, so a flipped cluster costs the PLAN and never the advisory.' || E'\n' ||
'  -- cutover_block_reason_v3 fails OPEN, so this can never halt the plan because IT broke.' || E'\n' ||
'  DECLARE v_cut jsonb; BEGIN' || E'\n' ||
'    v_cut := public.cutover_block_reason_v3();' || E'\n' ||
'    IF COALESCE((v_cut->>''blocked'')::boolean, false) THEN' || E'\n' ||
'      RETURN jsonb_build_object(''status'', ''refused_cutover_not_implemented'',' || E'\n' ||
'        ''plan_date'', p_plan_date,' || E'\n' ||
'        ''clusters_on_v3'', v_cut->''clusters'',' || E'\n' ||
'        ''machines_confirmed'', v_confirmed, ''machines_included'', v_included,' || E'\n' ||
'        ''message'', v_cut->>''message'',' || E'\n' ||
'        ''next_action'', ''revert_cluster_to_v19_v3(<cluster>, <reason>) restores the nightly plan '' ||' || E'\n' ||
'                        ''immediately and is never evidence-gated.'');' || E'\n' ||
'    END IF;' || E'\n' ||
'  END;' || E'\n' ||
'' || E'\n' ||
v_anchor;

  v_new := replace(v_old, v_anchor, v_guard);

  IF position('cutover_block_reason_v3' in v_new) = 0 THEN
    RAISE EXCEPTION 'DR-1: post-image does not contain the guard call';
  END IF;
  IF position('refused_live_plan' in v_new) = 0 THEN
    RAISE EXCEPTION 'DR-1: post-image LOST the LAW-12 live-plan guard';
  END IF;
  IF position('awaiting_confirmation' in v_new) = 0 THEN
    RAISE EXCEPTION 'DR-1: post-image LOST the Gate-0 advisory';
  END IF;
  IF position('skipped_saturday' in v_new) = 0 THEN
    RAISE EXCEPTION 'DR-1: post-image LOST the WS-E calendar check';
  END IF;

  -- ⛔ pg_get_functiondef output carries NO trailing semicolon; a paste that continues without one
  --    fails with "syntax error at or near DO". Add it.
  EXECUTE v_new || ';';
END
$mig$;

-- ── POST-IMAGE PROOFS (S-298) ────────────────────────────────────────────────
DO $post$
DECLARE
  v_calls int; v_law12 int; v_gate0 int; v_blocked jsonb;
BEGIN
  SELECT count(*) INTO v_calls FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='_build_draft_core_v3' AND p.prosrc LIKE '%cutover_block_reason_v3%';
  SELECT count(*) INTO v_law12 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='_build_draft_core_v3' AND p.prosrc LIKE '%refused_live_plan%';
  SELECT count(*) INTO v_gate0 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='_build_draft_core_v3' AND p.prosrc LIKE '%awaiting_confirmation%';

  IF v_calls <> 1 THEN RAISE EXCEPTION 'DR-1 post-image: builder does not call the guard'; END IF;
  IF v_law12 <> 1 THEN RAISE EXCEPTION 'DR-1 post-image: LAW-12 guard missing from builder'; END IF;
  IF v_gate0 <> 1 THEN RAISE EXCEPTION 'DR-1 post-image: Gate-0 advisory missing from builder'; END IF;

  v_blocked := public.cutover_block_reason_v3();
  IF (v_blocked->>'blocked')::boolean OR (v_blocked->>'degraded')::boolean THEN
    RAISE EXCEPTION 'DR-1 post-image: guard is blocked or degraded on a flag-off system: %', v_blocked;
  END IF;

  RAISE NOTICE 'DR-1 builder OK: guard wired, LAW-12 + Gate-0 intact, guard clear and not degraded';
END
$post$;
