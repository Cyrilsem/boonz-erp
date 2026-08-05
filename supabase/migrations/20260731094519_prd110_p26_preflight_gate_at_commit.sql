-- ═══════════════════════════════════════════════════════════════════════════
-- PRD-110 · P2.6 · PREFLIGHT INVARIANTS BLOCKING AT COMMIT (WS-B2)
-- BUILD SPEC P2.6: "Preflight invariants -> blocking at commit incl. corrected
-- INV-06". INV-06 v2 already shipped (P0.6(d)); what was missing is the GATE:
-- commit_refill_plan performed ZERO invariant checking, so a plan with a known
-- conservation leak could be committed with nothing refusing or recording it.
--
-- SHIPS INERT. refill_policy_params.preflight_enforcement is 'warn' and stays
-- 'warn'. In warn mode the ONLY behavioural change is that the commit response
-- gains a 'preflight' block. Flipping to 'block' remains a parked CS decision
-- pending burn-in, and now arms BOTH gates (stitch and commit) with one flag.
--
-- CODY REVIEW (Articles 1, 2, 4, 7, 8, 12, 14, 16). Material finding: the first
-- design stamped consumed_at on preflight_override_log, which carries
-- pol_no_update / pol_no_delete. A SECURITY DEFINER owned by postgres would
-- have bypassed RLS and silently defeated Article 7. Consumption is therefore
-- recorded by an INSERT on the CONSUMING side: refill_commit_log names the
-- override that let it through. Both logs stay append-only.
--
-- ⛔ p_machine_ids CARRIES `DEFAULT NULL::uuid[]` AND MUST KEEP IT. A first
-- apply omitted it and Postgres refused with 42P13 "cannot remove parameter
-- defaults from existing function" - the same class as the 13-day driver-confirm
-- outage. Check pronargdefaults before ANY CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. audit shape (additive, nullable, forward-only) ──────────────────────
ALTER TABLE public.preflight_override_log
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'stitch';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.preflight_override_log'::regclass
                    AND conname  = 'chk_preflight_override_source') THEN
    ALTER TABLE public.preflight_override_log
      ADD CONSTRAINT chk_preflight_override_source CHECK (source IN ('stitch','commit'));
  END IF;
END $$;

COMMENT ON COLUMN public.preflight_override_log.source IS
  'Which gate was overridden. ''stitch'' = the inline p_force path in stitch_pod_to_boonz (the default, and correct for every pre-P2.6 row). ''commit'' = an explicit preflight_override_v3 grant consumed by commit_refill_plan.';

ALTER TABLE public.refill_commit_log
  ADD COLUMN IF NOT EXISTS preflight_verdict         text  NULL,
  ADD COLUMN IF NOT EXISTS preflight_violation_count int   NULL,
  ADD COLUMN IF NOT EXISTS preflight_override_id     uuid  NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.refill_commit_log'::regclass
                    AND conname  = 'fk_refill_commit_log_preflight_override') THEN
    ALTER TABLE public.refill_commit_log
      ADD CONSTRAINT fk_refill_commit_log_preflight_override
      FOREIGN KEY (preflight_override_id)
      REFERENCES public.preflight_override_log(override_id);
  END IF;
END $$;

COMMENT ON COLUMN public.refill_commit_log.preflight_override_id IS
  'PRD-110 P2.6. NOT NULL only when this commit was let through a FAIL verdict by an audited preflight_override_v3 grant. This column IS the consumption record: an override is spent when a commit row references it, so a grant can never be reused. Article 7 - neither log is ever UPDATEd.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_refill_commit_log_override_single_use
  ON public.refill_commit_log (preflight_override_id)
  WHERE preflight_override_id IS NOT NULL;

-- ── 2. the audited escape hatch ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.preflight_override_v3(
  p_plan_date date,
  p_reason    text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_user_id     uuid;
  v_pf          record;
  v_override_id uuid;
  v_existing    uuid;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'preflight_override_v3', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_user_id AND up.role = ANY(ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'preflight_override_v3: caller % lacks operator_admin/superadmin/manager role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN
    RAISE EXCEPTION 'preflight_override_v3: p_plan_date required';
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'preflight_override_v3: p_reason of at least 10 characters is required - the override is audited and must say WHY';
  END IF;

  SELECT * INTO v_pf FROM public.preflight_refill_plan(p_plan_date);

  -- Nothing to override. Refusing here is what stops an operator banking a
  -- blanket grant now and committing a plan that goes bad later.
  IF v_pf.verdict <> 'FAIL' THEN
    RETURN jsonb_build_object(
      'status','not_needed',
      'plan_date', p_plan_date,
      'preflight_verdict', v_pf.verdict,
      'message','Preflight does not fail for this plan_date, so there is nothing to override. Commit normally.');
  END IF;

  -- No stacking: one live grant per plan_date at a time.
  SELECT pol.override_id INTO v_existing
    FROM public.preflight_override_log pol
   WHERE pol.plan_date = p_plan_date
     AND pol.source    = 'commit'
     AND NOT EXISTS (SELECT 1 FROM public.refill_commit_log rcl
                      WHERE rcl.preflight_override_id = pol.override_id)
   ORDER BY pol.overridden_at DESC
   LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status','already_granted',
      'plan_date', p_plan_date,
      'override_id', v_existing,
      'message','An unspent commit override already exists for this plan_date. Use it or let it lapse; grants do not stack.');
  END IF;

  INSERT INTO public.preflight_override_log
    (plan_date, overridden_by, reason, verdict, violation_count, violations, invariant_versions, source)
  VALUES (p_plan_date, v_user_id, trim(p_reason), v_pf.verdict,
          jsonb_array_length(v_pf.violations), v_pf.violations, v_pf.invariant_versions, 'commit')
  RETURNING override_id INTO v_override_id;

  RETURN jsonb_build_object(
    'status','granted',
    'plan_date', p_plan_date,
    'override_id', v_override_id,
    'preflight_verdict', v_pf.verdict,
    'violation_count', jsonb_array_length(v_pf.violations),
    'message','Single-use override granted. The next commit_refill_plan for this plan_date will consume it and record the link.');
END
$fn$;

COMMENT ON FUNCTION public.preflight_override_v3(date,text) IS
  'PRD-110 P2.6. The single audited escape hatch for a blocked commit. Grants ONE single-use override for a plan_date whose preflight verdict is FAIL. Consumed by commit_refill_plan, which records the link in refill_commit_log.preflight_override_id; a grant can never be spent twice.';

REVOKE ALL ON FUNCTION public.preflight_override_v3(date,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.preflight_override_v3(date,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.preflight_override_v3(date,text) TO authenticated, service_role;

-- ── 3. the gate ────────────────────────────────────────────────────────────
-- CREATE OR REPLACE on the IDENTICAL 3-arg signature INCLUDING its default
-- (Article 12). An overload carrying extra defaulted params would make the
-- 3-arg call ambiguous; the grant-then-commit split avoids that entirely.
CREATE OR REPLACE FUNCTION public.commit_refill_plan(
  p_plan_date   date,
  p_comment     text,
  p_machine_ids uuid[] DEFAULT NULL::uuid[]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_user_id   uuid;
  v_scope     text;
  v_summary   jsonb;
  v_commit_id uuid;
  v_pf        record;
  v_enforce   text;
  v_override_id uuid;
  v_preflight jsonb;
BEGIN
  PERFORM set_config('app.via_rpc',  'true', true);
  PERFORM set_config('app.rpc_name', 'commit_refill_plan', true);

  v_user_id := auth.uid();
  IF v_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
    WHERE up.id = v_user_id AND up.role = ANY(ARRAY['operator_admin','superadmin','manager'])
  ) THEN
    RAISE EXCEPTION 'commit_refill_plan: caller % lacks operator_admin/superadmin/manager role', v_user_id;
  END IF;

  IF p_plan_date IS NULL THEN RAISE EXCEPTION 'p_plan_date required'; END IF;
  IF p_comment IS NULL OR length(trim(p_comment)) < 1 THEN
    RAISE EXCEPTION 'p_comment required (non-empty)';
  END IF;

  -- ══ P2.6 PREFLIGHT GATE ══════════════════════════════════════════════════
  -- Article 16: read the canonical object, never re-derive an invariant here.
  SELECT * INTO v_pf FROM public.preflight_refill_plan(p_plan_date);

  SELECT COALESCE(rpp.preflight_enforcement,'warn') INTO v_enforce
    FROM public.refill_policy_params rpp ORDER BY rpp.id LIMIT 1;
  v_enforce := COALESCE(v_enforce,'warn');

  IF v_pf.verdict = 'FAIL' AND v_enforce = 'block' THEN
    -- an unspent grant is one with no commit row pointing at it
    SELECT pol.override_id INTO v_override_id
      FROM public.preflight_override_log pol
     WHERE pol.plan_date = p_plan_date
       AND pol.source    = 'commit'
       AND NOT EXISTS (SELECT 1 FROM public.refill_commit_log rcl
                        WHERE rcl.preflight_override_id = pol.override_id)
     ORDER BY pol.overridden_at DESC
     LIMIT 1;

    IF v_override_id IS NULL THEN
      RETURN jsonb_build_object(
        'status','preflight_failed',
        'plan_date', p_plan_date,
        'preflight_verdict', v_pf.verdict,
        'enforcement', v_enforce,
        'violation_count', jsonb_array_length(v_pf.violations),
        'violations', v_pf.violations,
        'warnings',   v_pf.warnings,
        'invariant_versions', v_pf.invariant_versions,
        'message','Commit refused: the plan violates one or more refill invariants. Every violation carries a fix_path. Fix them and re-commit, or call preflight_override_v3(plan_date, reason) for a single-use audited override.');
    END IF;
  END IF;

  v_preflight := jsonb_build_object(
    'verdict',         v_pf.verdict,
    'enforcement',     v_enforce,
    'violation_count', jsonb_array_length(v_pf.violations),
    'warning_count',   jsonb_array_length(v_pf.warnings),
    'checked_at',      v_pf.checked_at,
    'overridden',      (v_override_id IS NOT NULL),
    'override_id',     v_override_id);
  -- ══ end P2.6 gate ════════════════════════════════════════════════════════

  v_scope := CASE WHEN p_machine_ids IS NULL OR array_length(p_machine_ids,1) IS NULL
                  THEN 'all' ELSE 'subset' END;

  WITH lines AS (
    SELECT rpo.machine_name, rpo.action
      FROM public.refill_plan_output rpo
     WHERE rpo.plan_date = p_plan_date
       AND (p_machine_ids IS NULL OR rpo.machine_name IN (
             SELECT official_name FROM public.machines WHERE machine_id = ANY(p_machine_ids)))
  ),
  by_action AS (
    SELECT action, COUNT(*) AS n FROM lines GROUP BY action
  )
  SELECT jsonb_build_object(
           'total_lines', (SELECT COUNT(*) FROM lines),
           'machines',    (SELECT COUNT(DISTINCT machine_name) FROM lines),
           'by_action',   COALESCE((SELECT jsonb_object_agg(action, n) FROM by_action), '{}'::jsonb)
         )
    INTO v_summary;

  INSERT INTO public.refill_commit_log(plan_date, comment, committed_by, machine_ids, scope, summary,
                                       via_rpc, rpc_name,
                                       preflight_verdict, preflight_violation_count, preflight_override_id)
  VALUES (p_plan_date, trim(p_comment), v_user_id, p_machine_ids, v_scope, v_summary, true, 'commit_refill_plan',
          v_pf.verdict, jsonb_array_length(v_pf.violations), v_override_id)
  RETURNING commit_id INTO v_commit_id;

  RETURN jsonb_build_object(
    'status','ok', 'commit_id', v_commit_id, 'plan_date', p_plan_date,
    'scope', v_scope, 'summary', v_summary, 'preflight', v_preflight
  );
END;
$fn$;

COMMENT ON FUNCTION public.commit_refill_plan(date,text,uuid[]) IS
  'Canonical writer for refill_commit_log. PRD-110 P2.6: consults preflight_refill_plan before committing and enforces the verdict per refill_policy_params.preflight_enforcement. warn (current) = report only; block = refuse a FAIL unless an unspent preflight_override_v3 grant exists, which this consumes by reference.';
