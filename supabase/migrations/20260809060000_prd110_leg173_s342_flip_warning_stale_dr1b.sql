-- PRD-110 leg 173 — S-342: the flip's SUCCESS payload stated a falsehood.
--
-- flip_cluster_to_v3_v3's 'applied' return carried:
--   "the ADD engines are whole-plan-date scoped: until DR-1b ships, the nightly
--    builder will REFUSE to build while any cluster is on v3"
-- DR-1b shipped in leg 161 (migration 20260808…): the HALT became a BRANCH.
-- _build_draft_core_v3 still CALLS cutover_block_reason_v3, but uses it as the branch
-- predicate, not a halt, and engine_add_pod's plan-date-wide DELETE is now the DR-1b
-- scoped wipe. Verified live this leg: no RAISE follows the call site.
--
-- CS reads this string at the instant a flip succeeds (~Aug 17). The most likely
-- reaction to it is an unnecessary revert_cluster_to_v19_v3 — a stale sentence talking
-- a correct cutover back out of existence.
--
-- SCOPE: the string only. No signature change, no logic change, no flag flipped, no
-- decision rule touched. S-341 (the WMAPE population mismatch) is a CS ruling and stays
-- parked. S-313 (the same staleness inside cutover_block_reason_v3) is NOT touched here:
-- it is unreachable through the builder and is byte-pinned by fixture 74 seq 65/66.
--
-- BLAST RADIUS (verified live, not assumed):
--   • ZERO golden assertions read flip_cluster_to_v3_v3.prosrc
--   • ZERO assertions read the returned 'warning' key (fixture 60 seq 39/40 are the
--     miner warnings, unrelated)
--   • fixtures 47, 74, 75, 77 call the RPC in scenario_sql — re-fired as proof
--
-- PRE-IMAGE GUARD: md5(prosrc) = ba5dc8a5b5e3e5c3035b36682e06580e

DO $guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'flip_cluster_to_v3_v3'
      AND md5(prosrc) = 'ba5dc8a5b5e3e5c3035b36682e06580e'
  ) THEN
    RAISE EXCEPTION 'S-342 pre-image guard failed: flip_cluster_to_v3_v3 is not at the '
                    'expected md5 ba5dc8a5b5e3e5c3035b36682e06580e. Someone changed it '
                    'since leg 173 read it. Re-derive the body before replacing it.';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.flip_cluster_to_v3_v3(p_cluster_key text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor   uuid;
  v_role    text;
  v_ready   public.v_cutover_readiness_v3%ROWTYPE;
  v_evid    jsonb;
  v_from    text;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'flip_cluster_to_v3_v3', true);

  IF p_cluster_key IS NULL OR btrim(p_cluster_key) = '' THEN
    RAISE EXCEPTION 'p_cluster_key required';
  END IF;
  -- The 10-char floor is the pod_inventory_edit idiom: the audit row must be worth reading later.
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required, minimum 10 characters (got %)', COALESCE(length(btrim(p_reason)), 0);
  END IF;

  v_actor := auth.uid();
  IF v_actor IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_actor;
    IF v_role NOT IN ('operator_admin','superadmin') THEN
      RAISE EXCEPTION 'unauthorized: cutover requires operator_admin or superadmin (caller is %)', v_role;
    END IF;
  END IF;

  SELECT * INTO v_ready FROM public.v_cutover_readiness_v3 WHERE cluster_key = p_cluster_key;

  IF NOT FOUND THEN
    v_evid := jsonb_build_object('cluster_key', p_cluster_key, 'found', false);
    INSERT INTO public.engine_cutover_audit_v3
      (cluster_key, action, outcome, refusal_code, from_engine, to_engine, reason, evidence, actor, actor_role)
    VALUES (p_cluster_key, 'flip_to_v3', 'refused', 'cluster_not_live', NULL, 'v3', p_reason, v_evid, v_actor, v_role);
    RETURN jsonb_build_object('outcome','refused','refusal_code','cluster_not_live',
                              'cluster_key', p_cluster_key,
                              'message','no ACTIVE machines carry this venue_group');
  END IF;

  v_evid := to_jsonb(v_ready) || jsonb_build_object('evaluated_at', now());
  v_from := v_ready.authoritative_engine;

  IF v_ready.refusal_code <> 'ready' THEN
    -- ⭐ A REFUSED FLIP IS AUDITED. "CS tried to flip VOX on Aug 17 and the gate said no" is the
    --   most interesting row this table will ever hold; an audit of successes only would drop it.
    INSERT INTO public.engine_cutover_audit_v3
      (cluster_key, action, outcome, refusal_code, from_engine, to_engine, reason, evidence, actor, actor_role)
    VALUES (p_cluster_key, 'flip_to_v3', 'refused', v_ready.refusal_code, v_from, 'v3', p_reason, v_evid, v_actor, v_role);
    RETURN jsonb_build_object('outcome','refused','refusal_code', v_ready.refusal_code,
                              'cluster_key', p_cluster_key,
                              'wmape_v3', v_ready.wmape_v3, 'wmape_v19', v_ready.wmape_v19,
                              'n_settled_v3', v_ready.n_settled_v3,
                              'evidence', v_evid);
  END IF;

  UPDATE public.engine_cutover_authority_v3
     SET authoritative_engine = 'v3',
         flipped_at           = now(),
         flipped_by           = v_actor,
         flip_reason          = p_reason,
         flip_evidence        = v_evid,
         n_machines_at_flip   = v_ready.n_machines_active,
         updated_at           = now(),
         updated_by           = v_actor
   WHERE cluster_key = p_cluster_key;

  INSERT INTO public.engine_cutover_audit_v3
    (cluster_key, action, outcome, refusal_code, from_engine, to_engine, reason, evidence, actor, actor_role)
  VALUES (p_cluster_key, 'flip_to_v3', 'applied', NULL, v_from, 'v3', p_reason, v_evid, v_actor, v_role);

  RETURN jsonb_build_object('outcome','applied','cluster_key', p_cluster_key,
                            'from_engine', v_from, 'to_engine','v3',
                            'wmape_v3', v_ready.wmape_v3, 'wmape_v19', v_ready.wmape_v19,
                            'n_machines', v_ready.n_machines_active,
                            'warning','scoped per DR-1b: from the next nightly build this cluster '
                                      || 'plans with v3 while every other cluster continues on v19 for the '
                                      || 'same plan_date. Reversible with revert_cluster_to_v19_v3.');
END;
$function$;

-- ⛔ the semicolon above is NOT decoration: pg_get_functiondef emits no trailing
-- terminator, so without it the DO block below is parsed as part of the CREATE.

DO $verify$
DECLARE v_src text;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'flip_cluster_to_v3_v3';
  IF position('REFUSE to build' in v_src) > 0 OR position('until DR-1b ships' in v_src) > 0 THEN
    RAISE EXCEPTION 'S-342 post-image verify failed: the stale warning survived the replace.';
  END IF;
  IF position('Reversible with revert_cluster_to_v19_v3' in v_src) = 0 THEN
    RAISE EXCEPTION 'S-342 post-image verify failed: the corrected warning is absent.';
  END IF;
  RAISE NOTICE 'S-342 fixed: flip warning now describes the DR-1b branch, not the dead halt.';
END
$verify$;
