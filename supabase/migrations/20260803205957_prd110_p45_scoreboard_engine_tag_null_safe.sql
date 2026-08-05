-- PRD-110 P4.5 fix, found by golden fixture 65 seq 10 on its first run.
-- ck_scoreboard_engine_tag as shipped in 20260803205310 read:
--   (metric_key = 'wmape' AND engine_tag IN ('v3','v19'))
--   OR (metric_key <> 'wmape' AND engine_tag IS NULL)
-- For metric_key='wmape' with engine_tag NULL that is (TRUE AND NULL) OR FALSE = NULL,
-- and a CHECK constraint ACCEPTS a NULL result. So the one shape the constraint existed
-- to forbid -- an untagged wmape row, which could not be attributed to v3 or v19 and would
-- collide on the upsert key -- was let through. Three-valued logic, caught by the fixture
-- rather than by review. Rewritten as a CASE so the result is always TRUE or FALSE.
-- Forward-only (Article 12); no existing row violates the corrected form.
ALTER TABLE public.scoreboard_daily_v3 DROP CONSTRAINT ck_scoreboard_engine_tag;
ALTER TABLE public.scoreboard_daily_v3 ADD CONSTRAINT ck_scoreboard_engine_tag CHECK (
  CASE WHEN metric_key = 'wmape'
       THEN engine_tag IS NOT NULL AND engine_tag IN ('v3','v19')
       ELSE engine_tag IS NULL END);
