-- PRD-110 · S-41 · leg 36 · fixture 27: restore seq 9's ORIGINAL meaning after the seq-7 split
--
-- Splitting the synthetic probe into a first-raise capture (v_nC1) for seq 7 silently changed what
-- `anom_dup_key_rows` measured: it became "rows added by the SECOND raise alone" (0) instead of
-- "rows on record after raising the identical observation twice" (1). seq 9's wording and its
-- RECORDED PRE-FIX BASELINE OF 2 both refer to the pair total, so the expression is restored
-- rather than the expectation re-fitted. Re-fitting seq 9 to 0 would have quietly detached it from
-- the failing baseline that justifies it.
--
--   anom_first_raise_rows = v_nC1 - v_nB   -> seq 7  (first raise recorded)          expect 1
--   anom_dup_key_rows     = v_nC  - v_nB   -> seq 9  (pair total: 2 pre-fix, 1 post) expect 1
--   anom_new_snapshot_rows= v_nD  - v_nC   -> seq 10 (new observation recorded)      expect 1
--
-- One expression changed. No assertion expectation altered, no behaviour touched.

BEGIN;

UPDATE golden.fixtures
   SET scenario_sql = replace(
         scenario_sql,
         $old$'anom_dup_key_rows',      (v_nC - v_nC1)::text,$old$,
         $new$'anom_dup_key_rows',      (v_nC - v_nB)::text,$new$)
 WHERE fixture_id = 27;

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM golden.fixtures
              WHERE fixture_id = 27 AND scenario_sql LIKE '%(v_nC - v_nC1)%') THEN
    RAISE EXCEPTION 'fixture 27: the seq-9 expression replacement did not apply - refusing to leave it half-edited';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM golden.fixtures
                  WHERE fixture_id = 27 AND scenario_sql LIKE '%(v_nC - v_nB)::text%') THEN
    RAISE EXCEPTION 'fixture 27: the restored seq-9 expression is absent after replacement';
  END IF;
END
$guard$;

COMMIT;