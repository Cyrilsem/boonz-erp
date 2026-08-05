-- PRD-110 leg 111 · UNIT B follow-up · fix a stale cross-reference introduced minutes earlier.
-- 20260804002428 landed seq 8's description saying "Paired with seq 43"; the new assertion was
-- actually inserted at seq 57 (fixture 40 occupies 1..56 contiguously). A fixture carrying a
-- wrong cross-reference is the same stale-narrative defect S-200 is about, so it is corrected
-- forward rather than left as a harmless-looking typo.
DO $fix$
DECLARE v_n integer;
BEGIN
  UPDATE golden.assertions
     SET description = replace(description, 'Paired with seq 43,', 'Paired with seq 57,')
   WHERE fixture_id = 40 AND seq = 8 AND description LIKE '%Paired with seq 43,%';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'leg111 UNIT B2: (40,8) cross-ref fix hit % rows, expected 1', v_n; END IF;
END $fix$;
