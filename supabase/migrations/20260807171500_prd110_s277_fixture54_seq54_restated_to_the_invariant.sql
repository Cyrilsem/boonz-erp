-- PRD-110 · leg 146 · S-277
-- FIXTURE 54 seq 54 RESTATED: re-run preservation is a RELATIVE property, and an absolute
-- count over an APPEND-ONLY ledger can never state it.
--
-- WHAT THE PLANT UNCOVERED. With the S-274 plants in place fixture 54 went 43/44 - every
-- premise green, every swap green, D-36 green - and the single survivor was seq 54,
-- "RE-RUN PRESERVATION: a second compose applies the same swap, dropping nothing",
-- expect 4, actual 5.
--
-- THE FIFTH EDIT IS NOT THIS RUN'S. plan_edits_v3 history for (2030-02-24, A07) reads:
-- every run from 2026-07-31 22:25Z to 2026-08-06 22:09Z dropped "SF Pancake"; the run at
-- 2026-08-07 16:15:59Z dropped "Keen Health Dipped Crackers" instead. HUAWEI-2003 A07 was
-- re-podded in the same ~18-hour window that re-podded A03 to "Al Ain Zero".
-- ⭐ ONE re-podding event, TWO casualties: A03 broke seq 2 (S-274) and A07 orphaned the
-- SF Pancake drop leg. The census saw the first and the first MASKED the second - the
-- cross swap was the only swap still running, so nobody counted its legs.
--
-- THE ORPHAN CANNOT BE RETIRED, AND THAT IS BY DESIGN. record_plan_edit_v3 supersedes on
-- (plan_date, shelf_id, pod_product_id); no future run will ever emit an edit on the
-- SF Pancake key again, because A07's incumbent is now OWNED by the S-274 plant. And
-- plan_edits_v3 carries tg_plan_edits_v3_append_only on DELETE, UPDATE and TRUNCATE
-- (verified from pg_trigger), so the row cannot be removed. It stays active forever,
-- inert: effective_qty 0, "drop on a shelf the base did not plan: already satisfied".
--
-- ⛔ SO expect 4 WAS NEVER THE INVARIANT - IT WAS A CENSUS OF THE LEDGER THAT HAPPENED TO
-- AGREE WITH IT. The property named in the description is that compose #2 applies exactly
-- what compose #1 applied. That is stated relatively, and it is immune to a ledger that by
-- constitutional design only grows.
--
-- ⛔ THIS IS A RESTATEMENT, NOT A LOOSENING (S-103, S-272 - expect_op and expect move with
-- the SHAPE of check_sql). One assertion becomes three, and each is STRICTER than the one
-- it replaces:
--   seq 54 (restated) - c2's applied edit_id SET is identical to c1's, not merely the same
--                       size. The old form could not tell "applied the same four" from
--                       "applied four different ones"; this one can.
--   seq 56 (new)      - all FOUR of the fixture's own legs are in c2.applied, matched by
--                       (shelf_id, pod_product_id, kind). The old absolute count never
--                       checked WHICH edits were applied.
--   seq 57 (new)      - every applied edit that is NOT one of the four is INERT
--                       (effective_qty 0). A real extra edit goes red; only a historical
--                       no-op is tolerated, and it is tolerated explicitly rather than
--                       silently absorbed into a number.
--
-- Nothing outside golden.assertions is touched. No engine body moves.

-- ----------------------------------------------------------------------------
-- seq 54 - RESTATED (the row is UPDATEd in place; the assertion is not deleted)
-- ----------------------------------------------------------------------------
UPDATE golden.assertions SET
  description =
    'RE-RUN PRESERVATION: the second compose applied exactly the edits the first did - '
    'same count AND the same edit_id set. S-277 restatement: the old form asserted an '
    'absolute active-edit count (4), which an append-only ledger can only grow. It broke '
    'when HUAWEI-2003 A07 was re-podded and orphaned a drop leg that can never be '
    'superseded. Set equality states the named property directly and cannot rot.',
  check_sql =
    'SELECT CASE
       WHEN NOT EXISTS (SELECT 1 FROM golden.scratch
                         WHERE fixture_id=54 AND key=''compose''
                           AND value ? ''c1'' AND value ? ''c2'')
         THEN ''absent''
       WHEN (SELECT value->''c1''->>''edits_applied'' FROM golden.scratch
              WHERE fixture_id=54 AND key=''compose'')
            IS DISTINCT FROM
            (SELECT value->''c2''->>''edits_applied'' FROM golden.scratch
              WHERE fixture_id=54 AND key=''compose'')
         THEN ''count_moved''
       WHEN (SELECT array_agg(el.value->>''edit_id'' ORDER BY el.value->>''edit_id'')
               FROM golden.scratch s,
                    LATERAL jsonb_array_elements(s.value->''c1''->''applied'') el
              WHERE s.fixture_id=54 AND s.key=''compose'')
            IS DISTINCT FROM
            (SELECT array_agg(el.value->>''edit_id'' ORDER BY el.value->>''edit_id'')
               FROM golden.scratch s,
                    LATERAL jsonb_array_elements(s.value->''c2''->''applied'') el
              WHERE s.fixture_id=54 AND s.key=''compose'')
         THEN ''set_moved''
       ELSE ''preserved'' END',
  expect_op = 'eq',
  expect    = 'preserved'
WHERE fixture_id = 54 AND seq = 54;

DO $guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM golden.assertions
                  WHERE fixture_id=54 AND seq=54 AND expect='preserved') THEN
    RAISE EXCEPTION 'seq 54 restatement did not land';
  END IF;
END
$guard$;

-- ----------------------------------------------------------------------------
-- seq 56 / 57 - the precision the absolute count only pretended to carry
-- ----------------------------------------------------------------------------
INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
VALUES
(54, 56,
 'S-277 non-vacuity: all FOUR of the fixture''s OWN swap legs are in the second compose''s applied set, matched by (shelf_id, pod_product_id, kind) - the two A04 legs of the same-machine swap and the two A07 legs of the cross-machine swap. The A07 drop key is stable because the S-274 plant now OWNS A07''s incumbent',
 'SELECT (SELECT count(*)::text
            FROM golden.scratch s,
                 LATERAL jsonb_array_elements(s.value->''c2''->''applied'') el
           WHERE s.fixture_id=54 AND s.key=''compose''
             AND (COALESCE(el.value->>''shelf_id'','''')
                 ,COALESCE(el.value->>''pod_product_id'','''')
                 ,COALESCE(el.value->>''kind'','''')) IN (
                   (''b6454a65-f4da-4c07-8570-b8791f687ee2'',''31186e1c-b61b-4d13-b520-052fb86725a3'',''drop''),
                   (''b6454a65-f4da-4c07-8570-b8791f687ee2'',''cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'',''add''),
                   (''8539b03e-4628-4e26-bffe-6aa33c282b7a'',''8b8cc695-b5cc-4b9b-ac67-c7994f260243'',''drop''),
                   (''8539b03e-4628-4e26-bffe-6aa33c282b7a'',''ed88eeff-cb1a-4863-8874-7178339493d0'',''add'')))',
 'eq', '4', true, 'P3'),
(54, 57,
 'S-277 residue is INERT, and tolerated explicitly rather than absorbed into a number: every applied edit that is NOT one of the fixture''s four legs carries effective_qty 0. The known member is the orphaned SF Pancake drop on A07, minted 2026-08-06 22:09Z before the re-podding and unretirable because plan_edits_v3 is append-only. A LIVE extra edit - one that actually moves a quantity - goes red here',
 'SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM golden.scratch
                      WHERE fixture_id=54 AND key=''compose'' AND value ? ''c2'')
      THEN ''absent''
    WHEN (SELECT count(*)
            FROM golden.scratch s,
                 LATERAL jsonb_array_elements(s.value->''c2''->''applied'') el
           WHERE s.fixture_id=54 AND s.key=''compose''
             AND (COALESCE(el.value->>''shelf_id'','''')
                 ,COALESCE(el.value->>''pod_product_id'','''')
                 ,COALESCE(el.value->>''kind'','''')) NOT IN (
                   (''b6454a65-f4da-4c07-8570-b8791f687ee2'',''31186e1c-b61b-4d13-b520-052fb86725a3'',''drop''),
                   (''b6454a65-f4da-4c07-8570-b8791f687ee2'',''cf2d60f1-cbd5-4ba1-8fb4-b995387f7f77'',''add''),
                   (''8539b03e-4628-4e26-bffe-6aa33c282b7a'',''8b8cc695-b5cc-4b9b-ac67-c7994f260243'',''drop''),
                   (''8539b03e-4628-4e26-bffe-6aa33c282b7a'',''ed88eeff-cb1a-4863-8874-7178339493d0'',''add''))
             AND COALESCE((el.value->>''effective_qty'')::int, -1) <> 0) = 0
      THEN ''inert''
    ELSE ''live_residue'' END',
 'eq', 'inert', true, 'P3');
