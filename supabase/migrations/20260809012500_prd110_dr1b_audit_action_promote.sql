-- PRD-110 DR-1b · leg 161 · Object 5 — widen engine_cutover_audit_v3.action to admit 'promote'
--
-- Found by golden fixture 75, not by review: DR-1 constrained `action` to
-- {flip_to_v3, revert_to_v19}, and DR-1b's promotion writes action='promote'. The flag-off
-- no-op path returns BEFORE the audit insert, so the migration's own executed guard could
-- never reach this — only a fixture that actually flips a cluster and promotes could.
-- ⭐ That is the argument for driving the branch rather than inspecting it.
--
-- Article 7 is untouched: this widens the DOMAIN of a column on an append-only table. It adds
-- no write path, relaxes no policy, and drops no data. Article 12 is satisfied — this is a NEW
-- forward migration, not an edit of `20260808212000`.

ALTER TABLE public.engine_cutover_audit_v3
  DROP CONSTRAINT IF EXISTS engine_cutover_audit_v3_action_check;

ALTER TABLE public.engine_cutover_audit_v3
  ADD CONSTRAINT engine_cutover_audit_v3_action_check
  CHECK (action = ANY (ARRAY['flip_to_v3'::text, 'revert_to_v19'::text, 'promote'::text]));

COMMENT ON CONSTRAINT engine_cutover_audit_v3_action_check ON public.engine_cutover_audit_v3 IS
  'PRD-110 DR-1b. flip_to_v3 / revert_to_v19 are CS decisions; promote is the nightly publish of '
  'an engine_add_pod_v3 run into pod_refills for the clusters already authoritative for v3.';

-- ── post-image guards ────────────────────────────────────────────────────────────
DO $guard$
DECLARE v_def text;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint
   WHERE conrelid = 'public.engine_cutover_audit_v3'::regclass
     AND conname  = 'engine_cutover_audit_v3_action_check';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'DR-1b: the action CHECK was dropped and not replaced';
  END IF;

  -- All three verbs admitted...
  IF position('promote' in v_def) = 0
     OR position('flip_to_v3' in v_def) = 0
     OR position('revert_to_v19' in v_def) = 0 THEN
    RAISE EXCEPTION 'DR-1b: the action CHECK lost a verb: %', v_def;
  END IF;

  -- ...and the constraint still actually CONSTRAINS. A widened CHECK that admits anything is
  -- worse than the one it replaced, and reads identically in a migration diff.
  BEGIN
    INSERT INTO public.engine_cutover_audit_v3
      (cluster_key, action, outcome, refusal_code, from_engine, to_engine, reason, evidence)
    VALUES ('__dr1b_guard__', 'not_a_real_verb', 'applied', NULL, 'v19', 'v3',
            'dr1b constraint guard, must be refused', '{}'::jsonb);
    RAISE EXCEPTION 'DR-1b: the action CHECK admitted a junk verb';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'DR-1b: action CHECK widened to 3 verbs and still refuses junk';
  END;

  -- Article 7 sanity: the append-only policies are still in place.
  IF (SELECT count(*) FROM pg_policy
       WHERE polrelid = 'public.engine_cutover_audit_v3'::regclass
         AND polcmd IN ('w','d') AND pg_get_expr(polqual, polrelid) = 'false') < 2 THEN
    RAISE EXCEPTION 'DR-1b: the audit table lost its no-update/no-delete policies (Article 7)';
  END IF;
END $guard$;
