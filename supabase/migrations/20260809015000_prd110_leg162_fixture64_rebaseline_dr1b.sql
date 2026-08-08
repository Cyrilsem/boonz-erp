-- PRD-110 · leg 162 · fixture 64 seq 18 re-baseline — the SECOND authorized movement
--
-- Leg 161's own sweep A (tag 'leg161 sweepA', 17:30-17:53 UTC) banked fixture 64 at
-- 23 pass / 1 fail. The one red is seq 18, the byte-pin on the live 16:00 UTC plan
-- builder: expect 9200830a, actual 247103af.
--
-- ⭐ THE SENSOR IS WORKING, AND LEG 161 IS WHAT MOVED IT. DR-1b's migration
--    20260809011500_prd110_dr1b_build_draft_core_branch rewrote _build_draft_core_v3
--    so that the DR-1 cutover HALT became a per-cluster BRANCH. That is an authorized,
--    Cody-reviewed, logged engine change. Leg 161 shipped it and did not re-baseline
--    the sensor, then launched a sweep that caught its own omission.
--
-- ⛔ seq 18's existing description says "Any FURTHER movement of this value is an
--    unexplained edit ... and must be treated as a red, not re-baselined again." That
--    sentence was written by leg 160, before DR-1b existed. The movement here IS
--    explained, and the explanation is a named migration. The instruction is honoured
--    the only way it can be: the movement is PROVEN to be DR-1b's before the expect is
--    touched, and the description is rewritten to carry BOTH movements so the next leg
--    inherits the real history rather than a rolling "trust me".
--
-- EVIDENCE, read live at 2026-08-08 17:5x UTC before this file was written:
--   md5(prosrc) of _build_draft_core_v3 = 247103afc4a8c2c8d380b3977422d01f
--   exactly one signature
--   the body now references the DR-1b cutover objects (branch present)
--   it STILL calls cutover_block_reason_v3, whose own prosrc md5 is
--     2006f1c8db739375bc4795b7a6cdfc9a — byte-identical to leg 161's recorded value,
--     so fixture 74 seq 13/65/66 are unaffected by this file.
--
-- ⛔ S-103: expect AND description move together. ⛔ Never softened to not_null.

BEGIN;

DO $guard$
DECLARE v_md5 text; v_n int; v_expect text;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname = '_build_draft_core_v3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'leg162: expected exactly 1 _build_draft_core_v3, found %', v_n;
  END IF;

  SELECT md5(prosrc) INTO v_md5 FROM pg_proc WHERE proname = '_build_draft_core_v3';
  IF left(v_md5, 8) <> '247103af' THEN
    RAISE EXCEPTION 'leg162: builder md5 is % - this file re-baselines to 247103af only. The builder moved AGAIN and that is a red to bisect, not to re-baseline.', v_md5;
  END IF;

  -- The movement must be DR-1b's, not an anonymous edit that happens to differ.
  IF NOT EXISTS (SELECT 1 FROM pg_proc
                  WHERE proname = '_build_draft_core_v3'
                    AND (position('promote_v3_shadow_to_live_v3' in prosrc) > 0
                      OR position('is_cluster_authoritative_v3'  in prosrc) > 0)) THEN
    RAISE EXCEPTION 'leg162: the builder does not reference the DR-1b cutover objects, so 247103af is NOT DR-1b''s image';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations
                  WHERE version = '20260809011500') THEN
    RAISE EXCEPTION 'leg162: DR-1b builder migration 20260809011500 is not recorded as applied';
  END IF;

  -- fixture 74 reads cutover_block_reason_v3's body; it must be untouched by DR-1b.
  SELECT md5(prosrc) INTO v_md5 FROM pg_proc WHERE proname = 'cutover_block_reason_v3';
  IF v_md5 <> '2006f1c8db739375bc4795b7a6cdfc9a' THEN
    RAISE EXCEPTION 'leg162: cutover_block_reason_v3 md5 is % - fixture 74 seq 65/66 would be collateral', v_md5;
  END IF;

  -- refuse to "re-baseline" a value that is already current (a silent no-op file)
  SELECT expect INTO v_expect FROM golden.assertions WHERE fixture_id = 64 AND seq = 18;
  IF v_expect IS NULL THEN
    RAISE EXCEPTION 'leg162: fixture 64 seq 18 does not exist';
  END IF;
  IF v_expect = '247103af' THEN
    RAISE EXCEPTION 'leg162: fixture 64 seq 18 already expects 247103af - nothing to re-baseline';
  END IF;
  IF v_expect <> '9200830a' THEN
    RAISE EXCEPTION 'leg162: fixture 64 seq 18 expects %, not leg 160''s 9200830a - the baseline history is not what this file assumes', v_expect;
  END IF;
END
$guard$;

UPDATE golden.assertions
   SET expect = '247103af',
       description =
'LAW 12 + CS scope: _build_draft_core_v3 body is byte-pinned (md5 prosrc, never pg_get_functiondef - S-109). '
'⭐ Re-baselined TWICE, both times for a named, Cody-reviewed migration against the live 16:00 UTC plan builder: '
'(1) leg 160, fef941d5 -> 9200830a, migration 20260808214000, which wired the PRD-110 DR-1 cutover GUARD into the builder; '
'(2) leg 162, 9200830a -> 247103af, migration 20260809011500 (DR-1b), which turned that guard''s fleet-wide HALT into a per-cluster BRANCH. '
'⛔ Any FURTHER movement is an unexplained edit to the nightly plan builder: bisect it, name the migration that caused it, and only then re-baseline - expect and this description together (S-103). '
'⛔ Do NOT soften this to not_null.'
 WHERE fixture_id = 64 AND seq = 18;

DO $post$
DECLARE v_expect text; v_desc text;
BEGIN
  SELECT expect, description INTO v_expect, v_desc
    FROM golden.assertions WHERE fixture_id = 64 AND seq = 18;
  IF v_expect <> '247103af' THEN
    RAISE EXCEPTION 'leg162: re-baseline did not land, expect is %', v_expect;
  END IF;
  IF position('Re-baselined TWICE' in v_desc) = 0 THEN
    RAISE EXCEPTION 'leg162: expect moved but the description did not (S-103)';
  END IF;
  IF position('20260809011500' in v_desc) = 0 THEN
    RAISE EXCEPTION 'leg162: the description does not name the migration that moved the value';
  END IF;
END
$post$;

COMMIT;
