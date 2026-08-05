SET LOCAL statement_timeout = '120s';

-- ============================================================================
-- PRD-110 leg 83 · UNIT 2 — S-129 HALF ONE: THE MISLABEL TRIPWIRE STOPS FIRING
--                            ON A LEGITIMATELY FULL SHELF
--
-- Fixture 8 has been RED (17/2) since somewhere in legs 56-81. Leg 82 proved the
-- reds are NOT the P4.2 engine change (identical reds against the restored prior
-- definition in a rolled-back txn). This unit closes the FALSE red only.
--
-- seq 27 counts `clamp_reason='skipped_full' AND ceil_u < cover_units` and calls
-- it a mislabel. ⛔ But when `fill_to_cap = 0` the shelf is GENUINELY full:
-- need_raw and need_raw_no_expiry are both 0, the expiry branch correctly never
-- fires, and 'skipped_full' is the MORE accurate label of the two. The tripwire
-- had no exemption, so a correctly-labelled full shelf read as a mislabel.
--
-- ⭐ VERIFIED LIVE against run bb049152 (32 lines) BEFORE writing this migration,
--    rather than taken from the parking lot on trust:
--      mislabelled_full with the tripwire as it stands ....... 1
--      the single offending row .... cap=0 ceil=0 need=0 cover=1 floor=0
--      mislabelled_full with `fill_to_cap > 0` added ......... 0
--    The exemption is exactly sufficient and no wider than it needs to be.
--
-- ⛔ THIS DOES NOT CLOSE S-129. Fixture 8 stays RED at 18/1; seq 29 remains red
--    and is a TRUE red - see S-132. What this buys is that the ONE remaining red
--    is the real signal, with the false positive no longer sitting next to it.
-- ============================================================================

DO $mig$
DECLARE
  s      text;
  n      int;
  anchor CONSTANT text := E'    ''mislabelled_full'', (SELECT count(*) FROM fx8_l\n                          WHERE clamp_reason = ''skipped_full''\n                            AND ceil_u IS NOT NULL AND ceil_u < cover_units),';
  repl   text;
BEGIN
  SELECT scenario_sql INTO s FROM golden.fixtures WHERE fixture_id = 8;
  IF s IS NULL THEN
    RAISE EXCEPTION 'FX8 scenario not found - refusing to edit nothing';
  END IF;
  IF strpos(s, 'fill_to_cap > 0') <> 0 THEN
    RAISE EXCEPTION 'the exemption is already present - refusing to double-apply';
  END IF;

  n := (length(s) - length(replace(s, anchor, ''))) / length(anchor);
  IF n <> 1 THEN
    RAISE EXCEPTION 'mislabelled_full anchor matched % times, expected exactly 1', n;
  END IF;

  repl :=
     E'    ''mislabelled_full'', (SELECT count(*) FROM fx8_l\n'
  || E'                          WHERE clamp_reason = ''skipped_full''\n'
  || E'                            AND ceil_u IS NOT NULL AND ceil_u < cover_units\n'
  || E'                            -- ⛔ S-129 EXEMPTION: fill_to_cap = 0 means the shelf really IS\n'
  || E'                            -- full. need_raw and need_raw_no_expiry are both 0, the expiry\n'
  || E'                            -- branch never fires, and ''skipped_full'' is the MORE accurate\n'
  || E'                            -- of the two labels - there is no clamp class being hidden from\n'
  || E'                            -- procurement because nothing was clamped. Without this, a\n'
  || E'                            -- correctly-labelled full shelf reads as a mislabel.\n'
  || E'                            AND fill_to_cap > 0),';

  s := replace(s, anchor, repl);

  IF strpos(s, 'AND fill_to_cap > 0),') = 0 THEN
    RAISE EXCEPTION 'post-check: the exemption did not land';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = s WHERE fixture_id = 8;
END
$mig$;

-- ⛔ The metric name and the assertion's check_sql/expect are UNCHANGED (the fix is in
--    how the scenario COMPUTES the metric). The description is re-stated so the
--    exemption is documented where the next reader meets it.
UPDATE golden.assertions SET
  description = 'MISLABEL: a line the expiry ceiling pushed below its cover may never report clamp_reason=''skipped_full''. That label means the shelf is FULL and would hide the entire clamp class from procurement. ⛔ S-129 (leg 83): EXEMPTS fill_to_cap = 0, where the shelf is genuinely full, need_raw is 0, the expiry branch correctly never fires and ''skipped_full'' is the more accurate label - verified live as the sole offending row on run bb049152'
WHERE fixture_id = 8 AND seq = 27;
