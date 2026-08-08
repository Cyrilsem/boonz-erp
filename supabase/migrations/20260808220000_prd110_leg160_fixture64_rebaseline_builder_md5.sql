-- PRD-110 DR-1 (leg 160) — fixture 64 seq 18 re-baselined, because THIS leg is what moved the md5.
--
-- ⭐ THE SENSOR WORKED. Fixture 64 seq 18 pins `left(md5(prosrc),8)` of `_build_draft_core_v3` and
--    went RED in sweep A: `fef941d5` → `9200830a`. That is not a defect — it is the D-46 / S-237
--    idiom firing correctly. The md5 moved because `20260808214000` wired the DR-1 cutover guard
--    into the builder, under Cody, with a pre-image md5 guard on that exact value.
--
-- ⛔ THE RE-BASELINE IS A NEW EXPECTED VALUE, NOT A LOOSENING. Softening seq 18 to `not_null` would
--    retire the only sensor that notices an unauthorised edit to the live nightly producer. The
--    expectation moves to the new byte image and the DESCRIPTION moves with it, naming which unit
--    was allowed to move it and when — so the next unexplained change is still a red.
--
-- Article 12: forward-only. The assertion row is UPDATEd; the past migration is untouched.

DO $mig$
DECLARE
  v_live text;
  v_old  text;
  v_n    int;
BEGIN
  SELECT left(md5(prosrc),8) INTO v_live
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='_build_draft_core_v3';

  SELECT expect INTO v_old FROM golden.assertions WHERE fixture_id=64 AND seq=18;

  IF v_old IS NULL THEN RAISE EXCEPTION 'fixture 64 seq 18 not found'; END IF;
  IF v_old <> 'fef941d5' THEN
    RAISE EXCEPTION 'fixture 64 seq 18 expected fef941d5 as the OLD baseline, found % — re-derive before re-baselining', v_old;
  END IF;
  IF v_live <> '9200830a' THEN
    RAISE EXCEPTION 'fixture 64 seq 18: live builder md5 is %, not the 9200830a this leg produced — the body moved again and that needs explaining, not re-baselining', v_live;
  END IF;

  -- ⛔ The builder must still carry all four load-bearing behaviours, or the md5 moved for a
  --    reason this migration is not entitled to bless.
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='_build_draft_core_v3'
     AND p.prosrc LIKE '%cutover_block_reason_v3%'
     AND p.prosrc LIKE '%refused_live_plan%'
     AND p.prosrc LIKE '%awaiting_confirmation%'
     AND p.prosrc LIKE '%skipped_saturday%';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'fixture 64 re-baseline REFUSED: the builder is missing the guard, the LAW-12 guard, the Gate-0 advisory or the calendar check';
  END IF;

  UPDATE golden.assertions
     SET expect = '9200830a',
         description = 'LAW 12 + CS scope: _build_draft_core_v3 body is byte-pinned (md5 prosrc, '
                    || 'never pg_get_functiondef — S-109). ⭐ Re-baselined ONCE, at leg 160, '
                    || 'fef941d5 → 9200830a, by migration 20260808214000, which wired the PRD-110 '
                    || 'DR-1 cutover guard into the live nightly producer under Cody with a '
                    || 'pre-image md5 guard on fef941d5. ⛔ Any FURTHER movement of this value is '
                    || 'an unexplained edit to the 16:00 UTC plan builder and must be treated as a '
                    || 'red, not re-baselined again. ⛔ Do NOT soften this to not_null.'
   WHERE fixture_id=64 AND seq=18;

  RAISE NOTICE 'fixture 64 seq 18 re-baselined fef941d5 -> 9200830a';
END
$mig$;
