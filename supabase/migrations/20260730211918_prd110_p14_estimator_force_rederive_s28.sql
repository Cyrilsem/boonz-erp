-- PRD-110 · S-28 half 2 · re-derive path for the P1.4 composition estimator.
--
-- WHY. estimate_shelf_composition_v3 is idempotent per (shelf, WEIMI snapshot) via
-- source_ref = 'estimator:<snapshot_at>'. Golden fixtures 20 and 22 deliberately perturb
-- per-SKU belief and then call the estimator to observe the reconciliation. Once cron 44
-- goes fleet-wide (D-08, pre-approved, ~2026-08-02) the cron consumes each snapshot FIRST,
-- so the fixtures' own calls become no-ops: fixture 22 goes honestly red (measured leg 25:
-- 7 fail / 13 pass) and fixture 20 - the EXPIRY IRON RULE (LAW 7) proof - would pass
-- VACUOUSLY, because its assertions are shaped "the expired bucket was NOT touched".
-- Leg 25 shipped the seq-89 no-op detector. This is the repair that detector exists for.
--
-- WHAT. A third argument p_force_rederive (DEFAULT false) that skips ONLY the
-- already-processed CONTINUE. Nothing else in the body changes. Force is refused
-- fleet-wide: it requires a single p_shelf_id, so an accidental mass re-derive is
-- impossible by construction.
--
-- LANDMINE (CLAUDE.md repurpose_machine foot-gun). CREATE OR REPLACE with an added
-- parameter creates an OVERLOAD, not a replacement. BOTH existing parameters carry
-- defaults, so a 2-arg and a 3-arg-all-defaults candidate would make EVERY call site
-- ambiguous - including cron 44's live `(shelf_id, false)` call. The 2-arg version is
-- therefore DROPPED in the same transaction, and the cron's 2-arg call re-resolves to
-- the 3-arg signature with p_force_rederive defaulted to false.
--
-- HOW IT IS PROVEN. The new body is derived from the LIVE prosrc by four exact
-- substitutions. Each anchor is asserted to occur exactly once before it is applied
-- (a missed anchor aborts the migration whole). The END STATE is then asserted:
-- the 3-arg function exists, the 2-arg one does not, and a reverse substitution of the
-- new body reproduces the old body BYTE-FOR-BYTE - proving nothing else moved.
-- (R25-U1's Cody revision: guard the end state, not "did the replace fire".)
--
-- CODY (leg 26): approve with revisions - Articles 1, 4, 8, 11, 12, 13, 16.
--   rev 1 (Art 12) idempotent re-run: section 0a returns a no-op if already applied.
--   rev 2 (Art 13) caller proof: section 6 executes cron 44's 2-arg positional shape.
--   rev 3 documentation: the COMMENT records the anomaly re-raise (R25-D3).

DO $mig$
DECLARE
  v_old  text;
  v_new  text;
  v_back text;
  v_probe_shelf uuid;

  a1 constant text := E'  n_cold_short int := 0;\nBEGIN\n';
  r1 constant text := E'  n_cold_short int := 0;\n  n_forced int := 0;\nBEGIN\n';

  a2 constant text := E'  SELECT composition_decay_per_day, composition_decay_per_unexplained\n';
  r2 constant text := E'  IF p_force_rederive AND p_shelf_id IS NULL THEN\n'
                   || E'    RAISE EXCEPTION ''estimate_shelf_composition_v3: p_force_rederive requires a single p_shelf_id (refusing a fleet-wide forced re-derive)'';\n'
                   || E'  END IF;\n\n'
                   || E'  SELECT composition_decay_per_day, composition_decay_per_unexplained\n';

  a3 constant text := E'      n_skipped_done := n_skipped_done + 1; CONTINUE;\n    END IF;\n';
  r3 constant text := E'      IF p_force_rederive THEN\n'
                   || E'        n_forced := n_forced + 1;\n'
                   || E'      ELSE\n'
                   || E'        n_skipped_done := n_skipped_done + 1; CONTINUE;\n'
                   || E'      END IF;\n'
                   || E'    END IF;\n';

  a4 constant text := E'    ''already_processed_skipped'', n_skipped_done,\n';
  r4 constant text := E'    ''already_processed_skipped'', n_skipped_done,\n'
                   || E'    ''force_rederive'', p_force_rederive,\n'
                   || E'    ''forced_rederive'', n_forced,\n';

  FUNCTION_MISSING constant text := 'PRD-110 S-28: the 2-arg estimate_shelf_composition_v3 was not found - refusing to guess a body';
BEGIN
  ---------------------------------------------------------------- 0a. idempotency (Article 12)
  -- A re-run must be a safe no-op, not a hard failure. If the 3-arg signature is already
  -- present and the 2-arg one is gone, this migration has already landed.
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3'
                AND pg_get_function_identity_arguments(p.oid) = 'p_shelf_id uuid, p_dry_run boolean, p_force_rederive boolean')
     AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                      WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3'
                        AND pg_get_function_identity_arguments(p.oid) = 'p_shelf_id uuid, p_dry_run boolean')
  THEN
    RAISE NOTICE 'PRD-110 S-28: already applied (3-arg present, 2-arg absent) - no-op';
    RETURN;
  END IF;

  ---------------------------------------------------------------- 0b. source of truth
  SELECT p.prosrc INTO v_old
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'estimate_shelf_composition_v3'
     AND pg_get_function_identity_arguments(p.oid) = 'p_shelf_id uuid, p_dry_run boolean';
  IF v_old IS NULL THEN RAISE EXCEPTION '%', FUNCTION_MISSING; END IF;

  ---------------------------------------------------------------- 1. anchors, each exactly once
  IF (length(v_old) - length(replace(v_old, a1, ''))) / length(a1) <> 1 THEN
    RAISE EXCEPTION 'S-28 anchor 1 (n_forced declaration) matched % times, expected exactly 1',
      (length(v_old) - length(replace(v_old, a1, ''))) / length(a1);
  END IF;
  IF (length(v_old) - length(replace(v_old, a2, ''))) / length(a2) <> 1 THEN
    RAISE EXCEPTION 'S-28 anchor 2 (fleet-force guard) matched % times, expected exactly 1',
      (length(v_old) - length(replace(v_old, a2, ''))) / length(a2);
  END IF;
  IF (length(v_old) - length(replace(v_old, a3, ''))) / length(a3) <> 1 THEN
    RAISE EXCEPTION 'S-28 anchor 3 (already-processed CONTINUE) matched % times, expected exactly 1',
      (length(v_old) - length(replace(v_old, a3, ''))) / length(a3);
  END IF;
  IF (length(v_old) - length(replace(v_old, a4, ''))) / length(a4) <> 1 THEN
    RAISE EXCEPTION 'S-28 anchor 4 (return jsonb) matched % times, expected exactly 1',
      (length(v_old) - length(replace(v_old, a4, ''))) / length(a4);
  END IF;

  ---------------------------------------------------------------- 2. derive the new body
  v_new := replace(replace(replace(replace(v_old, a1, r1), a2, r2), a3, r3), a4, r4);
  IF v_new = v_old THEN RAISE EXCEPTION 'S-28: substitution produced an identical body'; END IF;

  ---------------------------------------------------------------- 3. reverse proof, BEFORE any DDL
  v_back := replace(replace(replace(replace(v_new, r1, a1), r2, a2), r3, a3), r4, a4);
  IF v_back <> v_old THEN
    RAISE EXCEPTION 'S-28: reverse substitution did not reproduce the original body - the four edits are not the only change (old % chars, round-trip % chars)',
      length(v_old), length(v_back);
  END IF;

  ---------------------------------------------------------------- 4. drop-then-create, one txn
  DROP FUNCTION public.estimate_shelf_composition_v3(uuid, boolean);

  EXECUTE format(
    'CREATE FUNCTION public.estimate_shelf_composition_v3('
    || 'p_shelf_id uuid DEFAULT NULL::uuid, '
    || 'p_dry_run boolean DEFAULT true, '
    || 'p_force_rederive boolean DEFAULT false) '
    || 'RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS %L',
    v_new);

  -- privileges, replicated exactly from the dropped function (postgres=X, authenticated=X,
  -- service_role=X; PUBLIC and anon hold nothing).
  REVOKE ALL ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean) FROM PUBLIC;
  GRANT EXECUTE ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean)
     TO postgres, authenticated, service_role;

  COMMENT ON FUNCTION public.estimate_shelf_composition_v3(uuid, boolean, boolean) IS
    'PRD-110 P1.4 (WS-J2) composition estimator. Reconciles WEIMI pod-level counts against per-SKU belief. Idempotent per WEIMI snapshot via source_ref=estimator:<snapshot_at> (stress S4). Expired buckets are excluded from derived-decrement allocation (EXPIRY IRON RULE) and an unexplainable residual raises negative_delta_unallocatable rather than consuming them. Defaults to DRY RUN. p_force_rederive (S-28) re-derives a snapshot this shelf has already consumed - it is what lets a golden fixture perturb belief and still observe the estimator after cron 44 has run; it requires a single p_shelf_id and is REFUSED fleet-wide. NOTE: a forced re-derive re-raises count_above_capacity on a sensor-lie shelf, because anomalies are raised once per snapshot per offending shelf and are NOT idempotent the way events are (R25-D3).';

  ---------------------------------------------------------------- 5. end state
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3'
                    AND pg_get_function_identity_arguments(p.oid) = 'p_shelf_id uuid, p_dry_run boolean, p_force_rederive boolean') THEN
    RAISE EXCEPTION 'S-28 end state: the 3-arg function does not exist after CREATE';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3'
                AND pg_get_function_identity_arguments(p.oid) = 'p_shelf_id uuid, p_dry_run boolean') THEN
    RAISE EXCEPTION 'S-28 end state: the 2-arg overload still exists - cron 44 call site is ambiguous';
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3') <> 1 THEN
    RAISE EXCEPTION 'S-28 end state: expected exactly one estimate_shelf_composition_v3, found %',
      (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname='public' AND p.proname='estimate_shelf_composition_v3'
                    AND p.prosecdef AND p.proconfig @> ARRAY['search_path=public, pg_temp']) THEN
    RAISE EXCEPTION 'S-28 end state: SECURITY DEFINER / search_path not preserved';
  END IF;

  ---------------------------------------------------------------- 6. caller proof (Article 13)
  -- cron 44 issues a 2-arg POSITIONAL call: estimate_shelf_composition_v3(shelf_id, false).
  -- Resolution is decided by the signature, not by the boolean's value, so proving it with
  -- p_dry_run => true proves the call site while writing nothing. If the 2-arg overload had
  -- survived, this raises 42725 (function is not unique) and the whole migration rolls back.
  SELECT shelf_id INTO v_probe_shelf
    FROM public.v_shelf_state WHERE pod_product_id IS NOT NULL ORDER BY shelf_id LIMIT 1;
  IF v_probe_shelf IS NULL THEN
    RAISE EXCEPTION 'S-28 caller proof: no pod-bound shelf available to probe with';
  END IF;
  PERFORM public.estimate_shelf_composition_v3(v_probe_shelf, true);   -- cron 44's shape
  PERFORM public.estimate_shelf_composition_v3(NULL::uuid, true);      -- fleet dry-run shape

  ---------------------------------------------------------------- 7. the new guard actually guards
  BEGIN
    PERFORM public.estimate_shelf_composition_v3(NULL::uuid, true, true);
    RAISE EXCEPTION 'S-28: fleet-wide forced re-derive was ACCEPTED - the containment guard does not bind';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%requires a single p_shelf_id%' THEN RAISE; END IF;
  END;
END
$mig$;
