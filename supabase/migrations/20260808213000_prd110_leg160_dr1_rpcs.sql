-- PRD-110 DR-1 (leg 160) — the cutover RPCs.
-- Article 1: flip_cluster_to_v3_v3 / revert_cluster_to_v19_v3 are the ONLY write paths to
-- engine_cutover_authority_v3 (RLS blocks UPDATE/DELETE for authenticated; no INSERT policy).
-- Article 4: both set app.via_rpc + app.rpc_name and validate role and inputs.
-- Article 5: the status column transitions through these two verbs or not at all.

-- ── 1. THE READ PREDICATE — what the Phase 5 write path will consult ─────────
-- Cody: SECURITY INVOKER, not DEFINER. It is read-only and the registry's SELECT policy already
-- admits `authenticated`; a DEFINER here would be privilege for no reason.
CREATE OR REPLACE FUNCTION public.is_cluster_authoritative_v3(p_machine_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $fn$
  SELECT EXISTS (
    SELECT 1
      FROM public.machines m
      JOIN public.engine_cutover_authority_v3 a ON a.cluster_key = m.venue_group
     WHERE m.machine_id = p_machine_id
       AND a.authoritative_engine = 'v3');
$fn$;

COMMENT ON FUNCTION public.is_cluster_authoritative_v3(uuid) IS
 'PRD-110 DR-1. TRUE when this machine''s cluster has been cut over to v3. FALSE for every machine '
 'while the unit ships flag-off. The predicate Phase 5''s write path (DR-1b) will branch on.';

-- ── 2. THE BUILDER'S GUARD — and the fail-open contract Cody made blocking ───
CREATE OR REPLACE FUNCTION public.cutover_block_reason_v3()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_clusters text[];
BEGIN
  SELECT array_agg(cluster_key ORDER BY cluster_key)
    INTO v_clusters
    FROM public.engine_cutover_authority_v3
   WHERE authoritative_engine = 'v3';

  IF v_clusters IS NULL OR cardinality(v_clusters) = 0 THEN
    RETURN jsonb_build_object('blocked', false, 'clusters', '[]'::jsonb, 'degraded', false);
  END IF;

  RETURN jsonb_build_object(
    'blocked',  true,
    'clusters', to_jsonb(v_clusters),
    'degraded', false,
    'message',  'cluster(s) ' || array_to_string(v_clusters, ', ') || ' are authoritative for v3, '
                || 'but the ADD engines are whole-plan-date scoped so a partial cutover cannot be '
                || 'honoured. Run revert_cluster_to_v19_v3 to resume the nightly plan, or ship DR-1b.');
EXCEPTION WHEN OTHERS THEN
  -- ⛔⛔ FAIL OPEN. This guard sits in the LIVE nightly producer (cron 13, 16:00 UTC). If its own
  --    read fails — table missing, permission denied, anything — the nightly plan must still be
  --    built. A guard that can halt production because IT broke is worse than no guard at all.
  --    `degraded` is how that shows up in the return payload instead of hiding.
  RETURN jsonb_build_object('blocked', false, 'clusters', '[]'::jsonb, 'degraded', true,
                            'sqlstate', SQLSTATE, 'message', 'cutover authority unreadable; '
                            || 'defaulting to v19 and proceeding: ' || SQLERRM);
END;
$fn$;

COMMENT ON FUNCTION public.cutover_block_reason_v3() IS
 'PRD-110 DR-1. Asked once per nightly build by _build_draft_core_v3. Returns blocked=false while '
 'no cluster is cut over. FAILS OPEN (degraded=true) if the authority read itself errors.';

-- ── 3. THE FLIP — evidence-gated, audited either way ─────────────────────────
CREATE OR REPLACE FUNCTION public.flip_cluster_to_v3_v3(p_cluster_key text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
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
                            'warning','the ADD engines are whole-plan-date scoped: until DR-1b ships, '
                                      || 'the nightly builder will REFUSE to build while any cluster is on v3');
END;
$fn$;

-- ── 4. THE REVERT — ⭐ NEVER EVIDENCE-GATED ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.revert_cluster_to_v19_v3(p_cluster_key text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_actor uuid;
  v_role  text;
  v_from  text;
BEGIN
  PERFORM set_config('app.via_rpc', 'true', true);
  PERFORM set_config('app.rpc_name', 'revert_cluster_to_v19_v3', true);

  IF p_cluster_key IS NULL OR btrim(p_cluster_key) = '' THEN
    RAISE EXCEPTION 'p_cluster_key required';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'p_reason required, minimum 10 characters (got %)', COALESCE(length(btrim(p_reason)), 0);
  END IF;

  v_actor := auth.uid();
  IF v_actor IS NOT NULL THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_actor;
    IF v_role NOT IN ('operator_admin','superadmin') THEN
      RAISE EXCEPTION 'unauthorized: cutover revert requires operator_admin or superadmin (caller is %)', v_role;
    END IF;
  END IF;

  SELECT authoritative_engine INTO v_from
    FROM public.engine_cutover_authority_v3 WHERE cluster_key = p_cluster_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cluster % is not in the cutover registry', p_cluster_key;
  END IF;

  -- ⭐⭐ NO EVIDENCE CHECK, DELIBERATELY AND PERMANENTLY. A rollback blocked by the same gate that
  --    blocks the forward path is not a rollback, it is a trap. The whole point of this verb is
  --    that it works at 02:00 when a cutover has gone wrong and nobody wants to argue with a view.
  UPDATE public.engine_cutover_authority_v3
     SET authoritative_engine = 'v19',
         flipped_at           = NULL,
         flipped_by           = NULL,
         flip_reason          = NULL,
         flip_evidence        = NULL,
         n_machines_at_flip   = NULL,
         updated_at           = now(),
         updated_by           = v_actor
   WHERE cluster_key = p_cluster_key;

  INSERT INTO public.engine_cutover_audit_v3
    (cluster_key, action, outcome, refusal_code, from_engine, to_engine, reason, evidence, actor, actor_role)
  VALUES (p_cluster_key, 'revert_to_v19', 'applied', NULL, v_from, 'v19', p_reason,
          jsonb_build_object('reverted_from', v_from, 'gated', false, 'reverted_at', now()), v_actor, v_role);

  RETURN jsonb_build_object('outcome','applied','cluster_key', p_cluster_key,
                            'from_engine', v_from, 'to_engine','v19', 'evidence_gated', false);
END;
$fn$;

-- ── 5. GRANTS — S-268: name `anon` explicitly, give it nothing ───────────────
REVOKE ALL ON FUNCTION public.flip_cluster_to_v3_v3(text,text)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revert_cluster_to_v19_v3(text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_cluster_authoritative_v3(uuid)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cutover_block_reason_v3()           FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.flip_cluster_to_v3_v3(text,text)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.revert_cluster_to_v19_v3(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_cluster_authoritative_v3(uuid)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.cutover_block_reason_v3()           TO authenticated;

-- ── 6. POST-IMAGE PROOFS (S-298) ────────────────────────────────────────────
DO $post$
DECLARE
  v_blocked jsonb; v_auth int; v_anon int;
BEGIN
  v_blocked := public.cutover_block_reason_v3();
  IF (v_blocked->>'blocked')::boolean THEN
    RAISE EXCEPTION 'DR-1 post-image: guard reports BLOCKED on a flag-off system: %', v_blocked;
  END IF;
  IF (v_blocked->>'degraded')::boolean THEN
    RAISE EXCEPTION 'DR-1 post-image: guard is DEGRADED — its own read failed: %', v_blocked;
  END IF;

  SELECT count(*) INTO v_auth FROM public.machines m
   WHERE m.status='Active' AND public.is_cluster_authoritative_v3(m.machine_id);
  IF v_auth <> 0 THEN RAISE EXCEPTION 'DR-1 post-image: LAW 4 VIOLATED — % machine(s) authoritative for v3', v_auth; END IF;

  SELECT count(*) INTO v_anon FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public'
     AND p.proname IN ('flip_cluster_to_v3_v3','revert_cluster_to_v19_v3','is_cluster_authoritative_v3','cutover_block_reason_v3')
     AND has_function_privilege('anon', p.oid, 'EXECUTE');
  IF v_anon <> 0 THEN RAISE EXCEPTION 'DR-1 post-image: anon holds EXECUTE on % cutover function(s)', v_anon; END IF;

  RAISE NOTICE 'DR-1 RPCs OK: guard clear and not degraded, 0 machines authoritative, anon holds nothing';
END
$post$;
