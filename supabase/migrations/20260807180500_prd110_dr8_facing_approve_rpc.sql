-- PRD-110 DR-8 — the canonical decision writer for facing_proposals_v3.status.
-- CS ruling 2026-08-04: "BUILD THE FACING approve-RPC."
--
-- ⛔ IT IS NOT A COPY OF approve_feedback_proposal_v3, AND THE DIFFERENCE IS THE POINT.
--    facing_proposals_v3 carries CHECK fp_v3_review_named:
--        status NOT IN ('approved','rejected','applied') OR reviewed_by IS NOT NULL
--    approve_feedback_proposal_v3 tolerates auth.uid() IS NULL (feedback_proposals_v3 has no such
--    CHECK), so a transliteration of it would reach fp_v3_review_named and surface to CS as a bare
--    23514 naming a constraint instead of the missing identity. This RPC refuses the anonymous
--    caller FIRST, by name. Fixture 69 seq 20 asserts P0001-and-not-23514.
--
-- ⭐ S-128 APPLIED AS DISCLOSURE, NOT REFUSAL. approve_feedback_proposal_v3 REFUSES the
--    never_stock kind because approving it MINTS A PIN the engine ignores — a live rule that
--    lies. Approving a FACING proposal mints nothing; it records a decision. Refusing here would
--    leave CS unable to clear the queue at all. So the RPC returns an explicit
--    plan_effect = 'none_yet' that names the gap, and NEVER writes status='applied' or
--    applied_to_plan_date — those belong to a future applier that really does move a plan.
--
-- ⛔ AND THE QUEUE IT SERVES IS EMPTY TODAY (S-276, leg 145). All 20 pending rows are fixture-48
--    residue at plan_date 2030-02-18; under S-244 a CS-facing read filters plan_date < 2027-01-01,
--    so the reviewable queue is zero, and no cron mints facings (propose_facing_changes_v3 is
--    unwired). Shipping the writer is still correct — it closes an Article-1 gap and it is what
--    was ruled — but nobody may report "facing review shipped". Fixture 69 seq 44/45 measure it.

-- ⛔ CODY R1 — THE OVERLOAD GUARD, BEFORE THE CREATE.
--    CREATE OR REPLACE does not replace across a DIFFERING signature; it silently OVERLOADS.
--    On a decision writer that is the repurpose_machine foot-gun (CLAUDE.md) pointed at CS review:
--    two functions of the same name, one of them never called and never maintained. Fixture 69
--    seq 1 catches it after the fact; this refuses it before the fact.
DO $guard$
DECLARE v_other text;
BEGIN
  SELECT string_agg(pg_get_function_identity_arguments(p.oid), ' | ') INTO v_other
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'approve_facing_proposal_v3'
     AND pg_get_function_identity_arguments(p.oid) <> 'p_proposal_id uuid, p_decision text, p_review_note text';
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'DR-8 refuses to apply: approve_facing_proposal_v3 already exists with a different signature (%). CREATE OR REPLACE would overload rather than replace it. Resolve the existing function first.', v_other;
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.approve_facing_proposal_v3(
  p_proposal_id uuid,
  p_decision    text,
  p_review_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid uuid;
  pr    public.facing_proposals_v3%ROWTYPE;
  v_new text;
BEGIN
  PERFORM set_config('app.via_rpc',  'true',                          true);
  PERFORM set_config('app.rpc_name', 'approve_facing_proposal_v3',    true);

  v_uid := auth.uid();

  -- ⛔ ORDER IS LOAD-BEARING. This must be the FIRST refusal, ahead of the role check and ahead
  --    of every argument guard, because the failure it pre-empts is a CHECK violation deep in the
  --    UPDATE at the bottom. Moving it down, or deleting it as "the role check covers it", puts a
  --    bare 23514 in front of CS. Fixture 69 seq 20/22 are its tripwires.
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'approve_facing_proposal_v3: cannot decide proposal % without an identified caller; facing_proposals_v3 carries CHECK fp_v3_review_named, so a decision that cannot name its reviewer is not a decision this table can hold',
      p_proposal_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.user_profiles up
     WHERE up.id = v_uid AND up.role IN ('operator_admin','superadmin')
  ) THEN
    RAISE EXCEPTION 'approve_facing_proposal_v3: caller % is not permitted to decide facing proposals', v_uid;
  END IF;

  -- ⛔ 'applied' is deliberately NOT an accepted decision. It is a real status of this table and
  --    it belongs to a future applier, not to a reviewer.
  IF p_decision IS NULL OR p_decision NOT IN ('approve','reject') THEN
    RAISE EXCEPTION 'approve_facing_proposal_v3: decision % is not one of approve/reject',
      COALESCE(p_decision,'<null>');
  END IF;

  IF p_review_note IS NULL OR char_length(btrim(p_review_note)) < 10 THEN
    RAISE EXCEPTION 'approve_facing_proposal_v3: review_note must be at least 10 characters';
  END IF;

  SELECT * INTO pr FROM public.facing_proposals_v3
   WHERE proposal_id = p_proposal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'approve_facing_proposal_v3: proposal % not found', p_proposal_id;
  END IF;
  IF pr.status <> 'pending' THEN
    RAISE EXCEPTION 'approve_facing_proposal_v3: proposal % is already %; only pending proposals can be decided',
      p_proposal_id, pr.status;
  END IF;

  v_new := CASE WHEN p_decision = 'approve' THEN 'approved' ELSE 'rejected' END;

  -- ⛔ applied_to_plan_date IS NOT TOUCHED, AND status NEVER BECOMES 'applied'. CHECK
  --    fp_v3_applied_dated ties the two together; writing either here would claim a facing change
  --    had reached a machine when nothing did. Fixture 69 seq 33/34.
  UPDATE public.facing_proposals_v3
     SET status      = v_new,
         reviewed_by = v_uid,
         reviewed_at = now(),
         review_note = btrim(p_review_note)
   WHERE proposal_id = p_proposal_id;

  RETURN jsonb_build_object(
    'status',            v_new,
    'proposal_id',       p_proposal_id,
    'plan_date',         pr.plan_date,
    'machine_id',        pr.machine_id,
    'pod_product_id',    pr.pod_product_id,
    'direction',         pr.direction,
    'facings_current',   pr.facings_current,
    'facings_proposed',  pr.facings_proposed,
    'reviewed_by',       v_uid,
    -- ⭐ THE DISCLOSURE. Not decoration: it is the difference between "CS approved a facing
    --    change" and "CS recorded an opinion". Fixture 69 seq 31/32/42/43.
    'plan_effect',       'none_yet',
    'plan_effect_detail','recorded only: no plan object consumes facing_proposals_v3.status today, so this decision changes no refill plan, no pin and no dispatch. The one reader of the approved status is v_proposal_acceptance_v3, the G12 acceptance scoreboard. Applying a facing change to a planogram needs an applier that does not exist yet.');
END
$fn$;

ALTER FUNCTION public.approve_facing_proposal_v3(uuid, text, text) OWNER TO postgres;

-- ⛔ S-268: REVOKE ALL ... FROM PUBLIC does NOT remove Supabase's schema default privileges.
--    anon must be named explicitly or it keeps EXECUTE. Fixture 69 seq 5/6.
REVOKE ALL ON FUNCTION public.approve_facing_proposal_v3(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_facing_proposal_v3(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.approve_facing_proposal_v3(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_facing_proposal_v3(uuid, text, text) TO service_role;

COMMENT ON FUNCTION public.approve_facing_proposal_v3(uuid, text, text) IS
'PRD-110 DR-8. Canonical decision writer for facing_proposals_v3.status (approve|reject). Refuses the anonymous caller BY NAME ahead of CHECK fp_v3_review_named. Never writes status=''applied'' or applied_to_plan_date. Returns plan_effect=''none_yet'': no plan object consumes the approved status today (S-276). Proven by golden fixture 69.';
