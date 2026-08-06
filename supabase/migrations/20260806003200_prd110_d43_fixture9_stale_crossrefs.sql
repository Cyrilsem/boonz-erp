-- PRD-110 · D-43 — the two fixture-9 descriptions that survived the re-base still describing the
-- old system. Text only: no expect, no check_sql, no expect_op is touched anywhere in this file.
--
-- ⛔ WHY THIS IS ITS OWN MIGRATION RATHER THAN A SILENT EDIT INTO 20260806003100. That migration is
-- the RE-BASE, and its whole claim is "these ten sensors went red and here is why". Folding two
-- unrelated text corrections into it would blur which lines were the proof. Forward-only, one
-- concern per migration (Article 12).
--
-- ⭐ BOTH ARE CROSS-REFERENCES THAT WENT STALE THE MOMENT THEIR TARGETS MOVED — the failure mode
-- S-103 is about. Neither assertion is wrong; both now explain themselves by pointing at a
-- statement that is no longer true:
--   · seq 1  said "when D-43 is executed this is one of the two assertions that must change".
--            D-43 IS executed and seq 1 did NOT change — option (a) leaves repack's own gate
--            intact, so only seq 2 moved. Leg 108 wrote "1-2"; leg 133's recon called it half
--            right; leg 134 measured it. The corrected text records that, so the next leg does
--            not go looking for a change that was never owed.
--   · seq 14 said it is "what makes assertion 13 mean the freeze". Assertion 13 no longer means
--            the freeze — after S-193 its zero means idempotency — so seq 14's anti-confound job
--            now attaches to 9/11/74, and the text says so.
--
-- Cody: Article 12 (forward-only) · Article 16 (no metric touched). golden.* is harness metadata.

UPDATE golden.assertions SET
  description = $d$⭐ repack_machine ADMITS the warehouse role, read from prosrc so the fact is pinned in the source and not only in behaviour. ⛔ MEASURED AT D-43 EXECUTION (leg 134): this assertion did NOT move and was never owed a move. CS chose option (a) — widen push — so repack's own gate is untouched and seq 2 is the only half-1 sensor. The leg-108 note "seq 1-2 go red" was half right and leg 133's recon called it before the fact. ⛔ Under option (b) — drop warehouse FROM repack — this is the assertion that would have flipped instead.$d$
WHERE fixture_id=9 AND seq=1;

UPDATE golden.assertions SET
  description = $d$⛔ S-195, THE ANTI-CONFOUND GUARD. A plant with a NULL pod_product_id makes push report lines_skipped_null_product and move nothing — INDISTINGUISHABLE from a genuine zero-push. Leg 107 nearly recorded a false root cause on exactly that. ⚠️ It used to be what made assertion 13 mean the freeze; after S-193 assertion 13's zero means idempotency, so this now backs seq 9/11/74 instead: it proves the push counts they read were produced by the real path and not by a line silently dropped for a missing product.$d$
WHERE fixture_id=9 AND seq=14;
