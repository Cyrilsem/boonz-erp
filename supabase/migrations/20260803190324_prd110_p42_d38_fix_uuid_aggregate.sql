-- PRD-110 D-38 follow-up — fix a defect in 20260803190030's record_plan_edit_v3 body.
--
-- ⛔ `min(uuid)` DOES NOT EXIST in PostgreSQL. The boonz-product resolve used
--    `CASE WHEN count(DISTINCT ...) = 1 THEN min(pm.boonz_product_id) END`, which parses fine
--    and fails at RUNTIME with 42883 the first time a below-floor edit is recorded — i.e. on
--    the ONLY path D-38 exists to serve. Aggregate coverage for uuid is not the same as for
--    int/text, and "it compiled" proves nothing about a plpgsql body.
--
-- ⭐ HOW IT WAS CAUGHT, AND WHY THAT MATTERS. Fixture 62 seq 2 is the anti-vacuity guard that
--    captures any scenario exception into a scratch field instead of letting it fall through.
--    Without it, seqs 6-12 would have read 'no_column' — the SAME value they showed in the RED
--    baseline — and the leg would have concluded "the wiring did not take" and gone hunting in
--    the substitution logic. ⛔ A fixture whose failure mode is indistinguishable from its
--    pre-change state cannot tell you WHICH thing broke. Seq 2 is what made this a two-minute
--    fix instead of a bisect.
--
-- The replacement is `(array_agg(DISTINCT ...))[1]`, which is uuid-safe and, guarded by the
-- count(DISTINCT)=1 test, provably picks the only element.

DO $fix$
DECLARE
  v_def text;
  v_new text;
  v_a   text := 'THEN min(pm.boonz_product_id) END';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'record_plan_edit_v3';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'D-38 FIX: record_plan_edit_v3 not found';
  END IF;
  IF v_def LIKE '%array_agg(DISTINCT pm.boonz_product_id)%' THEN
    RAISE NOTICE 'D-38 FIX: already applied, skipping';
    RETURN;
  END IF;
  IF (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'D-38 FIX: anchor does not appear exactly once';
  END IF;

  v_new := replace(v_def, v_a, 'THEN (array_agg(DISTINCT pm.boonz_product_id))[1] END');
  EXECUTE v_new;
END $fix$;

DO $verify$
BEGIN
  -- ⛔ S-163 again: the fix is a body edit ONLY. Same overload count, DEFINER, zero defaults,
  --    same identity arguments, same pinned search_path, same whole ACL (S-140).
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
       WHERE n.nspname='public' AND p.proname='record_plan_edit_v3'
         AND p.prosecdef AND p.pronargdefaults = 0
         AND p.proacl::text = '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
         AND p.proconfig::text = '{"search_path=public, pg_temp"}'
         AND p.prosrc LIKE '%array_agg(DISTINCT pm.boonz_product_id)%'
         AND p.prosrc NOT LIKE '%min(pm.boonz_product_id)%'
         AND pg_get_function_identity_arguments(p.oid)
             = 'p_plan_date date, p_shelf_id uuid, p_pod_product_id uuid, p_kind text, p_qty integer, p_lock text, p_reason text') <> 1 THEN
    RAISE EXCEPTION 'D-38 FIX VERIFY: record_plan_edit_v3 shape/ACL/body not as required';
  END IF;
END $verify$;
