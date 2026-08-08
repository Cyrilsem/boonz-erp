-- PRD-110 · D-27(a) · leg 150
-- RESTATE the two resolve_supply_ladder_v3 md5 sentinels that D-27(a) legitimately moved.
--
-- Fixtures 6 (seq 50) and 44 (seq 28) each pin md5(prosrc) of resolve_supply_ladder_v3 to
-- 920b32d09cb4582076da775a0f5123e3 and assert "byte-untouched by this unit". D-27(a) moved
-- that body ON PURPOSE (rung 4 now reads public.v_m2m_donor_surplus), so BOTH went red in the
-- leg-150 blast radius. ⭐ That is the sentinels working, not failing - they are the reason the
-- change could not land silently.
--
-- ⛔ S-272: a restatement must move `expect` AND `description` together, keeping the SHAPE of
--    check_sql. The check_sql is untouched here; only the pinned value and the prose move, so
--    the assertion still fails on ANY future unreviewed edit to the ladder.
-- ⛔ NEVER weaken these to `not_null` (S-103). The whole value is that they are exact.
--
-- ⚠️ D-37 WILL MOVE THIS BODY AGAIN. `ladder_prefer_own_stock_transfer` is an engine change to
--    this same 16,996-character function (leg-149 addendum sequencing landmine). When D-37 lands
--    it must restate these two sentinels a THIRD time - and re-derive the value, never guess it.

UPDATE golden.assertions
   SET expect = '056cca45077bb00f31ab663409d4c573',
       description = 'LAW 3: resolve_supply_ladder_v3 carries the D-27(a) body and no other. '
         || 'Restated at leg 150 (was 920b32d0…, the post-S-85 body): D-27(a) moved rung 4 off its '
         || 'inline copy of the overstock rule and onto the canonical public.v_m2m_donor_surplus, '
         || 'which list_m2m_donors_v3 also reads. Fixture 6 RECORDS the rung order, it does not '
         || 'change it. ⛔ Any OTHER movement of this md5 is an unreviewed engine edit - and D-37 '
         || '(ladder_prefer_own_stock_transfer) is the next authorised one, so re-derive this '
         || 'value when D-37 lands rather than assuming it.'
 WHERE fixture_id = 6 AND seq = 50;

UPDATE golden.assertions
   SET expect = '056cca45077bb00f31ab663409d4c573',
       description = 'The ladder carries the D-27(a) body and no other (LAW 3). Restated at leg '
         || '150 (was 920b32d0…, the post-S-85 body): rung 4 now reads the canonical '
         || 'public.v_m2m_donor_surplus instead of its own verbatim copy of the overstock rule. '
         || '⛔ Any OTHER movement of this md5 is an unreviewed engine edit; D-37 is the next '
         || 'authorised one and must re-derive this value.'
 WHERE fixture_id = 44 AND seq = 28;

-- Both rows must exist and must have moved. A silent 0-row UPDATE would leave the fixtures red
-- and the next leg hunting a phantom regression.
DO $verify$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM golden.assertions
   WHERE (fixture_id, seq) IN ((6,50),(44,28))
     AND expect = '056cca45077bb00f31ab663409d4c573';
  IF n <> 2 THEN
    RAISE EXCEPTION 'D-27(a) RESTATE: expected 2 restated sentinels, found % - the (fixture,seq) coordinates drifted', n;
  END IF;

  -- The pinned value must be the LIVE one, re-derived here rather than copied from the header.
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'resolve_supply_ladder_v3'
     AND md5(p.prosrc) = '056cca45077bb00f31ab663409d4c573';
  IF n <> 1 THEN
    RAISE EXCEPTION 'D-27(a) RESTATE: the pinned md5 does not match the live resolve_supply_ladder_v3 body';
  END IF;
END $verify$;
