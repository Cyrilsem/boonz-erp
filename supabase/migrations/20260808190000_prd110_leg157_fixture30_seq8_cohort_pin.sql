-- PRD-110 · leg 157 · LAW 8 · S-301 (second application) · S-302
-- FIXTURE 30 seq 8 RESTATED: the S-10 tripwire counted a population an AUTHORISED write can grow.
--
-- WHAT HAPPENED. Fixture 30 was GREEN at 2026-08-08 09:31Z and RED from 12:48Z on seq 8 alone:
--     actual 80   expect 77
-- The bisect is exact and it is NOT an engine regression. The three extra rows are
-- **Fade Fit - Coconut**, three Active venue edges on co_managed machines, valid_from
-- 2026-08-08 10:06:34Z - inside the green->red window. Leg 151 minted them (six edges total,
-- three 7Up + three Fade Fit - Coconut) to mirror product_mapping intent that CS's own writes
-- had recorded. `Fade Fit - Coconut` matches this tripwire's `LIKE 'Fade Fit -%'` arm; the three
-- 7Up edges sit on Soft Drinks Mix and match no arm, which is why the counter moved by exactly 3.
--
-- ⛔ THE LEG-156 POINTER'S HYPOTHESIS WAS WRONG AND IS CORRECTED HERE. It read the +3 as "the
--    same magnitude as the facing-proposal minting - check that coupling first." It is not that
--    coupling. Two unrelated things moved by 3 in the same window. ⭐ **Magnitude is not a
--    mechanism.** The coupling is to the S-285 sourcing mint, proven by valid_from and by product
--    name, not inferred from a delta.
--
-- ⭐ S-302 (NEW) - THE AUTHORISED-WRITE DIRECTION OF S-301.
--    S-301 found that an absolute count of live rows can be moved by a SIBLING FIXTURE. This is
--    the same defect with a different mover: an absolute count of live rows can also be moved by
--    THIS LOOP'S OWN AUTHORISED WRITES. Leg 151 did nothing wrong; it mirrored a CS decision
--    through the canonical writer and logged it. The fixture still went red five legs later, and
--    the red says nothing about the property the fixture exists to protect. ⛔ **Before pinning a
--    count, ask not only which sibling can move it (S-301) but which AUTHORISED write can.**
--
-- THE RESTATEMENT, AND WHY IT IS STRICTLY STRONGER - NOT A WEAKENING.
--    seq 8's own description ends "Never fix this by weakening the assertion", and that ruling is
--    honoured literally. The named failure mode is a backfill that reverts to most-specific-wins
--    and RE-SOURCES VOX goods to Boonz WH. `eq 77` was only ever a proxy for that. It is a poor
--    proxy in both directions:
--      · it goes RED on an authorised mint that flips nothing (what happened here), and
--      · it stays GREEN if one edge flips to boonz_wh while one new venue edge is minted -
--        the exact arithmetic that just occurred, one mint away from hiding a real flip.
--    Two assertions replace it and neither can be fooled that way:
--      seq 8 (restated) `vox_venue_pre_aug` eq 77 - the S-10 exposure cohort as it stood BEFORE
--        2026-08-01, pinned EXACTLY. This set is closed history: no future mint can enlarge it,
--        and superseding any member shrinks it, so the pin is both exact and drift-proof.
--      seq 21 (new)     `vox_boonz_wh`      eq 0  - the failure mode stated DIRECTLY. Any member
--        of the S-10 exposure families that resolves to boonz_wh on a co_managed machine reds
--        this, whatever the venue count happens to be.
--    `vox_venue_edges` (80 today) is still computed and still written to golden.scratch for any
--    leg that wants the live number. ⭐ Recording and asserting are different jobs (S-301).
--
-- ⏸️ NOT SILENTLY BLESSED. The three Fade Fit - Coconut edges remain behind S-285's OPEN CS ask
--    ("confirm Fade Fit - Coconut really is venue-supplied"). This migration does not ratify
--    them - it stops a tripwire aimed at a DIFFERENT failure from standing red over them. If CS
--    rules the mapping wrong, the mapping and the edges are reverted together and seq 8's pinned
--    cohort of 77 is untouched by that revert, because none of the 77 is one of the six.

DO $do$
DECLARE
  v_scen   text;
  v_new    text;
  v_before text;
BEGIN
  SELECT scenario_sql INTO v_scen FROM golden.fixtures WHERE fixture_id = 30;
  IF v_scen IS NULL THEN
    RAISE EXCEPTION 'REFUSED: fixture 30 has no scenario_sql.';
  END IF;

  -- S-298: count the anchors exactly. A guard that refuses a correct migration is also a failure,
  -- so each anchor is required to appear EXACTLY once - not "at least once", not "at most once".
  IF (length(v_scen) - length(replace(v_scen, '  v_vox_venue      bigint;', ''))) / length('  v_vox_venue      bigint;') <> 1
  THEN RAISE EXCEPTION 'REFUSED: the v_vox_venue declaration is not present exactly once.'; END IF;

  IF (length(v_scen) - length(replace(v_scen, '    ''vox_venue_edges'',    v_vox_venue::text,', ''))) / length('    ''vox_venue_edges'',    v_vox_venue::text,') <> 1
  THEN RAISE EXCEPTION 'REFUSED: the vox_venue_edges payload line is not present exactly once.'; END IF;

  IF position('vox_venue_pre_aug' in v_scen) > 0 THEN
    RAISE EXCEPTION 'REFUSED: fixture 30 already carries vox_venue_pre_aug - already restated.';
  END IF;

  -- (a) two more locals
  v_new := replace(v_scen,
    '  v_vox_venue      bigint;',
    '  v_vox_venue      bigint;' || E'\n' ||
    '  v_vox_pre_aug    bigint;' || E'\n' ||
    '  v_vox_boonz      bigint;');

  -- (b) the two new measurements, taken immediately after the existing tripwire count.
  --     Read from public.product_sourcing directly rather than from fx30_edge: that temp table
  --     is shared by six other measures and does not carry valid_from, and widening it would put
  --     this migration's diff across measures D-30 never authorised. status='Active' is the same
  --     filter fx30_edge applies, restated here so the two sets are provably the same population.
  v_new := replace(v_new,
    '  -- MIXED-POD GUARD. The Coca-Cola family and Mountain Dew on the Soft Drinks Mix pod stay',
    '  -- S-302 / leg 157. The CLOSED-HISTORY half of the S-10 tripwire: the exposure cohort as it'  || E'\n' ||
    '  -- stood before 2026-08-01. No later mint can enlarge this set, so it can be pinned EXACTLY' || E'\n' ||
    '  -- without the counter moving under an authorised write. Superseding a member shrinks it.'   || E'\n' ||
    '  SELECT count(*) INTO v_vox_pre_aug'                                                          || E'\n' ||
    '    FROM public.product_sourcing ps'                                                           || E'\n' ||
    '    JOIN public.machines m ON m.machine_id = ps.machine_id'                                    || E'\n' ||
    '    JOIN public.boonz_products bp ON bp.product_id = ps.boonz_product_id'                      || E'\n' ||
    '   WHERE ps.status = ''Active'' AND m.operating_model = ''co_managed'''                        || E'\n' ||
    '     AND ps.source = ''venue'' AND ps.valid_from < ''2026-08-01'''                             || E'\n' ||
    '     AND (bp.boonz_product_name LIKE ''Fade Fit -%'''                                          || E'\n' ||
    '       OR bp.boonz_product_name LIKE ''VOX %'''                                                || E'\n' ||
    '       OR bp.boonz_product_name = ''Aquafina - Regular'');'                                    || E'\n' ||
    E'\n' ||
    '  -- S-302 / leg 157. The failure mode stated DIRECTLY rather than proxied by a count: any'    || E'\n' ||
    '  -- member of the S-10 exposure families resolving to boonz_wh on a co_managed machine IS'    || E'\n' ||
    '  -- the most-specific-wins regression. This cannot be masked by a simultaneous mint.'         || E'\n' ||
    '  SELECT count(*) INTO v_vox_boonz'                                                            || E'\n' ||
    '    FROM public.product_sourcing ps'                                                           || E'\n' ||
    '    JOIN public.machines m ON m.machine_id = ps.machine_id'                                    || E'\n' ||
    '    JOIN public.boonz_products bp ON bp.product_id = ps.boonz_product_id'                      || E'\n' ||
    '   WHERE ps.status = ''Active'' AND m.operating_model = ''co_managed'''                        || E'\n' ||
    '     AND ps.source = ''boonz_wh'''                                                             || E'\n' ||
    '     AND (bp.boonz_product_name LIKE ''Fade Fit -%'''                                          || E'\n' ||
    '       OR bp.boonz_product_name LIKE ''VOX %'''                                                || E'\n' ||
    '       OR bp.boonz_product_name = ''Aquafina - Regular'');'                                    || E'\n' ||
    E'\n' ||
    '  -- MIXED-POD GUARD. The Coca-Cola family and Mountain Dew on the Soft Drinks Mix pod stay');

  -- (c) both new measures reach the payload; vox_venue_edges is KEPT (recorded, not asserted).
  v_new := replace(v_new,
    '    ''vox_venue_edges'',    v_vox_venue::text,',
    '    ''vox_venue_edges'',    v_vox_venue::text,'   || E'\n' ||
    '    ''vox_venue_pre_aug'',  v_vox_pre_aug::text,' || E'\n' ||
    '    ''vox_boonz_wh'',       v_vox_boonz::text,');

  IF v_new = v_scen THEN
    RAISE EXCEPTION 'REFUSED: scenario_sql unchanged after all three replacements.';
  END IF;
  IF position('vox_venue_pre_aug' in v_new) = 0 OR position('vox_boonz_wh' in v_new) = 0 THEN
    RAISE EXCEPTION 'REFUSED: post-image is missing one of the two new keys.';
  END IF;

  UPDATE golden.fixtures SET scenario_sql = v_new WHERE fixture_id = 30;

  -- ---- seq 8: restated onto the closed-history cohort -------------------------------------
  SELECT check_sql INTO v_before FROM golden.assertions WHERE fixture_id = 30 AND seq = 8;
  IF v_before IS NULL THEN
    RAISE EXCEPTION 'REFUSED: fixture 30 seq 8 does not exist.';
  END IF;
  IF v_before NOT LIKE '%vox_venue_edges%' THEN
    RAISE EXCEPTION 'REFUSED: fixture 30 seq 8 does not read vox_venue_edges (reads: %). '
                    'It has already been restated or renumbered; re-derive before overwriting.', v_before;
  END IF;

  UPDATE golden.assertions
     SET check_sql = 'SELECT value->>''vox_venue_pre_aug'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
         expect_op = 'eq',
         expect    = '77',
         description = 'S-10 TRIPWIRE, CLOSED-HISTORY HALF (restated at leg 157, S-302): the 77 VOX-supplied venue edges that existed on co_managed machines BEFORE 2026-08-01 (Aquafina 11, Fade Fit 44, VOX Cotton Candy 4, VOX Lollies 6, VOX Popcorn 12) are all still venue. Each carries a GLOBAL-DEFAULT venue_team row, so they are correct under ANY-scope and wrong under most-specific-wins; a backfill that reverts to most-specific-wins re-sources VOX goods to Boonz WH and undoes P0.4. ⛔ This seq previously pinned the LIVE count at 77 and went red at leg 156 when leg 151 minted three authorised Fade Fit - Coconut venue edges (valid_from 2026-08-08 10:06:34Z) mirroring a CS product_mapping decision - the tripwire fired over a write that flipped nothing. Worse, the live count would have stayed 77 if one edge had flipped to boonz_wh while one was minted. The cohort below is closed history: no mint can enlarge it and superseding a member shrinks it, so the pin is exact AND drift-proof. ⭐ The live count is still computed and recorded in golden.scratch as vox_venue_edges (80 at leg 157) - recording and asserting are different jobs. The over-correction itself is now asserted DIRECTLY by seq 21. Never fix this by weakening either half.'
   WHERE fixture_id = 30 AND seq = 8;

  -- ---- seq 21: the failure mode, stated directly -------------------------------------------
  IF EXISTS (SELECT 1 FROM golden.assertions WHERE fixture_id = 30 AND seq = 21) THEN
    RAISE EXCEPTION 'REFUSED: fixture 30 seq 21 already exists - renumber before inserting.';
  END IF;

  INSERT INTO golden.assertions (fixture_id, seq, description, check_sql, expect_op, expect, enabled, phase_required)
  VALUES (30, 21,
    'S-10 TRIPWIRE, THE FAILURE MODE STATED DIRECTLY (new at leg 157, S-302): ZERO edges in the S-10 exposure families (Fade Fit *, VOX *, Aquafina - Regular) resolve to boonz_wh on a co_managed machine. This is what a most-specific-wins backfill actually does, and unlike a population count it cannot be masked by a simultaneous authorised mint: seq 8 plus this pair goes red on a flip whether or not the venue total is restored by new rows. Measured 0 at leg 157.',
    'SELECT value->>''vox_boonz_wh'' FROM golden.scratch WHERE fixture_id={{fixture_id}} AND key=''obs''',
    'eq', '0', true, 'P1');
END
$do$;
