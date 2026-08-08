-- PRD-110 · DR-10 · leg 156
-- FIXTURE 73 - RED BASELINE, applied and fired BEFORE the trigger migration (LAW 1, S-297).
--
-- DR-10 (raised leg 148, parking lot): "ARTICLE 8 GAP ACROSS THE WHOLE *_proposals_v3 FAMILY.
--   facing_proposals_v3 carries zero user triggers, so a decision mints no write_audit_log row.
--   Measured across all four proposal tables - facing, feedback, rotation, picker_weight - all
--   zero... It is a single family-wide unit: install the generic trigger on all four, one
--   migration, one fixture asserting a write_audit_log row per decision on each."
--
-- ⛔ THE PARKING LOT SAYS FOUR. THE CATALOGUE SAYS FIVE (S-280, S-299 NEW).
--    Re-deriving the site list from the catalogue BY SHAPE rather than trusting the note's
--    enumeration returns a fifth table the note never mentions: reallocation_proposals_v3,
--    92 live rows, also carrying zero triggers. Had this unit shipped "the four the note
--    names", the family would have been left one table divergent - which is the exact rot
--    DR-10 was raised to prevent, reproduced by the fix for it.
--    The SHAPE that defines the family: a public table carrying all four of
--    proposal_id / status / reviewed_by / reviewed_at. That predicate returns exactly these
--    five and does NOT pull in warehouse_inventory_status_proposal (which has its own
--    tg_audit_wisp already). seq 1 pins the census so a SIXTH table cannot be added silently.
--
-- WHY THE STRUCTURAL ASSERTIONS ARE NOT ENOUGH ON THEIR OWN (D-47 / S-173 doctrine).
--    "A guard passed by inspection is not a guard passed." Asserting the trigger exists in
--    pg_trigger proves a catalogue row, not an audit row. seqs 10-14 EXECUTE a decision on
--    every one of the five and measure the write_audit_log row it mints, and seq 15 reads
--    that row's CONTENT - operation, row_pk, and the old/new payload - so a trigger wired to
--    the wrong pk column or firing on the wrong event cannot pass by existing.
--
-- HOW THE EXERCISE WRITES NOTHING (the whole reason it can run against live proposals).
--    Each decision is an UPDATE of a REAL pending proposal inside a PL/pgSQL subtransaction
--    that is rolled back by a sentinel RAISE. The audit row is counted INSIDE the block,
--    before the rollback; PL/pgSQL variables are not transactional, so the measurement
--    survives while every row change - the proposal AND its audit row - is discarded.
--    ⭐ Proven by dry run before this fixture was written (S-149): all five tables updated
--    without tripping a single CHECK, and a follow-up probe found all five status
--    populations and the family's write_audit_log count byte-unchanged. seqs 17-19 are the
--    standing version of that probe.
--    ⛔ This is why the fixture does NOT plant rows. Planting into these five means
--    satisfying fp_v3_direction_math, chk_fpr_v3_value, rp_v3_qty_le_headroom,
--    realloc_v3_unclaimed_is_empty, pwp_pairs_coherent and eleven FKs - a synthetic row
--    per table that would then have to be deleted from a table CS reviews by hand.
--    Deciding a row that already satisfies every constraint, and rolling back, is both
--    smaller and safer.
--
-- ⛔ picker_weight_proposals_v3 HAS NO PENDING ROW (1 applied, 2 superseded), so its
--    predicate is status IN ('pending','superseded'). 'applied' is excluded deliberately:
--    pwp_applied_shape ties status='applied' to applied_at/applied_weight being set, so
--    moving an applied row to 'rejected' would raise 23514 and the fixture would report a
--    constraint failure as an audit failure. Found by the dry run, not by reading.
--
-- S-266: golden.scratch is written at the END, in one statement, never mid-scenario.
-- S-272: every seq below states its expect_op/expect with the SHAPE it reads.

INSERT INTO golden.fixtures
  (fixture_id, name, source_incident, phase_required, plan_date, enabled, baseline_status, notes, scenario_sql)
VALUES (
  73,
  'DR-10: a decision on a proposal must mint a write_audit_log row, on every table in the *_proposals_v3 family. The family carried ZERO user triggers - approving or rejecting a facing, feedback, rotation, reallocation or picker-weight proposal left no Article 8 record anywhere. The parking lot recorded the family as FOUR tables; the catalogue, queried by shape, returns FIVE. This fixture decides a real proposal on each of the five inside a rolled-back subtransaction and measures the audit row that decision mints.',
  'DR-10 (leg 148) - Article 8 gap found while shipping DR-8''s facing approve-RPC; deliberately NOT fixed inside DR-8 because fixing one table would have diverged it from its siblings',
  'P4',
  DATE '2030-06-20',
  true,
  'failing_expected',
  'Leg 156. RED baseline applied and fired before 20260808181000. Census seq 1 and premise seqs 2-6 are green on BOTH sides. Structure seqs 7-9 and behaviour seqs 10-15 are red until the triggers land. Residue seqs 16-21 are green on BOTH sides - an exercise that leaves residue is not an exercise.',
$fx73$
DO $do$
DECLARE
  c_actor    uuid := '82bba4ee-cceb-4aa0-a4fd-22e3e3fd9e7d';

  -- census / premise
  v_family_n    int := -1;
  v_family_list text := 'absent';
  v_actor_ok    int := -1;
  v_cand        jsonb := '{}'::jsonb;
  v_cand_missing int := -1;

  -- structure
  v_no_trigger  int := -1;
  v_wrong_fn    int := -1;
  v_wrong_shape int := -1;

  -- behaviour
  v_audit       jsonb := '{}'::jsonb;
  v_audit_bad   int := -1;
  v_content     text := 'absent';
  v_errs        text := '';

  -- residue
  v_wal_before  int := -1;
  v_wal_after   int := -1;
  v_notes_left  int := -1;
  v_status_sig_before text := 'absent';
  v_status_sig_after  text := 'absent';
  v_law12       int := -1;
  v_via_trig    text := 'absent';
  v_via_rpc     text := 'absent';

  v_pk       uuid;
  v_n        int;
  v_one_ct   text;
  v_one_err  text;
  r          record;

  s_census  jsonb;
  s_struct  jsonb;
  s_behav   jsonb;
  s_residue jsonb;
BEGIN
  DELETE FROM golden.scratch WHERE fixture_id = 73;

  ------------------------------------------------------------------ 0. THE FAMILY, BY SHAPE --
  -- S-280: derived from the catalogue by SHAPE, never from the parking lot's enumeration and
  -- never from a name grep. A name grep on '%proposals_v3' happens to return the same five
  -- today, but it would miss a sibling named differently and would catch a view.
  CREATE TEMP TABLE _fam ON COMMIT DROP AS
    SELECT c.oid AS reloid, c.relname::text AS tbl
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r'
       AND (SELECT count(*) FROM pg_attribute a
             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
               AND a.attname IN ('proposal_id','status','reviewed_by','reviewed_at')) = 4;

  SELECT count(*), COALESCE(string_agg(tbl, ',' ORDER BY tbl), 'none')
    INTO v_family_n, v_family_list FROM _fam;

  SELECT count(*) INTO v_actor_ok FROM public.user_profiles WHERE id = c_actor;

  ----------------------------------------------------- 1. STRUCTURE (catalogue, no writes) --
  -- Three separate counters rather than one. "No trigger at all", "a trigger that is not
  -- audit_log_write" and "the right function wired the wrong way" are three different
  -- defects and a single boolean would blur them.
  SELECT count(*) INTO v_no_trigger FROM _fam f
   WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g
                      WHERE g.tgrelid = f.reloid AND NOT g.tgisinternal);

  SELECT count(*) INTO v_wrong_fn FROM _fam f
   WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g
                      WHERE g.tgrelid = f.reloid AND NOT g.tgisinternal
                        AND g.tgfoid = 'public.audit_log_write'::regproc);

  -- The wiring itself: AFTER, FOR EACH ROW, all three of INSERT/UPDATE/DELETE, and the pk
  -- column passed as the argument. audit_log_write COALESCEs a missing TG_ARGV[0] to 'id' -
  -- a column none of these five has - so a trigger created without the argument would log
  -- row_pk '?' forever and every structural existence check would still pass.
  SELECT count(*) INTO v_wrong_shape FROM _fam f
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_trigger g
      WHERE g.tgrelid = f.reloid AND NOT g.tgisinternal
        AND g.tgfoid = 'public.audit_log_write'::regproc
        AND pg_get_triggerdef(g.oid) ILIKE '%AFTER INSERT OR DELETE OR UPDATE%'
        AND pg_get_triggerdef(g.oid) ILIKE '%FOR EACH ROW%'
        AND pg_get_triggerdef(g.oid) ILIKE '%audit_log_write(' || quote_literal('proposal_id') || ')%');

  ------------------------------------------------------------ 2. RESIDUE BASELINE (before) --
  SELECT count(*) INTO v_wal_before FROM public.write_audit_log w
   WHERE w.table_name IN (SELECT tbl FROM _fam);

  SELECT string_agg(sig, '|' ORDER BY sig) INTO v_status_sig_before FROM (
    SELECT 'facing:'      || count(*)::text AS sig FROM public.facing_proposals_v3        WHERE status = 'pending'
    UNION ALL SELECT 'feedback:' || count(*)::text FROM public.feedback_proposals_v3      WHERE status = 'pending'
    UNION ALL SELECT 'rotation:' || count(*)::text FROM public.rotation_proposals_v3      WHERE status = 'pending'
    UNION ALL SELECT 'realloc:'  || count(*)::text FROM public.reallocation_proposals_v3  WHERE status = 'proposed'
    UNION ALL SELECT 'picker:'   || count(*)::text FROM public.picker_weight_proposals_v3 WHERE status IN ('pending','superseded')
  ) z;

  ------------------------------------------------- 3. THE EXERCISE - decide, measure, undo --
  CREATE TEMP TABLE _res(tbl text, pk text, n_audit int, content text, err text) ON COMMIT DROP;

  FOR r IN
    SELECT * FROM (VALUES
      ('facing_proposals_v3',        'status = ''pending'''),
      ('feedback_proposals_v3',      'status = ''pending'''),
      ('rotation_proposals_v3',      'status = ''pending'''),
      ('reallocation_proposals_v3',  'status = ''proposed'''),
      ('picker_weight_proposals_v3', 'status IN (''pending'',''superseded'')')
    ) AS v(tbl, pred)
  LOOP
    v_pk := NULL; v_n := -1; v_one_ct := 'absent'; v_one_err := NULL;

    EXECUTE format('SELECT proposal_id FROM public.%I WHERE %s ORDER BY proposal_id LIMIT 1',
                   r.tbl, r.pred) INTO v_pk;

    IF v_pk IS NULL THEN
      INSERT INTO _res VALUES (r.tbl, NULL, -1, 'no_candidate', 'NO_CANDIDATE');
      CONTINUE;
    END IF;

    -- ⛔ EVERY measurement below is taken into a VARIABLE, never into _res, and _res is
    --    written only AFTER the subtransaction has ended. PL/pgSQL variables survive a
    --    subtransaction rollback; rows do not. An INSERT into _res placed before the
    --    sentinel RAISE would be discarded by the very rollback it is measuring, and the
    --    fixture would report "no candidate" for all five tables on both sides of the fix.
    BEGIN
      EXECUTE format(
        'UPDATE public.%I SET status = %L, reviewed_by = %L, reviewed_at = now(), review_note = %L WHERE proposal_id = %L',
        r.tbl, 'rejected', c_actor, 'DR-10 fixture 73 exercise, rolled back', v_pk);

      SELECT count(*) INTO v_n
        FROM public.write_audit_log w
       WHERE w.table_name = r.tbl AND w.row_pk = v_pk::text AND w.operation = 'UPDATE';

      -- CONTENT, not just presence: the payload must carry BOTH sides of the change and the
      -- new side must show the decision that was actually made.
      SELECT COALESCE((SELECT CASE
                  WHEN w.payload ? 'old' AND w.payload ? 'new'
                   AND w.payload->'new'->>'status' = 'rejected'
                   AND w.payload->'old'->>'status' IS DISTINCT FROM 'rejected'
                  THEN 'ok' ELSE 'bad' END
                  FROM public.write_audit_log w
                 WHERE w.table_name = r.tbl AND w.row_pk = v_pk::text
                   AND w.operation = 'UPDATE'
                 ORDER BY w.occurred_at DESC LIMIT 1), 'absent')
        INTO v_one_ct;

      RAISE EXCEPTION 'DR10_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'DR10_ROLLBACK' THEN
        v_one_err := SQLERRM; v_n := -2; v_one_ct := 'error';
      END IF;
    END;

    INSERT INTO _res VALUES (r.tbl, v_pk::text, v_n, v_one_ct, v_one_err);
  END LOOP;

  SELECT jsonb_object_agg(tbl, n_audit) INTO v_audit FROM _res;
  SELECT count(*) INTO v_audit_bad FROM _res WHERE n_audit <> 1;
  SELECT count(*) INTO v_cand_missing FROM _res WHERE err = 'NO_CANDIDATE';
  SELECT jsonb_object_agg(tbl, CASE WHEN pk IS NULL THEN 'none' ELSE 'found' END) INTO v_cand FROM _res;
  SELECT CASE WHEN count(*) = 0 THEN 'no_rows'
              WHEN count(*) FILTER (WHERE content = 'ok') = count(*) THEN 'all_ok'
              ELSE 'bad' END
    INTO v_content FROM _res;
  SELECT COALESCE(string_agg(tbl || '=' || err, ' ~ ' ORDER BY tbl), '') INTO v_errs
    FROM _res WHERE err IS NOT NULL AND err <> 'NO_CANDIDATE';

  ------------------------------------------------------------- 4. RESIDUE (after the undo) --
  SELECT count(*) INTO v_wal_after FROM public.write_audit_log w
   WHERE w.table_name IN (SELECT tbl FROM _fam);

  SELECT string_agg(sig, '|' ORDER BY sig) INTO v_status_sig_after FROM (
    SELECT 'facing:'      || count(*)::text AS sig FROM public.facing_proposals_v3        WHERE status = 'pending'
    UNION ALL SELECT 'feedback:' || count(*)::text FROM public.feedback_proposals_v3      WHERE status = 'pending'
    UNION ALL SELECT 'rotation:' || count(*)::text FROM public.rotation_proposals_v3      WHERE status = 'pending'
    UNION ALL SELECT 'realloc:'  || count(*)::text FROM public.reallocation_proposals_v3  WHERE status = 'proposed'
    UNION ALL SELECT 'picker:'   || count(*)::text FROM public.picker_weight_proposals_v3 WHERE status IN ('pending','superseded')
  ) z;

  SELECT count(*) INTO v_notes_left FROM (
    SELECT review_note FROM public.facing_proposals_v3
    UNION ALL SELECT review_note FROM public.feedback_proposals_v3
    UNION ALL SELECT review_note FROM public.rotation_proposals_v3
    UNION ALL SELECT review_note FROM public.reallocation_proposals_v3
    UNION ALL SELECT review_note FROM public.picker_weight_proposals_v3
  ) z WHERE review_note LIKE '%fixture 73 exercise%';

  SELECT (SELECT count(*) FROM public.refill_plan_output        WHERE plan_date = DATE '2030-06-20')
       + (SELECT count(*) FROM public.refill_plan_output_shadow WHERE plan_date = DATE '2030-06-20')
    INTO v_law12;

  v_via_trig := COALESCE(NULLIF(current_setting('app.via_trigger', true), ''), '<unset>');
  v_via_rpc  := COALESCE(NULLIF(current_setting('app.via_rpc',     true), ''), '<unset>');

  ------------------------------------------------------------------------- 5. SCRATCH --
  s_census := jsonb_build_object(
    'family_n', v_family_n, 'family_list', v_family_list,
    'actor_ok', v_actor_ok, 'candidates', v_cand, 'candidates_missing', v_cand_missing);

  s_struct := jsonb_build_object(
    'no_trigger', v_no_trigger, 'wrong_fn', v_wrong_fn, 'wrong_shape', v_wrong_shape);

  s_behav := jsonb_build_object(
    'audit_rows', v_audit, 'audit_bad', v_audit_bad, 'content', v_content, 'errors', v_errs);

  s_residue := jsonb_build_object(
    'wal_before', v_wal_before, 'wal_after', v_wal_after,
    'wal_delta', v_wal_after - v_wal_before,
    'status_sig_before', v_status_sig_before, 'status_sig_after', v_status_sig_after,
    'status_unchanged', CASE WHEN v_status_sig_before = v_status_sig_after THEN 'yes' ELSE 'no' END,
    'notes_left', v_notes_left, 'law12', v_law12,
    'via_trigger', v_via_trig, 'via_rpc', v_via_rpc);

  INSERT INTO golden.scratch (fixture_id, key, value) VALUES
    (73, 'census',  s_census),
    (73, 'struct',  s_struct),
    (73, 'behav',   s_behav),
    (73, 'residue', s_residue);
END $do$;
$fx73$);

INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required) VALUES

-- ============================== CENSUS / PREMISE - green on BOTH sides ==============================
(73, 1, 'DR-10 S-280 CENSUS - the assertion that stops a SIXTH sibling being added without an audit trigger. Counts public tables carrying the proposal SHAPE (all four of proposal_id / status / reviewed_by / reviewed_at), never a name grep and never the parking lot''s enumeration. ⛔ The parking lot recorded this family as FOUR tables; the catalogue returns FIVE - reallocation_proposals_v3, 92 live rows, is the one the note never mentions. Had this unit shipped "the four the note names", the family would have been left one table divergent, which is exactly the rot DR-10 was raised to prevent. The day a sixth proposal table lands, this goes red and seq 7 goes red with it.',
 'SELECT COALESCE((SELECT value->>''family_n'' FROM golden.scratch WHERE fixture_id=73 AND key=''census''),''absent'')', 'eq', '5', true, 'P4'),
(73, 2, 'DR-10 census: the family membership is stated BY NAME, not just counted. A count alone would stay at 5 if one sibling were dropped and an unrelated table grew the shape on the same day - the two defects would cancel and nothing would say so.',
 'SELECT COALESCE((SELECT value->>''family_list'' FROM golden.scratch WHERE fixture_id=73 AND key=''census''),''absent'')', 'eq', 'facing_proposals_v3,feedback_proposals_v3,picker_weight_proposals_v3,reallocation_proposals_v3,rotation_proposals_v3', true, 'P4'),
(73, 3, 'DR-10 premise: the reviewer uuid the exercise decides as is a REAL user_profiles row. Every one of these five tables constrains reviewed_by with an FK to user_profiles, so a stale uuid would fail the UPDATE with 23503 and seqs 10-14 would report an FK error as an audit gap.',
 'SELECT COALESCE((SELECT value->>''actor_ok'' FROM golden.scratch WHERE fixture_id=73 AND key=''census''),''absent'')', 'eq', '1', true, 'P4'),
(73, 4, 'DR-10 premise (S-274): EVERY one of the five tables supplies a decidable row, so the exercise at seqs 10-14 is non-vacuous on all five. ⛔ Without this sensor a table that ran out of pending proposals would silently stop being tested and its audit trigger could be dropped with the fixture still reading green. picker_weight_proposals_v3 is the live proof this matters - it has NO pending row at all (1 applied, 2 superseded), which is why its predicate accepts superseded too.',
 'SELECT COALESCE((SELECT value->>''candidates_missing'' FROM golden.scratch WHERE fixture_id=73 AND key=''census''),''absent'')', 'eq', '0', true, 'P4'),
(73, 5, 'DR-10 premise: the per-table candidate map names which tables supplied a row, so seq 4''s zero can be read back to a table rather than to a number. All five must read "found".',
 'SELECT COALESCE((SELECT (value->''candidates''->>''facing_proposals_v3'')||''/''||(value->''candidates''->>''feedback_proposals_v3'')||''/''||(value->''candidates''->>''rotation_proposals_v3'')||''/''||(value->''candidates''->>''reallocation_proposals_v3'')||''/''||(value->''candidates''->>''picker_weight_proposals_v3'') FROM golden.scratch WHERE fixture_id=73 AND key=''census''),''absent'')', 'eq', 'found/found/found/found/found', true, 'P4'),
(73, 6, 'DR-10 premise: the exercise raised NO constraint error on any of the five. ⛔ This is the assertion that keeps a 23514 from being misread as an Article 8 gap - the two look identical at seqs 10-14 (both leave the audit count wrong) and only this seq tells them apart. It is also where the picker_weight pwp_applied_shape trap would surface if someone widened that predicate to include ''applied''.',
 'SELECT COALESCE((SELECT value->>''errors'' FROM golden.scratch WHERE fixture_id=73 AND key=''behav''),''absent'')', 'eq', '', true, 'P4'),

-- ============================== STRUCTURE - red until the triggers land ==============================
(73, 7, 'DR-10 STRUCTURE: ZERO tables in the family carry no user trigger at all. Reads 5 before the fix (the measured Article 8 gap - a decision on any proposal minted no write_audit_log row anywhere) and 0 after.',
 'SELECT COALESCE((SELECT value->>''no_trigger'' FROM golden.scratch WHERE fixture_id=73 AND key=''struct''),''absent'')', 'eq', '0', true, 'P4'),
(73, 8, 'DR-10 STRUCTURE: ZERO tables in the family lack a trigger bound specifically to public.audit_log_write. Separate from seq 7 on purpose - a table that grew SOME bespoke trigger would satisfy seq 7 while still bypassing the canonical Article 8 writer, and the family would have diverged again in a way only this counter can see.',
 'SELECT COALESCE((SELECT value->>''wrong_fn'' FROM golden.scratch WHERE fixture_id=73 AND key=''struct''),''absent'')', 'eq', '0', true, 'P4'),
(73, 9, 'DR-10 STRUCTURE - THE WIRING, NOT JUST THE BINDING: zero tables whose trigger is not AFTER INSERT OR DELETE OR UPDATE, FOR EACH ROW, with ''proposal_id'' passed as the argument. ⛔ audit_log_write COALESCEs a missing TG_ARGV[0] to ''id'' - a column NONE of these five has - so a trigger created without the argument would log row_pk ''?'' on every decision forever and seqs 7 and 8 would both still pass. This is the seq that makes the argument mandatory rather than conventional.',
 'SELECT COALESCE((SELECT value->>''wrong_shape'' FROM golden.scratch WHERE fixture_id=73 AND key=''struct''),''absent'')', 'eq', '0', true, 'P4'),

-- ============================== BEHAVIOUR - the ruling''s literal demand, EXECUTED ==============================
(73, 10, 'DR-10 BEHAVIOUR (facing_proposals_v3): deciding a real pending facing proposal mints EXACTLY ONE write_audit_log UPDATE row keyed to that proposal_id. Exactly one, not at least one - two rows would mean a duplicate trigger and Article 8 evidence that double-counts every decision. This is the table DR-10 was raised on, and the table DR-8''s approve-RPC shipped against without it.',
 'SELECT COALESCE((SELECT value->''audit_rows''->>''facing_proposals_v3'' FROM golden.scratch WHERE fixture_id=73 AND key=''behav''),''absent'')', 'eq', '1', true, 'P4'),
(73, 11, 'DR-10 BEHAVIOUR (feedback_proposals_v3): deciding a real pending feedback proposal mints exactly one write_audit_log UPDATE row. ⛔ This is the table whose approve-RPC shipped at P4.1 and SET THE PRECEDENT the other four followed - the gap was in the precedent itself, which is why fixing one table would never have been enough.',
 'SELECT COALESCE((SELECT value->''audit_rows''->>''feedback_proposals_v3'' FROM golden.scratch WHERE fixture_id=73 AND key=''behav''),''absent'')', 'eq', '1', true, 'P4'),
(73, 12, 'DR-10 BEHAVIOUR (rotation_proposals_v3): deciding a real pending rotation proposal mints exactly one write_audit_log UPDATE row. Rotation proposals move physical stock between machines when applied, so a decision here is the one with a truck behind it.',
 'SELECT COALESCE((SELECT value->''audit_rows''->>''rotation_proposals_v3'' FROM golden.scratch WHERE fixture_id=73 AND key=''behav''),''absent'')', 'eq', '1', true, 'P4'),
(73, 13, 'DR-10 BEHAVIOUR (reallocation_proposals_v3): deciding a real proposed reallocation mints exactly one write_audit_log UPDATE row. ⭐ THE TABLE THE PARKING LOT NEVER NAMED. Its predicate is status=''proposed'' rather than ''pending'' because realloc_v3_unclaimed_is_empty ties status=''unclaimed'' to target_shelf_id IS NULL - deciding an unclaimed row would raise 23514, which seq 6 would have caught and this seq would have misreported.',
 'SELECT COALESCE((SELECT value->''audit_rows''->>''reallocation_proposals_v3'' FROM golden.scratch WHERE fixture_id=73 AND key=''behav''),''absent'')', 'eq', '1', true, 'P4'),
(73, 14, 'DR-10 BEHAVIOUR (picker_weight_proposals_v3): deciding a real picker-weight proposal mints exactly one write_audit_log UPDATE row. This table''s decisions move the picker''s own weights, so an unaudited decision here changes which machines get visited with no record of who changed it.',
 'SELECT COALESCE((SELECT value->''audit_rows''->>''picker_weight_proposals_v3'' FROM golden.scratch WHERE fixture_id=73 AND key=''behav''),''absent'')', 'eq', '1', true, 'P4'),
(73, 15, 'DR-10 BEHAVIOUR - THE AUDIT ROW''S CONTENT, on all five. Each minted row must carry BOTH an old and a new payload, the new side showing status=''rejected'', and the old side showing something else. ⛔ A trigger that fired but wrote an empty or one-sided payload would satisfy seqs 10-14 and be useless as evidence: Article 8 asks what changed, not that something did.',
 'SELECT COALESCE((SELECT value->>''content'' FROM golden.scratch WHERE fixture_id=73 AND key=''behav''),''absent'')', 'eq', 'all_ok', true, 'P4'),

-- ============================== RESIDUE - green on BOTH sides ==============================
(73, 16, 'DR-10 RESIDUE: the family''s write_audit_log population is byte-unchanged across the whole scenario - delta exactly 0. ⛔ The exercise decides REAL proposals, so the subtransaction rollback is the only thing standing between this fixture and 5 spurious audit rows per run, forever. Stated as a DELTA rather than an absolute so it stays true once CS starts making real decisions that legitimately add rows.',
 'SELECT COALESCE((SELECT value->>''wal_delta'' FROM golden.scratch WHERE fixture_id=73 AND key=''residue''),''absent'')', 'eq', '0', true, 'P4'),
(73, 17, 'DR-10 RESIDUE: the decidable-row population of all five tables is identical before and after the exercise. ⛔ THE ASSERTION THAT PROTECTS LIVE PROPOSALS. The 20 facing and 23 reallocation proposals queued for CS Sunday review are real work product; if the rollback ever failed, this fixture would silently reject one of them per run and this is the seq that catches it.',
 'SELECT COALESCE((SELECT value->>''status_unchanged'' FROM golden.scratch WHERE fixture_id=73 AND key=''residue''),''absent'')', 'eq', 'yes', true, 'P4'),
(73, 18, 'DR-10 RESIDUE: the status signature is recorded verbatim, not just compared. seq 17 proves before=after; this seq is what lets a future leg read WHICH populations were live at leg 156 without re-running anything, and is the sensor for the day a table''s queue empties out.',
 'SELECT COALESCE((SELECT value->>''status_sig_after'' FROM golden.scratch WHERE fixture_id=73 AND key=''residue''),''absent'')', 'eq', 'facing:20|feedback:12|picker:2|realloc:23|rotation:25', true, 'P4'),
(73, 19, 'DR-10 RESIDUE: not one review_note left behind by the exercise, on any of the five. A second, independent witness to seq 17 - the status could be restored while a note survived, and a note on a real proposal is CS-visible pollution even when the status is right.',
 'SELECT COALESCE((SELECT value->>''notes_left'' FROM golden.scratch WHERE fixture_id=73 AND key=''residue''),''absent'')', 'eq', '0', true, 'P4'),
(73, 20, 'DR-10 LAW 12: the fixture''s synthetic 2030 plan_date holds zero rows across the live and shadow plan tables after the run. This fixture never touches a plan table; that is MEASURED here rather than declared in a comment.',
 'SELECT COALESCE((SELECT value->>''law12'' FROM golden.scratch WHERE fixture_id=73 AND key=''residue''),''absent'')', 'eq', '0', true, 'P4'),
(73, 21, 'DR-10 residue: neither app.via_trigger nor app.via_rpc leaks out of the fixture. ⛔ Both are read by audit_log_write itself to stamp via_rpc/rpc_name on every row it writes, so a GUC leaked out of this scenario would mislabel the provenance of the NEXT fixture''s audit rows (the app.via_trigger cross-statement leak is a recorded PRD-062 gotcha).',
 'SELECT COALESCE((SELECT (value->>''via_trigger'')||''/''||(value->>''via_rpc'') FROM golden.scratch WHERE fixture_id=73 AND key=''residue''),''absent'')', 'eq', '<unset>/<unset>', true, 'P4');
