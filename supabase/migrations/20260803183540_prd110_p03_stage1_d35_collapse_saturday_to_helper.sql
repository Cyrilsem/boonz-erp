-- PRD-110 P0.3 / CS DECISION D-35 — THE COLLAPSE. Body substitution, no signature change.
--
-- CS: "COLLAPSE the inline Saturday rule in _build_draft_core_v3 into the canonical helper;
-- agreement fixture required." The fixture is golden 61, applied in the previous migration
-- and RED on seq 4/5 against today's body. This migration greens it.
--
-- WHAT CHANGES: one IF condition. `EXTRACT(DOW FROM p_plan_date) = 6` becomes
-- `NOT public.is_refill_planning_day_v3(p_plan_date)`. Nothing else — not the branch, not
-- the returned payload, not the signature, not the ACL, not the pinned GUCs.
--
-- ⛔ SEMANTICS-PRESERVING ONLY BECAUSE OF WHAT SITS ABOVE IT. The helper is
-- `p IS NOT NULL AND EXTRACT(DOW FROM p) <> 6` — a STRICTLY LARGER guard set than the
-- inline rule. On a NULL date the inline rule is NULL (branch not taken) while
-- `NOT helper(NULL)` is TRUE (branch taken), which would turn a raise into a
-- 'skipped_saturday'. It is safe here, and only here, because `IF p_plan_date IS NULL THEN
-- RAISE` executes three lines earlier, so the extra guard is already discharged. Verified
-- structurally below (the RAISE must still precede the branch) rather than assumed.
--
-- ⛔ LAW 12. This is the live Stage 1 engine behind cron 13
-- (build_draft_for_confirmed_v3 → _build_draft_core_v3). Production behaviour must not
-- change, and the nightly advisory must still work the same night. That is precisely what
-- fixture 61 seq 7/8/9/10 assert: the two calendars agreed across a full week before this
-- migration and must still agree after it. A behaviour change here would show up as a
-- disagreement, not as a silent pass.
--
-- ⛔ S-163. The verify block asserts pronargdefaults, prosecdef, BOTH pinned GUCs, the WHOLE
-- ACL string read back (S-140), the identity arguments and the overload count. The 13-day
-- driver-confirm outage came from a CREATE OR REPLACE that dropped defaults unnoticed.

DO $mig$
DECLARE
  v_def       text;
  v_new       text;
  v_anchor    text;
  v_replace   text;
  v_n         int;
  v_acl_pre   text;
  v_acl_post  text;
  v_cfg_post  text[];
  v_src       text;
  v_ident     text;
BEGIN
  ----------------------------------------------------------------------------------------
  -- 0. Pre-flight. Exactly one overload, and capture the ACL BEFORE touching anything.
  ----------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-35: expected exactly 1 _build_draft_core_v3 overload, found %', v_n;
  END IF;

  SELECT pg_get_functiondef(p.oid), COALESCE(p.proacl::text, '<null>'), p.prosrc
    INTO v_def, v_acl_pre, v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3';

  ----------------------------------------------------------------------------------------
  -- 1. Idempotency. Re-applying this migration must be a no-op, not a second substitution.
  ----------------------------------------------------------------------------------------
  IF v_src ~ 'is_refill_planning_day_v3\(' THEN
    RAISE NOTICE 'D-35: _build_draft_core_v3 already asks the canonical helper - no-op.';
    RETURN;
  END IF;

  ----------------------------------------------------------------------------------------
  -- 2. The NULL guard must still precede the branch, or the collapse is NOT
  --    semantics-preserving (see header). Positional, measured on the live body.
  ----------------------------------------------------------------------------------------
  -- ⛔ CODY R3: check each landmark EXISTS before comparing positions. position() returns 0
  --    for "not found", so a bare `guard_pos > dow_pos` comparison reports "the guard moved"
  --    when the truth is "the branch is gone" - a correct refusal with a wrong diagnosis.
  IF v_def IS NULL OR v_src IS NULL THEN
    RAISE EXCEPTION 'D-35: could not read _build_draft_core_v3 back from pg_proc';
  END IF;
  IF position('EXTRACT(DOW FROM p_plan_date) = 6' in v_src) = 0 THEN
    RAISE EXCEPTION 'D-35 REFUSED: the inline Saturday branch is not where D-35 says it is. '
                    'The body has drifted - re-derive the premise live (S-158) before forcing this.';
  END IF;
  IF position('IF p_plan_date IS NULL THEN RAISE EXCEPTION' in v_src) = 0 THEN
    RAISE EXCEPTION 'D-35 REFUSED: the NULL-date RAISE is gone. The helper guards NULL and the '
                    'inline rule does not, so without that RAISE upstream this substitution '
                    'would turn a raise into a silent skipped_saturday.';
  END IF;
  IF position('IF p_plan_date IS NULL THEN RAISE EXCEPTION' in v_src)
     > position('EXTRACT(DOW FROM p_plan_date) = 6' in v_src) THEN
    RAISE EXCEPTION 'D-35 REFUSED: the NULL-date RAISE no longer precedes the Saturday '
                    'branch, so swapping in a helper that also guards NULL would change '
                    'behaviour on a NULL plan_date. Re-derive before forcing this.';
  END IF;

  ----------------------------------------------------------------------------------------
  -- 3. Substitute. The anchor must match EXACTLY ONCE, checked before the replace so a
  --    drifted body fails loudly instead of being edited in some unintended place.
  ----------------------------------------------------------------------------------------
  v_anchor :=
    '  -- PRD-035 WS-E: Saturday is a delivery day (no refill plan). Preserved verbatim from v1.' || E'\n' ||
    '  IF EXTRACT(DOW FROM p_plan_date) = 6 THEN';

  v_replace :=
    '  -- PRD-035 WS-E calendar. CS DECISION D-35: the rule is NOT restated here. Stage 1 asks' || E'\n' ||
    '  -- is_refill_planning_day_v3 by name, which is the same object run_nightly_shadow_v3 asks,' || E'\n' ||
    '  -- so the two cannot drift apart (Article 16: the illegal copy is retired, not shadowed).' || E'\n' ||
    '  -- Safe as a straight swap only because the NULL-date RAISE above already discharges the' || E'\n' ||
    '  -- helper''s extra IS NOT NULL guard; golden fixture 61 pins the agreement over a full week.' || E'\n' ||
    '  IF NOT public.is_refill_planning_day_v3(p_plan_date) THEN';

  -- Exact-substring count, deliberately NOT a regex: the anchor is 130+ characters of
  -- prose and punctuation, and hand-escaping it for regexp_matches is its own defect
  -- surface. length-delta division counts literal occurrences with nothing to escape.
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-35: anchor matched % times, expected exactly 1. Body has drifted - '
                    're-derive the anchor against pg_get_functiondef before substituting.', v_n;
  END IF;

  v_new := replace(v_def, v_anchor, v_replace);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'D-35: substitution produced an identical body';
  END IF;

  EXECUTE v_new;

  ----------------------------------------------------------------------------------------
  -- 4. VERIFY BY READING BACK. S-163 (defaults) + S-140 (whole ACL) + the pinned GUCs.
  ----------------------------------------------------------------------------------------
  SELECT p.prosrc, COALESCE(p.proacl::text, '<null>'), p.proconfig,
         pg_get_function_identity_arguments(p.oid)
    INTO v_src, v_acl_post, v_cfg_post, v_ident
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3';

  SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '_build_draft_core_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'D-35 VERIFY: overload count is now %, expected 1', v_n;
  END IF;

  IF v_ident <> 'p_plan_date date, p_repick boolean, p_auto_confirm boolean' THEN
    RAISE EXCEPTION 'D-35 VERIFY: identity arguments changed to %', v_ident;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
                    AND p.prosecdef AND p.pronargdefaults = 0) THEN
    RAISE EXCEPTION 'D-35 VERIFY: prosecdef / pronargdefaults changed (S-163)';
  END IF;

  IF v_acl_post IS DISTINCT FROM v_acl_pre THEN
    RAISE EXCEPTION 'D-35 VERIFY: proacl changed. before=% after=%', v_acl_pre, v_acl_post;
  END IF;

  IF NOT ('search_path=public' = ANY(v_cfg_post))
     OR NOT ('statement_timeout=1200000' = ANY(v_cfg_post)) THEN
    RAISE EXCEPTION 'D-35 VERIFY: pinned GUCs lost, proconfig is now %', v_cfg_post;
  END IF;

  IF (SELECT count(*) FROM regexp_matches(v_src, 'is_refill_planning_day_v3\(', 'g')) <> 1 THEN
    RAISE EXCEPTION 'D-35 VERIFY: helper is not called exactly once';
  END IF;
  IF (SELECT count(*) FROM regexp_matches(v_src, 'EXTRACT\(DOW FROM p_plan_date\)', 'g')) <> 0 THEN
    RAISE EXCEPTION 'D-35 VERIFY: an inline DOW copy survives';
  END IF;
  IF (SELECT count(*) FROM regexp_matches(v_src, 'skipped_saturday', 'g')) < 1 THEN
    RAISE EXCEPTION 'D-35 VERIFY: the Saturday exit itself was lost (S-162 class)';
  END IF;

  RAISE NOTICE 'D-35 APPLIED: Stage 1 now asks is_refill_planning_day_v3. ACL, GUCs, '
               'defaults and signature all verified unchanged.';
END $mig$
