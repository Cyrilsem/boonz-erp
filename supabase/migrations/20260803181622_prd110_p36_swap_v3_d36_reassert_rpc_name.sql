-- PRD-110 P3.6 / CS DECISION D-36 — EXECUTE the answer: re-assert app.rpc_name after each
-- inner call in swap_v3. No signature change, no new overload, no grant change.
--
-- Proof this fixes something real: fixture 54 seq 62/65/66 are RED on the body this migration
-- replaces (measured, not assumed — seq 62 read 'record_plan_edit_v3'). seq 64 is GREEN both
-- before and after, which is what establishes that seq 62 measures the inner calls rather than
-- the probe.
--
-- ⛔ CS explicitly chose option (a) over (b) "pass an origin argument through the writer",
--    because (b) changes a live signature and re-opens the pronargdefaults overload foot-gun.
--    This migration therefore edits the BODY ONLY, by substitution over pg_get_functiondef()
--    against two anchors each verified to match exactly once.
--
-- ⭐ Placement is after EACH inner call, not once on the way out. Externally the two are
--    indistinguishable today, but "after each" is the property that survives a third leg being
--    appended later — which is why fixture 54 seq 65 pins the tail after the LAST inner call
--    and seq 66 scales with the leg count instead of pinning a literal.

DO $mig$
DECLARE
  v_def    text;
  v_new    text;
  v_acl_be text;
  v_acl_af text;
  a1_old   text := $a1o$      v_reason || ' [leg:drop out=' || COALESCE(v_pod_out_nm,'?') || ']');
  END IF;$a1o$;
  a1_new   text := $a1n$      v_reason || ' [leg:drop out=' || COALESCE(v_pod_out_nm,'?') || ']');
    -- D-36 (CS: RE-ASSERT). record_plan_edit_v3 has just overwritten app.rpc_name with
    -- its own name, and set_config is TRANSACTION-scoped rather than statement-scoped,
    -- so without this the drop leg's writer would own the provenance for everything
    -- that follows in this transaction.
    PERFORM set_config('app.rpc_name', 'swap_v3', true);
  END IF;$a1n$;
  a2_old   text := $a2o$              ELSE ' [source:warehouse]' END);$a2o$;
  a2_new   text := $a2n$              ELSE ' [source:warehouse]' END);

  -- D-36 (CS: RE-ASSERT) after the LAST inner call, so swap_v3 RETURNS owning its own
  -- provenance and the next audited write in this transaction is stamped with the act
  -- the human performed rather than with the inner writer.
  PERFORM set_config('app.rpc_name', 'swap_v3', true);$a2n$;
BEGIN
  SELECT pg_get_functiondef(p.oid), COALESCE(p.proacl::text,'<null>')
    INTO v_def, v_acl_be
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'swap_v3';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'D-36: public.swap_v3 not found';
  END IF;

  -- Exactly one overload, or a substitution edit is aimed at the wrong body.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'swap_v3') <> 1 THEN
    RAISE EXCEPTION 'D-36: expected exactly one swap_v3 overload';
  END IF;

  -- Article 12: forward-only does not imply re-application-safe. A second run must not
  -- append a second copy of each re-assert.
  IF (SELECT count(*) FROM regexp_matches(v_def, 'set_config\(''app\.rpc_name'', ''swap_v3''', 'g')) >= 3 THEN
    RAISE NOTICE 'D-36 already applied to swap_v3; nothing to do';
    RETURN;
  END IF;

  IF position(a1_old in v_def) = 0 THEN RAISE EXCEPTION 'D-36: drop-leg anchor not found'; END IF;
  IF position(a2_old in v_def) = 0 THEN RAISE EXCEPTION 'D-36: add-leg anchor not found';  END IF;

  v_new := replace(v_def, a1_old, a1_new);
  v_new := replace(v_new, a2_old, a2_new);

  IF v_new = v_def THEN RAISE EXCEPTION 'D-36: substitution produced no change'; END IF;

  EXECUTE v_new;

  -- S-140: read the ACL back and compare the WHOLE string. CREATE OR REPLACE preserves
  -- privileges, and this asserts it rather than trusting it.
  SELECT COALESCE(p.proacl::text,'<null>') INTO v_acl_af
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'swap_v3';

  IF v_acl_af IS DISTINCT FROM v_acl_be THEN
    RAISE EXCEPTION 'D-36: swap_v3 ACL changed: % -> %', v_acl_be, v_acl_af;
  END IF;
END $mig$;

-- POST-CONDITIONS, asserted in the same migration: nothing half-applied.
DO $verify$
DECLARE
  v_src   text;
  v_parts text[];
  v_inner int;
  v_re    int;
  v_def   boolean;
  v_path  text;
  v_ndef  int;
BEGIN
  SELECT p.prosrc, p.prosecdef,
         COALESCE(array_to_string(p.proconfig, ','), '<none>'),
         p.pronargdefaults
    INTO v_src, v_def, v_path, v_ndef
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'swap_v3';

  v_parts := regexp_split_to_array(v_src, 'record_plan_edit_v3\(');
  v_inner := array_length(v_parts,1) - 1;
  SELECT count(*) INTO v_re
    FROM regexp_matches(v_src, 'set_config\(''app\.rpc_name'', ''swap_v3''', 'g');

  IF v_inner < 2 THEN
    RAISE EXCEPTION 'D-36: swap_v3 no longer routes both legs through record_plan_edit_v3 (found %)', v_inner;
  END IF;
  IF v_re - 1 < v_inner THEN
    RAISE EXCEPTION 'D-36: % re-asserts do not cover % inner calls', v_re, v_inner;
  END IF;
  IF v_parts[array_length(v_parts,1)] NOT LIKE '%set_config(''app.rpc_name'', ''swap_v3''%' THEN
    RAISE EXCEPTION 'D-36: no re-assert after the LAST inner call';
  END IF;

  -- Article 4: the security posture is unchanged by a body edit.
  IF NOT v_def THEN RAISE EXCEPTION 'D-36: swap_v3 lost SECURITY DEFINER'; END IF;
  IF v_path NOT LIKE '%search_path%' THEN
    RAISE EXCEPTION 'D-36: swap_v3 lost its pinned search_path (proconfig=%)', v_path;
  END IF;

  -- CODY R1: p_qty and p_cross_machine_source are defaulted, so every 5-argument caller
  -- depends on pronargdefaults surviving the replace. pg_get_functiondef does emit the
  -- DEFAULT clauses, but "should survive" is precisely the assumption behind the 13-day
  -- driver-confirm outage in the Wave-2 closeout. Assert it.
  IF v_ndef <> 2 THEN
    RAISE EXCEPTION 'D-36: swap_v3 pronargdefaults is %, expected 2 - 5-arg callers would break', v_ndef;
  END IF;

  RAISE NOTICE 'D-36 applied: % inner calls, % asserts, % defaults, search_path pinned, SECURITY DEFINER intact',
    v_inner, v_re, v_ndef;
END $verify$;
