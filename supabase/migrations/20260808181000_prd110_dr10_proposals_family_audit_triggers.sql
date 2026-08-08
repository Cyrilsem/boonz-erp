-- PRD-110 · DR-10 · leg 156
-- THE FIX: the Article 8 audit trigger, installed across the WHOLE *_proposals_v3 family.
--
-- DR-10 (leg 148): a decision on a proposal minted no write_audit_log row on any table in
-- the family. Measured, not inferred: fixture 73's RED baseline run f8664987 recorded
-- no_trigger=5, wrong_fn=5, wrong_shape=5 and ZERO audit rows from five real decisions.
--
-- ⛔ THE SITE LIST IS DERIVED AT RUNTIME, BY SHAPE - IT IS NOT A HARDCODED LIST OF NAMES.
--    The parking lot named FOUR tables; the catalogue holds FIVE. A migration that pasted
--    the note's four names would have left reallocation_proposals_v3 (92 live rows) as the
--    one divergent sibling - the precise failure mode DR-10 exists to prevent, committed by
--    the fix for it. Looping over the shape predicate means this migration installs on
--    whatever the family actually IS at apply time, and its own verification block is what
--    proves the loop covered all of it.
--
-- ⭐ WHY audit_log_write('proposal_id') AND NOT audit_log_write().
--    audit_log_write COALESCEs a missing TG_ARGV[0] to 'id'. NONE of these five tables has
--    an 'id' column, so the argument-less form would not error - it would log row_pk = '?'
--    on every decision, forever, and every "is the trigger installed" check would pass.
--    dispatch_pack_confirmation carries exactly that argument-less form live today; it is
--    not copied here. Fixture 73 seq 9 is the standing assertion that keeps it out.
--
-- ADDITIVE ONLY (Article 3 / LAW 3): this migration creates triggers. It alters no column,
--    drops no object it did not create, rewrites no function, and touches not one row of
--    proposal data. audit_log_write itself is untouched - the generic writer already used by
--    43 other triggers is reused verbatim rather than forked, which is what makes this one
--    family-wide unit instead of five bespoke ones.
--
-- ⛔ THE TRIGGERS ARE NOT RETROACTIVE. Decisions already recorded in these five tables
--    (20 facing, 12 feedback, 25 rotation, 23 reallocation, 3 picker-weight rows as of
--    leg 156) have no write_audit_log history and never will - a trigger cannot audit the
--    past. Article 8 coverage begins at this migration. Recorded here so a future reader
--    does not mistake the empty history for evidence that no decision was ever made.

DO $do$
DECLARE
  r            record;
  v_created    text := '';
  v_skipped    text := '';
  v_family_n   int;
  v_no_trigger int;
  v_wrong_fn   int;
  v_wrong_shp  int;
BEGIN
  ---------------------------------------------------------------- THE FAMILY, BY SHAPE --
  CREATE TEMP TABLE _fam ON COMMIT DROP AS
    SELECT c.oid AS reloid, c.relname::text AS tbl
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r'
       AND (SELECT count(*) FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND a.attname IN ('proposal_id','status','reviewed_by','reviewed_at')) = 4;

  SELECT count(*) INTO v_family_n FROM _fam;

  -- ⛔ S-298: this guard refuses an EMPTY family, not an unexpected count. A hardcoded
  --    "must equal 5" would refuse the correct migration on the day a sixth proposal table
  --    is added - the exact shape of guard that cost leg 155 a read-back. The loop below
  --    covers whatever the family is; the verification at the end is what proves it did.
  IF v_family_n = 0 THEN
    RAISE EXCEPTION 'DR-10 REFUSED: the proposal-family shape predicate matched ZERO tables. '
                    'Either the shape changed or this is the wrong database - installing '
                    'nothing and reporting success is the failure this guard prevents.';
  END IF;

  --------------------------------------------------------------------- INSTALL --
  FOR r IN SELECT reloid, tbl FROM _fam ORDER BY tbl LOOP
    IF EXISTS (
      SELECT 1 FROM pg_trigger g
       WHERE g.tgrelid = r.reloid AND NOT g.tgisinternal
         AND g.tgfoid = 'public.audit_log_write'::regproc
         AND pg_get_triggerdef(g.oid) ILIKE '%AFTER INSERT OR DELETE OR UPDATE%'
         AND pg_get_triggerdef(g.oid) ILIKE '%FOR EACH ROW%'
         AND pg_get_triggerdef(g.oid) ILIKE '%audit_log_write(' || quote_literal('proposal_id') || ')%')
    THEN
      -- Already correctly wired. Idempotent re-apply, and the one case where doing
      -- nothing is right: re-creating it would churn the catalogue for no gain.
      v_skipped := v_skipped || r.tbl || ' ';
      CONTINUE;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', 'tg_audit_' || r.tbl, r.tbl);
    EXECUTE format(
      'CREATE TRIGGER %I AFTER INSERT OR DELETE OR UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.audit_log_write(%L)',
      'tg_audit_' || r.tbl, r.tbl, 'proposal_id');

    v_created := v_created || r.tbl || ' ';
  END LOOP;

  ------------------------------------------------------- VERIFY, IN THIS TRANSACTION --
  -- The same three counters fixture 73 reads, re-derived here so a partial install can
  -- never commit. S-140: read the catalogue BACK and assert it whole.
  SELECT count(*) INTO v_no_trigger FROM _fam f
   WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g
                      WHERE g.tgrelid = f.reloid AND NOT g.tgisinternal);

  SELECT count(*) INTO v_wrong_fn FROM _fam f
   WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g
                      WHERE g.tgrelid = f.reloid AND NOT g.tgisinternal
                        AND g.tgfoid = 'public.audit_log_write'::regproc);

  SELECT count(*) INTO v_wrong_shp FROM _fam f
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_trigger g
      WHERE g.tgrelid = f.reloid AND NOT g.tgisinternal
        AND g.tgfoid = 'public.audit_log_write'::regproc
        AND pg_get_triggerdef(g.oid) ILIKE '%AFTER INSERT OR DELETE OR UPDATE%'
        AND pg_get_triggerdef(g.oid) ILIKE '%FOR EACH ROW%'
        AND pg_get_triggerdef(g.oid) ILIKE '%audit_log_write(' || quote_literal('proposal_id') || ')%');

  IF v_no_trigger <> 0 OR v_wrong_fn <> 0 OR v_wrong_shp <> 0 THEN
    RAISE EXCEPTION 'DR-10 VERIFY FAILED: family=% no_trigger=% wrong_fn=% wrong_shape=% (created: %) (skipped: %)',
      v_family_n, v_no_trigger, v_wrong_fn, v_wrong_shp, v_created, v_skipped;
  END IF;

  RAISE NOTICE 'DR-10 OK: family=% created=[%] already_correct=[%]', v_family_n, v_created, v_skipped;
END $do$;

-- Read-back proof, outside the DO block, so the applied migration returns the evidence
-- rather than only claiming it.
SELECT c.relname            AS proposal_table,
       t.tgname             AS trigger_name,
       pg_get_triggerdef(t.oid) AS trigger_def
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE NOT t.tgisinternal
   AND n.nspname = 'public'
   AND t.tgfoid = 'public.audit_log_write'::regproc
   AND (SELECT count(*) FROM pg_attribute a
         WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
           AND a.attname IN ('proposal_id','status','reviewed_by','reviewed_at')) = 4
 ORDER BY c.relname;
