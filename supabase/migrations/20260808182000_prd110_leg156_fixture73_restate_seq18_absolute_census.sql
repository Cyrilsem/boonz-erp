-- PRD-110 · leg 156 · S-301
-- FIXTURE 73 seq 18 RESTATED: an absolute live-population census is cross-fixture coupling.
--
-- WHAT HAPPENED. Fixture 73 fired GREEN 21/0 in isolation (8cd19e87) and RED 20/1 inside the
-- leg-156 full sweep, on seq 18 alone:
--     actual  facing:23|feedback:12|picker:2|realloc:24|rotation:25
--     expect  facing:20|feedback:12|picker:2|realloc:23|rotation:25
-- ⛔ +3 facing and +1 reallocation proposals appeared between the two runs. Fixture 73 did not
--    mint them: seq 17 (`status_unchanged`, before vs after WITHIN the run) PASSED in the same
--    sweep run, so the subtransaction rollback did exactly what it was built to do. Earlier
--    fixtures in the sweep minted into the live CS review queues - the standing S-265 finding
--    ("fixture 57 mints into the LIVE CS review queue") landing on a new assertion.
--
-- ⭐ S-301 (NEW) - THE MIRROR OF S-283, AND THE MORE DANGEROUS DIRECTION.
--    S-283 says never adjudicate a sweep RED without an isolation re-fire. This is the opposite
--    failure and it has no such guard: an assertion that pins an ABSOLUTE count of live rows
--    passes in isolation FOREVER and can only ever fail in a sweep, where its verdict depends on
--    which siblings ran first. Isolation does not merely fail to catch it - isolation actively
--    certifies it green. ⛔ **An assertion whose value another fixture can move is not an
--    assertion about the unit under test.**
--
-- THE RESTATEMENT (S-272: expect_op/expect move WITH the shape of check_sql).
--    seq 18's stated purpose was two things: let a future leg read WHICH populations were live,
--    and sense the day a table's queue empties out. The first is already served by
--    golden.scratch, which records the signature verbatim on every run and is not an assertion.
--    Only the second is worth asserting, and it does not need absolute volumes.
--    check_sql now buckets every count before comparing: a zero becomes `EMPTY`, any positive
--    number becomes `#`. Membership and ordering of all five tables are still pinned exactly, and
--    an emptied queue still goes red BY NAME - but a sibling fixture minting a proposal no longer
--    turns this red, because the volume is no longer what is asserted.
--    ⛔ `:0` cannot match inside `:20` - the pattern anchors on the colon, so the character before
--    the 0 must be the colon itself. Verified against the live signature before shipping.
--
-- ⭐ WHAT IS DELIBERATELY NOT LOOSENED. seq 17 (`status_unchanged` = yes) is untouched and is the
--    assertion that actually protects the 20 facing and 23 reallocation proposals queued for CS
--    review: it compares the populations BEFORE and AFTER within one run, so it is immune to what
--    siblings do and still goes red the instant this fixture's rollback fails. Nothing about the
--    residue guarantee is weakened here; a brittle census is replaced by a stable one.
--    seqs 4 and 5 (every table supplies a decidable candidate) also stand unchanged.

DO $do$
DECLARE
  v_before text;
  v_n      int;
  v_after  text;
BEGIN
  SELECT check_sql INTO v_before FROM golden.assertions WHERE fixture_id = 73 AND seq = 18;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'REFUSED: fixture 73 seq 18 does not exist - nothing to restate.';
  END IF;
  IF v_before NOT LIKE '%status_sig_after%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 73 seq 18 does not read status_sig_after (reads: %). '
                    'It has already been restated or renumbered; re-derive before overwriting.', v_before;
  END IF;

  UPDATE golden.assertions
     SET check_sql = 'SELECT COALESCE((SELECT regexp_replace(regexp_replace(value->>''status_sig_after'', '':0(\||$)'', '':EMPTY\1'', ''g''), '':[0-9]+'', '':#'', ''g'') FROM golden.scratch WHERE fixture_id=73 AND key=''residue''),''absent'')',
         expect_op = 'eq',
         expect    = 'facing:#|feedback:#|picker:#|realloc:#|rotation:#',
         description = 'DR-10 RESIDUE (S-301, restated at leg 156): all five decidable-row populations are NON-EMPTY, with membership and ordering pinned by name. ⛔ This seq previously pinned the ABSOLUTE counts (facing:20|...|realloc:23|...) and was RED in the leg-156 sweep while GREEN in isolation - earlier fixtures mint into the live CS review queues (S-265), so the absolute was a value a SIBLING fixture could move. An assertion that only a sweep can falsify, and that isolation certifies green forever, is not an assertion about the unit under test. Counts are now bucketed (a zero reads EMPTY, any positive reads #) so an emptied queue still goes red BY NAME while a minted proposal does not. ⭐ The verbatim signature is still recorded in golden.scratch every run for any leg that wants the numbers - recording and asserting are different jobs. seq 17 (before==after within the run) is untouched and remains the real residue guarantee.'
   WHERE fixture_id = 73 AND seq = 18;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'LANDING GUARD: expected to restate exactly 1 row, moved %', v_n;
  END IF;

  -- Prove the new check_sql actually evaluates, and evaluates to the expected shape, against
  -- the scratch the fixture last wrote. A restatement that ships an unparseable check_sql
  -- would read as a scenario failure on the next sweep (S-287: the migration applies cleanly
  -- and the SCENARIO is what fails).
  SELECT check_sql INTO v_after FROM golden.assertions WHERE fixture_id = 73 AND seq = 18;
  EXECUTE v_after INTO v_after;
  RAISE NOTICE 'fixture 73 seq 18 restated; evaluates to: %', v_after;

  IF v_after !~ '^(facing|feedback|picker|realloc|rotation):(#|EMPTY)(\|(facing|feedback|picker|realloc|rotation):(#|EMPTY)){4}$' THEN
    RAISE EXCEPTION 'RESTATEMENT DID NOT PRODUCE THE BUCKETED SHAPE: %', v_after;
  END IF;
END $do$;

SELECT fixture_id, seq, expect_op, expect FROM golden.assertions WHERE fixture_id = 73 AND seq = 18;
