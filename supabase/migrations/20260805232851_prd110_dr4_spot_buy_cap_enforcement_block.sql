-- PRD-110 · DR-4 EXECUTE — spot-buy pre-auth cap enforcement: 'warn' -> 'block'.
--
-- CS RULING (2026-08-04, POST-DONE DR REGISTER): "DR-4 CLOSED: AED 15 CONFIRMED; FLIP
-- spot_buy_cap_enforcement TO 'block'." The cap VALUE is unchanged at AED 15 — only the
-- enforcement mode moves. Both writers already carry the branch and have since P4.4:
--   · create_spot_purchase_v3          (warehouse path)
--   · receive_dispatch_line_sourced_v3 (driver path — deliberately capped too, or the cap would
--                                       be advisory in the one place a human stands at a till)
-- Neither branch fires unless a line's unit price actually EXCEEDS the cap, so the flip changes
-- nothing for an in-policy purchase; it converts an over-cap purchase from a warning into a
-- refusal.
--
-- ⛔ THE FIXTURE RE-BASELINE SHIPS IN THIS SAME TRANSACTION, NOT AFTERWARDS. Fixture 18 seq 5 is
-- the ONLY assertion in the harness reading this dial and it pins 'warn' on purpose — its own
-- description says "the day CS flips it this goes RED, which is the assertion working."
-- Landing the flip without the re-baseline would leave golden red between two migrations.
-- S-103 obeyed: `expect` AND `description` move together; never weakened to not_null.
--
-- ⭐ seq 4 (cap still defaults to 15) and seq 6 (CHECK constrains the three legal modes) are
-- DELIBERATELY UNTOUCHED — they are what stop this flip from being paired with a silent cap
-- change or a typo like 'blocked' that would disable the cap altogether.
--
-- Article 5: a status/mode transition made by an explicit, audited statement rather than an
-- arbitrary FE write. Article 12: forward-only.

UPDATE public.refill_policy_params
   SET spot_buy_cap_enforcement = 'block';

UPDATE golden.assertions
   SET expect = 'block',
       description = 'the cap ENFORCEMENT dial is ''block'' — DR-4 EXECUTED (CS ruling 2026-08-04, applied leg 132). Cap value stays AED 15 (seq 4). An over-cap spot line is now REFUSED by both create_spot_purchase_v3 and receive_dispatch_line_sourced_v3, not merely warned. Re-baseline expect AND description together (S-103) if it ever moves again.'
 WHERE fixture_id = 18 AND seq = 5;
